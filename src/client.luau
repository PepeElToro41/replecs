--!native
--!optimize 2

local jecs = require "../jecs"
local common = require "./common"
local customid = require "./customid"
local utils = require "./utils"

local cursor = utils.cursor

type Cursor = utils.Cursor
type CustomId = customid.CustomId

type Entity<T = any> = jecs.Entity<T>
type Id<T = any> = jecs.Id<T>
type World = jecs.World

type Array<T> = { T }
type Map<K, V> = { [K]: V }
type Set<T> = { [T]: boolean }
type Disconnect = () -> ()

type CommandBuffer = {
	tags: { [Entity]: boolean },
	components: { [Entity]: { value: any } },
	unreliable_components: { [Entity]: { value: any } },
	remove: { [Entity]: boolean },
	pairs: { [Entity]: Set<Entity> },
	pairs_values: { [Entity]: { [Entity]: { value: any } } },
	pairs_remove: { [Entity]: Set<Entity> },
	pairs_clear: Set<Entity>,
}

type HookMethod =
	& ((
		self: Client,
		action: "changed",
		relation: Id,
		callback: (entity: Entity, id: Id, value: any) -> ()
	) -> Disconnect)
	& ((self: Client, action: "removed", relation: Id, callback: (entity: Entity, id: Id) -> ()) -> Disconnect)
	& (self: Client, action: "deleted", entity: Entity, callback: (entity: Entity) -> ()) -> Disconnect

type ChangedHooksEntry = {
	overrides: boolean,
	callbacks: Array<(entity: Entity, id: Id, value: any) -> ()>,
}
type RemovedHooksEntry = {
	overrides: boolean,
	callbacks: Array<(entity: Entity, id: Id) -> ()>,
}
type DeletedHookEntry = {
	overrides: boolean,
	callbacks: Array<(entity: Entity) -> ()>,
}

type CustomIdMap = { [CustomId]: CustomId | Entity }

export type Client = {
	world: World,
	inited: boolean?,

	is_replicating: boolean,
	after_replication_callbacks: { () -> () },

	is_shared_dirty: boolean,
	requires_shared_lookup: { Entity },
	components: common.Components,
	shared: common.Shared,
	global_handler: ((id: number) -> Entity)?,
	server_ids: { [number]: Entity },
	client_ids: { [Entity]: number },
	ordered_creation: boolean,
	registered_custom_ids: { [CustomId]: boolean },
	command_buffers: { [Entity]: CommandBuffer }?,
	command_buffers_active: boolean,

	init: (self: Client, world: World?) -> (),
	destroy: (self: Client) -> (),
	handle_global: (self: Client, handler: (id: number) -> Entity) -> (),
	get_server_entity: (self: Client, client_entity: Entity) -> number?,
	get_client_entity: (self: Client, server_entity: number) -> Entity?,

	hooks: common.WorldHooks,
	hooked: Array<() -> ()>,

	after_replication: (self: Client, callback: () -> ()) -> (),
	added: (self: Client, callback: (entity: Entity) -> ()) -> Disconnect,
	hook: HookMethod,
	override: HookMethod,
	addition_hooks: Array<(entity: Entity) -> ()>,
	network_hooks: {
		deleted: { [Entity]: DeletedHookEntry },
		changed: { [Id]: ChangedHooksEntry },
		removed: { [Id]: RemovedHooksEntry },
	},

	encode_component: (self: Client, component: Entity) -> number,
	decode_component: (self: Client, component: number) -> Entity,
	register_custom_id: (self: Client, custom_id: CustomId) -> (),

	apply_updates: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),
	apply_unreliable: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),
	apply_full: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),
}

local client_replicator = {}
client_replicator.__index = client_replicator

local GLOBAL_ID_OFFSET = 10

local ENTITY_ID_TYPES = {
	entity = 1,
	custom_handler = 2,
	custom_id = 3,
	shared = 4,
}
local PACKET_TYPES = {
	full = 1,
	unreliable = 2,
	reliable = 3,
}

local WILDCARD = jecs.Wildcard

local function PAIR(first: Entity, second: Entity): Entity
	return jecs.pair(first, second)
end

local function get_or_create_entity(client: Client, server_id: number): Entity
	local server_entity = client.server_ids[server_id]
	if server_entity then
		return server_entity
	else
		local entity = client.world:entity()
		client.world:add(entity, client.components.__alive_tracking__)

		client.server_ids[server_id] = entity
		client.client_ids[entity] = server_id

		for _, callback in client.addition_hooks do
			callback(entity)
		end

		return entity
	end
end

local function get_command_buffer(client: Client, entity: Entity): CommandBuffer
	local command_buffers = client.command_buffers

	if not command_buffers then
		error "attempted to use a command buffer without having one. (this should never happen)"
	end

	local command_buffer = command_buffers[entity :: any]
	if not command_buffer then
		command_buffer = {
			tags = {},
			components = {},
			unreliable_components = {},
			remove = {},
			pairs = {},
			pairs_values = {},
			pairs_remove = {},
			pairs_clear = {},
		}
		command_buffers[entity :: any] = command_buffer
	end
	return command_buffer
