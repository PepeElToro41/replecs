--!native
--!optimize 2

local jecs = require "../jecs"
local common = require "./common"
local utils = require "./utils"

local cursor = utils.cursor
type Cursor = utils.Cursor

type Entity<T = any> = jecs.Entity<T>
type Id<T = any> = jecs.Id<T>
type World = jecs.World

type Array<T> = { T }
type Map<K, V> = { [K]: V }
type Disconnect = () -> ()

type HookMethod =
	& ((
		self: Client,
		entity: Entity,
		action: "change",
		relation: Entity,
		callback: (entity: Entity, id: Id, value: any) -> ()
	) -> Disconnect)
	& ((
		self: Client,
		entity: Entity,
		action: "removed",
		relation: Entity,
		callback: (entity: Entity, id: Id) -> ()
	) -> Disconnect)
	& (self: Client, entity: Entity, action: "deleted", callback: (entity: Entity) -> ()) -> Disconnect

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

export type Client = {
	world: World,
	inited: boolean?,

	is_replicating: boolean,
	after_replication_callbacks: { () -> () },

	is_dirty: boolean,
	requires_shared_lookup: { Entity },
	components: common.Components,
	shared: common.Shared,
	global_handler: ((id: number) -> Entity)?,
	server_ids: { [number]: Entity },
	client_ids: { [Entity]: number },
	ordered_creation: boolean,
	custom_ids: { [Entity]: (any) -> Entity },

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
	entity_hooks: {
		[Entity]: {
			changed: Map<Entity, ChangedHooksEntry>,
			removed: Map<Entity, RemovedHooksEntry>,
			deleted: DeletedHookEntry?,
		},
	},

	encode_component: (self: Client, component: Entity) -> number,
	decode_component: (self: Client, component: number) -> Entity,

	apply_updates: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),
	apply_unreliable: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),
	apply_full: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),
}

local GLOBAL_ID_OFFSET = 10
local ENTITY_ID_TYPES = {
	entity = 1,
	custom = 2,
	shared = 3,
}
local PACKET_TYPES = {
	full = 1,
	unreliable = 2,
	reliable = 3,
}

local ECS_NAME = jecs.Name
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

local function network_entity_set(client: Client, entity: Entity, id: Id, value: any, changed_hooks: ChangedHooksEntry?)
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

local function network_entity_add(client: Client, entity: Entity, component: Entity, changed_hooks: ChangedHooksEntry?)
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

local function network_entity_remove(client: Client, entity: Entity, id: Entity, removed_hooks: RemovedHooksEntry?)
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

local function network_entity_remove_relations(
	client: Client,
	entity: Entity,
	relation: Entity,
	removed_hooks: RemovedHooksEntry?
)
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

local function encode_component(client: Client, component: Entity): number
	local encoded = client.shared.ids[component]
	if not encoded then
		utils.logerror(`attempted to encode a non-shared component `, utils.logcomponent(client.world, component))
		return 0
	end
	return encoded
end
local function decode_component(client: Client, encoded: number): Entity
	local component = client.shared.components[encoded]
	if not component then
		print("NON SHARED COMPONENT", encoded, client.shared.components)
		error "attemped to decode a non shared component"
	end
	return component
end

local function read_component_id(client: Client, c: Cursor): Entity
	local shared_id = cursor.readu8(c)
	local component = client.shared.components[shared_id]
	if not component then
		print("NON SHARED COMPONENT", shared_id, client.shared.components)
		error "received a non shared component"
	end
	return component
end

local function read_component_value(client: Client, component: Entity, c: Cursor, variants: { any }?): any
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

local function read_component(client: Client, c: Cursor, variants: { any }?): (Entity, any)
	local component = read_component_id(client, c)
	local value = read_component_value(client, component, c, variants)
	return component, value
end

local function resolve_global(client: Client, global_id: number): Entity
	if not client.global_handler then
		error "global id parser not set, consider using client:handle_global()"
	end
	local parsed = client.global_handler(global_id)
	return parsed
