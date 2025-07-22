local jecs = require(script.Parent.Parent.roblox_packages.jecs)
local utils = require(script.Parent.utils)
local common = require(script.Parent.common)
local masking_controller = require(script.Parent.masking)

type Cursor = utils.Cursor

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }

type TrackInfo = {
	entities: { [jecs.Entity]: boolean },
	components: { [jecs.Entity]: { [jecs.Entity]: number } },
}

type EntityStorage = {
	tags: { [jecs.Entity]: boolean },
	values: { [jecs.Entity]: any },
	pairs: { [jecs.Entity]: Set<jecs.Entity> },
}

type Storage = { [jecs.Entity]: EntityStorage }

export type Server = {
	world: jecs.World,
	inited: boolean?,

	shared: common.Shared,

	components: common.Components,
	hooks: common.WorldHooks,
	alive_tracked: { [jecs.Entity]: boolean },

	track_info: TrackInfo,
	additions: { [jecs.Entity]: boolean },
	custom_ids: { [jecs.Entity]: jecs.Entity },
	storage: Storage,
	hooked: { () -> () },
	masking: masking_controller.MaskingController,

	init: (self: Server, world: jecs.World) -> (),
	get_full: (self: Server, player: Player) -> (),
	destroy: (self: Server) -> (),
}

local NIL_COMPONENT_VALUE = newproxy()

local COMPONENT_TYPES = masking_controller.COMPONENT_TYPES
local TRACK_TYPES = {
	component = 1,
	tag = 2,
	pair = 3,
}

local function track_entity_lifetime(server: Server, entity: jecs.Entity)
	if server.alive_tracked[entity] then
		return
	end
	server.alive_tracked[entity] = true
	server.world:add(entity, server.components.__alive_tracking__)
end

local function get_or_set_entity_storage(server: Server, entity: jecs.Entity)
	local storage = server.storage[entity]

	if not storage then
		storage = {
			tags = {},
			values = {},
			pairs = {},
		}
		server.storage[entity] = storage
	end

	return storage
end

local function allocate_component_change(server: Server, entity: jecs.Entity, component: jecs.Entity, value: any)
	local storage = get_or_set_entity_storage(server, entity)
	local non_nil = if value == nil then NIL_COMPONENT_VALUE else value

	storage.values[component] = non_nil
	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_component_change(entity, component, non_nil)
	end
end
local function allocate_tag_addition(server: Server, entity: jecs.Entity, tag: jecs.Entity)
	local storage = get_or_set_entity_storage(server, entity)
	storage.tags[tag] = true

	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_tag_addition(entity, tag)
	end
end
local function allocate_pair_addition(server: Server, entity: jecs.Entity, relation: jecs.Entity, target: jecs.Entity)
	local storage = get_or_set_entity_storage(server, entity)
	local targets = storage.pairs[relation]
	if targets == nil then
		targets = {}
		storage.pairs[relation] = targets
	end
	targets[target] = true

	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_pair_addition(entity, relation, target)
	end
end

local function allocate_component_removal(server: Server, entity: jecs.Entity, component: jecs.Entity)
	local storage = get_or_set_entity_storage(server, entity)
	storage.values[component] = nil

	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_component_removal(entity, component)
	end
end
local function allocate_tag_removal(server: Server, entity: jecs.Entity, tag: jecs.Entity)
	local storage = get_or_set_entity_storage(server, entity)
	storage.tags[tag] = nil

	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_tag_removal(entity, tag)
	end
end
local function allocate_pair_removal(server: Server, entity: jecs.Entity, relation: jecs.Entity, target: jecs.Entity)
	local storage = get_or_set_entity_storage(server, entity)
	local targets = storage.pairs[relation]
	if targets then
		targets[target] = nil
	end

	if not server.additions[entity] and server.track_info.entities[entity] then
		server.masking:allocate_pair_removal(entity, relation, target)
	end
end