end

function client_replicator.entity_set(
	client: Client,
	entity: Entity,
	id: Id,
	value: any,
	changed_hooks: ChangedHooksEntry?
)
	if client.command_buffers_active then
		local command_buffer = get_command_buffer(client, entity)
		command_buffer.components[id] = { value = value }
	else
		if changed_hooks then
			if not changed_hooks.overrides then
				client.world:set(entity, id, value)
			end
			for _, callback in changed_hooks.callbacks do
				callback(entity, id, value)
			end
		else
			client.world:set(entity, id, value)
		end
	end
end

function client_replicator.entity_set_unreliable(
	client: Client,
	entity: Entity,
	component: Entity,
	value: any,
	changed_hooks: ChangedHooksEntry?
)
	if client.command_buffers_active then
		local command_buffer = get_command_buffer(client, entity)
		command_buffer.unreliable_components[component] = value
	else
		client_replicator.entity_set(client, entity, component, value, changed_hooks)
	end
end

function client_replicator.entity_set_pair(
	client: Client,
	entity: Entity,
	relation: Entity,
	target: Entity,
	value: any,
	changed_hooks: ChangedHooksEntry?
)
	if client.command_buffers_active then
		local command_buffer = get_command_buffer(client, entity)
		local pair_relation = command_buffer.pairs_values[relation]

		if pair_relation then
			pair_relation[target] = { value = value }
		else
			command_buffer.pairs_values[relation] = { [target] = value }
		end
	else
		client_replicator.entity_set(client, entity, PAIR(relation, target), value, changed_hooks)
	end
end

function client_replicator.entity_add(
	client: Client,
	entity: Entity,
	component: Entity,
	changed_hooks: ChangedHooksEntry?
)
	if changed_hooks then
		if not changed_hooks.overrides then
			client.world:add(entity, component)
		end
		for _, callback in changed_hooks.callbacks do
			callback(entity, component)
		end
	else
		client.world:add(entity, component)
	end
end

function client_replicator.entity_add_pair(
	client: Client,
	entity: Entity,
	relation: Entity,
	target: Entity,
	changed_hooks: ChangedHooksEntry?
)
	if client.command_buffers_active then
		local command_buffer = get_command_buffer(client, entity)
		local pair_relation = command_buffer.pairs[relation]

		if pair_relation then
			pair_relation[target] = true
		else
			command_buffer.pairs[relation] = { [target] = true }
		end
	else
		client_replicator.entity_add(client, entity, PAIR(relation, target), changed_hooks)
	end
end

function client_replicator.entity_remove(client: Client, entity: Entity, id: Entity, removed_hooks: RemovedHooksEntry?)
	if client.command_buffers_active then
		local command_buffer = get_command_buffer(client, entity)
		command_buffer.remove[id] = true
	else
		if removed_hooks then
			for _, callback in removed_hooks.callbacks do
				callback(entity, id)
			end
			if not removed_hooks.overrides then
				client.world:remove(entity, id)
			end
		else
			client.world:remove(entity, id)
		end
	end
end

function client_replicator.entity_remove_pair(
	client: Client,
	entity: Entity,
	relation: Entity,
	target: Entity,
	removed_hooks: RemovedHooksEntry?
)
	if client.command_buffers_active then
		local command_buffer = get_command_buffer(client, entity)
		local pair_relation = command_buffer.pairs_remove[relation]

		if pair_relation then
			pair_relation[target] = true
		else
			command_buffer.pairs_remove[relation] = { [target] = true }
		end
	else
		client_replicator.entity_remove(client, entity, PAIR(relation, target), removed_hooks)
	end
end

function client_replicator.entity_remove_relations(
	client: Client,
	entity: Entity,
	relation: Entity,
	removed_hooks: RemovedHooksEntry?
)
	if client.command_buffers_active then
		local command_buffer = get_command_buffer(client, entity)
		command_buffer.pairs_clear[relation] = true
	else
		local world = client.world
		local entity_index = jecs.entity_index_try_get_fast(world.entity_index :: any, entity :: any)
		if not entity_index then
			return
		end
		local archetype = entity_index.archetype

		local wildcard = PAIR(relation, WILDCARD) :: any
		local idr = world.component_index[wildcard]
		if not idr then
			return
		end

		local archetype_id = archetype.id
		local count = idr.counts[archetype_id]
		if not count then
			return
		end

		local start = idr.records[archetype_id]
		if not start then
			return
		end

		if removed_hooks then
			for i = start, start + count - 1 do
				local pair = archetype.types[i]
				for _, callback in removed_hooks.callbacks do
					callback(entity, pair)
				end
				if not removed_hooks.overrides then
					world:remove(entity, pair :: any)
				end
			end
		else
			for i = start, start + count - 1 do
				local pair = archetype.types[i]
				world:remove(entity, pair :: any)
			end
		end
	end
