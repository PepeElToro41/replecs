--!optimize 2
--!native

local utils = require "./utils"
local common = require "./common"
local types = require "./types"
local customid = require "./customid"
local masking_controller = require "./masking"

local cursor = utils.cursor

type Cursor = utils.Cursor
type CustomId = customid.CustomId
type StorageGroup = masking_controller.StorageGroup

type World = common.World
type Entity = common.Entity
type Component<T = any> = common.Component<T>

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }

type FunctionFilter = types.FunctionFilter
type AnyFilter = types.AnyFilter

type CustomIdSerialization = {
	required: Map<Entity, CustomId>,
	cursor_skip: number,
}

type EntityTrackInfo = {
	components: Map<Component, number>,
	pairs: Map<Component, number>,
}

type TrackInfo = {
	networked: Set<Entity>,
	entities: Map<Entity, EntityTrackInfo>,
	components: Map<Component, Map<Entity, number>>,
	pairs: Map<Component, Map<Entity, number>>,
}

type EntityStorage = {
	tags: { [Component]: boolean },
	components: { [Component]: any },
	pair_tags: { [Component]: boolean },
	pair_components: { [Component]: any },

	relations: { [Component]: Set<Entity> },
	relation_values: { [Component]: Map<Entity, any> },
}

type Storage = { [Entity]: EntityStorage }

export type ServerImp = {
	set_networked: (server: Server, entity: Entity, filter: AnyFilter?) -> (),
	set_reliable: (server: Server, entity: Entity, component: Component, filter: AnyFilter?) -> (),
	set_unreliable: (server: Server, entity: Entity, component: Component, filter: AnyFilter?) -> (),
	set_pair: (server: Server, entity: Entity, id: Component, filter: AnyFilter?) -> (),
	set_relation: (server: Server, entity: Entity, relation: Component, filter: AnyFilter?) -> (),

	stop_networked: (server: Server, entity: Entity, keep: boolean?) -> (),
	stop_reliable: (server: Server, entity: Entity, component: Component, keep: boolean?) -> (),
	stop_unreliable: (server: Server, entity: Entity, component: Component, keep: boolean?) -> (),
	stop_pair: (server: Server, entity: Entity, id: Component, keep: boolean?) -> (),
	stop_relation: (server: Server, entity: Entity, relation: Component, keep: boolean?) -> (),

	set_custom: (server: Server, entity: Entity, component: Component | CustomId) -> (),
	remove_custom: (server: Server, entity: Entity) -> (),

	set_serdes: <T>(server: Server, id: Component<T>, serdes: types.Serdes<T>) -> (),
	remove_serdes: (server: Server, id: Component) -> (),
}

export type Server = ServerImp & {
	world: World,
	inited: boolean?,

	shared: types.Shared,

	components: types.Components,
	alive_tracked: Set<Entity>,

	is_shared_dirty: boolean,
	requires_shared_lookup: { Entity },

	track_info: TrackInfo,
	additions: Set<Entity>,
	custom_ids: Map<Entity, CustomId | Entity>,
	global_ids: Map<Entity, number>,
	storage: Storage,
	hooked: Array<() -> ()>,
	masking: masking_controller.MaskingController,
	pending_cleanups: Set<Entity>,
	connections: Array<RBXScriptConnection>,
	function_filters: masking_controller.EntityComponentIndex<FunctionFilter>,

	registered_custom_ids: Map<CustomId, boolean>,
	component_serdes: Map<Component, types.Serdes>,

	init: (self: Server, world: World?) -> (),
	destroy: (self: Server) -> (),

	encode_component: (self: Server, component: Component) -> number,
	decode_component: (self: Server, component: number) -> Component?,
	get_shared_count: (self: Server) -> number,
	register_custom_id: (self: Server, custom_id: CustomId) -> (),

	get_full: (self: Server, player: Player) -> (buffer, { { any } }),
	collect_entity: (self: Server, entity: Entity) -> () -> (Player, buffer, { { any } }),
	collect_updates: (self: Server) -> () -> (Player, buffer, { { any } }),
	collect_unreliable: (self: Server) -> () -> (Player, buffer, { { any } }),

	mark_player_ready: (self: Server, player: Player) -> (),
	is_player_ready: (self: Server, player: Player) -> boolean,

	add_player_alias: (self: Server, client: Player, alias: any) -> (),
	remove_player_alias: (self: Server, alias: any) -> (),

	generate_handshake: (self: Server) -> types.HandshakeInfo,
	verify_handshake: (self: Server, handshake: types.HandshakeInfo) -> (boolean, string?),
}

local server_replicator = {}
server_replicator.__index = server_replicator

local NIL_COMPONENT_VALUE = newproxy()
local GLOBAL_ID_OFFSET = 10

local COMPONENT_TYPES = {
	tag = 1,
	component = 2,
	pair_tag = 3,
	pair_component = 4,
	relation = 5,
	relation_value = 6,
	unreliable = 7,
}

local TRACK_TYPES = {
	tag = 1,
	component = 2,
	pair_tag = 3,
	pair_component = 4,
	relation = 5,
	relation_value = 6,
}

local PACKET_TYPES = {
	full = 1,
	entity = 2,
	updates = 3,
	unreliable = 4,
}

local MAX_PACKET_SIZE = 900
local ENTITY_ID_TYPES = {
	entity = 1,
	custom_handler = 2,
	custom_id = 3,
	shared = 4,
}

local RELATIONSHIPS = common.relationships
local WILDCARD = common.wildcard
local ECS_NAME = common.ecs_name

local IS_PAIR = common.is_pair
local PAIR = common.pair
local PAIR_FIRST = common.pair_first
local PAIR_SECOND = common.pair_second
local WORLD_ADD = common.world_add
local WORLD_HAS = common.world_has
local WORLD_GET = common.world_get
local WORLD_TARGET = common.world_target
local IS_COMPONENT = common.is_component

local LISTEN_RELATION = common.listen_relation

local HOOK_ADDED = common.hook_added
local HOOK_CHANGED = common.hook_changed
local HOOK_REMOVED = common.hook_removed

local HOOK_PAIR_ADDED = HOOK_ADDED
local HOOK_PAIR_CHANGED = HOOK_CHANGED
local HOOK_PAIR_REMOVED = HOOK_REMOVED

local function QUERY_TRACKING_TYPE(server: Server, track_type: Component)
	local world = server.world
	for entity in world.query(PAIR(track_type, WILDCARD)):iter() do
		local index = 0
		while true do
			local target = WORLD_TARGET(world, entity, track_type, index)
			if not target then
				break
			end
			server.set_reliable(server, entity, target, WORLD_GET(world, entity, PAIR(track_type, target)))
			index += 1
		end
	end
end

local function QUERY_CURRENT_NETWORKED(server: Server)
	for entity, filter in server.world.query(server.components.networked):iter() do
		server.set_networked(server, entity, filter)
	end

	if RELATIONSHIPS then
		QUERY_TRACKING_TYPE(server, server.components.reliable)
		QUERY_TRACKING_TYPE(server, server.components.unreliable)
		QUERY_TRACKING_TYPE(server, server.components.relation)
	end
end

local function QUERY_CURRENT_COMPONENTS(server: Server)
	for component, serdes in server.world.query(server.components.serdes):iter() do
		server.component_serdes[component] = serdes
	end
	for entity, id in server.world.query(server.components.global):iter() do
		server.global_ids[entity] = id
	end
end

local function track_entity_lifetime(server: Server, entity: Entity)
	if server.alive_tracked[entity] then
		return
	end
	server.alive_tracked[entity] = true
	WORLD_ADD(server.world, entity, server.components.__alive_tracking__)
end

local function get_or_set_entity_storage(server: Server, entity: Entity): EntityStorage
	local storage: EntityStorage = server.storage[entity]

	if not storage then
		storage = {
			tags = {},
			components = {},
			pair_tags = {},
			pair_components = {},
			relations = {},
			relation_values = {},
		}
		server.storage[entity] = storage
	end

	return storage
