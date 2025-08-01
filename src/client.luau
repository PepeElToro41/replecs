--!native
--!optimize 2

local jecs = require "../jecs"
local common = require "./common"
local utils = require "./utils"

local cursor = utils.cursor
type Cursor = utils.Cursor

type Entity<T = any> = jecs.Entity<T>
type World = jecs.World

export type Client = {
	world: World,
	inited: boolean?,
	is_replicating: boolean,
	after_replication_callbacks: { () -> () },

	components: common.Components,
	shared: common.Shared,
	global_id_parser: ((id: number) -> Entity)?,
	server_ids: { [number]: Entity },
	client_ids: { [Entity]: number },
	ordered_creation: boolean,
	custom_ids: { [Entity]: (any) -> Entity },

	init: (self: Client, world: World?) -> (),
	destroy: (self: Client) -> (),
	after_replication: (self: Client, callback: () -> ()) -> (),
	parse_global_id: (self: Client, parser: (id: number) -> Entity) -> (),
	get_server_entity: (self: Client, client_entity: Entity) -> number?,
	get_client_entity: (self: Client, server_entity: number) -> Entity?,

	apply_updates: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),
	apply_unreliable: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),
	apply_full: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),
}

local GLOBAL_ID_OFFSET = 10
local ENTITY_ID_TYPES = {
	entity = 1,
	custom = 2,
	shared = 3,
	global = 4,
}
local PACKET_TYPES = {
	full = 1,
	unreliable = 2,
	reliable = 3,
}

local ECS_NAME = jecs.Name

local function PAIR(first: Entity, second: Entity): Entity
	return jecs.pair(first, second)
end

local function get_or_create_entity(client: Client, server_id: number): Entity
	local server_entity = client.server_ids[server_id]
	if server_entity then
		return server_entity
	else
		local entity = client.world:entity()
		client.server_ids[server_id] = entity
		client.client_ids[entity] = server_id
		return entity
	end
end

local function read_component_id(client: Client, c: Cursor)
	local shared_id = cursor.readu8(c)
	local component = client.shared.components[shared_id]
	if not component then
		print("NON SHARED COMPONENT", shared_id, client.shared.components)
		error "received a non shared component"
	end
	return component
end

local function read_component_value(client: Client, c: Cursor, variants: { any }?): (Entity, any)
	local component = read_component_id(client, c)
	local serdes = client.shared.serdes[component]

	if serdes then
		local bytespan = client.shared.bytespan[component] or cursor.read_vlq(c)

		local appended = cursor.read_buffer(c, bytespan)
		local output = serdes.deserialize(appended)
		return component, output
	else
		local variant_id = cursor.read_vlq(c)
		if variant_id == 0 then
			return component, nil
		end
		local value = (variants :: { any })[variant_id]
		return component, value
	end
end

local function resolve_global_id(client: Client, global_id: number): Entity
	if not client.global_id_parser then
		error "global id parser not set, consider using client:parse_global_id()"
	end
	local parsed = client.global_id_parser(global_id)
	return parsed
end

local function read_entity_id(client: Client, c: Cursor, variants: { any }?): (Entity?, number?)
	local id_type = cursor.readi8(c)

	if id_type <= 10 then
		if id_type == ENTITY_ID_TYPES.entity then
			local server_id = cursor.readu40(c)
			return client.server_ids[server_id], server_id
		elseif id_type == ENTITY_ID_TYPES.custom then
			local component, value = read_component_value(client, c, variants)
			local custom_getter = client.custom_ids[component]
			if not custom_getter then
				error(
					`received a custom id for a non custom component, consider adding custom_id to component: {client.world:get(
						component,
						ECS_NAME
					) or "(no name)"} id: {component}`
				)
			end
			return custom_getter(value), nil
		elseif id_type == ENTITY_ID_TYPES.shared then
			return read_component_id(client, c), nil
		elseif id_type == ENTITY_ID_TYPES.global then
			local global_id = cursor.readu8(c) - GLOBAL_ID_OFFSET
			return resolve_global_id(client, global_id), nil
		end
		error(`malformed entity id {id_type} ` .. cursor.readu32(c))
	else
		return resolve_global_id(client, id_type - GLOBAL_ID_OFFSET), nil
	end
end

local function process_entity_id(client: Client, c: Cursor, variants: { any }?)
	local entity, server_id = read_entity_id(client, c, variants)
	if entity then
		return entity
	else
		return get_or_create_entity(client, server_id :: number)
	end
end

