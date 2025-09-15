--!optimize 2
--!native

local jecs = require "../jecs"
local utils = require "./utils"
local common = require "./common"
local masking_controller = require "./masking"

type Cursor = utils.Cursor

type World = jecs.World
type Entity<T = any> = jecs.Entity<T>
type Component = Entity

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }

type FunctionFilter = (player: Player) -> boolean
type AnyFilter = common.PlayerFilter | Player

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
	set_custom: (server: Server, entity: Entity, component: Component) -> (),

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
	custom_ids: Map<Entity, Component>,
	global_ids: Map<Entity, number>,
	storage: Storage,
	hooked: Array<() -> ()>,
	masking: masking_controller.MaskingController,
	pending_cleanups: Set<Entity>,
	connections: Array<RBXScriptConnection>,
	function_filters: masking_controller.EntityComponentIndex<FunctionFilter>,

	init: (self: Server, world: World?) -> (),
	destroy: (self: Server) -> (),

	encode_component: (self: Server, component: Component) -> number,
	decode_component: (self: Server, component: number) -> Component,

	get_full: (self: Server, player: Player) -> (buffer, { { any } }),
	collect_updates: (self: Server) -> () -> (Player, buffer, { { any } }),
	collect_unreliable: (self: Server) -> () -> (Player, buffer, { { any } }),
	mark_player_ready: (self: Server, player: Player) -> (),
	is_player_ready: (self: Server, player: Player) -> boolean,
	add_player_alias: (self: Server, client: Player, alias: any) -> (),
	remove_player_alias: (self: Server, alias: any) -> (),
}

local cursor = utils.cursor

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
	custom = 2,
	shared = 3,
}
local ECS_COMPONENT = jecs.Component

local function IS_PAIR(id: Component): boolean
	return jecs.IS_PAIR(id)
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

local function encode_component(server: Server, component: Entity): number
	local encoded = server.shared.ids[component]
	if not encoded then
		utils.logerror(`attempted to encode a non-shared component `, utils.logcomponent(server.world, component))
		return 0
	end
	return encoded
end

local function decode_component(server: Server, encoded: number): Entity
	local component = server.shared.components[encoded]
	if not component then
		print("NON SHARED COMPONENTS", encoded, server.shared.components)
		error "attemped to decode a non shared component"
	end
	return component
end

local function write_component_id(server: Server, c: Cursor, component: Entity)
	local encoded = server.shared.ids[component]
	if not encoded then
		utils.logerror(`attempted to replicate a non-shared component `, utils.logcomponent(server.world, component))
		return
	end
	cursor.writeu8(c, encoded)
end

local function write_component_value(server: Server, c: Cursor, component: Entity, value: any, variants: { any })
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

		local bytespan = server.shared.bytespan[component]
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

local function write_component(server: Server, c: Cursor, component: Entity, value: any, variants: { any })
	write_component_value(server, c, component, value, variants)
	write_component_id(server, c, component)
end

local function write_entity_id(server: Server, c: Cursor, entity: Entity, variants: { any })
	local custom = server.custom_ids[entity]
	local global_id = server.global_ids[entity]

	if global_id then
		cursor.writeu8(c, global_id + GLOBAL_ID_OFFSET)
	elseif custom then
		local value = server.world:get(entity, custom)
		write_component(server, c, custom, value, variants)
		cursor.writeu8(c, ENTITY_ID_TYPES.custom)
	else
		local shared_id = server.shared.ids[entity]
		if shared_id then
			cursor.writeu8(c, shared_id)
			cursor.writeu8(c, ENTITY_ID_TYPES.shared)
		else
			cursor.writeu40(c, entity :: any)
			cursor.writeu8(c, ENTITY_ID_TYPES.entity, entity)
		end
	end
end

local function write_entity_relations(
	server: Server,
	storage: EntityStorage,
	c: Cursor,
	relation: Entity,
	variants: { any }
)
	local targets = storage.pairs[relation]
	local total_targets = 0

	for target in targets do
		write_entity_id(server, c, target, variants)
		total_targets += 1
	end
	cursor.write_vlq(c, total_targets)
	write_component_id(server, c, relation)