end

local function allocate_component_change(server: Server, entity: Entity, component: Component, value: any)
	local storage = get_or_set_entity_storage(server, entity)

	local non_nil = if value == nil then NIL_COMPONENT_VALUE else value
	storage.components[component] = non_nil

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_component_change(entity, component, non_nil)
	end
end

local function allocate_tag_addition(server: Server, entity: Entity, tag: Component)
	local storage = get_or_set_entity_storage(server, entity)
	storage.tags[tag] = true

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_tag_addition(entity, tag)
	end
end

local function allocate_pair_addition(server: Server, entity: Entity, id: Component)
	local storage = get_or_set_entity_storage(server, entity)
	storage.pair_tags[id] = true

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_pair_addition(entity, id)
	end
end

local function allocate_pair_change(server: Server, entity: Entity, id: Component, value: any)
	local storage = get_or_set_entity_storage(server, entity)

	local non_nil = if value == nil then NIL_COMPONENT_VALUE else value
	storage.pair_components[id] = non_nil

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_pair_change(entity, id, non_nil)
	end
end

local function allocate_relation_value_change(
	server: Server,
	entity: Entity,
	relation: Component,
	target: Entity,
	value: any
)
	local storage = get_or_set_entity_storage(server, entity)

	local values = storage.relation_values[relation]
	if values == nil then
		values = {}
		storage.relation_values[relation] = values
	end

	local non_nil = if value == nil then NIL_COMPONENT_VALUE else value
	values[target] = non_nil

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_relation_value_change(entity, relation, target, non_nil)
	end
end

local function allocate_relation_addition(server: Server, entity: Entity, relation: Component, target: Entity)
	local storage = get_or_set_entity_storage(server, entity)
	local targets = storage.relations[relation]
	if targets == nil then
		targets = {}
		storage.relations[relation] = targets
	end
	targets[target] = true

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_relation_addition(entity, relation, target)
	end
end

local function allocate_component_removal(server: Server, entity: Entity, component: Component)
	local storage = get_or_set_entity_storage(server, entity)
	storage.components[component] = nil

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_component_removal(entity, component)
	end
end

local function allocate_tag_removal(server: Server, entity: Entity, tag: Component)
	local storage = get_or_set_entity_storage(server, entity)
	storage.tags[tag] = nil

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_tag_removal(entity, tag)
	end
end

local function allocate_pair_tag_removal(server: Server, entity: Entity, id: Component)
	local storage = get_or_set_entity_storage(server, entity)
	storage.pair_tags[id] = nil

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_pair_tag_removal(entity, id)
	end
end

local function allocate_pair_component_removal(server: Server, entity: Entity, id: Component)
	local storage = get_or_set_entity_storage(server, entity)
	storage.pair_components[id] = nil

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_pair_component_removal(entity, id)
	end
end

local function allocate_relation_value_removal(server: Server, entity: Entity, relation: Component, target: Entity)
	local storage = get_or_set_entity_storage(server, entity)
	local values = storage.relation_values[relation]
	if values then
		values[target] = nil
	end

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_relation_value_removal(entity, relation, target)
	end
end

local function allocate_relation_removal(server: Server, entity: Entity, relation: Component, target: Entity)
	local storage = get_or_set_entity_storage(server, entity)
	local targets = storage.relations[relation]
	if targets then
		targets[target] = nil
	end

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_relation_removal(entity, relation, target)
	end
end

local function cleanup_entity(server: Server, entity: Entity)
	server.alive_tracked[entity] = nil
	server.storage[entity] = nil
	server.global_ids[entity] = nil
	server.custom_ids[entity] = nil
	server.additions[entity] = nil
	server.masking:cleanup_entity(entity)

	local track_info = server.track_info.entities[entity]
	if track_info then
		for component in track_info.components do
			local track_component = server.track_info.components[component]
			if track_component then
				track_component[entity] = nil
			end
		end
		for id in track_info.pairs do
			local track_pair = server.track_info.pairs[id]
			if track_pair then
				track_pair[entity] = nil
			end
		end
		server.track_info.entities[entity] = nil
	end
end

local function hook_pair(server: Server, pair_id: Component)
	local world = server.world

	if server.track_info.pairs[pair_id] then
		error(`attemped to track a pair twice: {common.log_component(server.world, PAIR_SECOND(world, pair_id))}`)
	end

	local info = {} :: Map<Entity, number>
	server.track_info.pairs[pair_id] = info

	local function hook(unhook: () -> ())
		table.insert(server.hooked, unhook)
	end

	hook(HOOK_PAIR_ADDED(world, pair_id, function(entity, id, value)
		local track_type = info[entity]
		if not track_type then
			return
		end

		if track_type == TRACK_TYPES.pair_component then
			allocate_pair_change(server, entity, id, value)
		else
			allocate_pair_addition(server, entity, id)
		end
	end))
	hook(HOOK_PAIR_CHANGED(world, pair_id, function(entity, id, value)
		local track_type = info[entity]
		if not track_type then
			return
		end

		allocate_pair_change(server, entity, id, value)
	end))
	hook(HOOK_PAIR_REMOVED(world, pair_id, function(entity, id)
		local track_type = info[entity]
		if not track_type then
			return
		end

		if track_type == TRACK_TYPES.pair_component then
			allocate_pair_component_removal(server, entity, id)
		else
			allocate_pair_tag_removal(server, entity, id)
		end
	end))

	return info
end

local function hook_component(server: Server, component: Component, hooked: Component)
	local world = server.world

	if server.track_info.components[component] then
		error(`attemped to track a component twice: {common.log_component(server.world, component)}`)
	end

	local info = {} :: Map<Entity, number>
	server.track_info.components[component] = info

	local function hook(unhook: () -> ())
		table.insert(server.hooked, unhook)
	end

	hook(HOOK_ADDED(world, hooked, function(entity, id, value)
		local track_type = info[entity]
		if not track_type then
			return
		end

		if track_type == TRACK_TYPES.component then
			allocate_component_change(server, entity, component, value)
		elseif track_type == TRACK_TYPES.tag then
			allocate_tag_addition(server, entity, component)
		elseif track_type == TRACK_TYPES.relation then
			if not IS_PAIR(id) then
				return
			end
			allocate_relation_addition(server, entity, component, PAIR_SECOND(world, id))
		elseif track_type == TRACK_TYPES.relation_value then
			if not IS_PAIR(id) then
				return
			end
			allocate_relation_value_change(server, entity, component, PAIR_SECOND(world, id), value)
		end
	end))
	hook(HOOK_CHANGED(world, hooked, function(entity, id, value)
		local track_type = info[entity]
		if not track_type then
			return
		end
		if track_type == TRACK_TYPES.component then
			allocate_component_change(server, entity, component, value)
		elseif track_type == TRACK_TYPES.relation_value then
			if not IS_PAIR(id) then
				return
			end
			allocate_relation_value_change(server, entity, component, PAIR_SECOND(world, id), value)
		end
	end))
	hook(HOOK_REMOVED(world, hooked, function(entity, id)
		local track_type = info[entity]
		if not track_type then
			return
		end

		if track_type == TRACK_TYPES.component then
			allocate_component_removal(server, entity, component)
		elseif track_type == TRACK_TYPES.tag then
			allocate_tag_removal(server, entity, component)
		elseif track_type == TRACK_TYPES.relation then
			if not IS_PAIR(id) then
				return
			end
			allocate_relation_removal(server, entity, component, PAIR_SECOND(world, id))
		elseif track_type == TRACK_TYPES.relation_value then
			if not IS_PAIR(id) then
				return
			end
			allocate_relation_value_removal(server, entity, component, PAIR_SECOND(world, id))
		end
	end))

	return info
end

local function add_entity_component_tracked(server: Server, entity: Entity, component: Component, track_type: number)
	local track: EntityTrackInfo = server.track_info.entities[entity]
	if track == nil then
		track = {
			components = { [component] = track_type },
			pairs = {},
		}
		server.track_info.entities[entity] = track
	else
		track.components[component] = track_type
	end
