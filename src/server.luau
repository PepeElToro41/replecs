--!optimize 2
--!native

local jecs = require "../jecs"
local utils = require "./utils"
local common = require "./common"
local customid = require "./customid"
local masking_controller = require "./masking"

local cursor = utils.cursor

type Cursor = utils.Cursor
type CustomId = customid.CustomId

type World = jecs.World
type Entity<T = any> = jecs.Entity<T>
type Component = Entity

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }

type FunctionFilter = common.FunctionFilter
type AnyFilter = common.AnyFilter

type CustomIdSerialization = {
	required: Map<Entity, CustomId>,
	cursor_skip: number,
}

type TrackInfo = {
	networked: Set<Entity>,
	entities: Map<Entity, Map<Component, number>>,
	components: Map<Component, Map<Entity, number>>,
}

type EntityStorage = {
	tags: { [Component]: boolean },
	values: { [Component]: any },
	pairs: { [Component]: Set<Entity> },
	pairs_values: { [Component]: Map<Entity, any> },
}

type Storage = { [Entity]: EntityStorage }

export type ServerImpl = {
	set_networked: (server: Server, entity: Entity, filter: AnyFilter?) -> (),
	stop_networked: (server: Server, entity: Entity) -> (),

	set_reliable: (server: Server, entity: Entity, component: Component, filter: AnyFilter?) -> (),
	set_unreliable: (server: Server, entity: Entity, component: Component, filter: AnyFilter?) -> (),
	set_pair: (server: Server, entity: Entity, relation: Component, filter: AnyFilter?) -> (),
	set_custom: (server: Server, entity: Entity, component: Component | CustomId) -> (),

	stop_reliable: (server: Server, entity: Entity, component: Component) -> (),
	stop_unreliable: (server: Server, entity: Entity, component: Component) -> (),
	stop_pair: (server: Server, entity: Entity, relation: Component) -> (),
	remove_custom: (server: Server, entity: Entity) -> (),
}

export type Server = ServerImpl & {
	world: World,
	inited: boolean?,

	shared: common.Shared,

	components: common.Components,
	hooks: common.WorldHooks,
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

	init: (self: Server, world: World?) -> (),
	destroy: (self: Server) -> (),

	encode_component: (self: Server, component: Component) -> number,
	decode_component: (self: Server, component: number) -> Component,
	register_custom_id: (self: Server, custom_id: CustomId) -> (),

	get_full: (self: Server, player: Player) -> (buffer, { { any } }),
	collect_updates: (self: Server) -> () -> (Player, buffer, { { any } }),
	collect_unreliable: (self: Server) -> () -> (Player, buffer, { { any } }),

	mark_player_ready: (self: Server, player: Player) -> (),
	is_player_ready: (self: Server, player: Player) -> boolean,

	add_player_alias: (self: Server, client: Player, alias: any) -> (),
	remove_player_alias: (self: Server, alias: any) -> (),

	generate_handshake: (self: Server) -> common.ReplicationHandshake,
	verify_handshake: (self: Server, handshake: common.ReplicationHandshake) -> (boolean, string?),
}

local server_replicator = {}
server_replicator.__index = server_replicator

local NIL_COMPONENT_VALUE = newproxy()
local GLOBAL_ID_OFFSET = 10

local COMPONENT_TYPES = masking_controller.COMPONENT_TYPES
local TRACK_TYPES = {
	component = 1,
	tag = 2,
	pair = 3,
	pair_value = 4,
}

local PACKET_TYPES = {
	full = 1,
	unreliable = 2,
	reliable = 3,
}

local MAX_PACKET_SIZE = 900
local ENTITY_ID_TYPES = {
	entity = 1,
	custom_handler = 2,
	custom_id = 3,
	shared = 4,
}

local ECS_COMPONENT = jecs.Component
local WILDCARD = jecs.Wildcard

local function IS_PAIR(id: Component): boolean
	return jecs.IS_PAIR(id)
end

local function PAIR(relation: Entity, target: Entity): Entity
	return jecs.pair(relation, target)
end

local function PAIR_SECOND(world: World, id: Entity): Entity
	if not IS_PAIR(id) then
		error(`expected a pair, got: {utils.logcomponent(world, id)}`)
	end
	return jecs.pair_second(world, id)