end

function client_replicator.encode_component(client: Client, component: Entity): number
	local encoded = client.shared.components.members[component]
	if not encoded then
		utils.logerror(`attempted to encode a non-shared component `, utils.logcomponent(client.world, component))
		return 0
	end
	return encoded
end
function client_replicator.decode_component(client: Client, encoded: number): Entity
	local component = client.shared.components.indexes[encoded]
	if not component then
		print("NON SHARED COMPONENT", encoded, client.shared.components)
		error "attemped to decode a non shared component"
	end
	return component
end

function client_replicator.read_component_id(client: Client, c: Cursor): Entity
	local shared_id = cursor.readu8(c)
	local component = client.shared.components.indexes[shared_id]
	if not component then
		print("NON SHARED COMPONENT", shared_id, client.shared.components)
		error "received a non shared component"
	end
	return component
end

function client_replicator.read_component_value(client: Client, component: Entity, c: Cursor, variants: { any }?): any
	local serdes = client.shared.serdes[component]

	if serdes then
		local bytespan = client.shared.bytespan[component] or cursor.read_vlq(c)

		local appended = cursor.read_buffer(c, bytespan)
		local serdes_variants: { any }? = nil

		if serdes.includes_variants then
			local start_variant = cursor.read_vlq(c)

			if start_variant > 0 then
				local size = cursor.read_vlq(c)
				serdes_variants = table.move(variants :: { any }, start_variant, start_variant + size - 1, 1, {})
			end
		end

		local output = serdes.deserialize(appended, serdes_variants)
		return output
	else
		local variant_id = cursor.read_vlq(c)
		if variant_id == 0 then
			return nil
		end
		local value = (variants :: { any })[variant_id]
		return value
	end
end

function client_replicator.read_component(client: Client, c: Cursor, variants: { any }?): (Entity, any)
	local component = client_replicator.read_component_id(client, c)
	local value = client_replicator.read_component_value(client, component, c, variants)
	return component, value
end

function client_replicator.resolve_global(client: Client, global_id: number): Entity
	if not client.global_handler then
		error "global id parser not set, consider using client:handle_global()"
	end
	local parsed = client.global_handler(global_id)
	return parsed
end

-- returns entity, server_id, id_type
function client_replicator.read_entity_id(client: Client, c: Cursor): (Entity?, number?, number?)
	local id_type = cursor.readu8(c)

	if id_type <= GLOBAL_ID_OFFSET then
		if
			id_type == ENTITY_ID_TYPES.entity
			or id_type == ENTITY_ID_TYPES.custom_id
			or id_type == ENTITY_ID_TYPES.custom_handler
		then
			local server_id = cursor.readu40(c)
			return client.server_ids[server_id], server_id, id_type
		elseif id_type == ENTITY_ID_TYPES.shared then
			return client_replicator.read_component_id(client, c), nil, id_type
		end
		error(`malformed entity type {id_type} ` .. cursor.readu32(c))
	else
		return client_replicator.resolve_global(client, id_type - GLOBAL_ID_OFFSET), nil, id_type
	end
end

function client_replicator.process_entity_id(
	client: Client,
	c: Cursor,
	custom_ids: CustomIdMap,
	process: (entity: Entity) -> ()
)
	local entity, server_id, id_type = client_replicator.read_entity_id(client, c)

	if entity then
		-- skip customid, keep cursor offset
		if id_type == ENTITY_ID_TYPES.custom_id then
			client_replicator.read_component_id(client, c)
		elseif id_type == ENTITY_ID_TYPES.custom_handler then
			cursor.readu8(c)
		end

		return process(entity)
	else
		if id_type == ENTITY_ID_TYPES.custom_id or id_type == ENTITY_ID_TYPES.custom_handler then
			if id_type == ENTITY_ID_TYPES.custom_id then
				local component_id = client_replicator.read_component_id(client, c)
				custom_ids[server_id :: any] = component_id
			elseif id_type == ENTITY_ID_TYPES.custom_handler then
				local shared_custom_id = cursor.readu8(c)
				local handler = client.shared.custom_ids.indexes[shared_custom_id]

				if not handler then
					utils.logerror "attempted to use a custom id that wasn't registered"
				end
				custom_ids[server_id :: any] = handler
			end

			if client.command_buffers_active then
				-- negative id means it's a custom id,
				-- it needs to be translated first
				process(-server_id :: any)
			else
				client.command_buffers_active = true
				process(-server_id :: any)
				client.command_buffers_active = false
			end
		else
			local new_entity = get_or_create_entity(client, server_id :: number)
			process(new_entity)
		end
	end
end

function client_replicator.process_entity_relations(
	client: Client,
	entity: jecs.Entity,
	c: Cursor,
	custom_ids: CustomIdMap
)
	local components = client.components
	local relation = client_replicator.read_component_id(client, c)
	local total_targets = cursor.read_vlq(c)
	local pair_hooks = client.network_hooks.changed[PAIR(components.pair, relation)]

	for _ = 1, total_targets do
		client_replicator.process_entity_id(client, c, custom_ids, function(target)
			client_replicator.entity_add_pair(client, entity, relation, target, pair_hooks)
		end)
	end