end

local function read_entity_id(client: Client, c: Cursor, variants: { any }?): (Entity?, number?)
	local id_type = cursor.readu8(c)

	if id_type <= GLOBAL_ID_OFFSET then
		if id_type == ENTITY_ID_TYPES.entity then
			local server_id = cursor.readu40(c)
			return client.server_ids[server_id], server_id
		elseif id_type == ENTITY_ID_TYPES.custom then
			local component, value = read_component(client, c, variants)
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
		end
		error(`malformed entity id {id_type} ` .. cursor.readu32(c))
	else
		return resolve_global(client, id_type - GLOBAL_ID_OFFSET), nil
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

local function process_entity_relations(
	client: Client,
	entity: jecs.Entity,
	changed_hooks: Map<Entity, ChangedHooksEntry>?,
	c: Cursor,
	variants: { any }?
)
	local components = client.components
	local relation = read_component_id(client, c)
	local total_targets = cursor.read_vlq(c)
	local pair_hooks = changed_hooks and changed_hooks[PAIR(components.pair, relation)]

	for _ = 1, total_targets do
		local target = process_entity_id(client, c, variants)
		network_entity_add(client, entity, PAIR(relation, target), pair_hooks)
	end
end

local function process_entity_relation_values(
	client: Client,
	entity: jecs.Entity,
	changed_hooks: Map<Entity, ChangedHooksEntry>?,
	c: Cursor,
	variants: { any }?
)
	local relation = read_component_id(client, c)
	local total_targets = cursor.read_vlq(c)
	local components = client.components
	local pair_hooks = changed_hooks and changed_hooks[PAIR(components.pair, relation)]

	for _ = 1, total_targets do
		local value = read_component_value(client, relation, c, variants)
		local target = process_entity_id(client, c, variants)
		network_entity_set(client, entity, PAIR(relation, target), value, pair_hooks)
	end
end

local function process_entity(client: Client, c: Cursor, variants: { any }?)
	local entity = process_entity_id(client, c, variants)
	local entity_hooks = client.entity_hooks[entity]
	local changed_hooks = entity_hooks and entity_hooks.changed
	local components = client.components

	local total_tags = cursor.read_vlq(c)
	for _ = 1, total_tags do
		local tag = read_component_id(client, c)
		local tag_hooks = changed_hooks and changed_hooks[PAIR(components.reliable, tag)]
		network_entity_add(client, entity, tag, tag_hooks)
	end

	local total_components = cursor.read_vlq(c)
	for _ = 1, total_components do
		local component, value = read_component(client, c, variants)
		local component_hooks = changed_hooks and changed_hooks[PAIR(components.reliable, component)]
		network_entity_set(client, entity, component, value, component_hooks)
	end

	local total_pairs = cursor.read_vlq(c)
	for _ = 1, total_pairs do
		process_entity_relations(client, entity, changed_hooks, c, variants)
	end

	local total_pairs_values = cursor.read_vlq(c)
	for _ = 1, total_pairs_values do
		process_entity_relation_values(client, entity, changed_hooks, c, variants)
	end
end

local function finish_replication(client: Client)
	client.is_replicating = false
	for _, callback in client.after_replication_callbacks do
		callback()
	end
	table.clear(client.after_replication_callbacks)
end

local function resolve_dirty(client: Client)
	if client.is_dirty then
		client.shared = utils.create_shared_lookup(client.world, client.components)
		client.is_dirty = false :: true -- wtf
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