end

local function add_entity_pair_tracked(server: Server, entity: Entity, id: Component, track_type: number)
	local track: EntityTrackInfo = server.track_info.entities[entity]
	if track == nil then
		track = {
			components = {},
			pairs = { [id] = track_type },
		}
		server.track_info.entities[entity] = track
	else
		track.pairs[id] = track_type
	end
end

local function remove_entity_component_tracked(server: Server, entity: Entity, component: Component)
	local track = server.track_info.entities[entity]
	if track then
		track.components[component] = nil
	end
end

local function remove_entity_pair_tracked(server: Server, entity: Entity, id: Component)
	local track = server.track_info.entities[entity]
	if track then
		track.pairs[id] = nil
	end
end

local function track_entity_component(server: Server, entity: Entity, component: Component)
	local world = server.world
	local info = server.track_info.components[component]
	if not info then
		info = hook_component(server, component, component)
	end

	local entity_storage = get_or_set_entity_storage(server, entity)

	if IS_COMPONENT(world, component) then
		if WORLD_HAS(world, entity, component) then
			local value = WORLD_GET(world, entity, component)

			if value == nil then
				entity_storage.components[component] = NIL_COMPONENT_VALUE
			else
				entity_storage.components[component] = value
			end
		end

		info[entity] = TRACK_TYPES.component
		add_entity_component_tracked(server, entity, component, TRACK_TYPES.component)

		return COMPONENT_TYPES.component
	else
		if WORLD_HAS(world, entity, component) then
			entity_storage.tags[component] = true
		end

		info[entity] = TRACK_TYPES.tag
		add_entity_component_tracked(server, entity, component, TRACK_TYPES.tag)

		return COMPONENT_TYPES.tag
	end
end

local function track_entity_pair(server: Server, entity: Entity, id: Component)
	local world = server.world
	local info = server.track_info.pairs[id]
	if not info then
		info = hook_pair(server, id)
	end

	local entity_storage = get_or_set_entity_storage(server, entity)

	if IS_COMPONENT(world, id) then
		if WORLD_HAS(world, entity, id) then
			local value = WORLD_GET(world, entity, id)

			if value == nil then
				entity_storage.pair_components[id] = NIL_COMPONENT_VALUE
			else
				entity_storage.pair_components[id] = value
			end
		end

		info[entity] = TRACK_TYPES.pair_component
		add_entity_pair_tracked(server, entity, id, TRACK_TYPES.pair_component)

		return COMPONENT_TYPES.pair_component
	else
		if WORLD_HAS(world, entity, id) then
			entity_storage.pair_tags[id] = true
		end

		info[entity] = TRACK_TYPES.pair_tag
		add_entity_pair_tracked(server, entity, id, TRACK_TYPES.pair_tag)

		return COMPONENT_TYPES.pair_tag
	end
end

local function track_entity_relation(server: Server, entity: Entity, relation: Component)
	local world = server.world
	local info = server.track_info.components[relation]
	if not info then
		info = hook_component(server, relation, LISTEN_RELATION(relation))
	end

	local entity_storage = get_or_set_entity_storage(server, entity)

	if IS_COMPONENT(world, relation) then
		local targets = {} :: Map<Entity, any>

		local index = 0
		while true do
			local target = WORLD_TARGET(world, entity, relation, index)
			if not target then
				break
			end
			index += 1
			local value = WORLD_GET(world, entity, PAIR(relation, target))
			targets[target] = if value == nil then NIL_COMPONENT_VALUE else value :: any
		end

		entity_storage.relation_values[relation] = targets
		info[entity] = TRACK_TYPES.relation_value
		add_entity_component_tracked(server, entity, relation, TRACK_TYPES.relation_value)

		return COMPONENT_TYPES.relation_value
	else
		local targets = {} :: Set<Entity>

		local index = 0
		while true do
			local target = WORLD_TARGET(world, entity, relation, index)
			if not target then
				break
			end
			index += 1
			targets[target] = true
		end

		entity_storage.relations[relation] = targets
		info[entity] = TRACK_TYPES.relation
		add_entity_component_tracked(server, entity, relation, TRACK_TYPES.relation)

		return COMPONENT_TYPES.relation
	end
end

local function untrack_entity_component(server: Server, entity: Entity, component: Component): number?
	local info = server.track_info.components[component]
	if not info then
		return nil
	end
	local listen_type = info[entity]
	info[entity] = nil

	local storage = server.storage[entity]
	if storage then
		storage.components[component] = nil
		storage.tags[component] = nil
	end

	remove_entity_component_tracked(server, entity, component)
	return listen_type
end

local function untrack_entity_pair(server: Server, entity: Entity, id: Entity): number?
	local info = server.track_info.pairs[id]
	if not info then
		return nil
	end
	local listen_type = info[entity]
	info[entity] = nil

	local storage = server.storage[entity]
	if storage then
		storage.pair_tags[id] = nil
		storage.pair_components[id] = nil
	end

	remove_entity_pair_tracked(server, entity, id)
	return listen_type
end

local function untrack_entity_relation(server: Server, entity: Entity, relation: Entity): number?
	local info = server.track_info.components[relation]
	if not info then
		return nil
	end
	local listen_type = info[entity]
	info[entity] = nil

	local storage = server.storage[entity]
	if storage then
		storage.relations[relation] = nil
		storage.relation_values[relation] = nil
	end

	remove_entity_component_tracked(server, entity, relation)
	return listen_type
end

local function write_vlq_bitmask(c: Cursor, value: number, mask: number, bit: number): number
	if value > 0 then
		cursor.write_vlq(c, value)
		return utils.setbit(mask, bit)
	else
		return mask
	end
end