end

local function write_entity_relations_values(
	server: Server,
	storage: EntityStorage,
	c: Cursor,
	relation: Entity,
	variants: { any }
)
	local targets = storage.pairs_values[relation]
	local total_targets = 0

	for target, value in targets do
		write_entity_id(server, c, target, variants)
		write_component_value(server, c, relation, value, variants)
		total_targets += 1
	end
	cursor.write_vlq(c, total_targets)
	write_component_id(server, c, relation)
end

local function write_entity(
	server: Server,
	c: Cursor,
	entity: Entity,
	active: masking_controller.ActiveEntity,
	variants: { any }
)
	local storage = server.storage[entity]

	local all_pairs_values = 0
	for relation in active.components[COMPONENT_TYPES.pair_value] do
		write_entity_relations_values(server, storage, c, relation, variants)
		all_pairs_values += 1
	end
	cursor.write_vlq(c, all_pairs_values)

	local all_pairs = 0
	for relation in active.components[COMPONENT_TYPES.pair] do
		write_entity_relations(server, storage, c, relation, variants)
		all_pairs += 1
	end
	cursor.write_vlq(c, all_pairs)

	local components = 0
	for component in active.components[COMPONENT_TYPES.component] do
		local value = storage.values[component]
		if value == nil then
			continue
		end

		write_component(server, c, component, value, variants)
		components += 1
	end
	cursor.write_vlq(c, components)

	local tags = 0
	for tag in active.components[COMPONENT_TYPES.tag] do
		local has_tag = storage.tags[tag]
		if has_tag then
			write_component_id(server, c, tag)
			tags += 1
		end
	end
	cursor.write_vlq(c, tags)
	write_entity_id(server, c, entity, variants)
end

local function resolve_dirty(server: Server)
	if server.is_shared_dirty then
		server.shared = utils.create_shared_lookup(server.world, server.components)
		server.is_shared_dirty = false :: true -- wtf
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

local function get_full(server: Server, client: Player): (buffer, { { any } })
	resolve_dirty(server)
	local index = server.masking.client_indexes[client]
	if index == nil then
		utils.logerror "attempted to replicate for a non registered client"
	end

	local packets: Array<Packet> = {}
	local total_size = 0

	-- maybe edges to quickly find all relevant storages improves performance?
	for _, storage in server.masking.storages do
		if not storage.mask.bitmask:get(index) then
			continue
		end
		local c = cursor.new()
		local variants = {}

		local total_entities = 0
		for entity, active in storage.active do
			write_entity(server, c, entity, active, variants)
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