end

local function track_entity_lifetime(server: Server, entity: Entity)
	if server.alive_tracked[entity] then
		return
	end
	server.alive_tracked[entity] = true
	server.world:add(entity, server.components.__alive_tracking__)
end

local function get_or_set_entity_storage(server: Server, entity: Entity): EntityStorage
	local storage = server.storage[entity]

	if not storage then
		storage = {
			tags = {},
			values = {},
			pairs = {},
			pairs_values = {},
		}
		server.storage[entity] = storage
	end

	return storage
end

local function add_entity_tracked(server: Server, entity: Entity, component: Component, track_type: number)
	local track = server.track_info.entities[entity]
	if track == nil then
		track = {
			[component] = track_type,
		}
		server.track_info.entities[entity] = track
	else
		track[component] = track_type
	end
end

local function remove_entity_tracked(server: Server, entity: Entity, component: Component)
	local track = server.track_info.entities[entity]
	if track then
		track[component] = nil
	end
end

local function allocate_component_change(server: Server, entity: Entity, component: Component, value: any)
	local storage = get_or_set_entity_storage(server, entity)

	local non_nil = if value == nil then NIL_COMPONENT_VALUE else value

	storage.values[component] = non_nil
	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_component_change(entity, component, non_nil)
	end
end
local function allocate_pair_value_change(
	server: Server,
	entity: Entity,
	relation: Component,
	target: Entity,
	value: any
)
	local storage = get_or_set_entity_storage(server, entity)

	local non_nil = if value == nil then NIL_COMPONENT_VALUE else value

	local values = storage.pairs_values[relation]
	if values == nil then
		values = {}
		storage.pairs_values[relation] = values
	end
	values[target] = non_nil

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_pair_value_change(entity, relation, target, non_nil)
	end
end

local function allocate_tag_addition(server: Server, entity: Entity, tag: Component)
	local storage = get_or_set_entity_storage(server, entity)
	storage.tags[tag] = true

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_tag_addition(entity, tag)
	end
end
local function allocate_pair_addition(server: Server, entity: Entity, relation: Component, target: Entity)
	local storage = get_or_set_entity_storage(server, entity)
	local targets = storage.pairs[relation]
	if targets == nil then
		targets = {}
		storage.pairs[relation] = targets
	end
	targets[target] = true

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_pair_addition(entity, relation, target)
	end
end

local function allocate_component_removal(server: Server, entity: Entity, component: Component)
	local storage = get_or_set_entity_storage(server, entity)
	storage.values[component] = nil

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_component_removal(entity, component)
	end
end
local function allocate_pair_value_removal(server: Server, entity: Entity, relation: Component, target: Entity)
	local storage = get_or_set_entity_storage(server, entity)
	local values = storage.pairs_values[relation]
	if values then
		values[target] = nil
	end

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_pair_value_removal(entity, relation, target)
	end
end

local function allocate_tag_removal(server: Server, entity: Entity, tag: Component)
	local storage = get_or_set_entity_storage(server, entity)
	storage.tags[tag] = nil

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_tag_removal(entity, tag)
	end
end
local function allocate_pair_removal(server: Server, entity: Entity, relation: Component, target: Entity)
	local storage = get_or_set_entity_storage(server, entity)
	local targets = storage.pairs[relation]
	if targets then
		targets[target] = nil
	end

	if not server.additions[entity] and server.track_info.networked[entity] then
		server.masking:allocate_pair_removal(entity, relation, target)
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
		for component in track_info do
			local track_component = server.track_info.components[component]
			if track_component then
				track_component[entity] = nil
			end
		end
		server.track_info.entities[entity] = nil
	end
end