function server_replicator.write_component_id(server: Server, c: Cursor, component: Entity)
	local shared_componens = server.shared.components
	local encoded = shared_componens.members[component]
	if not encoded then
		common.log_error(`attempted to replicate a non-shared component `, common.log_component(server.world, component))
		return
	end
	cursor.write_span(c, encoded, #shared_componens.keys)
end

function server_replicator.write_variant_value(
	server: Server,
	c: Cursor,
	log_component: Component,
	serdes: types.Serdes?,
	value: any,
	variants: any
)
	if serdes then
		local output, serdes_variants = serdes.serialize(if value == NIL_COMPONENT_VALUE then nil else value)

		if serdes.includes_variants then
			if serdes_variants == nil then
				-- 128 is zero for vlq
				cursor.writeu8(c, 128)
			else
				local start_variants = #variants
				if #serdes_variants > 0 then
					table.move(serdes_variants, 1, #serdes_variants, #variants + 1, variants)
				end
				cursor.write_vlq(c, #serdes_variants)
				cursor.write_vlq(c, start_variants + 1)
			end
		elseif serdes_variants ~= nil then
			common.log_error(
				"serdes: serializer provided variants yet includes_variants is not set to true for component: ",
				common.log_component(server.world, log_component)
			)
		end

		local bytespan = serdes.bytespan
		cursor.write_buffer(c, output)
		if bytespan then
			if bytespan ~= buffer.len(output) then
				common.log_error(
					`bytespan: {bytespan} mismatch for buffer lenght: {buffer.len(output)} in component: `,
					common.log_component(server.world, log_component)
				)
			end
		else
			local len = buffer.len(output)
			cursor.write_vlq(c, len)
		end
	else
		if value == NIL_COMPONENT_VALUE then
			-- 128 is zero for vlq
			cursor.writeu8(c, 128)
		else
			table.insert(variants, value :: any)
			cursor.write_vlq(c, #variants)
		end
	end
end

function server_replicator.write_component_value(
	server: Server,
	c: Cursor,
	component: Component,
	value: any,
	variants: { any }
)
	local serdes = server.shared.serdes[component]
	server_replicator.write_variant_value(server, c, component, serdes, value, variants)
end

function server_replicator.write_pair_value(
	server: Server,
	c: Cursor,
	relation: Component,
	id: Entity,
	value: any,
	variants: { any }
)
	local serdes = server.shared.serdes[id] or server.shared.serdes[PAIR(relation, WILDCARD)]
	server_replicator.write_variant_value(server, c, relation, serdes, value, variants)
end

function server_replicator.write_entity_id(server: Server, c: Cursor, entity: Entity)
	local custom = server.custom_ids[entity]
	local global_id = server.global_ids[entity]

	if global_id then
		cursor.writeu8(c, global_id + GLOBAL_ID_OFFSET)
	elseif custom then
		if type(custom) == "number" then
			server_replicator.write_component_id(server, c, (custom :: any) :: Entity)
			cursor.writeu40(c, entity :: any)
			cursor.writeu8(c, ENTITY_ID_TYPES.custom_id)
		else
			cursor.writeu8(c, server.shared.custom_ids.members[custom :: CustomId])
			cursor.writeu40(c, entity :: any)
			cursor.writeu8(c, ENTITY_ID_TYPES.custom_handler)
		end
	else
		local shared_id = server.shared.components.members[entity]
		if shared_id then
			cursor.writeu8(c, shared_id)
			cursor.writeu8(c, ENTITY_ID_TYPES.shared)
		else
			cursor.writeu40(c, entity :: any)
			cursor.writeu8(c, ENTITY_ID_TYPES.entity, entity)
		end
	end
end

function server_replicator.write_entity_relations(server: Server, storage: EntityStorage, c: Cursor, relation: Entity)
	local targets = storage.relations[relation]
	local total_targets = 0

	for target in targets do
		server_replicator.write_entity_id(server, c, target)
		total_targets += 1
	end
	cursor.write_vlq(c, total_targets)
	server_replicator.write_component_id(server, c, relation)
end

function server_replicator.write_entity_relations_values(
	server: Server,
	storage: EntityStorage,
	c: Cursor,
	relation: Entity,
	variants: { any }
)
	local targets = storage.relation_values[relation]
	local total_targets = 0

	for target, value in targets do
		server_replicator.write_entity_id(server, c, target)
		server_replicator.write_component_value(server, c, relation, value, variants)
		total_targets += 1
	end
	cursor.write_vlq(c, total_targets)
	server_replicator.write_component_id(server, c, relation)
end

function server_replicator.write_entity_pair_value(
	server: Server,
	world: World,
	c: Cursor,
	id: Component,
	value: any,
	variants: { any }
)
	local first, second = PAIR_FIRST(world, id), PAIR_SECOND(world, id)
	local pointer_start = c.offset

	server_replicator.write_pair_value(server, c, first, id, value, variants)

	-- if the entity is a custom id, we dont know if this has a serdes in the client, as it needs to be processed first
	-- we write a vlq so the client can jump in the cursor to skip this value entirely and process it later
	local pointer_offset = c.offset - pointer_start
	cursor.write_vlq(c, pointer_offset)

	server_replicator.write_entity_id(server, c, second)
	server_replicator.write_component_id(server, c, first)
end

function server_replicator.write_entity_pair(server: Server, world: World, c: Cursor, id: Component)
	local first, second = PAIR_FIRST(world, id), PAIR_SECOND(world, id)

	server_replicator.write_entity_id(server, c, second)
	server_replicator.write_component_id(server, c, first)
end

function server_replicator.write_entity(
	server: Server,
	c: Cursor,
	entity: Entity,
	active: masking_controller.ActiveEntity,
	variants: { any }
)
	local world = server.world
	local storage = server.storage[entity]
	local entity_mask = 0

	local total_relation_values = 0
	for relation in active.components[COMPONENT_TYPES.relation_value] do
		server_replicator.write_entity_relations_values(server, storage, c, relation, variants)
		total_relation_values += 1
	end
	entity_mask = write_vlq_bitmask(c, total_relation_values, entity_mask, 5)

	local total_relations = 0
	for relation in active.components[COMPONENT_TYPES.relation] do
		server_replicator.write_entity_relations(server, storage, c, relation)
		total_relations += 1
	end
	entity_mask = write_vlq_bitmask(c, total_relations, entity_mask, 4)

	local total_pair_values = 0
	for id in active.components[COMPONENT_TYPES.pair_component] do
		local value = storage.pair_components[id]
		if value == nil then
			continue
		end

		server_replicator.write_entity_pair_value(server, world, c, id, value, variants)
		total_pair_values += 1
	end
	entity_mask = write_vlq_bitmask(c, total_pair_values, entity_mask, 3)

	local total_pairs = 0
	for id in active.components[COMPONENT_TYPES.pair_tag] do
		local has_pair = storage.pair_tags[id]
		if has_pair then
			server_replicator.write_entity_pair(server, world, c, id)
			total_pairs += 1
		end
	end
	entity_mask = write_vlq_bitmask(c, total_pairs, entity_mask, 2)

	local total_components = 0
	for component in active.components[COMPONENT_TYPES.component] do
		local value = storage.components[component]
		if value == nil then
			continue
		end

		server_replicator.write_component_value(server, c, component, value, variants)
		server_replicator.write_component_id(server, c, component)
		total_components += 1
	end
	entity_mask = write_vlq_bitmask(c, total_components, entity_mask, 1)

	local total_tags = 0
	for tag in active.components[COMPONENT_TYPES.tag] do
		local has_tag = storage.tags[tag]
		if has_tag then
			server_replicator.write_component_id(server, c, tag)
			total_tags += 1
		end
	end
	entity_mask = write_vlq_bitmask(c, total_tags, entity_mask, 0)
	cursor.writeu8(c, entity_mask)
end

function server_replicator.resolve_dirty(server: Server)
	if server.is_shared_dirty then
		-- stylua: ignore
		server.shared = utils.resolved_shared(
			server.world,
			server.components,
			server.registered_custom_ids,
			server.component_serdes
		)
		server.is_shared_dirty = false
	end
end

type Packet = {
	buffer: buffer,
	variants: { any },
}
type MemberPackets = {
	packets: Array<Packet>,
	variants: { { any } },
	total_size: number,
}

local function append_packet(packets: { [Player]: MemberPackets }, members: { any }, output: buffer, variants: { any })
	local len = buffer.len(output)
	for _, member in members do
		if not utils.is_client_valid(member) then
			continue
		end

		local member_packets = packets[member]

		if member_packets then
			table.insert(member_packets.packets, {
				buffer = output,
				variants = variants,
			})
			member_packets.total_size += len
		else
			member_packets = {
				packets = { {
					buffer = output,
					variants = variants,
				} },
				total_size = len,
			}
			packets[member] = member_packets :: MemberPackets
		end
	end
end

local function combine_packet_outputs(outputs: Array<Packet>, total_size: number, id: number): (buffer, { { any } })
	local combined = buffer.create(total_size + utils.vlq_span(#outputs) + 1)
	local offset = 0
	local variants = table.create(#outputs) :: { { any } }

	for _, output in outputs do
		buffer.copy(combined, offset, output.buffer)
		offset += buffer.len(output.buffer)
		table.insert(variants, output.variants)
	end
	cursor.write_vlq({
		offset = offset,
		buffer = combined,
	}, #outputs)
	buffer.writeu8(combined, buffer.len(combined) - 1, id)

	return combined, variants
end

type PacketIterator = () -> (Player, buffer, { { any } })

local function create_packet_iterator(packets: { [Player]: MemberPackets }, id: number)
	local iterated: Player? = nil
	local function iterator()
		local player, data = next(packets, iterated)
		while not utils.is_client_valid(player) do
			if not player and not data then
				break
			end
			player, data = next(packets, player)
		end
		if not player then
			return nil :: any
		end
		iterated = player

		local combined, variants = combine_packet_outputs(data.packets, data.total_size, id)
		return player, combined, variants
	end
	return iterator :: PacketIterator
end

local function create_unreliable_packet_iterator(packets: { [Player]: MemberPackets })
	return coroutine.wrap(function()
		for player, data in packets do
			if not utils.is_client_valid(player) then
				continue
			end

			table.sort(data.packets, function(a, b)
				return buffer.len(a.buffer) < buffer.len(b.buffer)
			end)
			local total_packets = #data.packets

			local current_packet_index = 1
			while current_packet_index <= total_packets do
				local sending = {} :: { Packet }
				local total_size = 0

				while current_packet_index <= total_packets do
					local packet = data.packets[current_packet_index]
					local buffer_size = buffer.len(packet.buffer)

					if total_size + buffer_size > MAX_PACKET_SIZE and #sending > 0 then
						break
					end

					table.insert(sending, packet)
					total_size += buffer_size
					current_packet_index += 1

					if total_size >= MAX_PACKET_SIZE then
						break
					end
				end

				if #sending > 0 then
					coroutine.yield(player, combine_packet_outputs(sending, total_size, PACKET_TYPES.unreliable))
				end
			end
		end
	end) :: PacketIterator
end

function server_replicator.get_full(server: Server, client: Player): (buffer, { { any } })
	server_replicator.resolve_dirty(server)
	local index = server.masking.client_indexes[client]
	if index == nil then
		common.log_error "attempted to replicate for a non registered client"
	end

	local packets: Array<Packet> = {}
	local total_size = 0

	-- maybe edges to quickly find all relevant storages improves performance?
	for _, storage in server.masking.storages do
		if storage.active_count == 0 then
			continue
		end
		if not storage.mask.bitmask:get(index) then
			continue
		end
		local c = cursor.new()
		local variants: { any } = {}

		local total_entities = 0
		for entity, active in storage.active do
			server_replicator.write_entity(server, c, entity, active, variants)
			server_replicator.write_entity_id(server, c, entity)
			total_entities += 1
		end
		cursor.write_vlq(c, total_entities)

		local output = cursor.close(c)
		table.insert(packets, {
			buffer = output,
			variants = variants,
		})
		total_size += buffer.len(output)
	end

	return combine_packet_outputs(packets, total_size, PACKET_TYPES.full)
end

function server_replicator.collect_entity(server: Server, entity: Entity)
	server_replicator.resolve_dirty(server)
	local packets: { [Player]: MemberPackets } = {}
	local processed_storages: Set<StorageGroup> = {}

	local lookup = server.masking.lookups.entities[entity]
	local entity_storage = lookup.storage_group

	local c_main = cursor.new()
	local variants_main = {}

	server_replicator.write_entity(server, c_main, entity, entity_storage.active[entity], variants_main)
	server_replicator.write_entity_id(server, c_main, entity)
	append_packet(packets, entity_storage.mask.members, cursor.close(c_main), variants_main)
	processed_storages[entity_storage] = true

	for _, filtered in lookup.filtered_components do
		for _, component in filtered do
			local storage = component.storage_group
			if processed_storages[storage] then
				continue
			end

			local c = cursor.new()
			local variants = {}

			server_replicator.write_entity(server, c, entity, storage.active[entity], variants)
			server_replicator.write_entity_id(server, c_main, entity)
			append_packet(packets, storage.mask.members, cursor.close(c), variants)
			processed_storages[storage] = true
		end
	end

	return create_packet_iterator(packets, PACKET_TYPES.entity)
end

function server_replicator.collect_updates(server: Server)
	server_replicator.resolve_dirty(server)
	local world = server.world
	local packets: { [Player]: MemberPackets } = {}

	for _, storage in server.masking.storages do
		local c = cursor.new()
		local variants = {}

		local storage_mask = 0

		local total_deleted = 0
		local entity_deletions = storage.deletions.entities
		for entity in entity_deletions do
			server_replicator.write_entity_id(server, c, entity)
			total_deleted += 1
		end
		table.clear(entity_deletions)
		storage_mask = write_vlq_bitmask(c, total_deleted, storage_mask, 4)

		local total_component_deleted = 0
		local component_deletions = storage.deletions.components
		for entity, deleted in component_deletions do
			local total_relations = 0

			for relation in deleted[COMPONENT_TYPES.relation_value] do
				server_replicator.write_component_id(server, c, relation)
				total_relations += 1
			end
			for relation in deleted[COMPONENT_TYPES.relation] do
				server_replicator.write_component_id(server, c, relation)
				total_relations += 1
			end
			cursor.write_vlq(c, total_relations)

			local total_pairs = 0
			for id in deleted[COMPONENT_TYPES.pair_component] do
				server_replicator.write_entity_pair(server, world, c, id)
				total_pairs += 1
			end
			for id in deleted[COMPONENT_TYPES.pair_tag] do
				server_replicator.write_entity_pair(server, world, c, id)
				total_pairs += 1
			end
			cursor.write_vlq(c, total_pairs)

			local total_components = 0
			for component in deleted[COMPONENT_TYPES.component] do
				server_replicator.write_component_id(server, c, component)
				total_components += 1
			end
			for tag in deleted[COMPONENT_TYPES.tag] do
				server_replicator.write_component_id(server, c, tag)
				total_components += 1
			end
			cursor.write_vlq(c, total_components)

			server_replicator.write_entity_id(server, c, entity)
			total_component_deleted += 1
		end
		table.clear(component_deletions)
		storage_mask = write_vlq_bitmask(c, total_component_deleted, storage_mask, 3)

		local storage_changes = storage.changes
		local changed = 0
		for entity, changes in storage_changes.changed do
			-- relations remove

			local total_relations_removed = 0
			for relation, targets in changes.relation_removed.component do
				local total_targets = 0

				for target in targets do
					server_replicator.write_entity_id(server, c, target)
					total_targets += 1
				end
				cursor.write_vlq(c, total_targets)
				server_replicator.write_component_id(server, c, relation)
				total_relations_removed += 1
			end
			for relation, targets in changes.relation_removed.tag do
				local total_targets = 0

				for target in targets do
					server_replicator.write_entity_id(server, c, target)
					total_targets += 1
				end
				cursor.write_vlq(c, total_targets)
				server_replicator.write_component_id(server, c, relation)
				total_relations_removed += 1
			end
			-- using a normal vlq here sadly
			-- cause I ran out of bitmask space for this one :/
			cursor.write_vlq(c, total_relations_removed)

			local changed_mask = 0

			-- relations add/set

			local total_relation_values = 0
			for relation, targets in changes.relation_value do
				local total_targets = 0

				for target, value in targets do
					server_replicator.write_entity_id(server, c, target)
					server_replicator.write_component_value(server, c, relation, value, variants)
					total_targets += 1
				end
				cursor.write_vlq(c, total_targets)
				server_replicator.write_component_id(server, c, relation)
				total_relation_values += 1
			end
			changed_mask = write_vlq_bitmask(c, total_relation_values, changed_mask, 7)

			local total_relations_added = 0
			for relation, targets in changes.relation_added do
				local total_targets = 0

				for target in targets do
					server_replicator.write_entity_id(server, c, target)
					total_targets += 1
				end
				cursor.write_vlq(c, total_targets)
				server_replicator.write_component_id(server, c, relation)
				total_relations_added += 1
			end
			changed_mask = write_vlq_bitmask(c, total_relations_added, changed_mask, 6)

			-- pairs removed

			local total_pairs_removed = 0
			for id in changes.pair_removed.component do
				server_replicator.write_entity_pair(server, world, c, id)
				total_pairs_removed += 1
			end
			for id in changes.pair_removed.tag do
				server_replicator.write_entity_pair(server, world, c, id)
				total_pairs_removed += 1
			end
			changed_mask = write_vlq_bitmask(c, total_pairs_removed, changed_mask, 5)

			-- pairs add/set

			local total_pairs_set = 0
			for id, value in changes.pair_changed do
				server_replicator.write_entity_pair_value(server, world, c, id, value, variants)
				total_pairs_set += 1
			end
			changed_mask = write_vlq_bitmask(c, total_pairs_set, changed_mask, 4)

			local total_pairs_added = 0
			for id in changes.pair_added do
				server_replicator.write_entity_pair(server, world, c, id)
				total_pairs_added += 1
			end
			changed_mask = write_vlq_bitmask(c, total_pairs_added, changed_mask, 3)

			-- tags/components removed

			local total_removed = 0
			for component in changes.removed.component do
				server_replicator.write_component_id(server, c, component)
				total_removed += 1
			end
			for component in changes.removed.tag do
				server_replicator.write_component_id(server, c, component)
				total_removed += 1
			end
			changed_mask = write_vlq_bitmask(c, total_removed, changed_mask, 2)

			-- tags/components set

			local total_components = 0
			for component, value in changes.component do
				server_replicator.write_component_value(server, c, component, value, variants)
				server_replicator.write_component_id(server, c, component)
				total_components += 1
			end
			changed_mask = write_vlq_bitmask(c, total_components, changed_mask, 1)

			local total_tagged = 0
			for tag in changes.tagged do
				server_replicator.write_component_id(server, c, tag)
				total_tagged += 1
			end
			changed_mask = write_vlq_bitmask(c, total_tagged, changed_mask, 0)

			if changed_mask + total_relations_removed ~= 0 then
				cursor.writeu8(c, changed_mask)
				server_replicator.write_entity_id(server, c, entity)
				changed += 1
			end
		end
		table.clear(storage_changes.changed)
		storage_mask = write_vlq_bitmask(c, changed, storage_mask, 2)

		local total_components_added = 0
		for entity, components in storage_changes.added_components do
			local entity_storage = server.storage[entity]
			local added_mask = 0

			local total_relation_values = 0
			for relation in components[COMPONENT_TYPES.relation_value] do
				server_replicator.write_entity_relations_values(server, entity_storage, c, relation, variants)
				total_relation_values += 1
			end
			added_mask = write_vlq_bitmask(c, total_relation_values, added_mask, 5)

			local total_relations = 0
			for relation in components[COMPONENT_TYPES.relation] do
				server_replicator.write_entity_relations(server, entity_storage, c, relation)
				total_relations += 1
			end
			added_mask = write_vlq_bitmask(c, total_relations, added_mask, 4)

			local total_pair_values = 0
			for id in components[COMPONENT_TYPES.pair_component] do
				local value = entity_storage.pair_components[id]
				-- nil is saved here as a special value, this gets automatically handled by write_component_value
				if value == nil then
					continue
				end

				server_replicator.write_entity_pair_value(server, world, c, id, value, variants)
				total_pair_values += 1
			end
			added_mask = write_vlq_bitmask(c, total_pair_values, added_mask, 3)

			local total_pairs = 0
			for id in components[COMPONENT_TYPES.pair_tag] do
				server_replicator.write_entity_pair(server, world, c, id)
				total_pairs += 1
			end
			added_mask = write_vlq_bitmask(c, total_pairs, added_mask, 2)

			local total_components = 0
			for component in components[COMPONENT_TYPES.component] do
				local value = entity_storage.components[component]
				-- nil is saved here as a special value, this gets automatically handled by write_component_value
				if value == nil then
					continue
				end
				server_replicator.write_component_value(server, c, component, value, variants)
				server_replicator.write_component_id(server, c, component)
				total_components += 1
			end
			added_mask = write_vlq_bitmask(c, total_components, added_mask, 1)

			local total_tags = 0
			for component in components[COMPONENT_TYPES.tag] do
				local has_tag = entity_storage.tags[component]
				if has_tag then
					server_replicator.write_component_id(server, c, component)
					total_tags += 1
				end
			end
			added_mask = write_vlq_bitmask(c, total_tags, added_mask, 0)

			if added_mask ~= 0 then
				cursor.writeu8(c, added_mask)
				server_replicator.write_entity_id(server, c, entity)
				total_components_added += 1
			end
		end
		table.clear(storage_changes.added_components)
		storage_mask = write_vlq_bitmask(c, total_components_added, storage_mask, 1)

		local total_added = 0
		for entity in storage_changes.added do
			local active = storage.active[entity]
			if not active then
				continue
			end

			server_replicator.write_entity(server, c, entity, active, variants)
			server_replicator.write_entity_id(server, c, entity)
			total_added += 1
		end
		table.clear(storage_changes.added)
		storage_mask = write_vlq_bitmask(c, total_added, storage_mask, 0)

		if storage_mask ~= 0 then
			cursor.writeu8(c, storage_mask)
			local output = cursor.close(c)
			append_packet(packets, storage.mask.members, output, variants)
		end
	end
	table.clear(server.additions)
	return create_packet_iterator(packets, PACKET_TYPES.updates)
end

function server_replicator.collect_unreliable(server: Server)
	server_replicator.resolve_dirty(server)
	local world = server.world
	local packets: { [Player]: MemberPackets } = {}

	for _, mask_storage in server.masking.storages do
		if mask_storage.active_count == 0 then
			continue
		end
		local active = mask_storage.active

		local c = cursor.new()
		local variants = {} :: Array<{ any }>
		local total_entities = 0

		local checkpoint_offset = 0
		local checkpoint_variants_count = 0
		local checkpoint_total_entities = 0

		local function create_checkpoint()
			checkpoint_offset = c.offset
			checkpoint_variants_count = #variants
			checkpoint_total_entities = total_entities
		end

		local function rollback_checkpoint()
			local new_cursor = cursor.new()
			cursor.write_buffer(new_cursor, c.buffer, checkpoint_offset, c.offset - checkpoint_offset)
			c.offset = checkpoint_offset
			c = new_cursor

			local new_variants = {} :: Array<{ any }>
			for _ = #variants, checkpoint_variants_count + 1, -1 do
				table.insert(new_variants, 1, table.remove(variants) :: { any })
			end

			variants = new_variants
			total_entities = total_entities - checkpoint_total_entities
		end

		local function commit_checkpoint(commit_c, commit_variants, commit_total_entities)
			if commit_total_entities <= 0 then
				return
			end

			cursor.write_vlq(commit_c, commit_total_entities)
			local output = cursor.close(commit_c)
			append_packet(packets, mask_storage.mask.members, output, commit_variants)
		end

		for entity, actives in active do
			create_checkpoint()

			local total_unreliable = 0
			for component in actives.components[COMPONENT_TYPES.unreliable] do
				local value = WORLD_GET(world, entity, component)
				if value == nil then
					continue
				end

				server_replicator.write_component_value(server, c, component, value, variants)
				server_replicator.write_component_id(server, c, component)

				total_unreliable += 1
			end

			if total_unreliable <= 0 then
				continue
			end
			total_entities += 1
			cursor.write_vlq(c, total_unreliable)
			server_replicator.write_entity_id(server, c, entity)

			if c.offset > MAX_PACKET_SIZE then
				local commit_cursor = c
				local commit_variants = variants

				rollback_checkpoint()
				commit_checkpoint(commit_cursor, commit_variants, checkpoint_total_entities)
			end
		end
		commit_checkpoint(c, variants, total_entities)
	end

	return create_unreliable_packet_iterator(packets)
end

function server_replicator.start_networked(server: Server, entity: Entity, filter: AnyFilter?)
	local masking = server.masking

	masking:deallocate_entity_stop(entity)
	masking:start_entity(entity, filter)
	masking:allocate_propagated_entity_start(entity)

	server.additions[entity] = true
	server.track_info.networked[entity] = true
	track_entity_lifetime(server, entity)
end

function server_replicator.start_reliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local masking = server.masking

	local track_type = track_entity_component(server :: Server, entity, component)
	masking:deallocate_component_stop(entity, component, track_type)
	masking:start_component(entity, component, track_type, filter)

	if server.additions[entity] then
		masking:allocate_shared_entity_start(entity, component, track_type)
	elseif server.track_info.networked[entity] then
		masking:allocate_component_start(entity, component, track_type)
	end
end

function server_replicator.start_unreliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local masking = server.masking

	masking:deallocate_component_stop(entity, component, COMPONENT_TYPES.unreliable)
	masking:start_component(entity, component, COMPONENT_TYPES.unreliable, filter)
	if server.additions[entity] then
		masking:allocate_component_start(entity, component, COMPONENT_TYPES.unreliable)
	end
end

function server_replicator.start_pair(server: Server, entity: Entity, id: Component, filter: AnyFilter?)
	local masking = server.masking

	local track_type = track_entity_pair(server :: Server, entity, id)
	masking:deallocate_component_stop(entity, id, track_type)
	masking:start_component(entity, id, track_type, filter)

	if server.additions[entity] then
		masking:allocate_shared_entity_start(entity, id, track_type)
	elseif server.track_info.networked[entity] then
		masking:allocate_component_start(entity, id, track_type)
	end
end

function server_replicator.start_relation(server: Server, entity: Entity, relation: Component, filter: AnyFilter?)
	local masking = server.masking

	local track_type = track_entity_relation(server, entity, relation)
	masking:deallocate_component_stop(entity, relation, track_type)
	masking:start_component(entity, relation, track_type, filter)

	if server.additions[entity] then
		masking:allocate_shared_entity_start(entity, relation, track_type)
	elseif server.track_info.networked[entity] then
		masking:allocate_component_start(entity, relation, track_type)
	end
end

function server_replicator.change_networked(server: Server, entity: Entity, filter: AnyFilter?)
	local masking = server.masking
	masking:set_entity(entity, filter)
end

function server_replicator.change_reliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local world = server.world
	local masking = server.masking

	if IS_COMPONENT(world, component) then
		masking:set_component(entity, component, COMPONENT_TYPES.component, filter)
	else
		masking:set_component(entity, component, COMPONENT_TYPES.tag, filter)
	end
end

function server_replicator.change_unreliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local masking = server.masking
	masking:set_component(entity, component, COMPONENT_TYPES.unreliable, filter)
end

function server_replicator.change_pair(server: Server, entity: Entity, id: Component, filter: AnyFilter?)
	local world = server.world
	local masking = server.masking

	if IS_COMPONENT(world, id) then
		masking:set_component(entity, id, COMPONENT_TYPES.pair_component, filter)
	else
		masking:set_component(entity, id, COMPONENT_TYPES.pair_tag, filter)
	end
end

function server_replicator.change_relation(server: Server, entity: Entity, relation: Component, filter: AnyFilter?)
	local world = server.world
	local masking = server.masking

	if IS_COMPONENT(world, relation) then
		masking:set_component(entity, relation, COMPONENT_TYPES.relation_value, filter)
	else
		masking:set_component(entity, relation, COMPONENT_TYPES.relation, filter)
	end
end

local function stop_tracked_component(
	server: Server,
	entity: Entity,
	component: Component,
	track_type: number,
	keep: boolean?
)
	local masking = server.masking
	if server.track_info.networked[entity] then
		masking:deallocate_component_start(entity, component, track_type)
		if not keep then
			masking:allocate_component_stop(entity, component, track_type)
		end
	end
	masking:stop_component(entity, component, track_type)
end

function server_replicator.stop_networked(server: Server, entity: Entity, keep: boolean?)
	if not server.track_info.networked[entity] then
		return
	end

	local masking = server.masking
	if not keep then
		masking:allocate_entity_stop(entity)
	end
	masking:stop_entity(entity)

	server.additions[entity] = nil
	server.track_info.networked[entity] = nil
end

function server_replicator.stop_reliable(server: Server, entity: Entity, component: Component, keep: boolean?)
	if not server.track_info.entities[entity] then
		return
	end

	local track_type = untrack_entity_component(server, entity, component)
	if not track_type then
		return
	end

	stop_tracked_component(server, entity, component, track_type, keep)
end

function server_replicator.stop_unreliable(server: Server, entity: Entity, component: Component, keep: boolean?)
	if not server.track_info.entities[entity] then
		return
	end

	local track_type = untrack_entity_component(server, entity, component)
	if not track_type then
		return
	end

	stop_tracked_component(server, entity, component, COMPONENT_TYPES.unreliable, keep)
end

function server_replicator.stop_pair(server: Server, entity: Entity, id: Component, keep: boolean?)
	if not server.track_info.entities[entity] then
		return
	end

	local track_type = untrack_entity_pair(server, entity, id)
	if not track_type then
		return
	end

	stop_tracked_component(server, entity, id, track_type, keep)
end

function server_replicator.stop_relation(server: Server, entity: Entity, relation: Component, keep: boolean?)
	if not server.track_info.entities[entity] then
		return
	end

	local track_type = untrack_entity_relation(server, entity, relation)
	if not track_type then
		return
	end

	stop_tracked_component(server, entity, relation, track_type, keep)
end

function server_replicator.set_networked(server: Server, entity: Entity, filter: AnyFilter?)
	if server.track_info.networked[entity] then
		server_replicator.change_networked(server, entity, filter)
	else
		server_replicator.start_networked(server, entity, filter)
	end
end

function server_replicator.set_reliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local entity_tracked = server.track_info.entities[entity]
	if entity_tracked and entity_tracked.components[component] then
		server_replicator.change_reliable(server, entity, component, filter)
	else
		server_replicator.start_reliable(server, entity, component, filter)
	end
end

function server_replicator.set_unreliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local entity_tracked = server.track_info.entities[entity]
	if entity_tracked and entity_tracked.components[component] then
		server_replicator.change_unreliable(server, entity, component, filter)
	else
		server_replicator.start_unreliable(server, entity, component, filter)
	end
end

function server_replicator.set_pair(server: Server, entity: Entity, id: Component, filter: AnyFilter?)
	local entity_tracked = server.track_info.entities[entity]
	if entity_tracked and entity_tracked.pairs[id] then
		server_replicator.change_pair(server, entity, id, filter)
	else
		server_replicator.start_pair(server, entity, id, filter)
	end
end

function server_replicator.set_relation(server: Server, entity: Entity, relation: Component, filter: AnyFilter?)
	local entity_tracked = server.track_info.entities[entity]
	if entity_tracked and entity_tracked.components[relation] then
		server_replicator.change_relation(server, entity, relation, filter)
	else
		server_replicator.start_relation(server, entity, relation, filter)
	end
end

function server_replicator.set_custom(server: Server, entity: Entity, handler: Component | CustomId)
	if server.custom_ids[entity] then
		common.log_warn("attempted to register a custom_id twice for the same entity", debug.traceback())
		return
	end
	server.custom_ids[entity] = handler
end

function server_replicator.remove_custom(server: Server, entity: Entity)
	server.custom_ids[entity] = nil
end

function server_replicator.set_serdes(server: Server, component: Component, serdes: types.Serdes)
	server.component_serdes[component] = serdes
	server.is_shared_dirty = true
end

function server_replicator.remove_serdes(server: Server, component: Component)
	server.component_serdes[component] = nil
	server.is_shared_dirty = true
end

local function check_created(server: Server)
	if server.inited == true then
		warn "attempted to init a server twice"
		return false
	end
	if server.inited == nil then
		warn "attempted to init a destroyed server"
		return false
	end
	return true
end

function server_replicator.init(server: Server, wrd: World?)
	if not check_created(server) then
		return
	end
	server.inited = true :: any

	local world = wrd or server.world
	server.world = world

	if not world then
		error "Providing a world is required to start replecs"
	end

	if not server.components then
		server.components = utils.create_components(utils.tag_factory(world), utils.component_factory(world))
		utils.add_component_names(server.components, function(component, name)
			common.add_name(world, component, name)
		end)
	end

	local components = server.components

	local function hook(unhook: () -> ())
		table.insert(server.hooked, unhook)
	end

	hook(HOOK_ADDED(world, components.networked, function(entity, _, filter)
		server_replicator.start_networked(server, entity, filter)
	end))
	hook(HOOK_CHANGED(world, components.networked, function(entity, _, filter)
		server_replicator.change_networked(server, entity, filter)
	end))
	hook(HOOK_REMOVED(world, components.networked, function(entity)
		server_replicator.stop_networked(server, entity)
	end))

	if RELATIONSHIPS then
		hook(HOOK_ADDED(world, LISTEN_RELATION(components.reliable), function(entity, id, filter)
			local component = PAIR_SECOND(world, id)
			server_replicator.start_reliable(server, entity, component, filter)
		end))
		hook(HOOK_CHANGED(world, LISTEN_RELATION(components.reliable), function(entity, id, filter)
			local component = PAIR_SECOND(world, id)
			server_replicator.change_reliable(server, entity, component, filter)
		end))
		hook(HOOK_REMOVED(world, LISTEN_RELATION(components.reliable), function(entity, id)
			local component = PAIR_SECOND(world, id)
			server_replicator.stop_reliable(server, entity, component)
		end))

		hook(HOOK_ADDED(world, LISTEN_RELATION(components.relation), function(entity, id, filter)
			local relation = PAIR_SECOND(world, id)
			server_replicator.start_relation(server, entity, relation, filter)
		end))
		hook(HOOK_CHANGED(world, LISTEN_RELATION(components.relation), function(entity, id, filter)
			local relation = PAIR_SECOND(world, id)
			server_replicator.change_relation(server, entity, relation, filter)
		end))
		hook(HOOK_REMOVED(world, LISTEN_RELATION(components.relation), function(entity, id)
			local relation = PAIR_SECOND(world, id)
			server_replicator.stop_relation(server, entity, relation)
		end))

		hook(HOOK_ADDED(world, LISTEN_RELATION(components.unreliable), function(entity, id, filter)
			local component = PAIR_SECOND(world, id)
			server_replicator.start_unreliable(server, entity, component, filter)
		end))
		hook(HOOK_CHANGED(world, LISTEN_RELATION(components.unreliable), function(entity, id, filter)
			local component = PAIR_SECOND(world, id)
			server_replicator.change_unreliable(server, entity, component, filter)
		end))
		hook(HOOK_REMOVED(world, LISTEN_RELATION(components.unreliable), function(entity, id)
			local component = PAIR_SECOND(world, id)
			server_replicator.stop_unreliable(server, entity, component)
		end))

		hook(HOOK_ADDED(world, LISTEN_RELATION(components.custom), function(entity, id)
			if not IS_PAIR(id) then
				common.log_error "replecs.custom should be used with a relationship in the server"
			end
			local target = PAIR_SECOND(world, id)
			server_replicator.set_custom(server, entity, target)
		end))
		hook(HOOK_REMOVED(world, LISTEN_RELATION(components.custom), function(entity)
			server_replicator.remove_custom(server, entity)
		end))
	end
	hook(HOOK_ADDED(world, components.global, function(entity, _, value)
		if value > 245 then
			common.log_error "global id size exceeded, max is 245"
		end
		server.global_ids[entity] = value
	end))

	hook(HOOK_CHANGED(world, components.global, function(entity, _, value)
		if value > 245 then
			common.log_error "global id size exceeded, max is 245"
		end
		server.global_ids[entity] = value
	end))
	hook(HOOK_REMOVED(world, components.global, function(entity)
		server.global_ids[entity] = nil
	end))

	hook(HOOK_ADDED(world, components.serdes, function(component, _, serdes)
		server_replicator.set_serdes(server, component, serdes)
	end))
	hook(HOOK_CHANGED(world, components.serdes, function(component, _, serdes)
		server_replicator.set_serdes(server, component, serdes)
	end))
	hook(HOOK_REMOVED(world, components.serdes, function(component)
		server_replicator.remove_serdes(server, component)
	end))

	hook(HOOK_REMOVED(world, components.__alive_tracking__, function(entity)
		if server.track_info.networked[entity] then
			server_replicator.stop_networked(server, entity)
		end
		cleanup_entity(server, entity)
	end))

	for _, component in server.requires_shared_lookup do
		hook(HOOK_ADDED(world, component, function()
			server.is_shared_dirty = true
		end))
		hook(HOOK_CHANGED(world, component, function()
			server.is_shared_dirty = true
		end))
		hook(HOOK_REMOVED(world, component, function()
			server.is_shared_dirty = true
		end))
	end

	QUERY_CURRENT_COMPONENTS(server)
	QUERY_CURRENT_NETWORKED(server)

	server.shared = utils.resolved_shared(world, components, server.registered_custom_ids, server.component_serdes)

	if game and game:GetService("RunService"):IsServer() then
		local Players = game:GetService "Players"

		local added = Players.PlayerAdded:Connect(function(player)
			server.masking:register_client(player)
		end)
		local removed = Players.PlayerRemoving:Connect(function(player)
			server.masking:unregister_client(player)
		end)
		for _, player in Players:GetPlayers() do
			server.masking:register_client(player)
		end

		table.insert(server.connections, added)
		table.insert(server.connections, removed)
	end
end

function server_replicator.encode_component(server: Server, component: Entity): number
	server_replicator.resolve_dirty(server)
	local encoded = server.shared.components.members[component]
	if not encoded then
		common.log_error(`attempted to encode a non-shared component `, common.log_component(server.world, component))
		return 0
	end
	return encoded
end

function server_replicator.decode_component(server: Server, encoded: number): Entity?
	server_replicator.resolve_dirty(server)
	local component = server.shared.components.indexes[encoded]
	return component
end

function server_replicator.get_shared_count(server: Server): number
	server_replicator.resolve_dirty(server)
	return #server.shared.components.keys
end

function server_replicator.mark_player_ready(server: Server, player: Player)
	server.masking:activate_client(player)
end

function server_replicator.is_player_ready(server: Server, player: Player): boolean
	return server.masking:member_is_active(player)
end

function server_replicator.add_player_alias(server: Server, client: Player, alias: any)
	server.masking.client_aliases[alias] = client
end

function server_replicator.remove_player_alias(server: Server, alias: any)
	server.masking.client_aliases[alias] = nil
end

function server_replicator.register_custom_id(server: Server, custom_id: CustomId)
	server.registered_custom_ids[custom_id] = true
	server.is_shared_dirty = true
end

function server_replicator.generate_handshake(server: Server): types.HandshakeInfo
	server_replicator.resolve_dirty(server)
	return utils.generate_handshake(server.shared)
end

function server_replicator.verify_handshake(server: Server, handshake: types.HandshakeInfo): (boolean, string?)
	server_replicator.resolve_dirty(server)
	return utils.verify_handshake(server.shared, handshake, "client", "server")
end

function server_replicator.destroy(server: Server)
	if server.inited == nil then
		return warn "attempted to destroy a server twice"
	end
	server.inited = nil :: any

	for _, unhook in server.hooked do
		unhook()
	end
	for _, connection in server.connections do
		connection:Disconnect()
	end
end

local function create(world: World?, components: types.Components?): Server
	local self = {} :: Server

	if components then
		self.components = components
	elseif world then
		self.components = utils.create_components(utils.tag_factory(world), utils.component_factory(world))
		utils.add_component_names(self.components, function(component, name)
			common.add_name(world, component, name)
		end)
	end

	self.shared = {} :: types.Shared
	self.world = world :: any
	self.additions = {}
	self.storage = {}
	self.hooked = {}
	self.is_shared_dirty = false
	self.global_ids = {}
	self.pending_cleanups = {}
	self.track_info = {
		networked = {},
		entities = {},
		components = {},
		pairs = {},
	}
	self.connections = {}
	self.inited = false
	self.masking = masking_controller.create()
	self.alive_tracked = {}
	self.custom_ids = {}
	self.registered_custom_ids = {}
	self.component_serdes = {}
	self.requires_shared_lookup = {
		self.components.shared,
		ECS_NAME,
	}

	return setmetatable(self, server_replicator) :: any
end

return {
	create = create,
	server_replicator = server_replicator,
}