local function track_component(server: Server, component: jecs.Entity<any>)
	local world = server.world
	local hooks = server.hooks

	local info = {}
	server.track_info.components[component] = info

	local function hook(unhook: () -> ())
		table.insert(server.hooked, unhook)
	end

	hook(hooks.added(world, component, function(entity, id, value)
		local track_type = info[entity]
		if not track_type then
			return
		end

		if track_type == TRACK_TYPES.component then
			allocate_component_change(server, entity, component, value)
		elseif track_type == TRACK_TYPES.tag then
			allocate_tag_addition(server, entity, component)
		else
			if not jecs.IS_PAIR(id) then
				return error "a non-pair tag was added to a pair tracked component"
			end
			allocate_pair_addition(server, entity, component, jecs.pair_second(world, id))
		end
	end))
	hook(hooks.changed(world, component, function(entity, id, value)
		local track_type = info[entity]
		if not track_type then
			return
		end

		-- no check here because only components can trigger changed (I think?)
		allocate_component_change(server, entity, component, value)
	end))
	hook(hooks.removed(world, component, function(entity, id)
		local track_type = info[entity]
		if not track_type then
			return
		end

		if track_type == TRACK_TYPES.component then
			allocate_component_removal(server, entity, component)
		elseif track_type == TRACK_TYPES.tag then
			allocate_tag_removal(server, entity, component)
		else
			if not jecs.IS_PAIR(id) then
				return error "a non-pair tag was removed for a pair tracked component"
			end
			allocate_pair_removal(server, entity, component, jecs.pair_second(world, id))
		end
	end))

	return info
end

local function track_entity_component(server: Server, entity: jecs.Entity, component: jecs.Entity<any>)
	local world = server.world

	local info = server.track_info.components[component]
	if not info then
		info = track_component(server, component)
	end

	local entity_storage = get_or_set_entity_storage(server, entity)

	if world:has(component, jecs.Component) then
		-- component
		if world:has(entity, component) then
			local value = world:get(entity, component)

			if value == nil then
				entity_storage.values[component] = NIL_COMPONENT_VALUE
			else
				entity_storage.values[component] = value
			end
		end

		info[entity] = TRACK_TYPES.component

		return COMPONENT_TYPES.component
	else
		-- tag
		if world:has(entity, component) then
			entity_storage.tags[component] = true
		end
		info[entity] = TRACK_TYPES.tag

		return COMPONENT_TYPES.tag
	end
end

local function track_entity_pair(server: Server, entity: jecs.Entity, relation: jecs.Entity)
	local world = server.world
	local info = server.track_info.components[relation]
	if not info then
		info = track_component(server, relation)
	end

	local entity_storage = get_or_set_entity_storage(server, entity)
	local targets = {}
	local index = 0

	while true do
		local target = world:target(entity, relation, index)
		if not target then
			break
		end
		index += 1
		targets[target] = true
	end
	entity_storage.pairs[relation] = targets

	info[entity] = TRACK_TYPES.pair
end

local function untrack_entity_component(server: Server, entity: jecs.Entity, component: jecs.Entity<any>): number?
	local info = server.track_info.components[component]
	if not info then
		return
	end
	local listen_type = info[entity]
	info[entity] = nil

	local storage = server.storage[entity]
	if storage then
		storage.values[component] = nil
		storage.tags[component] = nil
	end

	return listen_type
end

local function untrack_entity_pair(server: Server, entity: jecs.Entity, relation: jecs.Entity)
	local info = server.track_info.components[relation]
	if not info then
		return
	end
	info[entity] = nil

	local storage = server.storage[entity]
	if storage then
		storage.pairs[relation] = nil
	end
end

