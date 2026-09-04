--!optimize 2

local common = require "./common"
local cursor = require "./cursor"
local types = require "./types"
local customid = require "./customid"
local shared = require "./shared"
local handshake = require "./handshake"
local utils = require "./utils"

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }
type Disconnect = () -> ()

type Cursor = cursor.Cursor

type World = common.World
type Entity = common.Entity
type Component<T = any> = common.Component<T>

type CustomId = customid.CustomId

type CommandBuffer = {
	tags: Set<Component>,
	components: Map<Component, { value: any }>,
	unreliable_components: Map<Component, { value: any }>,
	remove: Set<Component>,

	pairs_add: { [Component]: Set<Entity> },
	pairs_set: { [Component]: Map<Entity, { value: any }> },
	-- pair values whose target is an unresolved custom id: the serdes depends on
	-- the final pair, so the value stays in the packet (cursor frozen at its
	-- start) until the target resolves
	pairs_unprocessed: { [Component]: Map<Entity, UnprocessedPair> },
	pairs_remove: { [Component]: Set<Entity> },
	relations_clear: Set<Component>,
}

type UnprocessedPair = {
	cursor: Cursor,
	variants: Array<any>?,
	processed_value: { value: any }?,
}

type HookMethod =
	& ((
		self: Client,
		action: "changed",
		relation: Component,
		callback: (entity: Entity, id: Component, value: any) -> ()
	) -> Disconnect)
	& ((
		self: Client,
		action: "removed",
		relation: Component,
		callback: (entity: Entity, id: Component) -> ()
	) -> Disconnect)
	& (self: Client, action: "deleted", entity: Entity, callback: (entity: Entity) -> ()) -> Disconnect

type ChangedHooksEntry = {
	overrides: boolean,
	callbacks: Array<(entity: Entity, id: Component, value: any) -> ()>,
}
type RemovedHooksEntry = {
	overrides: boolean,
	callbacks: Array<(entity: Entity, id: Component) -> ()>,
}
type DeletedHookEntry = {
	overrides: boolean,
	callbacks: Array<(entity: Entity) -> ()>,
}

export type ClientImp = {
	init: (self: Client, world: World?) -> (),
	destroy: (self: Client) -> (),
	handle_global: (self: Client, handler: (id: number) -> Entity) -> (),
	get_server_entity: (self: Client, client_entity: Entity) -> number?,
	get_client_entity: (self: Client, server_entity: number) -> Entity?,

	register_entity: (self: Client, entity: Entity, server_entity: number) -> (),
	unregister_entity: (self: Client, entity: Entity) -> (),

	after_replication: (self: Client, callback: () -> ()) -> (),
	added: (self: Client, callback: (entity: Entity) -> ()) -> Disconnect,
	hook: HookMethod,
	override: HookMethod,

	apply_full: (self: Client, buf: buffer, variants: { any }?) -> (),
	apply_entity: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),
	apply_updates: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),
	apply_unreliable: (self: Client, buf: buffer, all_variants: { { any } }?) -> (),

	register_custom_id: (self: Client, custom_id: CustomId) -> (),
	set_serdes: <T>(self: Client, component: Component<T>, serdes: types.Serdes<T>) -> (),
	remove_serdes: (self: Client, component: Component) -> (),
	set_preprocessor: <B, A>(self: Client, component: Component<B>, preprocessor: types.Preprocessor<B, A>) -> (),
	remove_preprocessor: (self: Client, component: Component) -> (),
	set_delta_serializer: <T, D>(self: Client, component: Component<T>, delta: types.DeltaSerializer<T, D>) -> (),
	remove_delta_serializer: (self: Client, component: Component) -> (),

	resolve_dirty: (self: Client) -> (),
	encode_component: (self: Client, component: Component) -> number,
	decode_component: (self: Client, encoded: number) -> Component?,
	get_shared_count: (self: Client) -> number,

	generate_handshake: (self: Client) -> types.HandshakeInfo,
	verify_handshake: (self: Client, handshake: types.HandshakeInfo) -> (boolean, string?),
}

-- mirrors the server's options: the same component can carry any mix of the
-- three, resolved in one lookup at read time
type ComponentSerializationOptions = {
	serdes: types.Serdes?,
	preprocessor: types.Preprocessor?,
	delta_serializer: types.DeltaSerializer?,
}

export type Client = ClientImp & {
	world: World,
	inited: boolean?,

	components: types.Components,
	shared: types.Shared,
	registered_custom_ids: Set<CustomId>,
	-- single lookup for serdes/preprocessor/delta at read time
	component_serialization: Map<Component, ComponentSerializationOptions>,
	-- shared components, serdes and custom ids feed the handshake; set when any changes
	is_shared_dirty: boolean,

	is_replicating: boolean,
	after_replication_callbacks: Array<() -> ()>,

	global_handler: ((id: number) -> Entity)?,
	server_ids: { [number]: Entity },
	client_ids: { [Entity]: number },
	command_buffers: { [Entity]: CommandBuffer }?,
	command_buffers_active: boolean,

	addition_hooks: Array<(entity: Entity) -> ()>,
	network_hooks: {
		deleted: { [Entity]: DeletedHookEntry },
		changed: { [Component]: ChangedHooksEntry },
		removed: { [Component]: RemovedHooksEntry },
	},

	cleanups: { () -> () },
}

local PAIR = common.pair
local WILDCARD = common.wildcard
local ITERATE_ALL_RELATIONS = common.iterate_all_relations
local WORLD_ENTITY = common.world_entity
local WORLD_ADD = common.world_add
local WORLD_SET = common.world_set
local WORLD_REMOVE = common.world_remove
local WORLD_HAS = common.world_has
local WORLD_DELETE = common.world_delete
local WORLD_GET = common.world_get
local ECS_NAME = common.ecs_name

local HOOK_ADDED = common.hook_added
local HOOK_CHANGED = common.hook_changed
local HOOK_REMOVED = common.hook_removed

-- global ids are a single byte offset past the ENTITY_ID_TYPES tags, so any
-- id byte at or above the offset is a global id and never a tag
local GLOBAL_ID_OFFSET = 10

local ENTITY_ID_TYPES = {
	entity = 1,
	custom_handler = 2,
	custom_id = 3,
	shared = 4,
}

-- u8 the server appends last to every buffer, read first here; each apply
-- function checks it so mixed up packets error instead of desyncing
local PACKET_TYPES = {
	full = 1,
	entity = 2,
	updates = 3,
	unreliable = 4,
}