end

function client_replicator.process_entity_relation_values(
	client: Client,
	entity: jecs.Entity,
	c: Cursor,
	custom_ids: CustomIdMap,
	variants: { any }?
)
	local relation = client_replicator.read_component_id(client, c)
	local total_targets = cursor.read_vlq(c)
	local components = client.components
	local pair_hooks = client.network_hooks.changed[PAIR(components.pair, relation)]

	for _ = 1, total_targets do
		local value = client_replicator.read_component_value(client, relation, c, variants)
		client_replicator.process_entity_id(client, c, custom_ids, function(target)
			client_replicator.entity_set_pair(client, entity, relation, target, value, pair_hooks)
		end)
	end
end

function client_replicator.process_entity(client: Client, c: Cursor, custom_ids: CustomIdMap, variants: { any }?)
	client_replicator.process_entity_id(client, c, custom_ids, function(entity)
		local changed_hooks = client.network_hooks.changed
		local components = client.components

		local total_tags = cursor.read_vlq(c)
		for _ = 1, total_tags do
			local tag = client_replicator.read_component_id(client, c)
			local tag_hooks = changed_hooks[PAIR(components.reliable, tag)]
			client_replicator.entity_add(client, entity, tag, tag_hooks)
		end

		local total_components = cursor.read_vlq(c)
		for _ = 1, total_components do
			local component, value = client_replicator.read_component(client, c, variants)
			local component_hooks = changed_hooks[PAIR(components.reliable, component)]
			client_replicator.entity_set(client, entity, component, value, component_hooks)
		end

		local total_pairs = cursor.read_vlq(c)
		for _ = 1, total_pairs do
			client_replicator.process_entity_relations(client, entity, c, custom_ids)
		end

		local total_pairs_values = cursor.read_vlq(c)
		for _ = 1, total_pairs_values do
			client_replicator.process_entity_relation_values(client, entity, c, custom_ids, variants)
		end
	end)
end

function client_replicator.finish_replication(client: Client)
	client.is_replicating = false
	for _, callback in client.after_replication_callbacks do
		callback()
	end
	table.clear(client.after_replication_callbacks)
end

function client_replicator.resolve_dirty(client: Client)
	if client.is_shared_dirty then
		client.shared = utils.resolved_shared(client.world, client.components, client.registered_custom_ids)
		client.is_shared_dirty = false :: true -- wtf
	end
end

local function check_packet_type(c: Cursor, type: string)
	local byte_type = PACKET_TYPES[type]
	local packet_type = cursor.readu8(c)
	if packet_type ~= byte_type then
		local got: string = nil :: any
		for k, v in PACKET_TYPES do
			if v == packet_type then
				got = k :: string
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

function client_replicator.apply_command_buffer(
	client: Client,
	entity: Entity,
	command_buffer: CommandBuffer,
	request: (e: Entity, ...any) -> Entity?
)
	local components = client.components

	for tag in command_buffer.tags do
		local tag_hooks = client.network_hooks.changed[PAIR(components.reliable, tag)]
		client_replicator.entity_add(client, entity, tag, tag_hooks)
	end
	for component, value in command_buffer.components do
		local component_hooks = client.network_hooks.changed[PAIR(components.reliable, component)]
		client_replicator.entity_set(client, entity, component, value, component_hooks)
	end
	for component, value in command_buffer.unreliable_components do
		local component_hooks = client.network_hooks.changed[PAIR(components.unreliable, component)]
		client_replicator.entity_set(client, entity, component, value, component_hooks)
	end
	for component in command_buffer.remove do
		local component_hooks = client.network_hooks.removed[PAIR(components.reliable, component)]
		client_replicator.entity_remove(client, entity, component, component_hooks)
	end
	for relation, targets in command_buffer.pairs do
		local pair_hooks = client.network_hooks.changed[PAIR(components.pair, relation)]
		for target in targets do
			local client_target = request(target)
			if client_target then
				client_replicator.entity_add_pair(client, entity, relation, client_target, pair_hooks)
			end
		end
	end
	for relation, targets in command_buffer.pairs_values do
		local pair_hooks = client.network_hooks.changed[PAIR(components.pair, relation)]
		for target, value in targets do
			local client_target = request(target)
			if client_target then
				client_replicator.entity_set_pair(client, entity, relation, client_target, value.value, pair_hooks)
			end
		end
	end
	for relation, targets in command_buffer.pairs_remove do
		local pair_hooks = client.network_hooks.removed[PAIR(components.pair, relation)]
		for target in targets do
			local client_target = request(target)
			if client_target then
				client_replicator.entity_remove_pair(client, entity, relation, client_target, pair_hooks)
			end
		end
	end
	for relation in command_buffer.pairs_clear do
		local pair_hooks = client.network_hooks.removed[PAIR(components.pair, relation)]
		client_replicator.entity_remove_relations(client, entity, relation, pair_hooks)
	end