local function process_entity_relation(client: Client, entity: jecs.Entity, c: Cursor, variants: { any }?)
	local relation = read_component_id(client, c)
	local total_targets = cursor.read_vlq(c)

	for _ = 1, total_targets do
		local target = process_entity_id(client, c, variants)
		client.world:add(entity, PAIR(relation, target))
	end
end

local function process_entity(client: Client, c: Cursor, variants: { any }?)
	local entity = process_entity_id(client, c, variants)

	local total_tags = cursor.read_vlq(c)
	for _ = 1, total_tags do
		local tag = read_component_id(client, c)
		client.world:add(entity, tag)
	end

	local total_components = cursor.read_vlq(c)
	for _ = 1, total_components do
		local component, value = read_component_value(client, c, variants)
		client.world:set(entity, component, value)
	end

	local total_pairs = cursor.read_vlq(c)
	for _ = 1, total_pairs do
		process_entity_relation(client, entity, c, variants)
	end
end

local function check_packet_type(c: Cursor, type: string)
	local byte_type = PACKET_TYPES[type]
	local packet_type = cursor.readu8(c)
	if packet_type ~= byte_type then
		local got: string = nil :: any
		for k, v in PACKET_TYPES do
			if v == packet_type then
				got = k
				break
			end
		end

		error(`packet type mismatch, expected {type} got {got} instead`)
	end
end

local function read_vlq_bitmask(c: Cursor, mask: number, bit: number): number
	if utils.checkbit(mask, bit) then
		return cursor.read_vlq(c)
	else
		return 0
	end
end