local function collect_updates(server: Server)
	resolve_dirty(server)
	local packets: { [Player]: MemberPackets } = {}

	for _, storage in server.masking.storages do
		local c = cursor.new()

		local variants = {}
		local storage_mask = 0

		local total_deleted = 0
		local entity_deletions = storage.deletions.entities
		for entity in entity_deletions do
			write_entity_id(server, c, entity, variants)
			total_deleted += 1
		end
		table.clear(entity_deletions)
		storage_mask = write_vlq_bitmask(c, total_deleted, storage_mask, 4)

		local total_component_deleted = 0
		local component_deletions = storage.deletions.components
		for entity, deleted in component_deletions do
			local total_pairs = 0
			for relation in deleted[COMPONENT_TYPES.pair_value] do
				write_component_id(server, c, relation)
				total_pairs += 1
			end
			for relation in deleted[COMPONENT_TYPES.pair] do
				write_component_id(server, c, relation)
				total_pairs += 1
			end
			cursor.write_vlq(c, total_pairs)

			local total_removed = 0
			for component in deleted[COMPONENT_TYPES.component] do
				write_component_id(server, c, component)
				total_removed += 1
			end
			for tag in deleted[COMPONENT_TYPES.tag] do
				write_component_id(server, c, tag)
				total_removed += 1
			end
			cursor.write_vlq(c, total_removed)

			write_entity_id(server, c, entity, variants)
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
					write_entity_id(server, c, target, variants)
					write_component_value(server, c, relation, value, variants)
					total_targets += 1
				end
				cursor.write_vlq(c, total_targets)
				write_component_id(server, c, relation)
				total_pairs_values += 1
			end
			changed_mask = write_vlq_bitmask(c, total_pairs_values, changed_mask, 5)

			local total_pairs_values_removed = 0
			for relation, targets in changes.pairs_values.removed do
				local total_targets = 0

				for target in targets do
					write_entity_id(server, c, target, variants)
					total_targets += 1
				end
				cursor.write_vlq(c, total_targets)
				write_component_id(server, c, relation)
				total_pairs_values_removed += 1
			end
			changed_mask = write_vlq_bitmask(c, total_pairs_values_removed, changed_mask, 4)

			local total_pairs = 0
			for relation, targets in changes.pairs do
				local total_targets = 0

				for target, added in targets do
					write_entity_id(server, c, target, variants)
					if added then
						cursor.writei8(c, 1)
					else
						cursor.writei8(c, -1)
					end
					total_targets += 1
				end
				cursor.write_vlq(c, total_targets)
				write_component_id(server, c, relation)
				total_pairs += 1
			end
			changed_mask = write_vlq_bitmask(c, total_pairs, changed_mask, 3)

			local total_removed = 0
			for component in changes.removed do
				write_component_id(server, c, component)
				total_removed += 1
			end
			changed_mask = write_vlq_bitmask(c, total_removed, changed_mask, 2)

			local total_components = 0
			for component, value in changes.component do
				write_component(server, c, component, value, variants)
				total_components += 1
			end
			changed_mask = write_vlq_bitmask(c, total_components, changed_mask, 1)

			local total_tagged = 0
			for tag in changes.tagged do
				write_component_id(server, c, tag)
				total_tagged += 1
			end
			changed_mask = write_vlq_bitmask(c, total_tagged, changed_mask, 0)

			if changed_mask ~= 0 then
				cursor.writeu8(c, changed_mask)
				write_entity_id(server, c, entity, variants)
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
				write_entity_relations_values(server, entity_storage, c, relation, variants)
				total_pairs_values += 1
			end
			added_mask = write_vlq_bitmask(c, total_pairs_values, added_mask, 3)

			local total_pairs = 0
			for relation in components[COMPONENT_TYPES.pair] do
				write_entity_relations(server, entity_storage, c, relation, variants)
				total_pairs += 1
			end
			added_mask = write_vlq_bitmask(c, total_pairs, added_mask, 2)

			local total_components = 0
			for component in components[COMPONENT_TYPES.component] do
				local value = entity_storage.values[component]
				if value == nil then
					continue
				end
				write_component(server, c, component, value, variants)
				total_components += 1
			end
			added_mask = write_vlq_bitmask(c, total_components, added_mask, 1)

			local total_tags = 0
			for component in components[COMPONENT_TYPES.tag] do
				local has_tag = entity_storage.tags[component]
				if has_tag then
					write_component_id(server, c, component)
					total_tags += 1
				end
			end
			added_mask = write_vlq_bitmask(c, total_tags, added_mask, 0)

			if added_mask ~= 0 then
				cursor.writeu8(c, added_mask)
				write_entity_id(server, c, entity, variants)
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

			write_entity(server, c, entity, active, variants)
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

local function collect_unreliable(server: Server)
	resolve_dirty(server)
	local world = server.world
	local packets: { [Player]: MemberPackets } = {}

	for _, mask_storage in server.masking.storages do
		local active = mask_storage.active

		local c = cursor.new()
		local variants = {} :: { { any } }
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

			local new_variants = {} :: { { any } }
			for _ = #variants, checkpoint_variants_count + 1, -1 do
				table.insert(new_variants, 1, table.remove(variants))
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
				local value = world:get(entity, component)
				if value == nil then
					continue
				end

				write_component(server, c, component, value, variants)
				total_unreliable += 1
			end

			if total_unreliable <= 0 then
				continue
			end
			total_entities += 1
			cursor.write_vlq(c, total_unreliable)
			write_entity_id(server, c, entity, variants)

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