local function init(server: Server, world: jecs.World)
	if server.inited then
		return warn "attempted to init a server twice"
	end
	if server.inited == nil then
		return warn "attempted to re-init a destroyed server"
	end
	server.inited = true
	server.world = world

	local hooks: common.WorldHooks = {
		added = (world :: any).added,
		changed = (world :: any).changed,
		removed = (world :: any).removed,
	}
	server.hooks = hooks

	local components = server.components
	local masking = server.masking

	server.shared = utils.create_shared_lookup(world, components)

	local function hook(unhook: () -> ())
		table.insert(server.hooked, unhook)
	end

	hook(hooks.added(world, components.networked, function(entity, id, filter)
		masking:unregister_stop_entity(entity)
		masking:start_entity(entity, filter)
		masking:propagate_entity_addition(entity)

		server.additions[entity] = true
		server.track_info.entities[entity] = true
		track_entity_lifetime(server, entity)
	end))
	hook(hooks.changed(world, components.networked, function(entity, id, filter)
		masking:set_entity(entity, filter)
	end))
	hook(hooks.removed(world, components.networked, function(entity)
		masking:register_stop_entity(entity)
		masking:stop_entity(entity)

		server.additions[entity] = nil
		server.track_info.entities[entity] = nil
	end))

	hook(hooks.added(world, components.reliable, function(entity, id, filter)
		if not jecs.IS_PAIR(id) then
			return error "reliable should be used with a pair relationship"
		end
		local component = jecs.pair_second(world, id)

		local component_type = track_entity_component(server, entity, component)
		masking:unregister_stop_component(entity, component, component_type)
		masking:start_component(entity, component, component_type, filter)
		if server.additions[entity] then
			masking:allocate_entity_addition(entity, component, component_type)
		end
	end))
	hook(hooks.changed(world, components.reliable, function(entity, id, filter)
		if not jecs.IS_PAIR(id) then
			return error "reliable should be used with a pair relationship"
		end
		local component = jecs.pair_second(world, id)

		if world:has(component, jecs.Component) then
			masking:set_component(entity, component, COMPONENT_TYPES.component, filter)
		else
			masking:set_component(entity, component, COMPONENT_TYPES.tag, filter)
		end
	end))

	hook(hooks.removed(world, components.reliable, function(entity, id)
		if not jecs.IS_PAIR(id) then
			return error "reliable should be used with a pair relationship"
		end
		local component = jecs.pair_second(world, id)
		local component_type = untrack_entity_component(server, entity, component)
		if not component_type then
			return
		end
		masking:register_stop_component(entity, component, component_type)
		masking:stop_component(entity, component, component_type)
	end))

	hook(hooks.added(world, components.pair, function(entity, id, filter)
		if not jecs.IS_PAIR(id) then
			return error "pair should be used with a relationship"
		end
		local relation = jecs.pair_second(world, id)
		track_entity_pair(server, entity, relation)
		masking:unregister_stop_component(entity, relation, COMPONENT_TYPES.pair)
		masking:start_component(entity, relation, COMPONENT_TYPES.pair, filter)
	end))
	hook(hooks.changed(world, components.pair, function(entity, id, filter)
		if not jecs.IS_PAIR(id) then
			return error "reliable should be used with a pair relationship"
		end
		local relation = jecs.pair_second(world, id)
		masking:set_component(entity, relation, COMPONENT_TYPES.pair, filter)
	end))
	hook(hooks.removed(world, components.pair, function(entity, id)
		if not jecs.IS_PAIR(id) then
			return error "reliable should be used with a pair relationship"
		end
		local relation = jecs.pair_second(world, entity)
		untrack_entity_pair(server, entity, relation)
		masking:register_stop_component(entity, relation, COMPONENT_TYPES.pair)
		masking:stop_component(entity, relation, COMPONENT_TYPES.pair)
	end))

	hook(hooks.removed(world, components.__alive_tracking__, function(entity) end))

	hook(hooks.added(world, components.custom_id, function(entity, id)
		if not jecs.IS_PAIR(id) then
			return error "custom_id should be used with a relationship"
		end
		local target = jecs.pair_second(world, id)
		if not target then
			error "custom_id should be used with a relationship in the server"
		end
		if server.custom_ids[entity] then
			return warn("attempted to register a custom_id pair twice for the same entity", debug.traceback())
		end

		server.custom_ids[entity] = target
	end))

	hook(hooks.removed(world, components.custom_id, function(entity, id)
		server.custom_ids[entity] = nil
	end))
end

local function destroy(server: Server) end
local function get_full(server: Server, member: Player) end

local function collect_reliable(server: Server) end
local function collect_unreliable(server: Server) end

local server = {}
server.__index = server
server.init = init
server.destroy = destroy
server.get_full = get_full
server.collect_reliable = collect_reliable
server.collect_unreliable = collect_unreliable

local function create(components: common.Components): Server
	local self = {} :: Server

	self.components = components

	self.shared = {} :: common.Shared

	self.additions = {}
	self.storage = {}
	self.hooked = {}
	self.track_info = {
		entities = {},
		components = {},
	}

	self.inited = false
	self.masking = masking_controller.create()
	self.alive_tracked = {}
	self.custom_ids = {}

	return setmetatable(self, server) :: any
end

server.create = create

return server :: { create: typeof(create) }
