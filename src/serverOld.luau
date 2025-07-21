--!native
--!optimize 2

local Jecs = require(script.Parent.Parent.jecs)
local utils = require(script.Parent.utils)
local Common = require(script.Parent.common)
local Masking = require(script.Parent.masking)

type Cursor = utils.Cursor

local cursor = utils.cursor

type ServerInfo = {
	entities: { [Jecs.Entity]: boolean },
	components: { [Jecs.Entity]: { [Jecs.Entity]: number } },
}
type Changes = {
	-- entity
	added: { [Jecs.Entity]: boolean },
	deleted: { [Jecs.Entity]: boolean },

	-- data
	changed: {
		[Jecs.Entity]: {
			-- these can be nil.
			tagged: { [Jecs.Entity]: boolean },
			component: { [Jecs.Entity]: any },
			removed: { [Jecs.Entity]: boolean },
			pairs: { [Jecs.Entity]: Jecs.Entity },
		},
	},
}

type EntityStorage = {
	tags: { [Jecs.Entity]: boolean },
	values: { [Jecs.Entity]: any },
	pairs: { [Jecs.Entity]: Jecs.Entity },
}

type Storage = { [Jecs.Entity]: EntityStorage }

export type Server = {
	world: Jecs.World,
	inited: boolean?,

	shared: Common.Shared,

	components: Common.Components,
	hooks: Common.WorldHooks,
	lifetime_tracking: { [Jecs.Entity]: boolean },

	info: ServerInfo,
	custom_ids: { [Jecs.Entity]: Jecs.Entity },
	storage: Storage,
	changes: Changes,
	hooked: { () -> () },
	masking: Masking.MaskingController,

	init: (self: Server) -> (),

	get_full: (self: Server, player: Player) -> (),
	destroy: (self: Server) -> (),
	collect_reliable: (self: Server) -> (),
	collect_unreliable: (self: Server) -> (),
}

local NIL_COMPONENT_VALUE = newproxy()
local NO_PAIR_VALUE = newproxy()

-- [[ ENTITY TRACKING ]] --

local function track_entity_lifetime(server: Server, entity: Jecs.Entity)
	if server.lifetime_tracking[entity] then
		return
	end
	server.lifetime_tracking[entity] = true
	server.world:add(entity, server.components.__alive_tracking__)
end

local function cleanup_deleted_entity(server: Server, entity: Jecs.Entity)
	server.lifetime_tracking[entity] = nil
	server.storage[entity] = nil
end

local function get_entity_storage(server: Server, entity: Jecs.Entity)
	local storage = server.storage[entity]
	if not storage then
		track_entity_lifetime(server, entity)

		storage = {
			tags = {},
			values = {},
			pairs = {},
		}
		server.storage[entity] = storage
	end
	return storage
end

local function get_entity_changed(server: Server, entity: Jecs.Entity)
	local changed = server.changes.changed[entity]
	if changed == nil then
		changed = {} :: any
		server.changes.changed[entity] = changed
	end
	return changed
end

local function allocate_component_change(server: Server, entity: Jecs.Entity, component: Jecs.Entity, value: any)
	local storage = get_entity_storage(server, entity)
	local non_nil = if value == nil then NIL_COMPONENT_VALUE else value

	storage.values[component] = non_nil

	if not server.changes.added[entity] and server.info.entities[entity] then
		local changed = get_entity_changed(server, entity)
		local changed_component = changed.component
		if changed_component == nil then
			changed_component = {}
			changed.component = changed_component
		end

		changed_component[component] = non_nil
	end
end

local function allocate_component_removal(server: Server, entity: Jecs.Entity, component: Jecs.Entity)
	local storage = get_entity_storage(server, entity)
	storage.values[component] = nil

	if not server.changes.added[entity] and server.info.entities[entity] then
		local changed = get_entity_changed(server, entity)
		local removed = changed.removed
		if removed == nil then
			removed = {}
			changed.removed = removed
		end
		removed[component] = true
	end
end

local function allocate_tag_change(server: Server, entity: Jecs.Entity, tag: Jecs.Entity, added: boolean)
	local storage = get_entity_storage(server, entity)
	if added then
		storage.tags[tag] = true
	else
		storage.tags[tag] = nil
	end

	if not server.changes.added[entity] and server.info.entities[entity] then
		local changed = get_entity_changed(server, entity)
		local tagged = changed.tagged
		if tagged == nil then
			tagged = {}
			changed.tagged = tagged
		end
		local removed = changed.removed

		if added then
			tagged[tag] = true
			if removed then
				removed[tag] = nil
			end
		else
			tagged[tag] = nil
			if removed then
				removed[tag] = true
			else
				changed.removed = { [tag] = true }
			end
		end
	end