local function start_networked(server: Server, entity: Entity, filter: AnyFilter?)
	local masking = server.masking

	masking:unregister_stop_entity(entity)
	masking:start_entity(entity, filter)
	masking:propagate_entity_addition(entity)

	server.additions[entity] = true
	server.track_info.networked[entity] = true
	track_entity_lifetime(server, entity)
end
local function start_reliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
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

local function start_unreliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local masking = server.masking

	masking:unregister_stop_component(entity, component, COMPONENT_TYPES.unreliable)
	masking:start_component(entity, component, COMPONENT_TYPES.unreliable, filter)
	if server.additions[entity] then
		masking:allocate_entity_addition(entity, component, COMPONENT_TYPES.unreliable)
	end
end

local function start_pair(server: Server, entity: Entity, relation: Component, filter: AnyFilter?)
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

local function change_networked(server: Server, entity: Entity, filter: AnyFilter?)
	local masking = server.masking
	masking:set_entity(entity, filter)
end

local function change_reliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local world = server.world
	local masking = server.masking

	if world:has(component, ECS_COMPONENT) then
		masking:set_component(entity, component, COMPONENT_TYPES.component, filter)
	else
		masking:set_component(entity, component, COMPONENT_TYPES.tag, filter)
	end
end
local function change_unreliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local masking = server.masking
	masking:set_component(entity, component, COMPONENT_TYPES.unreliable, filter)
end
local function change_pair(server: Server, entity: Entity, relation: Component, filter: AnyFilter?)
	local world = server.world
	local masking = server.masking

	if world:has(relation, ECS_COMPONENT) then
		masking:set_component(entity, relation, COMPONENT_TYPES.pair_value, filter)
	else
		masking:set_component(entity, relation, COMPONENT_TYPES.pair, filter)
	end
end

local function stop_networked(server: Server, entity: Entity)
	if not server.track_info.networked[entity] then
		return
	end

	local masking = server.masking
	masking:register_stop_entity(entity)
	masking:stop_entity(entity)

	server.additions[entity] = nil
	server.track_info.networked[entity] = nil
end

local function stop_reliable(server: Server, entity: Entity, component: Component)
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
local function stop_unreliable(server: Server, entity: Entity, component: Component)
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
local function stop_pair(server: Server, entity: Entity, relation: Component)
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

local function set_networked(server: Server, entity: Entity, filter: AnyFilter?)
	if server.track_info.networked[entity] then
		change_networked(server, entity, filter)
	else
		start_networked(server, entity, filter)
	end
end

local function set_reliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local entity_tracked = server.track_info.entities[entity]
	if entity_tracked and entity_tracked[component] then
		change_reliable(server, entity, component, filter)
	else
		start_reliable(server, entity, component, filter)
	end
end

local function set_unreliable(server: Server, entity: Entity, component: Component, filter: AnyFilter?)
	local entity_tracked = server.track_info.entities[entity]
	if entity_tracked and entity_tracked[component] then
		change_unreliable(server, entity, component, filter)
	else
		start_unreliable(server, entity, component, filter)
	end
end

local function set_pair(server: Server, entity: Entity, relation: Component, filter: AnyFilter?)
	local entity_tracked = server.track_info.entities[entity]
	if entity_tracked and entity_tracked[relation] then
		change_pair(server, entity, relation, filter)
	else
		start_pair(server, entity, relation, filter)
	end
end

local function set_custom(server: Server, entity: Entity, component: Component)
	if server.custom_ids[entity] then
		utils.logwarn("attempted to register a custom_id twice for the same entity", debug.traceback())
		return
	end

	server.custom_ids[entity] = component
end

local function remove_custom(server: Server, entity: Entity)
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