local function track_component(server: Server, component: Component)
	local world = server.world
	local hooks = server.hooks

	if server.track_info.components[component] then
		error(`attemped to track a component twice: {utils.logcomponent(server.world, component)}`)
	end

	local info = {} :: Map<Entity, number>
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
		elseif track_type == TRACK_TYPES.pair then
			if not IS_PAIR(id) then
				return
			end
			allocate_pair_addition(server, entity, component, PAIR_SECOND(world, id))
		elseif track_type == TRACK_TYPES.pair_value then
			if not IS_PAIR(id) then
				return
			end
			allocate_pair_value_change(server, entity, component, PAIR_SECOND(world, id), value)
		end
	end))
	hook(hooks.changed(world, component, function(entity, id, value)
		local track_type = info[entity]
		if not track_type then
			return
		end
		if track_type == TRACK_TYPES.component then
			allocate_component_change(server, entity, component, value)
		elseif track_type == TRACK_TYPES.pair_value then
			if not IS_PAIR(id) then
				return
			end
			allocate_pair_value_change(server, entity, component, PAIR_SECOND(world, id), value)
		end
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
		elseif track_type == TRACK_TYPES.pair then
			if not IS_PAIR(id) then
				return
			end
			allocate_pair_removal(server, entity, component, PAIR_SECOND(world, id))
		elseif track_type == TRACK_TYPES.pair_value then
			if not IS_PAIR(id) then
				return
			end
			allocate_pair_value_removal(server, entity, component, PAIR_SECOND(world, id))
		end
	end))

	return info
end

local function track_entity_component(server: Server, entity: Entity, component: Entity<any>)
	local world = server.world
	local info = server.track_info.components[component]
	if not info then
		info = track_component(server, component)
	end

	local entity_storage = get_or_set_entity_storage(server, entity)

	if world:has(component, ECS_COMPONENT) then
		if world:has(entity, component) then
			local value = world:get(entity, component)

			if value == nil then
				entity_storage.values[component] = NIL_COMPONENT_VALUE
			else
				entity_storage.values[component] = value
			end
		end

		info[entity] = TRACK_TYPES.component
		add_entity_tracked(server, entity, component, TRACK_TYPES.component)

		return COMPONENT_TYPES.component
	else
		if world:has(entity, component) then
			entity_storage.tags[component] = true
		end

		info[entity] = TRACK_TYPES.tag
		add_entity_tracked(server, entity, component, TRACK_TYPES.tag)

		return COMPONENT_TYPES.tag
	end
end

local function track_entity_pair(server: Server, entity: Entity, relation: Entity)
	local world = server.world
	local info = server.track_info.components[relation]
	if not info then
		info = track_component(server, relation)
	end

	local entity_storage = get_or_set_entity_storage(server, entity)

	if world:has(relation, ECS_COMPONENT) then
		local targets = {} :: Map<Entity, any>

		local index = 0
		while true do
			local target = world:target(entity, relation, index)
			if not target then
				break
			end
			index += 1
			local value = world:get(entity, jecs.pair(relation, target))
			targets[target] = if value == nil then NIL_COMPONENT_VALUE else value :: any
		end

		entity_storage.pairs_values[relation] = targets
		info[entity] = TRACK_TYPES.pair_value
		add_entity_tracked(server, entity, relation, TRACK_TYPES.pair_value)

		return COMPONENT_TYPES.pair_value
	else
		local targets = {} :: Set<Entity>

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
		add_entity_tracked(server, entity, relation, TRACK_TYPES.pair)

		return COMPONENT_TYPES.pair
	end
end

local function untrack_entity_component(server: Server, entity: Entity, component: Entity<any>): number?
	local info = server.track_info.components[component]
	if not info then
		return nil
	end
	local listen_type = info[entity]
	info[entity] = nil

	local storage = server.storage[entity]
	if storage then
		storage.values[component] = nil
		storage.tags[component] = nil
	end

	local entity_tracked = server.track_info.entities[entity]
	if entity_tracked then
		entity_tracked[component] = nil
	end

	remove_entity_tracked(server, entity, component)

	return listen_type
end

local function untrack_entity_pair(server: Server, entity: Entity, relation: Entity): number?
	local info = server.track_info.components[relation]
	if not info then
		return nil
	end
	local listen_type = info[entity]
	info[entity] = nil

	local storage = server.storage[entity]
	if storage then
		storage.pairs[relation] = nil
		storage.pairs_values[relation] = nil
	end

	local entity_tracked = server.track_info.entities[entity]
	if entity_tracked then
		entity_tracked[relation] = nil
	end

	remove_entity_tracked(server, entity, relation)
	return listen_type
end

function server_replicator.encode_component(server: Server, component: Entity): number
	local encoded = server.shared.components.members[component]
	if not encoded then
		utils.logerror(`attempted to encode a non-shared component `, utils.logcomponent(server.world, component))
		return 0
	end
	return encoded