end

local function allocate_pair_change(server: Server, entity: Jecs.Entity, relation: Jecs.Entity)
	local target = server.world:target(entity, relation)
	if not target then
		return
	end

	local storage = get_entity_storage(server, entity)
	storage.pairs[relation] = target

	if not server.changes.added[entity] and server.info.entities[entity] then
		local changed = get_entity_changed(server, entity)
		local pairs = changed.pairs
		if pairs == nil then
			pairs = {}
			changed.pairs = pairs
		end
		pairs[relation] = target
	end
end

local function allocate_pair_removal(server: Server, entity: Jecs.Entity, relation: Jecs.Entity)
	local storage = get_entity_storage(server, entity)
	storage.pairs[relation] = nil

	if not server.changes.added[entity] and server.info.entities[entity] then
		local changed = get_entity_changed(server, entity)
		local pairs = changed.pairs
		if pairs == nil then
			pairs = {}
			changed.pairs = pairs
		end
		pairs[relation] = NO_PAIR_VALUE
	end
end

local function listen_component(server: Server, component: Jecs.Entity)
	local world = server.world
	local hooks = server.hooks

	local listening_set = {}
	server.info.components[component] = listening_set

	hooks.added(world, component, function(entity, id, value)
		local listen_type = listening_set[entity]
		if not listen_type then
			return
		end

		if listen_type == 0 then
			allocate_component_change(server, entity, component, value)
		elseif listen_type == 1 then
			allocate_tag_change(server, entity, component, true)
		else
			allocate_pair_change(server, entity, component)
		end
	end)

	hooks.changed(world, component, function(entity, id, value)
		local listen_type = listening_set[entity]
		if not listen_type then
			return
		end

		-- no listen_type check here because setting a value to a tag/pair shouldnt be possible/supported
		allocate_component_change(server, entity, component, value)
	end)

	hooks.removed(world, component, function(entity)
		local listen_type = listening_set[entity]
		if not listen_type then
			return
		end

		if listen_type == 0 then
			allocate_component_removal(server, entity, component)
		elseif listen_type == 1 then
			allocate_tag_change(server, entity, component, false)
		else
			allocate_pair_removal(server, entity, component)
		end
	end)

	return listening_set
end

local function track_entity_component(server: Server, entity: Jecs.Entity, component: Jecs.Entity<any>)
	local world = server.world

	local listening_set = server.info.components[component]
	if listening_set == nil then
		listening_set = listen_component(server, component)
	end

	local entity_storage = get_entity_storage(server, entity)

	if world:has(component, Jecs.Component) then
		-- component
		if world:has(entity, component) then
			local value = world:get(entity, component)

			if value == nil then
				entity_storage.values[component] = NIL_COMPONENT_VALUE
			else
				entity_storage.values[component] = value
			end
		end

		listening_set[entity] = 0
	else
		-- tag
		entity_storage.tags[component] = world:has(entity, component)
		listening_set[entity] = 1
	end
end

local function untrack_entity_component(server: Server, entity: Jecs.Entity, component: Jecs.Entity<any>)
	local listening_set = server.info.components[component]
	if listening_set == nil then
		return
	end
	listening_set[entity] = nil
	local storage = server.storage[entity]

	if storage then
		storage.tags[component] = nil
		storage.values[component] = nil
	end
end

local function track_entity_pair(server: Server, entity: Jecs.Entity, relation: Jecs.Entity)
	local listening_set = server.info.components[relation]
	if not listening_set then
		listening_set = listen_component(server, relation)
	end

	local entity_storage = get_entity_storage(server, entity)

	local target = server.world:target(entity, relation)

	if target then
		entity_storage.pairs[relation] = target
	end
	listening_set[entity] = 2
end

local function untrack_entity_pair(server: Server, entity: Jecs.Entity, relation: Jecs.Entity)
	local listening_set = server.info.components[relation]
	if not listening_set then
		return
	end
	listening_set[entity] = nil

	local storage = server.storage[entity]
	if storage then
		storage.pairs[relation] = nil
	end
end

local function on_network_start(server: Server, entity: Jecs.Entity, filter: Common.PlayerFilter)
	server.masking:start_entity(entity, nil)

	track_entity_lifetime(server, entity)
	server.info.entities[entity] = true
	server.changes.added[entity] = true
	server.changes.deleted[entity] = nil

	-- latest state will be given when the entity is created
	server.changes.changed[entity] = nil