local function init(server: Server, _world: World?)
	if not check_created(server) then
		return
	end
	server.inited = true :: any

	local world = _world or server.world
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

	server.shared = utils.create_shared_lookup(world, components)

	local function hook(unhook: () -> ())
		table.insert(server.hooked, unhook)
	end

	hook(hooks.added(world, components.networked, function(entity, _, filter)
		start_networked(server, entity, filter)
	end))
	hook(hooks.changed(world, components.networked, function(entity, _, filter)
		change_networked(server, entity, filter)
	end))
	hook(hooks.removed(world, components.networked, function(entity)
		stop_networked(server, entity)
	end))

	hook(hooks.added(world, components.reliable, function(entity, id, filter)
		local component = PAIR_SECOND(world, id)
		start_reliable(server, entity, component, filter)
	end))
	hook(hooks.changed(world, components.reliable, function(entity, id, filter)
		local component = PAIR_SECOND(world, id)
		change_reliable(server, entity, component, filter)
	end))
	hook(hooks.removed(world, components.reliable, function(entity, id)
		local component = PAIR_SECOND(world, id)
		stop_reliable(server, entity, component)
	end))

	hook(hooks.added(world, components.pair, function(entity, id, filter)
		local relation = PAIR_SECOND(world, id)
		start_pair(server, entity, relation, filter)
	end))
	hook(hooks.changed(world, components.pair, function(entity, id, filter)
		local relation = PAIR_SECOND(world, id)
		change_pair(server, entity, relation, filter)
	end))
	hook(hooks.removed(world, components.pair, function(entity, id)
		local relation = PAIR_SECOND(world, id)
		stop_pair(server, entity, relation)
	end))

	hook(hooks.added(world, components.unreliable, function(entity, id, filter)
		local component = PAIR_SECOND(world, id)
		start_unreliable(server, entity, component, filter)
	end))
	hook(hooks.changed(world, components.unreliable, function(entity, id, filter)
		local component = PAIR_SECOND(world, id)
		change_unreliable(server, entity, component, filter)
	end))
	hook(hooks.removed(world, components.unreliable, function(entity, id)
		local component = PAIR_SECOND(world, id)
		stop_unreliable(server, entity, component)
	end))

	hook(hooks.added(world, components.custom, function(entity, id)
		local component = PAIR_SECOND(world, id)
		set_custom(server, entity, component)
	end))
	hook(hooks.removed(world, components.custom, function(entity)
		remove_custom(server, entity)
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
			stop_networked(server, entity)
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

	if game and game:GetService("RunService"):IsServer() then
		local added = game:GetService("Players").PlayerAdded:Connect(function(player)
			server.masking:register_client(player)
		end)
		local removed = game:GetService("Players").PlayerRemoving:Connect(function(player)
			server.masking:unregister_client(player)
		end)

		table.insert(server.connections, added)
		table.insert(server.connections, removed)
	end
end

local function mark_player_ready(server: Server, player: Player)
	server.masking:activate_client(player)
end

local function is_player_ready(server: Server, player: Player): boolean
	return server.masking:member_is_active(player)
end

local function add_player_alias(server: Server, client: Player, alias: any)
	server.masking.client_aliases[alias] = client
end

local function remove_player_alias(server: Server, alias: any)
	server.masking.client_aliases[alias] = nil
end

local function destroy(server: Server)
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

local server = {}
server.__index = server
server.init = init
server.destroy = destroy
server.get_full = get_full
server.collect_updates = collect_updates
server.collect_unreliable = collect_unreliable
server.encode_component = encode_component
server.decode_component = decode_component
server.mark_player_ready = mark_player_ready

server.set_networked = set_networked
server.set_reliable = set_reliable
server.set_unreliable = set_unreliable
server.set_pair = set_pair
server.set_custom = set_custom

server.stop_networked = stop_networked
server.stop_reliable = stop_reliable
server.stop_unreliable = stop_unreliable
server.stop_pair = stop_pair
server.remove_custom = remove_custom

server.is_player_ready = is_player_ready
server.add_player_alias = add_player_alias
server.remove_player_alias = remove_player_alias

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
	self.requires_shared_lookup = {
		self.components.shared,
		self.components.serdes,
		self.components.bytespan,
		jecs.Name,
	}

	return setmetatable(self, server) :: any
end

server.create = create

return server :: { create: typeof(create) }