local function apply_updates(client: Client, buf: buffer, all_variants: { { any } }?)
	local c = cursor.from(buf)
	check_packet_type(c, "reliable")
	resolve_dirty(client)
	client.is_replicating = true

	local components = client.components
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

			local entity_hooks = client.entity_hooks[entity]
			local changed_hooks = entity_hooks and entity_hooks.changed

			local total_tags = read_vlq_bitmask(c, added_mask, 0)
			for _ = 1, total_tags do
				local tag = read_component_id(client, c)
				local tag_hooks = changed_hooks and changed_hooks[PAIR(components.reliable, tag)]
				network_entity_add(client, entity, tag, tag_hooks)
			end

			local total_components = read_vlq_bitmask(c, added_mask, 1)
			for _ = 1, total_components do
				local component, value = read_component(client, c, variants)
				local component_hooks = changed_hooks and changed_hooks[PAIR(components.reliable, component)]
				network_entity_set(client, entity, component, value, component_hooks)
			end

			local total_pairs = read_vlq_bitmask(c, added_mask, 2)
			for _ = 1, total_pairs do
				process_entity_relations(client, entity, changed_hooks, c, variants)
			end

			local total_pairs_values = read_vlq_bitmask(c, added_mask, 3)
			for _ = 1, total_pairs_values do
				process_entity_relation_values(client, entity, changed_hooks, c, variants)
			end
		end

		local total_changed = read_vlq_bitmask(c, storage_mask, 2)
		for _ = 1, total_changed do
			local entity = process_entity_id(client, c, variants)
			local changed_mask = cursor.readu8(c)

			local entity_hooks = client.entity_hooks[entity]
			local changed_hooks = entity_hooks and entity_hooks.changed
			local removed_hooks = entity_hooks and entity_hooks.removed

			local total_tagged = read_vlq_bitmask(c, changed_mask, 0)
			for _ = 1, total_tagged do
				local tag = read_component_id(client, c)
				local tag_hooks = changed_hooks and changed_hooks[PAIR(components.reliable, tag)]
				network_entity_add(client, entity, tag, tag_hooks)
			end

			local total_components = read_vlq_bitmask(c, changed_mask, 1)
			for _ = 1, total_components do
				local component, value = read_component(client, c, variants)
				local component_hooks = changed_hooks and changed_hooks[PAIR(components.reliable, component)]
				network_entity_set(client, entity, component, value, component_hooks)
			end

			local total_removed = read_vlq_bitmask(c, changed_mask, 2)
			for _ = 1, total_removed do
				local component = read_component_id(client, c)
				local component_hooks = removed_hooks and removed_hooks[PAIR(components.reliable, component)]
				network_entity_remove(client, entity, component, component_hooks)
			end

			local total_pairs = read_vlq_bitmask(c, changed_mask, 3)
			for _ = 1, total_pairs do
				local relation = read_component_id(client, c)
				local pair_changed_hooks = changed_hooks and changed_hooks[PAIR(components.pair, relation)]
				local pair_removed_hooks = removed_hooks and removed_hooks[PAIR(components.pair, relation)]
				local total_targets = cursor.read_vlq(c)

				for _ = 1, total_targets do
					local action_type = cursor.readi8(c)

					if action_type == 1 then -- add pair
						local target = process_entity_id(client, c, variants)
						network_entity_add(client, entity, PAIR(relation, target), pair_changed_hooks)
					elseif action_type == -1 then -- remove pair
						local target = read_entity_id(client, c, variants)
						if target then
							network_entity_remove(client, entity, PAIR(relation, target), pair_removed_hooks)
						end
					end
				end
			end

			local total_pairs_values_removed = read_vlq_bitmask(c, changed_mask, 4)
			for _ = 1, total_pairs_values_removed do
				local relation = read_component_id(client, c)
				local pair_hooks = removed_hooks and removed_hooks[PAIR(components.pair, relation)]
				local total_targets = cursor.read_vlq(c)

				for _ = 1, total_targets do
					local target = read_entity_id(client, c, variants)
					if target then
						network_entity_remove(client, entity, PAIR(relation, target), pair_hooks)
					end
				end
			end

			local total_pairs_values = read_vlq_bitmask(c, changed_mask, 5)
			for _ = 1, total_pairs_values do
				local relation = read_component_id(client, c)
				local pair_hooks = changed_hooks and changed_hooks[PAIR(components.pair, relation)]
				local total_targets = cursor.read_vlq(c)

				for _ = 1, total_targets do
					local value = read_component_value(client, relation, c, variants)
					local target = process_entity_id(client, c, variants)
					network_entity_set(client, entity, PAIR(relation, target), value, pair_hooks)
				end
			end
		end

		local total_component_deletions = read_vlq_bitmask(c, storage_mask, 3)
		for _ = 1, total_component_deletions do
			local entity = process_entity_id(client, c, variants)
			local entity_hooks = client.entity_hooks[entity]
			local removed_hooks = entity_hooks and entity_hooks.removed

			local total_removed = cursor.read_vlq(c)
			for _ = 1, total_removed do
				local component = read_component_id(client, c)
				local component_hooks = removed_hooks and removed_hooks[PAIR(components.reliable, component)]
				network_entity_remove(client, entity, component, component_hooks)
			end

			local total_pairs = cursor.read_vlq(c)
			for _ = 1, total_pairs do
				local relation = read_component_id(client, c)
				local pair_hooks = removed_hooks and removed_hooks[PAIR(components.pair, relation)]
				network_entity_remove_relations(client, entity, relation, pair_hooks)
			end
		end

		local total_deleted = read_vlq_bitmask(c, storage_mask, 4)
		for _ = 1, total_deleted do
			local entity, server_id = read_entity_id(client, c, variants)
			if entity then
				local entity_hooks = client.entity_hooks[entity]
				local deleted_hooks = entity_hooks and entity_hooks.deleted
				if deleted_hooks then
					for _, callback in deleted_hooks.callbacks do
						callback(entity)
					end
					if not deleted_hooks.overrides then
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

	finish_replication(client)