end

function client_replicator.find_component_in_buffer(command_buffer: CommandBuffer, component: Entity): { value: any }?
	return command_buffer.components[component] or command_buffer.unreliable_components[component]
end

function client_replicator.find_has_in_buffer(command_buffer: CommandBuffer, tag: Entity): boolean
	return (command_buffer.tags[tag] ~= nil)
		or (command_buffer.components[tag] ~= nil)
		or (command_buffer.unreliable_components[tag] ~= nil)
end
function client_replicator.find_pair_in_buffer(
	command_buffer: CommandBuffer,
	relation: Entity,
	target: Entity
): (boolean, any)
	local value_relations = command_buffer.pairs_values[relation]
	local value = value_relations and value_relations[target]

	if value then
		return true, value.value
	end

	local relations = command_buffer.pairs[relation]
	local pair = relations and relations[target]

	if pair then
		return true, nil
	end

	return false, nil
end

function client_replicator.find_target_in_buffer(
	command_buffer: CommandBuffer,
	relation: Entity,
	index: number?
): Entity?
	local pairs = command_buffer.pairs[relation]
	if pairs then
		local i = 0
		for target in pairs do
			if i == (index or 0) then
				return target
			end
			i += 1
		end
	end
	local pairs_values = command_buffer.pairs_values[relation]
	if pairs_values then
		local i = 0
		for target in pairs_values do
			if i == (index or 0) then
				return target
			end
			i += 1
		end
	end
	return nil
end

function client_replicator.finish_custom_ids(
	client: Client,
	custom_ids: CustomIdMap,
	command_buffers: { [Entity]: CommandBuffer }
)
	local funcs = {} -- this is so process can use create_context even if its defined after
	local processed: { [Entity]: boolean } = {}

	local function process(entity: Entity, custom_handler: (CustomId | Entity)?): Entity?
		-- negative entities means they are still server ids that haven't been processed yet
		if (entity :: any) > 0 then
			return entity
		end
		local server_entity = -(entity :: any)
		local client_entity = client.server_ids[server_entity]
		if client_entity then
			return client_entity
		end

		if processed[server_entity] then
			return nil
		end

		local new_entity: Entity? = nil
		local command_buffer = command_buffers[entity :: any]
		custom_handler = custom_handler or custom_ids[server_entity]

		if type(custom_handler) == "number" then
			local component: Entity = custom_handler :: any

			local handler = client.world:get(component, client.components.custom_handler)
			if not handler then
				return utils.logerror(
					`received a custom id for a non custom component, consider adding custom_id to component: {utils.logcomponent(
						client.world,
						component
					)}`
				)
			end
			if command_buffer then
				local value = client_replicator.find_component_in_buffer(command_buffer, component)
				if value then
					new_entity = handler(value.value)
				else
					utils.logwarn(
						`No component found for custom id handler: {utils.logcomponent(client.world, component)}`
					)
					new_entity = handler(nil)
				end
			else
				utils.logwarn(`No component found for custom id handler: {utils.logcomponent(client.world, component)}`)
				new_entity = handler(nil)
				warn "No "
			end
		else
			custom_handler = custom_handler or custom_ids[server_entity :: any]
			local handle_callback = (custom_handler :: CustomId).handle_callback
			new_entity = handle_callback(funcs.create_context(entity))
		end

		if new_entity then
			client.server_ids[server_entity] = new_entity
			if command_buffer then
				client_replicator.apply_command_buffer(client, new_entity, command_buffer, process)
				command_buffers[entity] = nil
			end
		end

		processed[server_entity] = true
		return new_entity
	end

	local function create_context(entity_id: Entity)
		local command_buffer = command_buffers[entity_id]

		local function component(component: Entity): any
			if not command_buffer then
				return nil
			end
			local val = client_replicator.find_component_in_buffer(command_buffer, component)
			return val and val.value
		end
		local function target(relation: Entity, index: number?): Entity
			if not command_buffer then
				return nil :: any
			end
			local server_target = client_replicator.find_target_in_buffer(command_buffer, relation, index)
			if server_target then
				return process(server_target :: any) :: Entity
			end
			return nil :: any
		end
		local function pair_value(relation: Entity, target: Entity): any
			if not command_buffer then
				return nil :: any
			end
			local _, value = client_replicator.find_pair_in_buffer(command_buffer, relation, target)
			return value
		end
		local function has_pair(relation: Entity, target: Entity): boolean
			if not command_buffer then
				return nil :: any
			end
			local has = client_replicator.find_pair_in_buffer(command_buffer, relation, target)
			return has
		end
		local function has(tag: Entity): boolean
			if not command_buffer then
				return nil :: any
			end
			return client_replicator.find_has_in_buffer(command_buffer, tag)
		end
		local function entity(server_entity: number): Entity
			return process(-server_entity :: any) :: Entity
		end

		local context: customid.HandleContext = {
			entity_id = math.abs(entity_id :: any),
			has = has,
			component = component,
			target = target,
			pair_value = pair_value,
			has_pair = has_pair,
			entity = entity,
		}

		return context
	end
	funcs.create_context = create_context

	for entity, custom_handler in custom_ids do
		process(-(entity :: any), custom_handler)
	end

	for entity, command_buffer in command_buffers do
		if (entity :: any) < 0 then
			continue
		end
		client_replicator.apply_command_buffer(client, entity, command_buffer, process)
	end
