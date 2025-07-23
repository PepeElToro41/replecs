--!native
--!optimize 2

local jecs = require(script.Parent.Parent.jecs)
local common = require(script.Parent.common)
local utils = require(script.Parent.utils)

local cursor = utils.cursor
type Cursor = utils.Cursor

export type Client = {
	world: jecs.World,

	components: common.Components,
	shared: common.Shared,
	server_ids: { [number]: jecs.Entity },
	client_ids: { [jecs.Entity]: number },
	ordered_creation: boolean,
	custom_ids: { [jecs.Entity]: (any) -> jecs.Entity },

	init: (self: Client, world: jecs.World) -> (),
	apply_updates: (self: Client, buf: buffer, variants: { any }?) -> (),
	apply_unreliable: (self: Client, buf: buffer, variants: { any }?) -> (),
	apply_full: (self: Client, buf: buffer, variants: { any }?) -> (),
}

local ENTITY_ID_TYPES = {
	id = 1,
	custom = 2,
	shared = 3,
}

local function get_or_create_entity(client: Client, server_id: number): jecs.Entity
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
		error "received a non shared component"
	end
	return component
end

local function read_component_value(client: Client, c: Cursor, variants: { any }?): (jecs.Entity, any)
	local component = read_component_id(client, c)
	local serdes = client.shared.serdes[component]
	if serdes then
		local bytespan = client.shared.bytespan[component] or cursor.read_vlq(c)

		local appended = cursor.read_buffer(c, bytespan)
		local output = serdes.deserialize(appended)
		return component, output
	else
		local variant_id = cursor.read_vlq(c)
		local value = (variants :: { any })[variant_id]
		return component, value
	end
end

local function read_entity_id(client: Client, c: Cursor, variants: { any }?)
	local id_type = cursor.readu8(c)

	if id_type == ENTITY_ID_TYPES.id then
		local server_id = cursor.readu24(c)
		local entity = get_or_create_entity(client, server_id)
		return entity
	elseif id_type == ENTITY_ID_TYPES.custom then
		local component, value = read_component_value(client, c, variants)
		local custom_getter = client.custom_ids[component]
		if not custom_getter then
			error(
				`received a custom id for a non custom component, consider adding custom_id to component: {client.world:get(
					component,
					jecs.Name
				) or "(no name)"} id: {component}`
			)
		end
		return custom_getter(value)
	elseif id_type == ENTITY_ID_TYPES.shared then
		return read_component_id(client, c)
	end
	error("malformed entity id" .. cursor.readu32(c))
end

local function read_entity(client: Client, c: Cursor, variants: { any }?)
	local entity = read_entity_id(client, c, variants)

	local total_tags = cursor.read_vlq(c)
	for i = 1, total_tags do
		local tag = read_component_id(client, c)
		client.world:add(entity, tag)
	end

	local total_components = cursor.read_vlq(c)
	for i = 1, total_components do
		local component, value = read_component_value(client, c, variants)
		client.world:set(entity, component, value)
	end

	local total_pairs = cursor.read_vlq(c)
	for i = 1, total_pairs do
		local relation = read_component_id(client, c)
		local total_targets = cursor.read_vlq(c)

		for i = 1, total_targets do
			local target = read_entity_id(client, c, variants)
			client.world:add(entity, jecs.pair(relation, target))
		end
	end
end

local function apply_updates(client: Client, buf: buffer, all_variants: { { any } }?)
	local c = cursor.from(buf)
	local total_packets = cursor.read_vlq(c)

	for i = 1, total_packets do
		local variants = all_variants and all_variants[i]
		local total_added = cursor.read_vlq(c)

		for i = 1, total_added do
			read_entity(client, c, variants)
		end

		local total_deleted = cursor.read_vlq(c)
		for i = 1, total_deleted do
			local entity = read_entity_id(client, c, variants :: { any })
			client.world:delete(entity)
		end

		local total_changed = cursor.read_vlq(c)
		for i = 1, total_changed do
			local entity = read_entity_id(client, c, variants :: { any })
			local total_tagged = cursor.read_vlq(c)
			for i = 1, total_tagged do
				local tag = read_component_id(client, c)
				client.world:add(entity, tag)
			end

			local total_removed = cursor.read_vlq(c)
			for i = 1, total_removed do
				local component = read_component_id(client, c)
				client.world:remove(entity, component)
			end

			local total_components = cursor.read_vlq(c)
			for i = 1, total_components do
				local component, value = read_component_value(client, c, variants :: { any })
				client.world:set(entity, component, value)
			end

			local total_pairs = cursor.read_vlq(c)
			for i = 1, total_pairs do
				local got_removed = cursor.readu8(c) == 0
				if got_removed then
					local component = read_component_id(client, c)
					utils.remove_all_relations(client.world, entity, component)
				else
					c.offset += 1 -- go back
					local relation = read_component_id(client, c)
					local target = read_entity_id(client, c, variants :: { any })
					client.world:add(entity, jecs.pair(relation, target))
				end
			end
		end
	end
end

local function apply_unreliable(client: Client, buf: buffer, variants: { { any } }?) end

local function apply_full(client: Client, buf: buffer, variants: { any }?)
	local c = cursor.from(buf)
	local total_entities = cursor.read_vlq(c)

	for i = 1, total_entities do
		read_entity(client, c, variants :: { any })
	end
end

local function init(client: Client, world: jecs.World)
	local components = client.components

	client.world = world
	client.shared = utils.create_shared_lookup(world, components)

	for component, custom_id_get in world:query(components.custom_id):with(components.shared, jecs.Name) do
		client.custom_ids[component] = custom_id_get
	end
end

local client = {}
client.__index = client
client.init = init
client.apply_updates = apply_updates
client.apply_unreliable = apply_unreliable
client.apply_full = apply_full

local function create(components: common.Components): Client
	local self = {} :: Client

	self.shared = {} :: common.Shared
	self.components = components
	self.ordered_creation = true
	self.custom_ids = {}

	return setmetatable(self, client) :: any
end

client.create = create

return client :: { create: typeof(create) }