end

local function on_network_stop(server: Server, entity: Jecs.Entity)
	server.masking:stop_entity(entity)

	server.info.entities[entity] = nil
	if server.changes.added[entity] then
		server.changes.added[entity] = nil
	else
		server.changes.deleted[entity] = true
	end
	server.changes.changed[entity] = nil
end

local function init(server: Server)
	if server.inited then
		return warn "attempted to init a server twice"
	end
	if server.inited == nil then
		return warn "attempted to re-init a destroyed server"
	end
	server.inited = true

	local world = server.world
	local added = server.hooks.added
	local changed = server.hooks.changed
	local removed = server.hooks.removed
	local components = server.components

	assert(added, "added hook not found")
	assert(changed, "changed hook not found")
	assert(removed, "removed hook not found")

	server.shared = utils.create_shared_lookup(world, components)
	server.masking:init()

	local function hook(unhook: () -> ())
		table.insert(server.hooked, unhook)
	end

	hook(added(world, components.networked, function(entity, id, filter)
		on_network_start(server, entity, filter)
	end))
	hook(removed(world, components.networked, function(entity)
		on_network_stop(server, entity)
	end))
	hook(changed(world, components.networked, function(entity, id, filter)
		server.masking:set_entity(entity, filter)
	end))

	hook(added(world, components.reliable, function(entity, _, value)
		local component = world:target(entity, components.reliable)
		if not component then
			return warn "reliable should be used with a pair relationship"
		end

		track_entity_component(server, entity, component)
	end))
	hook(removed(world, components.reliable, function(entity)
		local component = world:target(entity, components.reliable)
		if not component then
			return warn "reliable should be used with a pair relationship"
		end

		untrack_entity_component(server, entity, component)
	end))
	hook(changed(world, components.reliable, function(entity, id, component) end))

	hook(added(world, components.pair, function(entity)
		local relation = world:target(entity, components.pair)
		if not relation then
			return warn "pair should be used with a relationship"
		end

		track_entity_pair(server, entity, relation)
	end))
	hook(removed(world, components.pair, function(entity)
		local relation = world:target(entity, components.pair)
		if not relation then
			return warn "pair should be used with a relationship"
		end

		untrack_entity_pair(server, entity, relation)
	end))

	hook(removed(world, components.__alive_tracking__, function(entity)
		cleanup_deleted_entity(server, entity)
	end))

	hook(added(world, components.custom_id, function(entity)
		local target = world:target(entity, components.custom_id)
		if not target then
			error "custom_id should be used with a relationship in the server"
		end
		if server.custom_ids[entity] then
			return warn("attempted to register a custom_id pair twice for the same entity", debug.traceback())
		end

		server.custom_ids[entity] = target
	end))
	hook(removed(world, components.custom_id, function(entity, id)
		server.custom_ids[entity] = nil
	end))
end

-- [[ SERIALIZATION ]] --

local function write_component_id(server: Server, c: Cursor, component: Jecs.Entity)
	local encoded = server.shared.ids[component]
	if not encoded then
		warn("attempted to replicate a non-shared component", server.world:get(component, Jecs.Name), component)
		return
	end
	cursor.writeu8(c, encoded)
end