end

function client_replicator.apply_updates(client: Client, buf: buffer, all_variants: { { any } }?)
	local c = cursor.from(buf)
	check_packet_type(c, "reliable")
	client_replicator.resolve_dirty(client)
	client.is_replicating = true

	local components = client.components
	local total_packets = cursor.read_vlq(c)
	local variant_start = (all_variants and #all_variants + 1) :: number
	local changed_hooks = client.network_hooks.changed
	local removed_hooks = client.network_hooks.removed
	local deleted_hooks = client.network_hooks.deleted

	local command_buffers: { [Entity]: CommandBuffer } = {}
	local custom_ids: CustomIdMap = {}

	client.command_buffers = command_buffers

	for a = 1, total_packets do
		local variants = all_variants and all_variants[variant_start - a]
		local storage_mask = cursor.readu8(c)

		local total_added = read_vlq_bitmask(c, storage_mask, 0)
		for _ = 1, total_added do
			client_replicator.process_entity(client, c, custom_ids, variants)
		end

		local total_components_added = read_vlq_bitmask(c, storage_mask, 1)
		for _ = 1, total_components_added do
			client_replicator.process_entity_id(client, c, custom_ids, function(entity)
				local added_mask = cursor.readu8(c)

				local total_tags = read_vlq_bitmask(c, added_mask, 0)
				for _ = 1, total_tags do
					local tag = client_replicator.read_component_id(client, c)
					local tag_hooks = changed_hooks[PAIR(components.reliable, tag)]
					client_replicator.entity_add(client, entity, tag, tag_hooks)
				end

				local total_components = read_vlq_bitmask(c, added_mask, 1)
				for _ = 1, total_components do
					local component, value = client_replicator.read_component(client, c, variants)
					local component_hooks = changed_hooks[PAIR(components.reliable, component)]
					client_replicator.entity_set(client, entity, component, value, component_hooks)
				end

				local total_pairs = read_vlq_bitmask(c, added_mask, 2)
				for _ = 1, total_pairs do
					client_replicator.process_entity_relations(client, entity, c, custom_ids)
				end

				local total_pairs_values = read_vlq_bitmask(c, added_mask, 3)
				for _ = 1, total_pairs_values do
					client_replicator.process_entity_relation_values(client, entity, c, custom_ids, variants)
				end
			end)
		end

		local total_changed = read_vlq_bitmask(c, storage_mask, 2)
		for _ = 1, total_changed do
			client_replicator.process_entity_id(client, c, custom_ids, function(entity)
				local changed_mask = cursor.readu8(c)

				local total_tagged = read_vlq_bitmask(c, changed_mask, 0)
				for _ = 1, total_tagged do
					local tag = client_replicator.read_component_id(client, c)
					local tag_hooks = changed_hooks[PAIR(components.reliable, tag)]
					client_replicator.entity_add(client, entity, tag, tag_hooks)
				end

				local total_components = read_vlq_bitmask(c, changed_mask, 1)
				for _ = 1, total_components do
					local component, value = client_replicator.read_component(client, c, variants)
					local component_hooks = changed_hooks[PAIR(components.reliable, component)]
					client_replicator.entity_set(client, entity, component, value, component_hooks)
				end

				local total_removed = read_vlq_bitmask(c, changed_mask, 2)
				for _ = 1, total_removed do
					local component = client_replicator.read_component_id(client, c)
					local component_hooks = removed_hooks[PAIR(components.reliable, component)]
					client_replicator.entity_remove(client, entity, component, component_hooks)
				end

				local total_pairs = read_vlq_bitmask(c, changed_mask, 3)
				for _ = 1, total_pairs do
					local relation = client_replicator.read_component_id(client, c)
					local pair_changed_hooks = changed_hooks[PAIR(components.pair, relation)]
					local pair_removed_hooks = removed_hooks[PAIR(components.pair, relation)]
					local total_targets = cursor.read_vlq(c)

					for _ = 1, total_targets do
						local action_type = cursor.readi8(c)

						if action_type == 1 then -- add pair
							client_replicator.process_entity_id(client, c, custom_ids, function(target)
								client_replicator.entity_add_pair(client, entity, relation, target, pair_changed_hooks)
							end)
						elseif action_type == -1 then -- remove pair
							client_replicator.process_entity_id(client, c, custom_ids, function(target)
								client_replicator.entity_remove_pair(
									client,
									entity,
									relation,
									target,
									pair_removed_hooks
								)
							end)
						end
					end
				end

				local total_pairs_values_removed = read_vlq_bitmask(c, changed_mask, 4)
				for _ = 1, total_pairs_values_removed do
					local relation = client_replicator.read_component_id(client, c)
					local pair_hooks = removed_hooks[PAIR(components.pair, relation)]
					local total_targets = cursor.read_vlq(c)

					for _ = 1, total_targets do
						client_replicator.process_entity_id(client, c, custom_ids, function(target)
							client_replicator.entity_remove_pair(client, entity, relation, target, pair_hooks)
						end)
					end
				end

				local total_pairs_values = read_vlq_bitmask(c, changed_mask, 5)
				for _ = 1, total_pairs_values do
					local relation = client_replicator.read_component_id(client, c)
					local pair_hooks = changed_hooks[PAIR(components.pair, relation)]
					local total_targets = cursor.read_vlq(c)

					for _ = 1, total_targets do
						local value = client_replicator.read_component_value(client, relation, c, variants)
						client_replicator.process_entity_id(client, c, custom_ids, function(target)
							client_replicator.entity_set_pair(client, entity, relation, target, value, pair_hooks)
						end)
					end
				end
			end)
		end

		local total_component_deletions = read_vlq_bitmask(c, storage_mask, 3)
		for _ = 1, total_component_deletions do
			client_replicator.process_entity_id(client, c, custom_ids, function(entity)
				local total_removed = cursor.read_vlq(c)
				for _ = 1, total_removed do
					local component = client_replicator.read_component_id(client, c)
					local component_hooks = removed_hooks[PAIR(components.reliable, component)]
					client_replicator.entity_remove(client, entity, component, component_hooks)
				end

				local total_pairs = cursor.read_vlq(c)
				for _ = 1, total_pairs do
					local relation = client_replicator.read_component_id(client, c)
					local pair_hooks = removed_hooks[PAIR(components.pair, relation)]
					client_replicator.entity_remove_relations(client, entity, relation, pair_hooks)
				end
			end)
		end

		local total_deleted = read_vlq_bitmask(c, storage_mask, 4)
		for _ = 1, total_deleted do
			local entity, server_id = client_replicator.read_entity_id(client, c)
			if entity then
				local deleted_hook = deleted_hooks[entity]
				if deleted_hook then
					for _, callback in deleted_hook.callbacks do
						callback(entity)
					end
					if not deleted_hook.overrides then
						client.world:delete(entity)
					end
				else
					client.world:delete(entity)
				end
			end
			if server_id then
				client.server_ids[server_id] = nil
			end
		end
	end

	client_replicator.finish_custom_ids(client, custom_ids, command_buffers)
	client_replicator.finish_replication(client)
end

function client_replicator.apply_unreliable(client: Client, buf: buffer, all_variants: { { any } }?)
	local c = cursor.from(buf)
	check_packet_type(c, "unreliable")
	client_replicator.resolve_dirty(client)
	client.is_replicating = true

	local components = client.components
	local total_packets = cursor.read_vlq(c)
	local variant_start = (all_variants and #all_variants + 1) :: number
	local changed_hooks = client.network_hooks.changed

	for a = 1, total_packets do
		local total_entities = cursor.read_vlq(c)
		local variants = all_variants and all_variants[variant_start - a]

		for _ = 1, total_entities do
			local entity = client_replicator.read_entity_id(client, c)
			local total_unreliable = cursor.read_vlq(c)

			if entity then
				for _ = 1, total_unreliable do
					local component_id, value = client_replicator.read_component(client, c, variants)
					local unreliable_hooks = changed_hooks[PAIR(components.unreliable, component_id)]
					client_replicator.entity_set_unreliable(client, entity, component_id, value, unreliable_hooks)
				end
			else
				-- dont apply unreliable updates to entities that dont exist in the client yet
				-- but we still need to process the values to keep the cursor in the right place
				for _ = 1, total_unreliable do
					client_replicator.read_component(client, c, variants)
				end
			end
		end
	end

	client_replicator.finish_replication(client)
end

function client_replicator.apply_full(client: Client, buf: buffer, all_variants: { { any } }?)
	local c = cursor.from(buf)
	check_packet_type(c, "full")
	client_replicator.resolve_dirty(client)
	client.is_replicating = true

	local total_packets = cursor.read_vlq(c)
	local variant_start = (all_variants and #all_variants + 1) :: number

	local command_buffers: { [Entity]: CommandBuffer } = {}
	local custom_ids: CustomIdMap = {}

	client.command_buffers = command_buffers

	for a = 1, total_packets do
		local total_entities = cursor.read_vlq(c)
		local variants = all_variants and all_variants[variant_start - a]

		for _ = 1, total_entities do
			client_replicator.process_entity(client, c, custom_ids, variants)
		end
	end

	client_replicator.finish_custom_ids(client, custom_ids, command_buffers)
	client_replicator.finish_replication(client)
end

function client_replicator.init(client: Client, _world: World?)
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

	local hooks = {
		added = (world :: any).added,
		changed = (world :: any).changed,
		removed = (world :: any).removed,
	}
	client.hooks = hooks

	local components = client.components

	client.shared = utils.resolved_shared(world, components, client.registered_custom_ids)

	local alive_unhook = hooks.removed(world, components.__alive_tracking__, function(entity)
		local server_id = client.client_ids[entity]
		if server_id then
			client.server_ids[server_id] = nil
			client.client_ids[entity] = nil
		end
		client.network_hooks.deleted[entity] = nil
	end)
	table.insert(client.hooked, alive_unhook)

	for _, component in client.requires_shared_lookup do
		local added_hook = hooks.added(world, component, function()
			client.is_shared_dirty = true
		end)
		local removed_hook = hooks.removed(world, component, function()
			client.is_shared_dirty = true
		end)
		table.insert(client.hooked, added_hook)
		table.insert(client.hooked, removed_hook)
	end
end

function client_replicator.after_replication(client: Client, callback: () -> ())
	if client.is_replicating then
		table.insert(client.after_replication_callbacks, callback)
	else
		callback()
	end
end

function client_replicator.added(client: Client, callback: (entity: Entity) -> ())
	table.insert(client.addition_hooks, callback)
	return function()
		local index = table.find(client.addition_hooks, callback)
		if index then
			table.remove(client.addition_hooks, index)
		end
	end
end

local function add_hook_entry(client: Client, action: string, ...): ({ overrides: boolean }, () -> ())
	if action == "changed" or action == "removed" then
		local relation = select(1, ...) :: Entity
		local callback = select(2, ...) :: (entity: Entity, id: number, value: any) -> ()
		local hooks = action == "changed" and client.network_hooks.changed or client.network_hooks.removed
		local entries = hooks[relation] :: ChangedHooksEntry

		if not entries then
			entries = {
				overrides = false,
				callbacks = {},
			}
			hooks[relation] = entries
		end
		table.insert(entries.callbacks, callback)

		local function disconnect()
			local callbacks = entries.callbacks
			local index = table.find(callbacks, callback)
			if index then
				table.remove(callbacks, index)
				if #callbacks == 0 then
					hooks[relation] = nil
				end
			end
		end
		return entries, disconnect
	elseif action == "deleted" then
		local entity = select(1, ...) :: Entity
		local callback = select(2, ...) :: (entity: Entity) -> ()
		local hooks = client.network_hooks.deleted
		local entries = hooks[entity]

		if not entries then
			entries = {
				overrides = false,
				callbacks = {},
			}
			hooks[entity] = entries
		end
		table.insert(entries.callbacks, callback)

		local function disconnect()
			local callbacks = entries.callbacks
			local index = table.find(callbacks, callback)
			if index then
				table.remove(callbacks, index)
				if #callbacks == 0 then
					hooks[entity] = nil
				end
			end
		end
		return entries, disconnect
	else
		error("invalid hook action: " .. action)
	end
end

function client_replicator.hook(client: Client, action: string, ...)
	local entry, disconnect = add_hook_entry(client, action, ...)
	entry.overrides = false
	return disconnect
end
function client_replicator.override(client: Client, action: string, ...)
	local entry, disconnect = add_hook_entry(client, action, ...)
	entry.overrides = true
	return disconnect
end

function client_replicator.get_server_entity(client: Client, client_entity: Entity): number?
	return client.client_ids[client_entity]
end

function client_replicator.get_client_entity(client: Client, client_entity: number): Entity?
	return client.server_ids[client_entity]
end

function client_replicator.register_custom_id(client: Client, custom_id: CustomId)
	client.registered_custom_ids[custom_id] = true
	client.is_shared_dirty = true
end

function client_replicator.destroy(client: Client)
	if client.inited == nil then
		return warn "attempted to destroy a client twice"
	end
	client.inited = nil :: any
	for _, unhook in client.hooked do
		unhook()
	end
end

function client_replicator.handle_global(client: Client, handler: (id: number) -> Entity)
	client.global_handler = handler
end

local function create(world: World?, components: common.Components): Client
	local self = {} :: Client

	self.components = components
	self.ordered_creation = true
	self.server_ids = {}
	self.client_ids = {}
	self.is_shared_dirty = false
	self.requires_shared_lookup = {
		self.components.shared,
		self.components.serdes,
		self.components.bytespan,
		jecs.Name,
	}
	self.global_handler = nil
	self.world = world :: any
	self.inited = false
	self.is_replicating = false
	self.hooked = {}
	self.registered_custom_ids = {}

	self.addition_hooks = {}
	self.network_hooks = {
		deleted = {},
		changed = {},
		removed = {},
	}
	self.after_replication_callbacks = {}

	return setmetatable(self, client_replicator) :: any
end

return {
	create = create,
	client_replicator = client_replicator,
}