end

function server_replicator.decode_component(server: Server, encoded: number): Entity
	local component = server.shared.components.indexes[encoded]
	if not component then
		print("NON SHARED COMPONENTS", encoded, server.shared.components)
		error "attemped to decode a non shared component"
	end
	return component
end

function server_replicator.write_component_id(server: Server, c: Cursor, component: Entity)
	local shared_componens = server.shared.components
	local encoded = shared_componens.members[component]
	if not encoded then
		utils.logerror(`attempted to replicate a non-shared component `, utils.logcomponent(server.world, component))
		return
	end
	cursor.write_span(c, encoded, #shared_componens.keys)
end

function server_replicator.write_component_value(
	server: Server,
	c: Cursor,
	component: Entity,
	value: any,
	variants: { any }
)
	local serdes = server.shared.serdes[component]
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
			utils.logerror(
				"serdes: serializer provided variants yet includes_variants is not set to true for component",
				utils.logcomponent(server.world, component)
			)
		end

		local bytespan = serdes.bytespan
		cursor.write_buffer(c, output)
		if bytespan then
			if bytespan ~= buffer.len(output) then
				utils.logerror(
					`bytespan: {bytespan} mismatch for buffer lenght: {buffer.len(output)} in component`,
					utils.logcomponent(server.world, component)
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

function server_replicator.write_component(server: Server, c: Cursor, component: Entity, value: any, variants: { any })
	server_replicator.write_component_value(server, c, component, value, variants)
	server_replicator.write_component_id(server, c, component)
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
	local targets = storage.pairs[relation]
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
	local targets = storage.pairs_values[relation]
	local total_targets = 0

	for target, value in targets do
		server_replicator.write_entity_id(server, c, target)
		server_replicator.write_component_value(server, c, relation, value, variants)
		total_targets += 1
	end
	cursor.write_vlq(c, total_targets)
	server_replicator.write_component_id(server, c, relation)
end

function server_replicator.write_entity(
	server: Server,
	c: Cursor,
	entity: Entity,
	active: masking_controller.ActiveEntity,
	variants: { any }
)
	local storage = server.storage[entity]

	local all_pairs_values = 0
	for relation in active.components[COMPONENT_TYPES.pair_value] do
		server_replicator.write_entity_relations_values(server, storage, c, relation, variants)
		all_pairs_values += 1
	end
	cursor.write_vlq(c, all_pairs_values)

	local all_pairs = 0
	for relation in active.components[COMPONENT_TYPES.pair] do
		server_replicator.write_entity_relations(server, storage, c, relation)
		all_pairs += 1
	end
	cursor.write_vlq(c, all_pairs)

	local components = 0
	for component in active.components[COMPONENT_TYPES.component] do
		local value = storage.values[component]
		if value == nil then
			continue
		end

		server_replicator.write_component(server, c, component, value, variants)
		components += 1
	end
	cursor.write_vlq(c, components)

	local tags = 0
	for tag in active.components[COMPONENT_TYPES.tag] do
		local has_tag = storage.tags[tag]
		if has_tag then
			server_replicator.write_component_id(server, c, tag)
			tags += 1
		end
	end
	cursor.write_vlq(c, tags)
	server_replicator.write_entity_id(server, c, entity)
end

function server_replicator.resolve_dirty(server: Server)
	if server.is_shared_dirty then
		server.shared = utils.resolved_shared(server.world, server.components, server.registered_custom_ids)
		server.is_shared_dirty = false
	end
end

type Packet = {
	buffer: buffer,
	variants: { { any } },
}
type MemberPackets = {
	packets: Array<Packet>,
	variants: { { any } },
	total_size: number,
}

local function append_packet(
	packets: { [Player]: MemberPackets },
	members: { any },
	output: buffer,
	variants: { { any } }
)
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
		utils.logerror "attempted to replicate for a non registered client"
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
		local variants = {}

		local total_entities = 0
		for entity, active in storage.active do
			server_replicator.write_entity(server, c, entity, active, variants)
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

local function write_vlq_bitmask(c: Cursor, value: number, mask: number, bit: number): number
	if value > 0 then
		cursor.write_vlq(c, value)
		return utils.setbit(mask, bit)
	else
		return mask
	end
end

function server_replicator.collect_updates(server: Server)
	server_replicator.resolve_dirty(server)
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
			local total_pairs = 0

			for relation in deleted[COMPONENT_TYPES.pair_value] do
				server_replicator.write_component_id(server, c, relation)
				total_pairs += 1
			end
			for relation in deleted[COMPONENT_TYPES.pair] do
				server_replicator.write_component_id(server, c, relation)
				total_pairs += 1
			end
			cursor.write_vlq(c, total_pairs)

			local total_removed = 0
			for component in deleted[COMPONENT_TYPES.component] do
				server_replicator.write_component_id(server, c, component)
				total_removed += 1
			end
			for tag in deleted[COMPONENT_TYPES.tag] do
				server_replicator.write_component_id(server, c, tag)
				total_removed += 1
			end
			cursor.write_vlq(c, total_removed)

			server_replicator.write_entity_id(server, c, entity)
			total_component_deleted += 1
		end
		table.clear(component_deletions)
		storage_mask = write_vlq_bitmask(c, total_component_deleted, storage_mask, 3)

		local storage_changes = storage.changes
		local changed = 0
		for entity, changes in storage_changes.changed do
			local changed_mask = 0

			local total_pairs_values = 0
			for relation, targets in changes.pairs_values.changed do
				local total_targets = 0

				for target, value in targets do
					server_replicator.write_entity_id(server, c, target)
					server_replicator.write_component_value(server, c, relation, value, variants)
					total_targets += 1
				end
				cursor.write_vlq(c, total_targets)
				server_replicator.write_component_id(server, c, relation)
				total_pairs_values += 1
			end
			changed_mask = write_vlq_bitmask(c, total_pairs_values, changed_mask, 5)

			local total_pairs_values_removed = 0
			for relation, targets in changes.pairs_values.removed do
				local total_targets = 0

				for target in targets do
					server_replicator.write_entity_id(server, c, target)
					total_targets += 1
				end
				cursor.write_vlq(c, total_targets)
				server_replicator.write_component_id(server, c, relation)
				total_pairs_values_removed += 1
			end
			changed_mask = write_vlq_bitmask(c, total_pairs_values_removed, changed_mask, 4)

			local total_pairs = 0
			for relation, targets in changes.pairs do
				local total_targets = 0

				for target, added in targets do
					server_replicator.write_entity_id(server, c, target)
					if added then
						cursor.writei8(c, 1)
					else
						cursor.writei8(c, -1)
					end
					total_targets += 1
				end
				cursor.write_vlq(c, total_targets)
				server_replicator.write_component_id(server, c, relation)
				total_pairs += 1
			end
			changed_mask = write_vlq_bitmask(c, total_pairs, changed_mask, 3)

			local total_removed = 0
			for component in changes.removed do
				server_replicator.write_component_id(server, c, component)
				total_removed += 1
			end
			changed_mask = write_vlq_bitmask(c, total_removed, changed_mask, 2)

			local total_components = 0
			for component, value in changes.component do
				server_replicator.write_component(server, c, component, value, variants)
				total_components += 1
			end
			changed_mask = write_vlq_bitmask(c, total_components, changed_mask, 1)

			local total_tagged = 0
			for tag in changes.tagged do
				server_replicator.write_component_id(server, c, tag)
				total_tagged += 1
			end
			changed_mask = write_vlq_bitmask(c, total_tagged, changed_mask, 0)

			if changed_mask ~= 0 then
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

			local total_pairs_values = 0
			for relation in components[COMPONENT_TYPES.pair_value] do
				server_replicator.write_entity_relations_values(server, entity_storage, c, relation, variants)
				total_pairs_values += 1
			end
			added_mask = write_vlq_bitmask(c, total_pairs_values, added_mask, 3)

			local total_pairs = 0
			for relation in components[COMPONENT_TYPES.pair] do
				server_replicator.write_entity_relations(server, entity_storage, c, relation)
				total_pairs += 1
			end
			added_mask = write_vlq_bitmask(c, total_pairs, added_mask, 2)

			local total_components = 0
			for component in components[COMPONENT_TYPES.component] do
				local value = entity_storage.values[component]
				if value == nil then
					continue
				end
				server_replicator.write_component(server, c, component, value, variants)
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
	return create_packet_iterator(packets, PACKET_TYPES.reliable)
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
		local variants = {} :: { { any } }
		local custom_ids: Set<Entity> = {}
		local total_entities = 0

		local checkpoint_offset = 0
		local checkpoint_variants_count = 0
		local checkpoint_total_entities = 0
		local checkpoint_entity: Entity? = nil

		local function create_checkpoint(entity: Entity)
			checkpoint_offset = c.offset
			checkpoint_variants_count = #variants
			checkpoint_total_entities = total_entities
			checkpoint_entity = entity
		end

		local function rollback_checkpoint()
			local new_cursor = cursor.new()
			cursor.write_buffer(new_cursor, c.buffer, checkpoint_offset, c.offset - checkpoint_offset)
			c.offset = checkpoint_offset
			c = new_cursor

			local new_variants = {} :: { { any } }
			for _ = #variants, checkpoint_variants_count + 1, -1 do
				table.insert(new_variants, 1, table.remove(variants))
			end

			local new_custom_ids = {} :: Set<Entity>
			if checkpoint_entity then
				new_custom_ids[checkpoint_entity] = true
				custom_ids[checkpoint_entity] = nil
			end
			custom_ids = new_custom_ids

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
			create_checkpoint(entity)

			local total_unreliable = 0
			for component in actives.components[COMPONENT_TYPES.unreliable] do
				local value = world:get(entity, component)
				if value == nil then
					continue
				end

				server_replicator.write_component(server, c, component, value, variants)
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

	masking:unregister_stop_entity(entity)
	masking:start_entity(entity, filter)
	masking:propagate_entity_addition(entity)

	server.additions[entity] = true
	server.track_info.networked[entity] = true
	track_entity_lifetime(server, entity)
end
function server_replicator.start_reliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local masking = server.masking

	local component_type = track_entity_component(server :: Server, entity, component)
	masking:unregister_stop_component(entity, component, component_type)
	masking:start_component(entity, component, component_type, filter)
	if server.additions[entity] then
		masking:allocate_entity_addition(entity, component, component_type)
	elseif server.track_info.networked[entity] then
		masking:register_component_addition(entity, component, component_type)
	end
end

function server_replicator.start_unreliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local masking = server.masking

	masking:unregister_stop_component(entity, component, COMPONENT_TYPES.unreliable)
	masking:start_component(entity, component, COMPONENT_TYPES.unreliable, filter)
	if server.additions[entity] then
		masking:allocate_entity_addition(entity, component, COMPONENT_TYPES.unreliable)
	end
end

function server_replicator.start_pair(server: Server, entity: Entity, relation: Component, filter: AnyFilter?)
	local masking = server.masking

	local component_type = track_entity_pair(server, entity, relation)
	masking:unregister_stop_component(entity, relation, component_type)
	masking:start_component(entity, relation, component_type, filter)
	if server.additions[entity] then
		masking:allocate_entity_addition(entity, relation, component_type)
	elseif server.track_info.networked[entity] then
		masking:register_component_addition(entity, relation, component_type)
	end
end

function server_replicator.change_networked(server: Server, entity: Entity, filter: AnyFilter?)
	local masking = server.masking
	masking:set_entity(entity, filter)
end
function server_replicator.change_reliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local world = server.world
	local masking = server.masking

	if world:has(component, ECS_COMPONENT) then
		masking:set_component(entity, component, COMPONENT_TYPES.component, filter)
	else
		masking:set_component(entity, component, COMPONENT_TYPES.tag, filter)
	end
end
function server_replicator.change_unreliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local masking = server.masking
	masking:set_component(entity, component, COMPONENT_TYPES.unreliable, filter)
end
function server_replicator.change_pair(server: Server, entity: Entity, relation: Component, filter: AnyFilter?)
	local world = server.world
	local masking = server.masking

	if world:has(relation, ECS_COMPONENT) then
		masking:set_component(entity, relation, COMPONENT_TYPES.pair_value, filter)
	else
		masking:set_component(entity, relation, COMPONENT_TYPES.pair, filter)
	end
end

function server_replicator.stop_networked(server: Server, entity: Entity)
	if not server.track_info.networked[entity] then
		return
	end

	local masking = server.masking
	masking:register_stop_entity(entity)
	masking:stop_entity(entity)

	server.additions[entity] = nil
	server.track_info.networked[entity] = nil
end
function server_replicator.stop_reliable(server: Server, entity: Entity, component: Component)
	local masking = server.masking
	if not server.track_info.entities[entity] then
		return
	end

	local component_type = untrack_entity_component(server, entity, component)
	if not component_type then
		return
	end

	if server.track_info.networked[entity] then
		masking:unregister_component_addition(entity, component, component_type)
		masking:register_stop_component(entity, component, component_type)
	end
	masking:stop_component(entity, component, component_type)
end
function server_replicator.stop_unreliable(server: Server, entity: Entity, component: Component)
	local masking = server.masking
	if not server.track_info.entities[entity] then
		return
	end

	local component_type = untrack_entity_component(server, entity, component)
	if not component_type then
		return
	end

	if server.track_info.networked[entity] then
		masking:register_stop_component(entity, component, COMPONENT_TYPES.unreliable)
	end
	masking:stop_component(entity, component, COMPONENT_TYPES.unreliable)
end
function server_replicator.stop_pair(server: Server, entity: Entity, relation: Component)
	local masking = server.masking
	if not server.track_info.entities[entity] then
		return
	end

	local component_type = untrack_entity_pair(server, entity, relation)
	if not component_type then
		return
	end

	if server.track_info.networked[entity] then
		masking:unregister_component_addition(entity, relation, component_type)
		masking:register_stop_component(entity, relation, component_type)
	end
	masking:stop_component(entity, relation, component_type)
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
	if entity_tracked and entity_tracked[component] then
		server_replicator.change_reliable(server, entity, component, filter)
	else
		server_replicator.start_reliable(server, entity, component, filter)
	end
end
function server_replicator.set_unreliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local entity_tracked = server.track_info.entities[entity]
	if entity_tracked and entity_tracked[component] then
		server_replicator.change_unreliable(server, entity, component, filter)
	else
		server_replicator.start_unreliable(server, entity, component, filter)
	end
end
function server_replicator.set_pair(server: Server, entity: Entity, relation: Component, filter: AnyFilter?)
	local entity_tracked = server.track_info.entities[entity]
	if entity_tracked and entity_tracked[relation] then
		server_replicator.change_pair(server, entity, relation, filter)
	else
		server_replicator.start_pair(server, entity, relation, filter)
	end
end
function server_replicator.set_custom(server: Server, entity: Entity, handler: Component | CustomId)
	if server.custom_ids[entity] then
		utils.logwarn("attempted to register a custom_id twice for the same entity", debug.traceback())
		return
	end
	server.custom_ids[entity] = handler
end

function server_replicator.remove_custom(server: Server, entity: Entity)
	server.custom_ids[entity] = nil
end

local function check_created(server: Server)
	if server.inited == true then
		warn "attempted to init a server twice"
		return false
	end
	if server.inited == nil then
		warn "attempted to create a server twice"
		return false
	end
	return true
end

local function query_tracking_type(server: Server, track_type: Component)
	for entity in server.world:query(PAIR(track_type, WILDCARD)):iter() do
		local index = 0
		while true do
			local target = server.world:target(entity, track_type, index)
			if not target then
				break
			end
			server.set_reliable(server, entity, target, server.world:get(entity, PAIR(track_type, target)))
			index += 1
		end
	end
end

local function query_current_networked(server: Server)
	for entity, filter in server.world:query(server.components.networked):iter() do
		server.set_networked(server, entity, filter)
	end

	query_tracking_type(server, server.components.reliable)
	query_tracking_type(server, server.components.unreliable)
	query_tracking_type(server, server.components.pair)
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

	local hooks = {
		added = (world :: any).added,
		changed = (world :: any).changed,
		removed = (world :: any).removed,
	}
	server.hooks = hooks

	local components = server.components
	server.shared = utils.resolved_shared(world, components, server.registered_custom_ids)

	local function hook(unhook: () -> ())
		table.insert(server.hooked, unhook)
	end

	hook(hooks.added(world, components.networked, function(entity, _, filter)
		server_replicator.start_networked(server, entity, filter)
	end))
	hook(hooks.changed(world, components.networked, function(entity, _, filter)
		server_replicator.change_networked(server, entity, filter)
	end))
	hook(hooks.removed(world, components.networked, function(entity)
		server_replicator.stop_networked(server, entity)
	end))

	hook(hooks.added(world, components.reliable, function(entity, id, filter)
		local component = PAIR_SECOND(world, id)
		server_replicator.start_reliable(server, entity, component, filter)
	end))
	hook(hooks.changed(world, components.reliable, function(entity, id, filter)
		local component = PAIR_SECOND(world, id)
		server_replicator.change_reliable(server, entity, component, filter)
	end))
	hook(hooks.removed(world, components.reliable, function(entity, id)
		local component = PAIR_SECOND(world, id)
		server_replicator.stop_reliable(server, entity, component)
	end))

	hook(hooks.added(world, components.pair, function(entity, id, filter)
		local relation = PAIR_SECOND(world, id)
		server_replicator.start_pair(server, entity, relation, filter)
	end))
	hook(hooks.changed(world, components.pair, function(entity, id, filter)
		local relation = PAIR_SECOND(world, id)
		server_replicator.change_pair(server, entity, relation, filter)
	end))
	hook(hooks.removed(world, components.pair, function(entity, id)
		local relation = PAIR_SECOND(world, id)
		server_replicator.stop_pair(server, entity, relation)
	end))

	hook(hooks.added(world, components.unreliable, function(entity, id, filter)
		local component = PAIR_SECOND(world, id)
		server_replicator.start_unreliable(server, entity, component, filter)
	end))
	hook(hooks.changed(world, components.unreliable, function(entity, id, filter)
		local component = PAIR_SECOND(world, id)
		server_replicator.change_unreliable(server, entity, component, filter)
	end))
	hook(hooks.removed(world, components.unreliable, function(entity, id)
		local component = PAIR_SECOND(world, id)
		server_replicator.stop_unreliable(server, entity, component)
	end))

	hook(hooks.added(world, components.custom, function(entity, id)
		if not IS_PAIR(id) then
			utils.logerror "replecs.custom should be used with a relationship in the server"
		end
		local target = PAIR_SECOND(world, id)
		server_replicator.set_custom(server, entity, target)
	end))
	hook(hooks.removed(world, components.custom, function(entity)
		server_replicator.remove_custom(server, entity)
	end))
	hook(hooks.added(world, components.global, function(entity, _, value)
		if value > 245 then
			utils.logerror "global id size exceeded, max is 245"
		end
		server.global_ids[entity] = value
	end))

	hook(hooks.changed(world, components.global, function(entity, _, value)
		if value > 245 then
			utils.logerror "global id size exceeded, max is 245"
		end
		server.global_ids[entity] = value
	end))
	hook(hooks.removed(world, components.global, function(entity)
		server.global_ids[entity] = nil
	end))

	hook(hooks.removed(world, components.__alive_tracking__, function(entity)
		if server.track_info.networked[entity] then
			server_replicator.stop_networked(server, entity)
		end
		cleanup_entity(server, entity)
	end))

	for _, component in server.requires_shared_lookup do
		hook(hooks.added(world, component, function()
			server.is_shared_dirty = true
		end))
		hook(hooks.changed(world, component, function()
			server.is_shared_dirty = true
		end))
		hook(hooks.removed(world, component, function()
			server.is_shared_dirty = true
		end))
	end

	query_current_networked(server)

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

function server_replicator.generate_handshake(server: Server): common.ReplicationHandshake
	server_replicator.resolve_dirty(server)
	return utils.generate_handshake(server.world, server.shared)
end

function server_replicator.verify_handshake(server: Server, handshake: common.ReplicationHandshake): (boolean, string?)
	server_replicator.resolve_dirty(server)
	return utils.verify_handshake(server.world, server.shared, handshake, "client", "server")
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

local function create(world: World?, components: common.Components): Server
	local self = {} :: Server

	self.components = components

	self.shared = {} :: common.Shared
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
	}
	self.connections = {}
	self.inited = false
	self.masking = masking_controller.create()
	self.alive_tracked = {}
	self.custom_ids = {}
	self.registered_custom_ids = {}
	self.requires_shared_lookup = {
		self.components.shared,
		self.components.serdes,
		jecs.Name,
	}

	return setmetatable(self, server_replicator) :: any
end

return {
	create = create,
	server_replicator = server_replicator,
}