local function write_component_value(server: Server, c: Cursor, component: Jecs.Entity, value: any, variants: { any })
	local serdes = server.shared.serdes[component]
	if serdes then
		local output = serdes.serialize(value)

		local bytespan = server.shared.bytespan[component]
		cursor.write_buffer(c, output)
		if not bytespan then
			local len = buffer.len(output)
			cursor.write_vlq(c, len)
		end
	else
		table.insert(variants, value)
		cursor.write_vlq(c, #variants)
	end

	write_component_id(server, c, component)
end

local function write_entity_id(server: Server, c: Cursor, entity: Jecs.Entity, variants: { any })
	local custom_id = server.custom_ids[entity]
	if custom_id then
		local value = server.world:get(entity, custom_id)
		write_component_value(server, c, custom_id, value, variants)
		cursor.writeu8(c, 1)
	else
		cursor.writeu32(c, Jecs.ECS_ID(entity :: any) * 256)
	end
end

local function write_entity(
	server: Server,
	c: Cursor,
	entity: Jecs.Entity,
	active: Masking.ActiveComponents,
	variants: { any }
)
	local storage = server.storage[entity]

	local all_pairs = 0
	for relation in active[3] do
		local target = storage.pairs[relation]
		write_entity_id(server, c, target, variants)
		write_component_id(server, c, relation)
		all_pairs += 1
	end
	cursor.write_vlq(c, all_pairs)

	local components = 0

	local tags = 0
	for tag in active[2] do
		local has_tag = storage.tags[tag]
		if has_tag then
			write_component_id(server, c, tag)
			tags += 1
		end
	end
	cursor.write_vlq(c, tags)

	for component in active[1] do
		local value = storage.values[component]
		write_component_value(server, c, component, value, variants)
		write_component_id(server, c, component)
		components += 1
	end
	cursor.write_vlq(c, components)

	write_entity_id(server, c, entity, variants)
end

local function collect_reliable(server: Server)
	local variants = {} :: { any }
	local packets: { [Player]: { packets: {}, size: number } } = {}

	for _, mask_storage in server.masking.active_masks do
		local c = cursor.new()
		local mask_changes = mask_storage.changes

		local changed = 0
		for entity, changes in mask_changes.changed do
			local total_pairs = 0
			for relation, target in changes.pairs do
				write_component_id(server, c, relation)
				local shared_id = server.shared.ids[target]
				if shared_id then
					cursor.writeu8(c, 2)
					cursor.writeu8(c, shared_id)
				else
					write_entity_id(server, c, target, variants)
				end
				total_pairs += 1
			end
			cursor.write_vlq(c, total_pairs)

			local total_components = 0
			for component, value in changes.component do
				write_component_value(server, c, component, value, variants)
				write_component_id(server, c, component)
				total_components += 1
			end
			cursor.write_vlq(c, total_components)

			local total_removed = 0
			for component, value in changes.removed do
				write_component_id(server, c, component)
				total_removed += 1
			end
			cursor.write_vlq(c, total_removed)

			local total_tagged = 0
			for tag in changes.tagged do
				write_component_id(server, c, tag)
				total_tagged += 1
			end
			cursor.write_vlq(c, total_tagged)

			write_entity_id(server, c, entity, variants)
			changed += 1
		end
		cursor.write_vlq(c, changed)

		local total_deleted = 0
		for entity in mask_changes.deleted do
			write_entity_id(server, c, entity, variants)
			total_deleted += 1
		end
		cursor.write_vlq(c, total_deleted)

		local total_added = 0
		for entity in server.changes.added do
			local active = mask_storage.active[entity]
			if not active then
				continue
			end

			write_entity(server, c, entity, variants, active)
			total_added += 1
		end
		cursor.write_vlq(c, total_added)

		local output = cursor.close(c)
		local len = buffer.len(output)
		for _, player in mask_storage.mask.members do
			local player_packets = packets[player]
			if player_packets then
				table.insert(player_packets.packets, output)
				player_packets.size += len
			else
				player_packets = {
					packets = { output },
					size = len,
				}
				packets[player] = player_packets
			end
		end
	end
end

local function collect_unreliable(server: Server) end

local function get_full(server: Server, member: Player): (buffer, { any }?)
	local variants = {} :: { any }
	local c = cursor.new()
	local index = server.masking.player_indexes[member]
	if index == nil then
		return cursor.close(c), nil
	end

	for _, mask_storage in server.masking.active_masks do
		if not mask_storage.mask.bitmask:get(index) then
			continue
		end

		local total_entities = 0

		for entity, active in mask_storage.active do
			write_entity(server, c, entity, active, variants)
			total_entities += 1
		end
		cursor.write_vlq(c, total_entities)
	end

	if #variants > 0 then
		return cursor.close(c), variants
	else
		return cursor.close(c), nil
	end
end

local function destroy(server: Server)
	if server.inited == nil then
		return warn "attempted to destroy a server twice"
	end
	server.inited = nil

	for _, unhook in server.hooked do
		unhook()
	end
	server.masking:destroy()
end

local server = {}
server.__index = server
server.init = init
server.destroy = destroy
server.get_full = get_full
server.collect_reliable = collect_reliable
server.collect_unrealible = collect_unreliable

local function create(world: Jecs.World, components: Common.Components, hooks: Common.WorldHooks): Server
	local self = {} :: Server

	self.world = world
	self.hooks = hooks
	self.components = components

	self.shared = {} :: Common.Shared

	self.storage = {}
	self.hooked = {}
	self.info = {
		entities = {},
		components = {},
	}
	self.inited = false
	self.masking = Masking.create()
	self.lifetime_tracking = {}
	self.custom_ids = {}
	self.changes = {
		added = {},
		deleted = {},

		tagged = {},
		pairs = {},
		changed = {},
		removed = {},
	}

	return setmetatable(self, server) :: any
end

server.create = create

return server :: { create: typeof(create) }