-- section bits of the u8 entity mask in a full packet; a set bit means a vlq
-- count precedes that section (mirrors the server's FULL_BITS)
local FULL_BITS = {
	tags = 0,
	components = 1,
	pair_tags = 2,
	pair_components = 3,
	relation_tags = 4,
	relation_components = 5,
}

-- section bits of the u16 entity mask in an update packet (mirrors the
-- server's ENTITY_BITS)
local UPDATE_BITS = {
	reliable_removed = 0,
	reliable_added = 1,
	reliable_changed = 2,
	pair_removed = 3,
	pair_added = 4,
	pair_changed = 5,
	relations_removed = 6,
	full_relations = 7,
	changed_relations = 8,
}

-- trailer bits of the u16 group mask in an update packet (mirrors the
-- server's GROUP_BITS)
local UPDATE_GROUP_BITS = {
	updates = 0,
	added_entities = 1,
	deleted_entities = 2,
}

-- server id -> the custom_handler component or CustomId that resolves it,
-- collected while reading a packet and drained once every entity is known
type CustomIdMap = { [number]: CustomId | Entity }

local client = {}
client.__index = client

-- the removal hook on this tag is how a local world:delete cleans the id maps
local function track_alive(self: Client, entity: Entity)
	local alive_tracking = self.components.__alive_tracking__
	if not WORLD_HAS(self.world, entity, alive_tracking) then
		WORLD_ADD(self.world, entity, alive_tracking)
	end
end

local function ensure_entity(self: Client, server_id: number): Entity
	local client_entity = self.server_ids[server_id]
	if client_entity then
		return client_entity
	end

	local new_entity = WORLD_ENTITY(self.world)

	self.server_ids[server_id] = new_entity
	self.client_ids[new_entity] = server_id
	track_alive(self, new_entity)

	for _, callback in self.addition_hooks do
		callback(new_entity)
	end

	return new_entity
end

-- server said the entity is gone: fire its deleted hooks, then delete it
-- unless an override claimed the deletion. the id maps are cleared either
-- way so a later packet reusing the server id creates a fresh entity
local function delete_entity(self: Client, entity: Entity, server_id: number?)
	local deleted_hook = self.network_hooks.deleted[entity]
	if deleted_hook then
		for _, callback in deleted_hook.callbacks do
			callback(entity)
		end
		if deleted_hook.overrides then
			self.network_hooks.deleted[entity] = nil
			self.client_ids[entity] = nil
		else
			WORLD_DELETE(self.world, entity)
		end
	else
		WORLD_DELETE(self.world, entity)
	end
	if server_id then
		self.server_ids[server_id] = nil
	end
end

local function ensure_command_buffer(self: Client, entity: Entity): CommandBuffer
	local command_buffers = self.command_buffers
	if not command_buffers then
		error "attempted to use a command buffer without being active. (this should never happen)"
	end

	local command_buffer = command_buffers[entity]
	if not command_buffer then
		command_buffer = {
			tags = {},
			components = {},
			unreliable_components = {},
			remove = {},
			pairs_add = {},
			pairs_set = {},
			pairs_unprocessed = {},
			pairs_remove = {},
			relations_clear = {},
		}
		command_buffers[entity] = command_buffer
	end
	return command_buffer
end

local function entity_set(self: Client, entity: Entity, id: Component, value: any, changed_hooks: ChangedHooksEntry?)
	if self.command_buffers_active then
		local command_buffer = ensure_command_buffer(self, entity)
		command_buffer.components[id] = { value = value }
	else
		if changed_hooks then
			if not changed_hooks.overrides then
				WORLD_SET(self.world, entity, id, value)
			end
			for _, callback in changed_hooks.callbacks do
				callback(entity, id, value)
			end
		else
			WORLD_SET(self.world, entity, id, value)
		end
	end
end

local function entity_add(self: Client, entity: Entity, tag: Entity, changed_hooks: ChangedHooksEntry?)
	if self.command_buffers_active then
		local command_buffer = ensure_command_buffer(self, entity)
		command_buffer.tags[tag] = true
	else
		if changed_hooks then
			if not changed_hooks.overrides then
				WORLD_ADD(self.world, entity, tag)
			end
			for _, callback in changed_hooks.callbacks do
				callback(entity, tag)
			end
		else
			WORLD_ADD(self.world, entity, tag)
		end
	end
end

local function entity_set_unreliable(
	self: Client,
	entity: Entity,
	id: Entity,
	value: any,
	changed_hooks: ChangedHooksEntry?
)
	if self.command_buffers_active then
		local command_buffer = ensure_command_buffer(self, entity)
		command_buffer.unreliable_components[id] = { value = value }
	else
		if WORLD_HAS(self.world, entity, id) then
			entity_set(self, entity, id, value, changed_hooks)
		end
	end
end

local function entity_set_pair(
	self: Client,
	entity: Entity,
	relation: Entity,
	target: Entity,
	value: any,
	changed_hooks: ChangedHooksEntry?
)
	if self.command_buffers_active then
		local command_buffer = ensure_command_buffer(self, entity)
		local pair_relation = command_buffer.pairs_set[relation]

		if pair_relation then
			pair_relation[target] = { value = value }
		else
			command_buffer.pairs_set[relation] = { [target] = { value = value } }
		end
	else
		entity_set(self, entity, PAIR(relation, target), value, changed_hooks)
	end
end

local function entity_add_pair(
	self: Client,
	entity: Entity,
	relation: Entity,
	target: Entity,
	changed_hooks: ChangedHooksEntry?
)
	if self.command_buffers_active then
		local command_buffer = ensure_command_buffer(self, entity)
		local pair_relation = command_buffer.pairs_add[relation]

		if pair_relation then
			pair_relation[target] = true
		else
			command_buffer.pairs_add[relation] = { [target] = true }
		end
	else
		entity_add(self, entity, PAIR(relation, target), changed_hooks)
	end
end

local function entity_remove(self: Client, entity: Entity, id: Entity, removed_hooks: RemovedHooksEntry?)
	if self.command_buffers_active then
		local command_buffer = ensure_command_buffer(self, entity)
		command_buffer.remove[id] = true
	else
		if removed_hooks then
			for _, callback in removed_hooks.callbacks do
				callback(entity, id)
			end
			if not removed_hooks.overrides then
				WORLD_REMOVE(self.world, entity, id)
			end
		else
			WORLD_REMOVE(self.world, entity, id)
		end
	end
end

local function entity_remove_pair(
	self: Client,
	entity: Entity,
	relation: Entity,
	target: Entity,
	removed_hooks: RemovedHooksEntry?
)
	if self.command_buffers_active then
		local command_buffer = ensure_command_buffer(self, entity)
		local pair_relation = command_buffer.pairs_remove[relation]

		if pair_relation then
			pair_relation[target] = true
		else
			command_buffer.pairs_remove[relation] = { [target] = true }
		end
	else
		entity_remove(self, entity, PAIR(relation, target), removed_hooks)
	end
end

local function entity_clear_relation(self: Client, entity: Entity, relation: Entity, removed_hooks: RemovedHooksEntry?)
	if self.command_buffers_active then
		local command_buffer = ensure_command_buffer(self, entity)
		command_buffer.relations_clear[relation] = true
	else
		local world = self.world
		if removed_hooks then
			ITERATE_ALL_RELATIONS(world, entity, relation, function(pair)
				for _, callback in removed_hooks.callbacks do
					callback(entity, pair)
				end
				if not removed_hooks.overrides then
					WORLD_REMOVE(world, entity, pair)
				end
			end)
		else
			ITERATE_ALL_RELATIONS(world, entity, relation, function(pair)
				WORLD_REMOVE(world, entity, pair)
			end)
		end
	end
end

local function resolve_global(self: Client, global_id: number): Entity
	if not self.global_handler then
		common.log_error "global id parser not set, consider using client:handle_global()"
	end
	return (self.global_handler :: (id: number) -> Entity)(global_id)
end

local function read_component_id(self: Client, c: Cursor): Entity
	local shared_components = self.shared.components
	local shared_id = cursor.read_span(c, #shared_components.keys)
	local component = shared_components.indexes[shared_id]
	if not component then
		common.log_error(`received a non shared component: {shared_id}`)
	end
	return component
end

local function read_entity_id(self: Client, c: Cursor): (Entity?, number?, number?)
	local id_type = cursor.readu8(c)

	if id_type < GLOBAL_ID_OFFSET then
		if
			id_type == ENTITY_ID_TYPES.entity
			or id_type == ENTITY_ID_TYPES.custom_id
			or id_type == ENTITY_ID_TYPES.custom_handler
		then
			local server_id = cursor.readu40(c)
			return self.server_ids[server_id], server_id, id_type
		elseif id_type == ENTITY_ID_TYPES.shared then
			return read_component_id(self, c), nil, id_type
		end
		common.log_error(`malformed entity type: {id_type}`)
	end

	return resolve_global(self, id_type - GLOBAL_ID_OFFSET), nil, id_type
end

local function skip_custom_payload(self: Client, c: Cursor, id_type: number?)
	if id_type == ENTITY_ID_TYPES.custom_id then
		read_component_id(self, c)
	elseif id_type == ENTITY_ID_TYPES.custom_handler then
		cursor.readu8(c)
	end
end

-- lookup only: an entity the client doesn't know yet is never created.
local function find_entity(self: Client, c: Cursor): (Entity?, number?)
	local entity, server_id, id_type = read_entity_id(self, c)
	skip_custom_payload(self, c, id_type)
	return entity, server_id
end

-- reads an entity id and hands the resolved entity to process. unknown plain
-- entities are created on the spot; unknown custom ids record their handler in
-- custom_ids and hand process a negative server id, meaning the entity is not
-- resolved yet and everything applied to it must go through a command buffer
-- until finish_custom_ids step translates it
local function process_entity(self: Client, c: Cursor, custom_ids: CustomIdMap, process: ((entity: Entity) -> ())?)
	local entity, server_id, id_type = read_entity_id(self, c)

	if entity then
		skip_custom_payload(self, c, id_type)
		if process then
			process(entity)
		end
		return
	end

	local unresolved_id = server_id :: number

	if id_type == ENTITY_ID_TYPES.custom_id then
		custom_ids[unresolved_id] = read_component_id(self, c)
	elseif id_type == ENTITY_ID_TYPES.custom_handler then
		local shared_custom_id = cursor.readu8(c)
		local handler = self.shared.custom_ids.indexes[shared_custom_id]

		if not handler then
			common.log_error "attempted to use a custom id that wasn't registered"
		end
		custom_ids[unresolved_id] = handler
	else
		local new_entity = ensure_entity(self, unresolved_id)
		if process then
			process(new_entity)
		end
		return
	end

	if not process then
		return
	end

	local was_active = self.command_buffers_active
	self.command_buffers_active = true
	process(-unresolved_id :: any)
	self.command_buffers_active = was_active
end

-- reverse of the server's write_variant_value. a serdes value is its buffer
-- (length-prefixed unless the serdes has a fixed bytespan) plus, when the
-- serdes includes variants, the slice of the packet variants it appended;
-- anything else is a variant index, 0 meaning nil. the preprocessor undoes
-- itself last since the server applied it first
local function read_variant_value(c: Cursor, options: ComponentSerializationOptions?, variants: Array<any>?): any
	local serdes = options and options.serdes
	local value: any

	if serdes then
		local bytespan = serdes.bytespan or cursor.read_vlq(c)
		local appended = cursor.read_buffer(c, bytespan)
		local serdes_variants: Array<any>? = nil

		if serdes.includes_variants then
			local start_variant = cursor.read_vlq(c)

			if start_variant > 0 then
				local size = cursor.read_vlq(c)
				serdes_variants = table.move(variants :: Array<any>, start_variant, start_variant + size - 1, 1, {})
			end
		end

		value = serdes.deserialize(appended, serdes_variants :: any)
	else
		local variant_id = cursor.read_vlq(c)
		if variant_id == 0 then
			value = nil
		else
			value = (variants :: Array<any>)[variant_id]
		end
	end

	local preprocessor = options and options.preprocessor
	if preprocessor then
		value = preprocessor.deserialize(value)
	end

	return value
end

local function read_component_value(self: Client, component: Component, c: Cursor, variants: Array<any>?): any
	return read_variant_value(c, self.component_serialization[component], variants)
end

-- a pair value resolves its options like the server writes them: the exact
-- pair first, then the relation's wildcard pair
-- returns the pair id, the value
local function read_pair_value(
	self: Client,
	relation: Component,
	target: Entity,
	c: Cursor,
	variants: Array<any>?
): (Component, any)
	local pair_id = PAIR(relation, target)
	local component_serialization = self.component_serialization
	local options = component_serialization[pair_id] or component_serialization[PAIR(relation, WILDCARD)]
	return pair_id, read_variant_value(c, options, variants)
end

-- a section's vlq count is only written when its mask bit is set
local function read_vlq_bitmask(c: Cursor, mask: number, bit: number): number
	if bit32.btest(mask, bit32.lshift(1, bit)) then
		return cursor.read_vlq(c)
	end
	return 0
end

-- pair value whose target isn't resolved yet (negative id): keeps a cursor
-- frozen at the value so it can be read once the target's custom id resolves
-- and the pair's serdes is known. with buffers inactive the target is final
-- and the value is read right away
local function entity_set_postponed_pair(
	self: Client,
	entity: Entity,
	relation: Component,
	target: Entity,
	c: Cursor,
	variants: Array<any>?
): any
	if self.command_buffers_active then
		local command_buffer = ensure_command_buffer(self, entity)
		local pairs_unprocessed = command_buffer.pairs_unprocessed
		local unprocessed: UnprocessedPair = {
			cursor = c,
			variants = variants,
		}

		local pair_relation = pairs_unprocessed[relation]
		if pair_relation then
			pair_relation[target] = unprocessed
		else
			pairs_unprocessed[relation] = { [target] = unprocessed }
		end
		return nil
	end

	local pair_id, value = read_pair_value(self, relation, target, c, variants)
	entity_set(self, entity, pair_id, value, self.network_hooks.changed[PAIR(self.components.relation, relation)])
	return value
end

-- pair tag: [target id, relation]
local function process_entity_pair(self: Client, entity: Entity, c: Cursor, custom_ids: CustomIdMap)
	local relation = read_component_id(self, c)
	local relation_hooks = self.network_hooks.changed[PAIR(self.components.relation, relation)]
	process_entity(self, c, custom_ids, function(target)
		entity_add_pair(self, entity, relation, target, relation_hooks)
	end)
end

-- pair component: [value, vlq value size, target id, relation]. the size lets
-- the value be skipped when the target is an unresolved custom id, since the
-- serdes to read it with is only known once the final pair is
local function process_entity_pair_value(
	self: Client,
	entity: Entity,
	c: Cursor,
	custom_ids: CustomIdMap,
	variants: Array<any>?
)
	local relation = read_component_id(self, c)
	local relation_hooks = self.network_hooks.changed[PAIR(self.components.relation, relation)]
	process_entity(self, c, custom_ids, function(target)
		local value_size = cursor.read_vlq(c)
		local value_start = c.offset - value_size

		if (target :: any) > 0 then
			local _, value = read_pair_value(self, relation, target, c, variants)
			entity_set_pair(self, entity, relation, target, value, relation_hooks)
			-- the serdes must have consumed exactly the written size; pin the
			-- cursor to where the server said the value starts either way
			c.offset = value_start
		else
			local frozen_cursor = cursor.from_offset(c.buffer, c.offset)
			c.offset = value_start
			entity_set_postponed_pair(self, entity, relation, target, frozen_cursor, variants)
		end
	end)
end

-- relation tags: [target ids..., vlq count, relation]
local function process_entity_relations(self: Client, entity: Entity, c: Cursor, custom_ids: CustomIdMap)
	local relation = read_component_id(self, c)
	local total_targets = cursor.read_vlq(c)
	local relation_hooks = self.network_hooks.changed[PAIR(self.components.relation, relation)]

	for _ = 1, total_targets do
		process_entity(self, c, custom_ids, function(target)
			entity_add_pair(self, entity, relation, target, relation_hooks)
		end)
	end
end

-- relation components: [(target id, value)..., vlq count, relation]; values
-- use the relation's own options, not a per-pair one
local function process_entity_relation_values(
	self: Client,
	entity: Entity,
	c: Cursor,
	custom_ids: CustomIdMap,
	variants: Array<any>?
)
	local relation = read_component_id(self, c)
	local total_targets = cursor.read_vlq(c)
	local relation_hooks = self.network_hooks.changed[PAIR(self.components.relation, relation)]

	for _ = 1, total_targets do
		local value = read_component_value(self, relation, c, variants)
		process_entity(self, c, custom_ids, function(target)
			entity_set_pair(self, entity, relation, target, value, relation_hooks)
		end)
	end
end

-- one entity of a full snapshot, after its id: the FULL_BITS mask, then each
-- flagged section in write-reverse order (tags first, relation components
-- last)
local function process_full_entity(
	self: Client,
	entity: Entity,
	c: Cursor,
	custom_ids: CustomIdMap,
	variants: Array<any>?
)
	local mask = cursor.readu8(c)
	local changed_hooks = self.network_hooks.changed
	local components = self.components

	local total_tags = read_vlq_bitmask(c, mask, FULL_BITS.tags)
	for _ = 1, total_tags do
		local tag = read_component_id(self, c)
		entity_add(self, entity, tag, changed_hooks[PAIR(components.reliable, tag)])
	end

	local total_components = read_vlq_bitmask(c, mask, FULL_BITS.components)
	for _ = 1, total_components do
		local component = read_component_id(self, c)
		local value = read_component_value(self, component, c, variants)
		entity_set(self, entity, component, value, changed_hooks[PAIR(components.reliable, component)])
	end

	local total_pair_tags = read_vlq_bitmask(c, mask, FULL_BITS.pair_tags)
	for _ = 1, total_pair_tags do
		process_entity_pair(self, entity, c, custom_ids)
	end

	local total_pair_components = read_vlq_bitmask(c, mask, FULL_BITS.pair_components)
	for _ = 1, total_pair_components do
		process_entity_pair_value(self, entity, c, custom_ids, variants)
	end

	local total_relation_tags = read_vlq_bitmask(c, mask, FULL_BITS.relation_tags)
	for _ = 1, total_relation_tags do
		process_entity_relations(self, entity, c, custom_ids)
	end

	local total_relation_components = read_vlq_bitmask(c, mask, FULL_BITS.relation_components)
	for _ = 1, total_relation_components do
		process_entity_relation_values(self, entity, c, custom_ids, variants)
	end
end

-- pair tag removal: [target id, relation]
local function process_entity_pair_removal(self: Client, entity: Entity, c: Cursor, custom_ids: CustomIdMap)
	local relation = read_component_id(self, c)
	local relation_hooks = self.network_hooks.removed[PAIR(self.components.relation, relation)]
	process_entity(self, c, custom_ids, function(target)
		entity_remove_pair(self, entity, relation, target, relation_hooks)
	end)
end

-- relation target removals: [target ids..., vlq count, relation]
local function process_entity_relation_removals(self: Client, entity: Entity, c: Cursor, custom_ids: CustomIdMap)
	local relation = read_component_id(self, c)
	local total_targets = cursor.read_vlq(c)
	local relation_hooks = self.network_hooks.removed[PAIR(self.components.relation, relation)]

	for _ = 1, total_targets do
		process_entity(self, c, custom_ids, function(target)
			entity_remove_pair(self, entity, relation, target, relation_hooks)
		end)
	end
end

-- one entity of an update packet, after its id: the UPDATE_BITS mask, then
-- each flagged section in write-reverse order (reliable changed first,
-- relations removed last). unreliable tracked components ride the reliable
-- changed section for their presence, so they resolve reliable hooks here
local function process_entity_updates(
	self: Client,
	entity: Entity,
	c: Cursor,
	custom_ids: CustomIdMap,
	variants: Array<any>?
)
	local mask = cursor.readu16(c)
	local changed_hooks = self.network_hooks.changed
	local removed_hooks = self.network_hooks.removed
	local components = self.components

	-- reliables

	local total_changed = read_vlq_bitmask(c, mask, UPDATE_BITS.reliable_changed)
	for _ = 1, total_changed do
		local component = read_component_id(self, c)
		local value = read_component_value(self, component, c, variants)
		entity_set(self, entity, component, value, changed_hooks[PAIR(components.reliable, component)])
	end

	local total_added = read_vlq_bitmask(c, mask, UPDATE_BITS.reliable_added)
	for _ = 1, total_added do
		local tag = read_component_id(self, c)
		entity_add(self, entity, tag, changed_hooks[PAIR(components.reliable, tag)])
	end

	local total_removed = read_vlq_bitmask(c, mask, UPDATE_BITS.reliable_removed)
	for _ = 1, total_removed do
		local component = read_component_id(self, c)
		entity_remove(self, entity, component, removed_hooks[PAIR(components.reliable, component)])
	end

	-- pairs

	local total_pair_changed = read_vlq_bitmask(c, mask, UPDATE_BITS.pair_changed)
	for _ = 1, total_pair_changed do
		process_entity_pair_value(self, entity, c, custom_ids, variants)
	end

	local total_pair_added = read_vlq_bitmask(c, mask, UPDATE_BITS.pair_added)
	for _ = 1, total_pair_added do
		process_entity_pair(self, entity, c, custom_ids)
	end

	local total_pair_removed = read_vlq_bitmask(c, mask, UPDATE_BITS.pair_removed)
	for _ = 1, total_pair_removed do
		process_entity_pair_removal(self, entity, c, custom_ids)
	end

	-- relations

	if bit32.btest(mask, bit32.lshift(1, UPDATE_BITS.changed_relations)) then
		local total_relations_removed = cursor.read_vlq(c)
		for _ = 1, total_relations_removed do
			process_entity_relation_removals(self, entity, c, custom_ids)
		end

		local total_relations_added = cursor.read_vlq(c)
		for _ = 1, total_relations_added do
			process_entity_relations(self, entity, c, custom_ids)
		end

		local total_relations_changed = cursor.read_vlq(c)
		for _ = 1, total_relations_changed do
			process_entity_relation_values(self, entity, c, custom_ids, variants)
		end
	end

	if bit32.btest(mask, bit32.lshift(1, UPDATE_BITS.full_relations)) then
		local total_relation_tags = cursor.read_vlq(c)
		for _ = 1, total_relation_tags do
			process_entity_relations(self, entity, c, custom_ids)
		end

		local total_relation_components = cursor.read_vlq(c)
		for _ = 1, total_relation_components do
			process_entity_relation_values(self, entity, c, custom_ids, variants)
		end
	end

	local total_relations_cleared = read_vlq_bitmask(c, mask, UPDATE_BITS.relations_removed)
	for _ = 1, total_relations_cleared do
		local relation = read_component_id(self, c)
		entity_clear_relation(self, entity, relation, removed_hooks[PAIR(components.relation, relation)])
	end
end

-- one update group: [u16 group mask, added ids, per entity blocks, deleted
-- ids] in read order. creations, then updates, then deletions
local function process_update_group(self: Client, c: Cursor, custom_ids: CustomIdMap, variants: Array<any>?)
	local mask = cursor.readu16(c)

	local total_added = read_vlq_bitmask(c, mask, UPDATE_GROUP_BITS.added_entities)
	for _ = 1, total_added do
		process_entity(self, c, custom_ids)
	end

	local total_entities = read_vlq_bitmask(c, mask, UPDATE_GROUP_BITS.updates)
	for _ = 1, total_entities do
		process_entity(self, c, custom_ids, function(entity)
			process_entity_updates(self, entity, c, custom_ids, variants)
		end)
	end

	local total_deleted = read_vlq_bitmask(c, mask, UPDATE_GROUP_BITS.deleted_entities)
	for _ = 1, total_deleted do
		local entity, server_id = find_entity(self, c)
		if entity then
			delete_entity(self, entity, server_id)
		end
	end
end

local function apply_command_buffer(
	self: Client,
	entity: Entity,
	command_buffer: CommandBuffer,
	request: (e: Entity, ...any) -> Entity?
)
	local components = self.components
	local changed_hooks = self.network_hooks.changed
	local removed_hooks = self.network_hooks.removed

	for tag in command_buffer.tags do
		entity_add(self, entity, tag, changed_hooks[PAIR(components.reliable, tag)])
	end
	for component, value in command_buffer.components do
		entity_set(self, entity, component, value.value, changed_hooks[PAIR(components.reliable, component)])
	end
	for component, value in command_buffer.unreliable_components do
		if WORLD_HAS(self.world, entity, component) then
			entity_set(self, entity, component, value.value, changed_hooks[PAIR(components.unreliable, component)])
		end
	end
	for component in command_buffer.remove do
		entity_remove(self, entity, component, removed_hooks[PAIR(components.reliable, component)])
	end
	for relation, targets in command_buffer.pairs_add do
		local relation_hooks = changed_hooks[PAIR(components.relation, relation)]
		for target in targets do
			local client_target = request(target)
			if client_target then
				entity_add_pair(self, entity, relation, client_target, relation_hooks)
			end
		end
	end
	for relation, targets in command_buffer.pairs_set do
		local relation_hooks = changed_hooks[PAIR(components.relation, relation)]
		for target, value in targets do
			local client_target = request(target)
			if client_target then
				entity_set_pair(self, entity, relation, client_target, value.value, relation_hooks)
			end
		end
	end
	for relation, targets in command_buffer.pairs_unprocessed do
		local relation_hooks = changed_hooks[PAIR(components.relation, relation)]
		for target, unprocessed in targets do
			local client_target = request(target)
			if client_target then
				local processed_value = unprocessed.processed_value
				if processed_value then
					entity_set_pair(self, entity, relation, client_target, processed_value.value, relation_hooks)
				else
					local value = entity_set_postponed_pair(
						self,
						entity,
						relation,
						client_target,
						unprocessed.cursor,
						unprocessed.variants
					)
					unprocessed.processed_value = { value = value }
				end
			end
		end
	end
	for relation, targets in command_buffer.pairs_remove do
		local relation_hooks = removed_hooks[PAIR(components.relation, relation)]
		for target in targets do
			local client_target = request(target)
			if client_target then
				entity_remove_pair(self, entity, relation, client_target, relation_hooks)
			end
		end
	end
	for relation in command_buffer.relations_clear do
		entity_clear_relation(self, entity, relation, removed_hooks[PAIR(components.relation, relation)])
	end
end

local function find_component_in_buffer(command_buffer: CommandBuffer, component: Entity): { value: any }?
	return command_buffer.components[component] or command_buffer.unreliable_components[component]
end

local function find_has_in_buffer(command_buffer: CommandBuffer, tag: Entity): boolean
	return (command_buffer.tags[tag] ~= nil)
		or (command_buffer.components[tag] ~= nil)
		or (command_buffer.unreliable_components[tag] ~= nil)
end

local function find_pair_in_buffer(
	command_buffer: CommandBuffer,
	relation: Entity,
	target: Entity,
	find: (unprocessed_entity: Entity) -> (Entity?, Entity)
): (boolean, any)
	local value_relations = command_buffer.pairs_set[relation]
	if value_relations then
		for buffer_target, value in value_relations do
			local found = find(buffer_target)
			if found == target then
				return true, value.value
			end
		end
	end

	local relations = command_buffer.pairs_add[relation]
	if relations then
		for buffer_target in relations do
			local found = find(buffer_target)
			if found == target then
				return true, nil
			end
		end
	end

	local unprocessed_relations = command_buffer.pairs_unprocessed[relation]
	if unprocessed_relations then
		for buffer_target, unprocessed in unprocessed_relations do
			local found = find(buffer_target)
			if found == target then
				local processed_value = unprocessed.processed_value
				return true, processed_value and processed_value.value
			end
		end
	end

	return false, nil
end

local function find_target_in_buffer(command_buffer: CommandBuffer, relation: Entity, index: number?): Entity?
	local i = 0

	local pairs = command_buffer.pairs_add[relation]
	if pairs then
		for target in pairs do
			if i == (index or 0) then
				return target
			end
			i += 1
		end
	end

	local pairs_values = command_buffer.pairs_set[relation]
	if pairs_values then
		for target in pairs_values do
			if i == (index or 0) then
				return target
			end
			i += 1
		end
	end

	local unprocessed_pairs = command_buffer.pairs_unprocessed[relation]
	if unprocessed_pairs then
		for target in unprocessed_pairs do
			if i == (index or 0) then
				return target
			end
			i += 1
		end
	end

	return nil
end

-- resolves every custom id collected while reading a packet, then drains the
-- command buffers. ids are negative server ids until resolved; a handler can
-- pull other unresolved entities through its context, so resolution recurses
-- and each server id is attempted once
local function finish_custom_ids(self: Client, custom_ids: CustomIdMap, command_buffers: { [Entity]: CommandBuffer })
	local world = self.world
	local components = self.components
	local processed: { [number]: boolean } = {}
	local create_context: (unprocessed_entity: Entity) -> customid.HandleContext

	-- positive ids are already client entities; negative ones look up the
	-- server id, which may have resolved earlier in this pass
	local function find(unprocessed_entity: Entity): (Entity?, Entity)
		if (unprocessed_entity :: any) > 0 then
			return unprocessed_entity, unprocessed_entity
		end
		local server_id = -(unprocessed_entity :: any)
		return self.server_ids[server_id], server_id
	end

	local function process(unprocessed_entity: Entity, custom_handler: (CustomId | Entity)?): Entity?
		local client_entity, server_id = find(unprocessed_entity)
		if client_entity then
			return client_entity
		end
		if processed[server_id :: any] then
			return nil
		end

		custom_handler = custom_handler or custom_ids[server_id :: any]
		if not custom_handler then
			return nil
		end
		processed[server_id :: any] = true

		local command_buffer = command_buffers[unprocessed_entity]
		local new_entity: Entity? = nil

		if type(custom_handler) == "number" then
			local component: Entity = custom_handler :: any
			local handler = WORLD_GET(world, component, components.custom_handler)
			if not handler then
				common.log_error(
					"received a custom id for a component without a handler, consider adding custom_handler to component:",
					common.log_component(world, component)
				)
			end

			local value = command_buffer and find_component_in_buffer(command_buffer, component)
			if not value then
				common.log_warn(`no component found for custom id handler: {common.log_component(world, component)}`)
			end
			new_entity = handler(value and value.value)
		else
			local custom = custom_handler :: CustomId
			local handle_callback = custom.handle_callback
			if not handle_callback then
				common.log_error("no handler callback was set for custom id:", custom.identifier)
			end
			new_entity = (handle_callback :: any)(create_context(unprocessed_entity))
		end

		if new_entity then
			self.server_ids[server_id :: any] = new_entity
			self.client_ids[new_entity] = server_id :: any
			track_alive(self, new_entity)

			if command_buffer then
				apply_command_buffer(self, new_entity, command_buffer, process)
				command_buffers[unprocessed_entity] = nil
			end
		end

		return new_entity
	end

	-- what a custom id handler sees of the entity: its buffered state, with
	-- targets and referenced entities resolved on demand
	function create_context(unprocessed_entity: Entity): customid.HandleContext
		local command_buffer = command_buffers[unprocessed_entity]

		local function component(id: Entity): any
			if not command_buffer then
				return nil
			end
			local value = find_component_in_buffer(command_buffer, id)
			return value and value.value
		end
		local function has(tag: Entity): boolean
			if not command_buffer then
				return false
			end
			return find_has_in_buffer(command_buffer, tag)
		end
		local function target(relation: Entity, index: number?): Entity?
			if not command_buffer then
				return nil
			end
			local buffer_target = find_target_in_buffer(command_buffer, relation, index)
			if buffer_target then
				return process(buffer_target)
			end
			return nil
		end
		local function pair_value(relation: Entity, pair_target: Entity): any
			if not command_buffer then
				return nil
			end
			local _, value = find_pair_in_buffer(command_buffer, relation, pair_target, find)
			return value
		end
		local function has_pair(relation: Entity, pair_target: Entity): boolean
			if not command_buffer then
				return false
			end
			local found = find_pair_in_buffer(command_buffer, relation, pair_target, find)
			return found
		end
		local function entity(server_id: number): Entity
			return process(-server_id :: any) :: Entity
		end

		-- the context's generic accessors are typed for callers; the buffer
		-- lookups behind them are untyped
		local context = {
			entity_id = math.abs(unprocessed_entity :: any),
			has = has,
			component = component,
			target = target,
			pair_value = pair_value,
			has_pair = has_pair,
			entity = entity,
		}
		return context :: any
	end

	for server_id, custom_handler in custom_ids do
		process(-server_id :: any, custom_handler)
	end

	-- known entities whose buffers reference custom ids, now resolvable
	for entity, command_buffer in command_buffers do
		if (entity :: any) < 0 then
			continue
		end
		apply_command_buffer(self, entity, command_buffer, process)
	end
end

local function finish_replication(self: Client)
	self.is_replicating = false
	for _, callback in self.after_replication_callbacks do
		callback()
	end
	table.clear(self.after_replication_callbacks)
end

-- a full snapshot from get_full: [vlq entity count, per entity: id + sections].
-- entities whose id is a custom id are buffered until finish_custom_ids can
-- resolve them
local function check_packet_type(c: Cursor, expected_byte: number)
	local got_byte = cursor.readu8(c)
	if got_byte == expected_byte then
		return
	end

	local got_type: string? = nil
	local expected_type: string? = nil
	for packet_type, byte in PACKET_TYPES :: { [string]: number } do
		if byte == got_byte then
			got_type = packet_type
		elseif byte == expected_byte then
			expected_type = packet_type
		end
	end
	common.log_error(
		`packet type mismatch, expected: {expected_type or "(unknown)"} got: {got_type or "(unknown)"} instead`
	)
end

function client.apply_full(self: Client, buf: buffer, variants: { any }?)
	self:resolve_dirty()
	self.is_replicating = true

	local c = cursor.from(buf)
	check_packet_type(c, PACKET_TYPES.full)
	local command_buffers: { [Entity]: CommandBuffer } = {}
	local custom_ids: CustomIdMap = {}
	self.command_buffers = command_buffers

	local total_entities = cursor.read_vlq(c)
	for _ = 1, total_entities do
		process_entity(self, c, custom_ids, function(entity)
			process_full_entity(self, entity, c, custom_ids, variants)
		end)
	end

	finish_custom_ids(self, custom_ids, command_buffers)
	self.command_buffers = nil
	finish_replication(self)
end

-- a combined packet from collect_entity: [inner packets..., vlq packet count],
-- each inner packet a full snapshot of the same entity holding the members of
-- one filter group. the cursor reads from the end, so packets come out last
-- to first and pick their variants list by index
function client.apply_entity(self: Client, buf: buffer, all_variants: { { any } }?)
	self:resolve_dirty()
	self.is_replicating = true

	local c = cursor.from(buf)
	check_packet_type(c, PACKET_TYPES.entity)
	local command_buffers: { [Entity]: CommandBuffer } = {}
	local custom_ids: CustomIdMap = {}
	self.command_buffers = command_buffers

	local total_packets = cursor.read_vlq(c)
	for packet_index = total_packets, 1, -1 do
		local variants = if all_variants then all_variants[packet_index] else nil
		local total_entities = cursor.read_vlq(c)
		for _ = 1, total_entities do
			process_entity(self, c, custom_ids, function(entity)
				process_full_entity(self, entity, c, custom_ids, variants)
			end)
		end
	end

	finish_custom_ids(self, custom_ids, command_buffers)
	self.command_buffers = nil
	finish_replication(self)
end

-- a combined packet from collect_updates: [group packets..., vlq packet
-- count], one inner packet per visibility group the player belongs to. read
-- like apply_entity: last group first, variants picked by index
function client.apply_updates(self: Client, buf: buffer, all_variants: { { any } }?)
	self:resolve_dirty()
	self.is_replicating = true

	local c = cursor.from(buf)
	check_packet_type(c, PACKET_TYPES.updates)
	local command_buffers: { [Entity]: CommandBuffer } = {}
	local custom_ids: CustomIdMap = {}
	self.command_buffers = command_buffers

	local total_packets = cursor.read_vlq(c)
	for packet_index = total_packets, 1, -1 do
		local variants = if all_variants then all_variants[packet_index] else nil
		process_update_group(self, c, custom_ids, variants)
	end

	finish_custom_ids(self, custom_ids, command_buffers)
	self.command_buffers = nil
	finish_replication(self)
end

-- one entity of an unreliable packet, after its id: [vlq pair count, pairs...,
-- vlq component count, components...]. the packet carries current values
-- only, never presence: an entity or member the client doesn't have yet is
-- skipped (its adds travel reliably), but every value is still read so the
-- cursor stays aligned. `entity` is nil when the entity is unknown
local function process_unreliable_entity(self: Client, entity: Entity?, c: Cursor, variants: Array<any>?)
	local world = self.world
	local changed_hooks = self.network_hooks.changed
	local components = self.components

	local total_pairs = cursor.read_vlq(c)
	for _ = 1, total_pairs do
		local relation = read_component_id(self, c)
		local target = find_entity(self, c)
		local value_size = cursor.read_vlq(c)
		local value_start = c.offset - value_size

		if entity and target then
			local pair_id, value = read_pair_value(self, relation, target, c, variants)
			if WORLD_HAS(world, entity, pair_id) then
				entity_set(self, entity, pair_id, value, changed_hooks[PAIR(components.relation, relation)])
			end
		end
		-- the size skips the value when nothing can receive it
		c.offset = value_start
	end

	local total_components = cursor.read_vlq(c)
	for _ = 1, total_components do
		local component = read_component_id(self, c)
		local value = read_component_value(self, component, c, variants)
		if entity then
			entity_set_unreliable(self, entity, component, value, changed_hooks[PAIR(components.unreliable, component)])
		end
	end
end

-- a combined packet from collect_unreliable: [inner packets..., vlq packet
-- count], each inner packet [per entity: id + values, vlq entity count].
-- entities are only looked up, never created: the channel is lossy and
-- carries no presence, so no command buffers or custom id resolution here
function client.apply_unreliable(self: Client, buf: buffer, all_variants: { { any } }?)
	self:resolve_dirty()
	self.is_replicating = true

	local c = cursor.from(buf)
	check_packet_type(c, PACKET_TYPES.unreliable)

	local total_packets = cursor.read_vlq(c)
	for packet_index = total_packets, 1, -1 do
		local variants = if all_variants then all_variants[packet_index] else nil
		local total_entities = cursor.read_vlq(c)
		for _ = 1, total_entities do
			local entity = find_entity(self, c)
			process_unreliable_entity(self, entity, c, variants)
		end
	end

	finish_replication(self)
end

function client.after_replication(self: Client, callback: () -> ())
	if self.is_replicating then
		table.insert(self.after_replication_callbacks, callback)
	else
		callback()
	end
end

function client.added(self: Client, callback: (entity: Entity) -> ()): Disconnect
	table.insert(self.addition_hooks, callback)
	return function()
		local index = table.find(self.addition_hooks, callback)
		if index then
			table.remove(self.addition_hooks, index)
		end
	end
end

local function add_hook_entry(self: Client, action: string, ...): ({ overrides: boolean }, Disconnect)
	if action == "changed" or action == "removed" then
		local relation = select(1, ...) :: Entity
		local callback = select(2, ...) :: (entity: Entity, id: Component, value: any) -> ()
		local hooks = action == "changed" and self.network_hooks.changed or self.network_hooks.removed
		local entries = hooks[relation] :: ChangedHooksEntry

		if not entries then
			entries = {
				overrides = false,
				callbacks = {},
			}
			hooks[relation] = entries :: any
		end
		table.insert(entries.callbacks, callback)

		local function disconnect()
			local callbacks = entries.callbacks
			local index = table.find(callbacks, callback)
			if index then
				table.remove(callbacks, index)
				if #callbacks == 0 then
					hooks[relation] = nil :: any
				end
			end
		end
		return entries, disconnect
	elseif action == "deleted" then
		local entity = select(1, ...) :: Entity
		local callback = select(2, ...) :: (entity: Entity) -> ()
		local hooks = self.network_hooks.deleted
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

function client.hook(self: Client, action: string, ...)
	local entry, disconnect = add_hook_entry(self, action, ...)
	entry.overrides = false
	return disconnect
end

function client.override(self: Client, action: string, ...)
	local entry, disconnect = add_hook_entry(self, action, ...)
	entry.overrides = true
	return disconnect
end

function client.get_server_entity(self: Client, client_entity: Entity): number?
	return self.client_ids[client_entity]
end

function client.get_client_entity(self: Client, server_entity: number): Entity?
	return self.server_ids[server_entity]
end

function client.register_entity(self: Client, entity: Entity, server_entity: number)
	self.server_ids[server_entity] = entity
	self.client_ids[entity] = server_entity
	track_alive(self, entity)
end

function client.unregister_entity(self: Client, entity: Entity)
	local server_id = self.client_ids[entity]
	if server_id then
		self.server_ids[server_id] = nil
		self.client_ids[entity] = nil
	end
end

function client.handle_global(self: Client, handler: (id: number) -> Entity)
	self.global_handler = handler
end

function client.register_custom_id(self: Client, custom_id: CustomId)
	self.registered_custom_ids[custom_id] = true
	self.is_shared_dirty = true
end

local function ensure_component_serialization(self: Client, component: Component): ComponentSerializationOptions
	local options = self.component_serialization[component]
	if not options then
		options = {} :: ComponentSerializationOptions
		self.component_serialization[component] = options
	end
	return options
end

local function prune_component_serialization(self: Client, component: Component, options: ComponentSerializationOptions)
	if options.serdes == nil and options.preprocessor == nil and options.delta_serializer == nil then
		self.component_serialization[component] = nil
	end
end

-- serdes take part in the handshake, preprocessors and delta serializers are
-- local to each side and never mark shared dirty
function client.set_serdes(self: Client, component: Component, serdes: types.Serdes)
	ensure_component_serialization(self, component).serdes = serdes
	self.is_shared_dirty = true
end

function client.remove_serdes(self: Client, component: Component)
	local options = self.component_serialization[component]
	if not options then
		return
	end
	options.serdes = nil
	prune_component_serialization(self, component, options)
	self.is_shared_dirty = true
end

function client.set_preprocessor(self: Client, component: Component, preprocessor: types.Preprocessor)
	ensure_component_serialization(self, component).preprocessor = preprocessor
end

function client.remove_preprocessor(self: Client, component: Component)
	local options = self.component_serialization[component]
	if not options then
		return
	end
	options.preprocessor = nil
	prune_component_serialization(self, component, options)
end

function client.set_delta_serializer(self: Client, component: Component, delta_serializer: types.DeltaSerializer)
	ensure_component_serialization(self, component).delta_serializer = delta_serializer
end

function client.remove_delta_serializer(self: Client, component: Component)
	local options = self.component_serialization[component]
	if not options then
		return
	end
	options.delta_serializer = nil
	prune_component_serialization(self, component, options)
end

-- rebuilds the shared lookups (component ids, custom ids, serdes) when
-- flagged; cheap no-op otherwise, so every deserialize entry point calls it
function client.resolve_dirty(self: Client)
	if not self.is_shared_dirty then
		return
	end

	local serdes: { [Component]: types.Serdes } = {}
	for component, options in self.component_serialization do
		if options.serdes then
			serdes[component] = options.serdes
		end
	end

	self.shared = shared.resolve_shared(self.world, self.components, self.registered_custom_ids, serdes)
	self.is_shared_dirty = false
end

-- snapshot of the shared lookups for the server to verify against its own;
-- resolves pending shared changes first so the handshake never describes a
-- stale state
-- the wire id of a shared component, stable across server and client once the
-- handshake passes; 0 and an error for anything not shared
function client.encode_component(self: Client, component: Component): number
	self:resolve_dirty()
	local encoded = self.shared.components.members[component]
	if not encoded then
		common.log_error(`attempted to encode a non-shared component `, common.log_component(self.world, component))
		return 0
	end
	return encoded
end

function client.decode_component(self: Client, encoded: number): Component?
	self:resolve_dirty()
	return self.shared.components.indexes[encoded]
end

function client.get_shared_count(self: Client): number
	self:resolve_dirty()
	return #self.shared.components.keys
end

function client.generate_handshake(self: Client): types.HandshakeInfo
	self:resolve_dirty()
	return handshake.generate_handshake(self.shared)
end

function client.verify_handshake(self: Client, server_handshake: types.HandshakeInfo): (boolean, string?)
	self:resolve_dirty()
	return handshake.verify_handshake(self.shared, server_handshake, "server", "client")
end

function client.init(self: Client, wrd: World?)
	if self.inited == true then
		return common.log_warn "attempted to init a client twice"
	end
	if self.inited == nil then
		return common.log_warn "attempted to re-init a destroyed client"
	end
	self.inited = true

	local world = wrd or self.world
	self.world = world

	if not world then
		common.log_error "Providing a world is required to start replecs"
	end

	if not self.components then
		self.components = utils.create_world_components(world)
	end
	local components = self.components

	local function hook(unhook: () -> ())
		table.insert(self.cleanups, unhook)
	end

	-- shared components and their names feed the handshake lookups; any change
	-- rebuilds them at the next resolve_dirty
	local function mark_shared_dirty()
		self.is_shared_dirty = true
	end

	for _, component in { components.shared, ECS_NAME } do
		hook(HOOK_ADDED(world, component, mark_shared_dirty))
		hook(HOOK_CHANGED(world, component, mark_shared_dirty))
		hook(HOOK_REMOVED(world, component, mark_shared_dirty))
	end

	hook(HOOK_ADDED(world, components.serdes, function(component, _, serdes)
		self:set_serdes(component, serdes)
	end))
	hook(HOOK_CHANGED(world, components.serdes, function(component, _, serdes)
		self:set_serdes(component, serdes)
	end))
	hook(HOOK_REMOVED(world, components.serdes, function(component)
		self:remove_serdes(component)
	end))

	-- a replicated entity deleted locally (or by delete_entity) drops out of
	-- the id maps, so the server id can be bound to a fresh entity later
	hook(HOOK_REMOVED(world, components.__alive_tracking__, function(entity)
		local server_id = self.client_ids[entity]
		if server_id then
			self.server_ids[server_id] = nil
			self.client_ids[entity] = nil
		end
		self.network_hooks.deleted[entity] = nil
	end))

	for component, serdes in world:query(components.serdes):iter() do
		self:set_serdes(component, serdes)
	end

	self.is_shared_dirty = true
end

function client.destroy(self: Client)
	if self.inited == nil then
		return common.log_warn "attempted to destroy a client twice"
	end
	self.inited = nil
	for _, cleanup in self.cleanups do
		cleanup()
	end
	table.clear(self.cleanups)
end

-- components may be nil without preregistration: they are created from the
-- world here when one is given, otherwise at init
local function create(world: World?, components: types.Components?): Client
	local self = {} :: Client

	self.world = world :: any
	self.components = components or (if world then utils.create_world_components(world) else nil) :: any
	self.inited = false

	self.shared = {} :: types.Shared
	self.registered_custom_ids = {}
	self.component_serialization = {}
	-- starts dirty so the first resolve_dirty builds the lookups
	self.is_shared_dirty = true

	self.is_replicating = false
	self.after_replication_callbacks = {}

	self.global_handler = nil
	self.server_ids = {}
	self.client_ids = {}
	self.command_buffers = nil
	self.command_buffers_active = false

	self.addition_hooks = {}
	self.network_hooks = {
		deleted = {},
		changed = {},
		removed = {},
	}

	self.cleanups = {}
	return setmetatable(self, client) :: any
end

return {
	create = create,

	read_component_id = read_component_id,
	read_entity_id = read_entity_id,
	find_entity = find_entity,
	process_entity = process_entity,

	read_component_value = read_component_value,
	read_pair_value = read_pair_value,

	process_entity_pair = process_entity_pair,
	process_entity_pair_value = process_entity_pair_value,
	process_entity_relations = process_entity_relations,
	process_entity_relation_values = process_entity_relation_values,
	process_full_entity = process_full_entity,
	delete_entity = delete_entity,
}