local function apply_updates(client: Client, buf: buffer, all_variants: { { any } }?)
	local c = cursor.from(buf)
	check_packet_type(c, "reliable")

	local total_packets = cursor.read_vlq(c)
	local variant_start = (all_variants and #all_variants + 1) :: number

	for a = 1, total_packets do
		local variants = all_variants and all_variants[variant_start - a]
		local storage_mask = cursor.readu8(c)

		local total_added = read_vlq_bitmask(c, storage_mask, 0)
		for _ = 1, total_added do
			process_entity(client, c, variants)
		end

		local total_components_added = read_vlq_bitmask(c, storage_mask, 1)
		for _ = 1, total_components_added do
			local entity = process_entity_id(client, c, variants)
			local added_mask = cursor.readu8(c)

			local total_tags = read_vlq_bitmask(c, added_mask, 0)
			for _ = 1, total_tags do
				local tag = read_component_id(client, c)
				client.world:add(entity, tag)
			end

			local total_components = read_vlq_bitmask(c, added_mask, 1)
			for _ = 1, total_components do
				local component, value = read_component_value(client, c, variants)
				client.world:set(entity, component, value)
			end

			local total_pairs = read_vlq_bitmask(c, added_mask, 2)
			for _ = 1, total_pairs do
				process_entity_relation(client, entity, c, variants)
			end
		end

		local total_changed = read_vlq_bitmask(c, storage_mask, 2)
		for _ = 1, total_changed do
			local entity = process_entity_id(client, c, variants)
			local changed_mask = cursor.readu8(c)

			local total_tagged = read_vlq_bitmask(c, changed_mask, 0)
			for _ = 1, total_tagged do
				local tag = read_component_id(client, c)
				client.world:add(entity, tag)
			end

			local total_components = read_vlq_bitmask(c, changed_mask, 1)
			for _ = 1, total_components do
				local component, value = read_component_value(client, c, variants)
				client.world:set(entity, component, value)
			end

			local total_pairs = read_vlq_bitmask(c, changed_mask, 2)
			for _ = 1, total_pairs do
				local relation = read_component_id(client, c)
				local total_targets = cursor.read_vlq(c)

				for _ = 1, total_targets do
					local id_type = cursor.readi8(c)
					-- here I use negative numbers to indicate removals
					-- but "process_entity_id" expects a positive value
					-- so I just peek at it and put it back but positive
					-- (surely there is a better way to do this)
					cursor.writei8(c, math.abs(id_type))
					local target = process_entity_id(client, c, variants)

					if id_type > 0 then
						client.world:add(entity, PAIR(relation, target))
					elseif id_type < 0 then
						client.world:remove(entity, PAIR(relation, target))
					end
				end
			end

			local total_removed = read_vlq_bitmask(c, changed_mask, 3)
			for _ = 1, total_removed do
				local component = read_component_id(client, c)
				client.world:remove(entity, component)
			end
		end

		local total_component_deleted = read_vlq_bitmask(c, storage_mask, 3)
		for _ = 1, total_component_deleted do
			local entity = process_entity_id(client, c, variants)
			local deleted_mask = cursor.readu8(c)

			local total_tags = read_vlq_bitmask(c, deleted_mask, 0)
			for _ = 1, total_tags do
				local tag = read_component_id(client, c)
				client.world:remove(entity, tag)
			end

			local total_components = read_vlq_bitmask(c, deleted_mask, 1)
			for _ = 1, total_components do
				local component = read_component_id(client, c)
				client.world:remove(entity, component)
			end

			local total_pairs = read_vlq_bitmask(c, deleted_mask, 2)
			for _ = 1, total_pairs do
				local relation = read_component_id(client, c)
				utils.remove_all_relations(client.world, entity, relation)
			end
		end

		local total_deleted = read_vlq_bitmask(c, storage_mask, 4)
		for _ = 1, total_deleted do
			local entity, server_id = read_entity_id(client, c, variants)
			if entity then
				client.world:delete(entity)
			end
			if server_id then
				client.server_ids[server_id] = nil
			end
		end
	end
end

local function apply_unreliable(client: Client, buf: buffer, all_variants: { { any } }?)
	local c = cursor.from(buf)
	check_packet_type(c, "unreliable")

	local total_packets = cursor.read_vlq(c)
	local variant_start = (all_variants and #all_variants + 1) :: number

	for a = 1, total_packets do
		local total_entities = cursor.read_vlq(c)
		local variants = all_variants and all_variants[variant_start - a]

		for _ = 1, total_entities do
			local entity = read_entity_id(client, c, variants)
			local total_unreliable = cursor.read_vlq(c)

			if entity then
				local component_id, value = read_component_value(client, c, variants)
				client.world:set(entity, component_id, value)
			else
				-- dont apply unreliable updates to entities that dont exist in the client yet
				-- but we still need to process the values to keep the cursor in the right place
				for _ = 1, total_unreliable do
					read_component_value(client, c, variants)
				end
			end
		end
	end
end

local function apply_full(client: Client, buf: buffer, all_variants: { { any } }?)
	local c = cursor.from(buf)
	check_packet_type(c, "full")

	local total_packets = cursor.read_vlq(c)
	local variant_start = (all_variants and #all_variants + 1) :: number

	for a = 1, total_packets do
		local total_entities = cursor.read_vlq(c)
		local variants = all_variants and all_variants[variant_start - a]

		for _ = 1, total_entities do
			process_entity(client, c, variants)
		end
	end
end

local function init(client: Client, _world: World?)
	if client.inited == true then
		return warn "attempted to init a client twice"
	end
	if client.inited == nil then
		return warn "attempted to re-init a destroyed client"
	end
	client.inited = true :: any

	local world = _world or client.world
	client.world = world

	if not world then
		error "Providing a world is required to start replecs"
	end

	local components = client.components

	client.shared = utils.create_shared_lookup(world, components)

	for component, custom_id_get in world:query(components.custom_id):with(components.shared, ECS_NAME) do
		client.custom_ids[component] = custom_id_get
	end
end

local function after_replication(client: Client, callback: () -> ())
	if client.is_replicating then
		table.insert(client.after_replication_callbacks, callback)
	else
		callback()
	end
end

local function get_server_entity(client: Client, client_entity: Entity): number?
	return client.client_ids[client_entity]
end

local function get_client_entity(client: Client, client_entity: number): Entity?
	return client.server_ids[client_entity]
end

local function destroy(client: Client)
	if client.inited == nil then
		return warn "attempted to destroy a client twice"
	end
	client.inited = nil :: any
	-- I'll add any logic here if I need to clean up something
	-- right now this is kind of useless
end

local function parse_global_id(client: Client, parser: (id: number) -> Entity)
	client.global_id_parser = parser
end

local client = {}
client.__index = client
client.init = init
client.destroy = destroy
client.after_replication = after_replication
client.apply_updates = apply_updates
client.apply_unreliable = apply_unreliable
client.apply_full = apply_full
client.get_server_entity = get_server_entity
client.get_client_entity = get_client_entity
client.parse_global_id = parse_global_id

local function create(world: World?, components: common.Components): Client
	local self = {} :: Client

	self.components = components
	self.ordered_creation = true
	self.custom_ids = {}
	self.server_ids = {}
	self.client_ids = {}
	self.global_id_parser = nil
	self.world = world :: any
	self.inited = false
	self.is_replicating = false
	self.after_replication_callbacks = {}

	return setmetatable(self, client) :: any
end

client.create = create

return client :: { create: typeof(create) }