end

local function apply_unreliable(client: Client, buf: buffer, all_variants: { { any } }?)
	local c = cursor.from(buf)
	check_packet_type(c, "unreliable")
	resolve_dirty(client)
	client.is_replicating = true

	local components = client.components
	local total_packets = cursor.read_vlq(c)
	local variant_start = (all_variants and #all_variants + 1) :: number

	for a = 1, total_packets do
		local total_entities = cursor.read_vlq(c)
		local variants = all_variants and all_variants[variant_start - a]

		for _ = 1, total_entities do
			local entity = read_entity_id(client, c, variants)

			local total_unreliable = cursor.read_vlq(c)

			if entity then
				local entity_hooks = client.entity_hooks[entity]
				local changed_hooks = entity_hooks and entity_hooks.changed

				for _ = 1, total_unreliable do
					local component_id, value = read_component(client, c, variants)
					local unreliable_hooks = changed_hooks and changed_hooks[PAIR(components.unreliable, component_id)]
					network_entity_set(client, entity, component_id, value, unreliable_hooks)
				end
			else
				-- dont apply unreliable updates to entities that dont exist in the client yet
				-- but we still need to process the values to keep the cursor in the right place
				for _ = 1, total_unreliable do
					read_component(client, c, variants)
				end
			end
		end
	end

	finish_replication(client)
end

local function apply_full(client: Client, buf: buffer, all_variants: { { any } }?)
	local c = cursor.from(buf)
	check_packet_type(c, "full")
	resolve_dirty(client)
	client.is_replicating = true

	local total_packets = cursor.read_vlq(c)
	local variant_start = (all_variants and #all_variants + 1) :: number

	for a = 1, total_packets do
		local total_entities = cursor.read_vlq(c)
		local variants = all_variants and all_variants[variant_start - a]

		for _ = 1, total_entities do
			process_entity(client, c, variants)
		end
	end

	finish_replication(client)
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

	local hooks = {
		added = (world :: any).added,
		changed = (world :: any).changed,
		removed = (world :: any).removed,
	}
	client.hooks = hooks

	local components = client.components

	client.shared = utils.create_shared_lookup(world, components)

	for component, custom_get in world:query(components.custom_handler):with(components.shared, ECS_NAME) do
		client.custom_ids[component] = custom_get
	end

	local alive_unhook = hooks.removed(world, components.__alive_tracking__, function(entity)
		local server_id = client.client_ids[entity]
		if server_id then
			client.server_ids[server_id] = nil
			client.client_ids[entity] = nil
		end
		client.entity_hooks[entity] = nil
	end)
	table.insert(client.hooked, alive_unhook)

	for _, component in client.requires_shared_lookup do
		local added_hook = hooks.added(world, component, function()
			client.is_dirty = true
		end)
		local removed_hook = hooks.removed(world, component, function()
			client.is_dirty = true
		end)
		table.insert(client.hooked, added_hook)
		table.insert(client.hooked, removed_hook)
	end
end

local function after_replication(client: Client, callback: () -> ())
	if client.is_replicating then
		table.insert(client.after_replication_callbacks, callback)
	else
		callback()
	end
end

local function added(client: Client, callback: (entity: Entity) -> ())
	table.insert(client.addition_hooks, callback)
	return function()
		local index = table.find(client.addition_hooks, callback)
		if index then
			table.remove(client.addition_hooks, index)
		end
	end
end

local function get_or_create_entity_hooks(client: Client, entity: Entity)
	local entity_hooks = client.entity_hooks[entity]
	if not entity_hooks then
		entity_hooks = {
			changed = {},
			removed = {},
			deleted = nil :: DeletedHookEntry?,
		}
		client.entity_hooks[entity] = entity_hooks
	end
	return entity_hooks
end

local function add_hook_entry(client: Client, entity: Entity, action: string, ...): ({ overrides: boolean }, () -> ())
	if action == "changed" or action == "removed" then
		local relation = select(1, ...) :: Entity
		local callback = select(2, ...) :: (entity: Entity, id: number, value: any) -> ()
		local hooks = get_or_create_entity_hooks(client, entity)[action]
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
		local callback = select(1, ...) :: (entity: Entity) -> ()
		local hooks = get_or_create_entity_hooks(client, entity)
		local entries = hooks.deleted :: DeletedHookEntry

		if not entries then
			entries = {
				overrides = false,
				callbacks = {},
			}
			hooks.deleted = entries
		end
		table.insert(entries.callbacks, callback)

		local function disconnect()
			local callbacks = entries.callbacks
			local index = table.find(callbacks, callback)
			if index then
				table.remove(callbacks, index)
				if #callbacks == 0 then
					hooks.deleted = nil
				end
			end
		end
		return entries, disconnect
	else
		error("invalid hook action: " .. action)
	end
end

local function hook(client: Client, entity: Entity, action: string, ...)
	local entry, disconnect = add_hook_entry(client, entity, action, ...)
	entry.overrides = false
	return disconnect
end
local function override(client: Client, entity: Entity, action: string, ...)
	local entry, disconnect = add_hook_entry(client, entity, action, ...)
	entry.overrides = true
	return disconnect
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
	for _, unhook in client.hooked do
		unhook()
	end
end

local function handle_global(client: Client, handler: (id: number) -> Entity)
	client.global_handler = handler
end

local client = {}
client.__index = client
client.init = init
client.destroy = destroy
client.apply_updates = apply_updates
client.apply_unreliable = apply_unreliable
client.apply_full = apply_full
client.encode_component = encode_component
client.decode_component = decode_component
client.get_server_entity = get_server_entity
client.get_client_entity = get_client_entity
client.handle_global = handle_global
client.after_replication = after_replication
client.hook = hook
client.override = override
client.added = added

local function create(world: World?, components: common.Components): Client
	local self = {} :: Client

	self.components = components
	self.ordered_creation = true
	self.custom_ids = {}
	self.server_ids = {}
	self.client_ids = {}
	self.is_dirty = false
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

	self.addition_hooks = {}
	self.entity_hooks = {}
	self.after_replication_callbacks = {}

	return setmetatable(self, client) :: any
end

client.create = create

return client :: { create: typeof(create) }
