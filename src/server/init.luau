--!optimize 2

local common = require "./common"
local cursor = require "./cursor"
local registry = require "@self/registry"
local bitmasks = require "@self/bitmasks"
local filter_groups = require "@self/filter_group"
local types = require "./types"
local customid = require "./customid"
local shared = require "./shared"
local handshake = require "./handshake"
local utils = require "./utils"

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }

type Player = any

type FilterAny = types.FilterAny
type FilterSet = types.FilterSet
type FilterPredicator = types.FilterPredicator
type FilterPlayer = types.FilterPlayer
type FilterGroup = filter_groups.FilterGroup

-- what the public set_* API accepts as a filter
type FilterInput = FilterAny | FilterGroup

type MaskHash = string

type World = common.World
type Entity = common.Entity
type Component<T = any> = common.Component<T>
type Bitmask = buffer
type Bitset = number
type TrackType = number

type BitmaskDeltas = bitmasks.BitmaskDeltas
type Cursor = cursor.Cursor

export type ServerImp = {
	set_networked: (self: Server, entity: Entity, filter: FilterInput?) -> (),
	set_reliable: (self: Server, entity: Entity, component: Component, filter: FilterInput?) -> (),
	set_unreliable: (self: Server, entity: Entity, component: Component, filter: FilterInput?) -> (),
	set_once: (self: Server, entity: Entity, component: Component, filter: FilterInput?) -> (),
	set_pair: (self: Server, entity: Entity, id: Component, filter: FilterInput?) -> (),
	set_unreliable_pair: (self: Server, entity: Entity, id: Component, filter: FilterInput?) -> (),
	set_relation: (self: Server, entity: Entity, relation: Component, filter: FilterInput?) -> (),

	stop_networked: (self: Server, entity: Entity) -> (),
	stop_reliable: (self: Server, entity: Entity, component: Component) -> (),
	stop_unreliable: (self: Server, entity: Entity, component: Component) -> (),
	stop_once: (self: Server, entity: Entity, component: Component) -> (),
	stop_pair: (self: Server, entity: Entity, id: Component) -> (),
	stop_unreliable_pair: (self: Server, entity: Entity, id: Component) -> (),
	stop_relation: (self: Server, entity: Entity, relation: Component) -> (),

	force_change: (self: Server, entity: Entity, component: Component) -> (),

	set_global: (self: Server, entity: Entity, global_id: number) -> (),
	remove_global: (self: Server, entity: Entity) -> (),
	set_custom: (self: Server, entity: Entity, custom: Component | CustomId) -> (),
	remove_custom: (self: Server, entity: Entity) -> (),
	register_custom_id: (self: Server, custom_id: CustomId) -> (),

	set_serdes: <T>(self: Server, component: Component<T>, serdes: types.Serdes<T>) -> (),
	remove_serdes: (self: Server, component: Component) -> (),
	set_preprocessor: <B, A>(self: Server, component: Component<B>, preprocessor: types.Preprocessor<B, A>) -> (),
	remove_preprocessor: (self: Server, component: Component) -> (),
	set_delta_serializer: <T, D>(self: Server, component: Component<T>, delta: types.DeltaSerializer<T, D>) -> (),
	remove_delta_serializer: (self: Server, component: Component) -> (),
}

-- filter == nil means "replicate to all active clients", resolved at collect time
type StorageBase = {
	filter: Bitmask?,
	last_replicated: Bitmask?,

	-- set while a filter group drives this storage's filter; the listener is
	-- kept so it can be disconnected when the filter changes or the storage dies
	filter_group: FilterGroup?,
	filter_listener: ((Bitmask) -> ())?,
	filter_input: FilterInput?,
}

type TrackingStorageBase = StorageBase & {
	track_type: TrackType,

	dirty_flags: Bitset,
	is_component: boolean,
	-- once storages replicate on add, removal and visibility gain only; world
	-- value changes are ignored unless force_change is called
	is_once: boolean?,
	-- set by stop_*: the filter is forced empty so collect sends the removal
	-- delta, then the storage is discarded; a start_* before that revives it
	is_dead: boolean,
}

type ReliableStorage = TrackingStorageBase & {}
type PairStorage = TrackingStorageBase & {}
type UnreliableStorage = TrackingStorageBase & {}
type UnreliablePairStorage = TrackingStorageBase & {}

type RelationStorage = TrackingStorageBase & {
	dirty_targets: Set<Entity>,
}

type NetworkedStorage = StorageBase & {
	dirty_flags: Bitset,
	is_dead: boolean,
	-- live (not stopped) unreliable + unreliable_pair storages; keeps
	-- unreliable_networked membership in sync without scanning storages
	unreliable_count: number,
	-- set by cleanup_entity: unlike a stopped storage, a cleaned one cannot be
	-- revived; set_* calls error until collect_updates discards it
	cleaned: boolean?,

	dirty_reliable: Array<Component>,
	dirty_unreliable: Array<Component>,
	dirty_pairs: Array<Component>,
	dirty_unreliable_pairs: Array<Component>,
	dirty_relations: Array<Component>,

	replicate_exclude: Set<Component>?,

	reliable_storages: { [Component]: ReliableStorage },
	unreliable_storages: { [Component]: UnreliableStorage },
	pair_storages: { [Component]: PairStorage },
	unreliable_pair_storages: { [Component]: UnreliablePairStorage },
	relation_storages: { [Component]: RelationStorage },
}

type PostponedComponent = {
	filter: FilterInput?,
	once: boolean?,
}

-- a predicate-driven filter, re-evaluated before every collect_updates cycle
type FunctionFilterEntry = {
	predicator: registry.MemberPredicator,
	entity: Entity,
	networked: NetworkedStorage,

	-- set for reliable component filters, nil for entity-level ones
	tracking: Component?,
	tracking_storage: TrackingStorageBase?,
}

type NetworkedReferencesInfo = {
	networked: NetworkedStorage,
	tracking_storage: TrackingStorageBase,
}

type HookedInfo = {
	networked_references: Map<Entity, NetworkedReferencesInfo>,
}

type PostponedComponentsList = {
	[TrackType]: Map<Component, PostponedComponent>,
}

type ComponentSerializationOptions = {
	serdes: types.Serdes?,
	preprocessor: types.Preprocessor?,
	delta_serializer: types.DeltaSerializer?,
}

type CustomId = customid.CustomId

-- how an entity id is written on the wire; absent means plain entity / shared
type EntitySerializationOptions = {
	global_id: number?,
	custom: (Component | CustomId)?,
}

export type Server = ServerImp & {
	world: World,
	inited: boolean?,

	registry: registry.Registry,
	-- byte size of every bitmask, fixed by the client cap given to create
	bitmask_size: number,
	ready_players_bitmask: Bitmask,
	components: types.Components,
	shared: types.Shared,

	networked: Map<Entity, NetworkedStorage>,
	-- live networked entities with at least one live unreliable storage; the
	-- unreliable collect iterates this instead of every networked entity
	unreliable_networked: Set<Entity>,
	postponed_components: Map<Entity, PostponedComponentsList>,
	-- single lookup for global/custom id resolution at write time
	entity_serialization: Map<Entity, EntitySerializationOptions>,
	registered_custom_ids: Set<CustomId>,
	-- single lookup for serdes/preprocessor/delta at write time
	component_serialization: Map<Component, ComponentSerializationOptions>,
	-- serdes and custom ids feed the handshake; set when either changes
	is_shared_dirty: boolean,

	hooked_components: Map<Component, HookedInfo>,
	hooked_unreliable: Map<Component, HookedInfo>,
	hooked_pairs: Map<Component, HookedInfo>,
	hooked_unreliable_pairs: Map<Component, HookedInfo>,
	hooked_relations: Map<Component, HookedInfo>,

	dirty_networked: Array<Entity>,
	function_filters: Map<StorageBase, FunctionFilterEntry>,

	empty_bitmask: Bitmask,
	draft_bitmask: Bitmask,
	-- scratch for the entity target of the networked entity being collected
	target_bitmask: Bitmask,
	filled_bitmask: Bitmask,

	client_active_bitmask: Bitmask,
	last_active_bitmask: Bitmask,
	newly_active_bitmask: Bitmask,
	newly_unactive_bitmask: Bitmask,
	pending_active: Set<Player>,

	entity_bitmask_deltas: BitmaskDeltas,
	component_bitmask_deltas: BitmaskDeltas,

	cleanups: { () -> () },

	resolve_dirty: (self: Server) -> (),
	get_full: (self: Server, player: Player) -> (buffer, Array<any>),
	collect_entity: (self: Server, entity: Entity) -> PacketIterator,
	collect_updates: (self: Server) -> PacketIterator,
	collect_unreliable: (self: Server) -> PacketIterator,

	register_player: (self: Server, player: Player) -> (),
	add_player_alias: (self: Server, player: Player, alias: any) -> (),
	remove_player_alias: (self: Server, alias: any) -> (),
	mark_player_ready: (self: Server, player: Player) -> (),
	is_player_ready: (self: Server, player: Player) -> boolean,
	remove_player: (self: Server, player: Player) -> (),

	encode_component: (self: Server, component: Component) -> number,
	decode_component: (self: Server, encoded: number) -> Component?,
	get_shared_count: (self: Server) -> number,

	generate_handshake: (self: Server) -> types.HandshakeInfo,
	verify_handshake: (self: Server, handshake: types.HandshakeInfo) -> (boolean, string?),

	cleanup_entity: (self: Server, entity: Entity) -> (),

	init: (self: Server, world: World?) -> (),
	destroy: (self: Server) -> (),
}

-- matches replecs.MAX_CLIENTS; only reached when server.create
-- is called directly without a cap
local DEFAULT_MAX_CLIENTS = 128

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

local LOG_ERROR = common.log_error

-- pepecs hooks bind to pair ids directly
local HOOK_PAIR_ADDED = common.hook_added
local HOOK_PAIR_CHANGED = common.hook_changed
local HOOK_PAIR_REMOVED = common.hook_removed

local DIRTY_CHANGED_FLAG = 0b001
local DIRTY_FILTER_FLAG = 0b010
local DIRTY_COMPONENT_FLAG = 0b100

local VLQ_ZERO = 128

-- global ids are written as a single byte; values below the offset are
-- reserved for the ENTITY_ID_TYPES tags that trail every other id form
local GLOBAL_ID_OFFSET = 10

local MAX_GLOBAL_ID = 255 - GLOBAL_ID_OFFSET

-- unreliable remotes drop packets over the transport budget, so combined
-- batches stay under the ~1kB roblox limit
local MAX_UNRELIABLE_PACKET_SIZE = 900

local TRACK_TYPES = {
	reliable = 1,
	pair = 2,
	relation = 3,
	unreliable = 4,
	unreliable_pair = 5,
}

-- sentinel for nil component values (tags), keeps value arrays hole-free
local NIL_VALUE = newproxy()

-- wraps a world value before it enters a value array
local function SET_VALUE(value: any): any
	return if value == nil then NIL_VALUE else value
end

-- unwraps a value array entry back into the world value
local function READ_VALUE(value: any): any
	return if value == NIL_VALUE then nil else value
end

local ENTITY_ID_TYPES = {
	entity = 1,
	custom_handler = 2,
	custom_id = 3,
	shared = 4,
}

-- u8 trailing every outgoing buffer (the client reads it first) so a packet
-- fed to the wrong apply function fails loudly instead of desyncing
local PACKET_TYPES = {
	full = 1,
	entity = 2,
	updates = 3,
	unreliable = 4,
}
local PACKET_TYPE_SPAN = 1

local server = {}
server.__index = server

@native
local function flag_test(bitset: Bitset, flags: Bitset): boolean
	return bit32.band(bitset, flags) == flags
end

@native
function mark_networked_dirty(self: Server, entity: Entity, networked: NetworkedStorage, flag: Bitset)
	if networked.dirty_flags == 0 then
		table.insert(self.dirty_networked, entity)
	end
	networked.dirty_flags = bit32.bor(networked.dirty_flags, flag)
end

@native
local function get_dirty_list(networked: NetworkedStorage, track_type: TrackType): Array<Component>
	if track_type == TRACK_TYPES.reliable then
		return networked.dirty_reliable
	elseif track_type == TRACK_TYPES.unreliable then
		return networked.dirty_unreliable
	elseif track_type == TRACK_TYPES.pair then
		return networked.dirty_pairs
	elseif track_type == TRACK_TYPES.unreliable_pair then
		return networked.dirty_unreliable_pairs
	else
		return networked.dirty_relations
	end
end

@native
function mark_tracking_storage_dirty(
	self: Server,
	entity: Entity,
	component: Component,
	networked: NetworkedStorage,
	storage: TrackingStorageBase,
	flag: Bitset
)
	if storage.dirty_flags == 0 then
		table.insert(get_dirty_list(networked, storage.track_type), component)
	end
	storage.dirty_flags = bit32.bor(storage.dirty_flags, flag)
	mark_networked_dirty(self, entity, networked, DIRTY_COMPONENT_FLAG)
end

local function increment_unreliable(self: Server, entity: Entity, networked: NetworkedStorage)
	networked.unreliable_count += 1
	if not networked.is_dead then
		self.unreliable_networked[entity] = true
	end
end

local function decrement_unreliable(self: Server, entity: Entity, networked: NetworkedStorage)
	networked.unreliable_count -= 1
	if networked.unreliable_count <= 0 then
		self.unreliable_networked[entity] = nil
	end
end

@native
local function edit_storage_filter(self: Server, storage: StorageBase, filter: Bitmask?)
	if not storage.last_replicated then
		storage.last_replicated = bitmasks.clone(storage.filter or self.last_active_bitmask)
	end
	storage.filter = filter
end

@native
local function resolve_filter_bitmask(self: Server, filter: FilterAny): Bitmask
	local registry = self.registry
	local type = typeof(filter)
	if type == "table" then
		return registry:create_bitmask_from_set(filter :: FilterSet)
	elseif type == "function" then
		return registry:create_bitmask_from_function(filter :: registry.MemberPredicator)
	else
		return registry:create_bitmask_from_member(filter :: Player)
	end
end

local function disconnect_filter_group(storage: StorageBase)
	local group = storage.filter_group
	local listener = storage.filter_listener
	if group and listener then
		group:disconnect(listener)
	end
	storage.filter_group = nil
	storage.filter_listener = nil
end

-- releases whatever was driving this storage's filter (group or predicate)
local function clear_filter_source(self: Server, storage: StorageBase)
	disconnect_filter_group(storage)
	self.function_filters[storage] = nil
end

-- a nil-filter storage inherits entity visibility, so its replicated set is
-- exactly the entity's; clients entering the entity filter then get the
-- storage through its own added delta
local function snapshot_tracking_replicated(storage: TrackingStorageBase, entity_last: Bitmask)
	if storage.last_replicated then
		return
	end

	local filter = storage.filter
	if not filter then
		storage.last_replicated = bitmasks.clone(entity_last)
		return
	end

	local snapshot = bitmasks.clone(filter)
	bitmasks.band(snapshot, entity_last, snapshot)
	storage.last_replicated = snapshot
end

local function edit_networked_filter(self: Server, entity: Entity, networked: NetworkedStorage, bitmask: Bitmask?)
	edit_storage_filter(self, networked, bitmask)
	mark_networked_dirty(self, entity, networked, DIRTY_FILTER_FLAG)
	mark_networked_dirty(self, entity, networked, DIRTY_COMPONENT_FLAG)

	local entity_last = networked.last_replicated :: Bitmask

	for component, reliable_storage in networked.reliable_storages do
		snapshot_tracking_replicated(reliable_storage, entity_last)
		mark_tracking_storage_dirty(self, entity, component, networked, reliable_storage, DIRTY_FILTER_FLAG)
	end
	for component, unreliable_storage in networked.unreliable_storages do
		snapshot_tracking_replicated(unreliable_storage, entity_last)
		mark_tracking_storage_dirty(self, entity, component, networked, unreliable_storage, DIRTY_FILTER_FLAG)
	end
	for id, pair_storage in networked.pair_storages do
		snapshot_tracking_replicated(pair_storage, entity_last)
		mark_tracking_storage_dirty(self, entity, id, networked, pair_storage, DIRTY_FILTER_FLAG)
	end
	for id, unreliable_pair_storage in networked.unreliable_pair_storages do
		snapshot_tracking_replicated(unreliable_pair_storage, entity_last)
		mark_tracking_storage_dirty(self, entity, id, networked, unreliable_pair_storage, DIRTY_FILTER_FLAG)
	end
	for rel, relation_storage in networked.relation_storages do
		snapshot_tracking_replicated(relation_storage, entity_last)
		mark_tracking_storage_dirty(self, entity, rel, networked, relation_storage, DIRTY_FILTER_FLAG)
	end
end

local function edit_tracking_filter(
	self: Server,
	entity: Entity,
	component: Component,
	networked: NetworkedStorage,
	storage: TrackingStorageBase,
	bitmask: Bitmask?
)
	if not storage.last_replicated then
		-- only components in entity visibiblity were ever replicated, so the snapshot
		-- must not claim clients that were outside the entity filter
		local last_active = self.last_active_bitmask
		local snapshot = bitmasks.clone(storage.filter or last_active)
		local entity_last = networked.last_replicated or networked.filter or last_active
		bitmasks.band(snapshot, entity_last, snapshot)
		storage.last_replicated = snapshot
	end
	storage.filter = bitmask
	mark_tracking_storage_dirty(self, entity, component, networked, storage, DIRTY_FILTER_FLAG)
end

local function connect_networked_group(self: Server, entity: Entity, networked: NetworkedStorage, group: FilterGroup)
	local function listener(bitmask: Bitmask)
		edit_networked_filter(self, entity, networked, bitmask)
	end
	networked.filter_group = group
	networked.filter_listener = listener
	group:connect(listener)
end

local function connect_tracking_group(
	self: Server,
	entity: Entity,
	component: Component,
	networked: NetworkedStorage,
	storage: TrackingStorageBase,
	group: FilterGroup
)
	local function listener(bitmask: Bitmask)
		edit_tracking_filter(self, entity, component, networked, storage, bitmask)
	end
	storage.filter_group = group
	storage.filter_listener = listener
	group:connect(listener)
end

function ensure_hooked_component(self: Server, component: Component): HookedInfo
	local info = self.hooked_components[component]
	if info then
		return info
	end

	local networked_references: Map<Entity, NetworkedReferencesInfo> = {}
	local new_info: HookedInfo = {
		networked_references = networked_references,
	}
	self.hooked_components[component] = new_info

	local function hook(unhook: () -> ())
		table.insert(self.cleanups, unhook)
	end
	local world = self.world

	local function mark_component_dirty(entity: Entity)
		local reference = networked_references[entity]
		if not reference then
			return
		end
		mark_tracking_storage_dirty(
			self,
			entity,
			component,
			reference.networked,
			reference.tracking_storage,
			DIRTY_CHANGED_FLAG
		)
	end

	-- once storages only replicate the value on add, removal and visibility
	-- gain; in-place world changes are ignored (force_change bypasses this)
	local function mark_component_changed(entity: Entity)
		local reference = networked_references[entity]
		if not reference or reference.tracking_storage.is_once then
			return
		end
		mark_tracking_storage_dirty(
			self,
			entity,
			component,
			reference.networked,
			reference.tracking_storage,
			DIRTY_CHANGED_FLAG
		)
	end

	hook(HOOK_ADDED(world, component, mark_component_dirty))
	hook(HOOK_CHANGED(world, component, mark_component_changed))
	hook(HOOK_REMOVED(world, component, mark_component_dirty))

	return new_info
end

local function ensure_hooked_relation(self: Server, rel: Component): HookedInfo
	local info = self.hooked_relations[rel]
	if info then
		return info
	end

	local networked_references: Map<Entity, NetworkedReferencesInfo> = {}
	local new_info: HookedInfo = {
		networked_references = networked_references,
	}
	self.hooked_relations[rel] = new_info

	local function hook(unhook: () -> ())
		table.insert(self.cleanups, unhook)
	end
	local world = self.world

	local function mark_relation_dirty(entity: Entity, id: Entity)
		if not IS_PAIR(id) then
			return
		end

		local reference = networked_references[entity]
		if not reference then
			return
		end
		local affected = PAIR_SECOND(world, id)
		local relation_storage = reference.tracking_storage :: RelationStorage

		mark_tracking_storage_dirty(self, entity, rel, reference.networked, relation_storage, DIRTY_CHANGED_FLAG)
		relation_storage.dirty_targets[affected] = true
	end

	hook(HOOK_ADDED(world, LISTEN_RELATION(rel), mark_relation_dirty))
	hook(HOOK_CHANGED(world, LISTEN_RELATION(rel), mark_relation_dirty))
	hook(HOOK_REMOVED(world, LISTEN_RELATION(rel), mark_relation_dirty))

	return new_info
end

local function ensure_hooked_pair(self: Server, id: Entity)
	local info = self.hooked_pairs[id]
	if info then
		return info
	end

	local networked_references: Map<Entity, NetworkedReferencesInfo> = {}
	local new_info: HookedInfo = {
		networked_references = networked_references,
	}
	self.hooked_pairs[id] = new_info

	local function hook(unhook: () -> ())
		table.insert(self.cleanups, unhook)
	end
	local world = self.world

	local function mark_pair_dirty(entity: Entity)
		local reference = networked_references[entity]
		if not reference then
			return
		end
		mark_tracking_storage_dirty(self, entity, id, reference.networked, reference.tracking_storage, DIRTY_CHANGED_FLAG)
	end

	hook(HOOK_PAIR_ADDED(world, id, mark_pair_dirty))
	hook(HOOK_PAIR_CHANGED(world, id, mark_pair_dirty))
	hook(HOOK_PAIR_REMOVED(world, id, mark_pair_dirty))

	return new_info
end

local function ensure_hooked_unreliable(self: Server, component: Component): HookedInfo
	local info = self.hooked_unreliable[component]
	if info then
		return info
	end

	local networked_references: Map<Entity, NetworkedReferencesInfo> = {}
	local new_info: HookedInfo = {
		networked_references = networked_references,
	}
	self.hooked_unreliable[component] = new_info

	local function hook(unhook: () -> ())
		table.insert(self.cleanups, unhook)
	end
	local world = self.world

	local function mark_unreliable_dirty(entity: Entity)
		local reference = networked_references[entity]
		if not reference then
			return
		end
		mark_tracking_storage_dirty(
			self,
			entity,
			component,
			reference.networked,
			reference.tracking_storage,
			DIRTY_CHANGED_FLAG
		)
	end

	hook(HOOK_ADDED(world, component, mark_unreliable_dirty))
	hook(HOOK_REMOVED(world, component, mark_unreliable_dirty))

	return new_info
end

local function ensure_hooked_unreliable_pair(self: Server, id: Entity): HookedInfo
	local info = self.hooked_unreliable_pairs[id]
	if info then
		return info
	end

	local networked_references: Map<Entity, NetworkedReferencesInfo> = {}
	local new_info: HookedInfo = {
		networked_references = networked_references,
	}
	self.hooked_unreliable_pairs[id] = new_info

	local function hook(unhook: () -> ())
		table.insert(self.cleanups, unhook)
	end
	local world = self.world

	local function mark_unreliable_pair_dirty(entity: Entity)
		local reference = networked_references[entity]
		if not reference then
			return
		end
		mark_tracking_storage_dirty(self, entity, id, reference.networked, reference.tracking_storage, DIRTY_CHANGED_FLAG)
	end

	hook(HOOK_PAIR_ADDED(world, id, mark_unreliable_pair_dirty))
	hook(HOOK_PAIR_REMOVED(world, id, mark_unreliable_pair_dirty))

	return new_info
end

local function get_hooked_map(self: Server, track_type: TrackType): Map<Component, HookedInfo>
	if track_type == TRACK_TYPES.reliable then
		return self.hooked_components
	elseif track_type == TRACK_TYPES.unreliable then
		return self.hooked_unreliable
	elseif track_type == TRACK_TYPES.pair then
		return self.hooked_pairs
	elseif track_type == TRACK_TYPES.unreliable_pair then
		return self.hooked_unreliable_pairs
	else
		return self.hooked_relations
	end
end

-- hook references live as long as their storage: a stopped storage keeps
-- receiving world changes so a same-frame revive still replicates them. the
-- reference goes away only when collect discards the storage
local function clear_hook_reference(self: Server, entity: Entity, component: Component, storage: TrackingStorageBase)
	local info = get_hooked_map(self, storage.track_type)[component]
	if not info then
		return
	end
	local reference = info.networked_references[entity]
	if reference and reference.tracking_storage == storage then
		info.networked_references[entity] = nil
	end
end

local function clear_networked_references(self: Server, entity: Entity, networked: NetworkedStorage)
	for component, storage in networked.reliable_storages do
		clear_hook_reference(self, entity, component, storage)
	end
	for component, storage in networked.unreliable_storages do
		clear_hook_reference(self, entity, component, storage)
	end
	for id, storage in networked.pair_storages do
		clear_hook_reference(self, entity, id, storage)
	end
	for id, storage in networked.unreliable_pair_storages do
		clear_hook_reference(self, entity, id, storage)
	end
	for rel, storage in networked.relation_storages do
		clear_hook_reference(self, entity, rel, storage)
	end
end

-- resolves a filter input into a bitmask and attaches its driving source
-- (group listener or predicate entry) to the storage; nil filter means
-- "replicate to all active clients", resolved at collect
local function apply_tracking_filter(
	self: Server,
	entity: Entity,
	component: Component,
	networked: NetworkedStorage,
	storage: TrackingStorageBase,
	filter: FilterInput?
): Bitmask?
	local bitmask: Bitmask?

	if filter then
		if filter_groups.is_filter_group(filter) then
			local group = filter :: FilterGroup
			bitmask = group:calculate_up()
			connect_tracking_group(self, entity, component, networked, storage, group)
		elseif typeof(filter) == "function" then
			local predicator = filter :: registry.MemberPredicator
			bitmask = self.registry:create_bitmask_from_function(predicator)

			self.function_filters[storage] = {
				predicator = predicator,
				entity = entity,
				networked = networked,

				tracking = component,
				tracking_storage = storage,
			}
		else
			bitmask = resolve_filter_bitmask(self, filter :: FilterAny)
		end
	end

	return bitmask
end

local function change_tracking(
	self: Server,
	entity: Entity,
	component: Component,
	networked: NetworkedStorage,
	storage: TrackingStorageBase,
	filter: FilterInput?
)
	-- old filter source stops driving this storage before the new one takes over
	clear_filter_source(self, storage)

	local bitmask = apply_tracking_filter(self, entity, component, networked, storage, filter)

	-- a stopped storage keeps its last_replicated (forced at stop), so reviving
	-- here sends only the delta between the pre-stop and the new filter
	storage.is_dead = false
	storage.filter_input = filter
	edit_tracking_filter(self, entity, component, networked, storage, bitmask)
end

-- the last filter is forced into last_replicated and the current one becomes
-- the empty bitmask: collect emits the removal to everyone who had it, then
-- drops the storage. hooks stop feeding it right away
local function stop_tracking(
	self: Server,
	entity: Entity,
	component: Component,
	networked: NetworkedStorage,
	storage: TrackingStorageBase
)
	storage.is_dead = true
	storage.filter_input = nil
	clear_filter_source(self, storage)
	edit_tracking_filter(self, entity, component, networked, storage, self.empty_bitmask)
end

local function remove_postponed_component(self: Server, entity: Entity, track_type: TrackType, component: Component)
	local postponed = self.postponed_components[entity]
	if not postponed then
		return
	end
	local postponed_list = postponed[track_type]
	if postponed_list then
		postponed_list[component] = nil
	end
end

local function create_tracking_storage(
	self: Server,
	component: Component,
	track_type: TrackType,
	filter: FilterInput?
): TrackingStorageBase
	return {
		filter = nil :: Bitmask?,
		last_replicated = buffer.create(self.bitmask_size),

		track_type = track_type,
		is_component = IS_COMPONENT(self.world, component),

		dirty_flags = 0,
		is_dead = false,
		filter_input = filter,
	}
end

local function start_reliable(
	self: Server,
	entity: Entity,
	component: Component,
	networked: NetworkedStorage,
	filter: FilterInput?,
	once: boolean?
)
	local reliable_storage = networked.reliable_storages[component]

	if reliable_storage then
		-- revived storage keeps its last_replicated, collect sends only the delta
		change_tracking(self, entity, component, networked, reliable_storage, filter)
		-- set_once / set_reliable on an existing storage switches its mode
		reliable_storage.is_once = once
	else
		local new_storage = create_tracking_storage(self, component, TRACK_TYPES.reliable, filter) :: ReliableStorage
		new_storage.is_once = once
		networked.reliable_storages[component] = new_storage

		new_storage.filter = apply_tracking_filter(self, entity, component, networked, new_storage, filter)
		mark_tracking_storage_dirty(self, entity, component, networked, new_storage, DIRTY_FILTER_FLAG)
		reliable_storage = new_storage
	end

	local hook_info = ensure_hooked_component(self, component)
	hook_info.networked_references[entity] = {
		tracking_storage = reliable_storage,
		networked = networked,
	}
end

local function start_unreliable(
	self: Server,
	entity: Entity,
	component: Component,
	networked: NetworkedStorage,
	filter: FilterInput?
)
	local unreliable_storage = networked.unreliable_storages[component]

	if unreliable_storage then
		-- reviving a stopped storage regains the count its stop gave up
		if unreliable_storage.is_dead then
			increment_unreliable(self, entity, networked)
		end
		change_tracking(self, entity, component, networked, unreliable_storage, filter)
	else
		local new_storage = create_tracking_storage(self, component, TRACK_TYPES.unreliable, filter)
		networked.unreliable_storages[component] = new_storage
		increment_unreliable(self, entity, networked)

		new_storage.filter = apply_tracking_filter(self, entity, component, networked, new_storage, filter)
		mark_tracking_storage_dirty(self, entity, component, networked, new_storage, DIRTY_FILTER_FLAG)
		unreliable_storage = new_storage
	end

	local hook_info = ensure_hooked_unreliable(self, component)
	hook_info.networked_references[entity] = {
		tracking_storage = unreliable_storage,
		networked = networked,
	}
end

local function start_pair(
	self: Server,
	entity: Entity,
	id: Component,
	networked: NetworkedStorage,
	filter: FilterInput?
)
	local pair_storage = networked.pair_storages[id]

	if pair_storage then
		change_tracking(self, entity, id, networked, pair_storage, filter)
	else
		local new_storage = create_tracking_storage(self, id, TRACK_TYPES.pair, filter) :: PairStorage
		networked.pair_storages[id] = new_storage

		new_storage.filter = apply_tracking_filter(self, entity, id, networked, new_storage, filter)
		mark_tracking_storage_dirty(self, entity, id, networked, new_storage, DIRTY_FILTER_FLAG)
		pair_storage = new_storage
	end

	local hook_info = ensure_hooked_pair(self, id)
	hook_info.networked_references[entity] = {
		tracking_storage = pair_storage,
		networked = networked,
	}
end

local function start_unreliable_pair(
	self: Server,
	entity: Entity,
	id: Component,
	networked: NetworkedStorage,
	filter: FilterInput?
)
	local unreliable_pair_storage = networked.unreliable_pair_storages[id]

	if unreliable_pair_storage then
		-- reviving a stopped storage regains the count its stop gave up
		if unreliable_pair_storage.is_dead then
			increment_unreliable(self, entity, networked)
		end
		-- revived storage keeps its last_replicated, collect sends only the delta
		change_tracking(self, entity, id, networked, unreliable_pair_storage, filter)
	else
		local new_storage =
			create_tracking_storage(self, id, TRACK_TYPES.unreliable_pair, filter) :: UnreliablePairStorage
		networked.unreliable_pair_storages[id] = new_storage
		increment_unreliable(self, entity, networked)

		new_storage.filter = apply_tracking_filter(self, entity, id, networked, new_storage, filter)
		mark_tracking_storage_dirty(self, entity, id, networked, new_storage, DIRTY_FILTER_FLAG)
		unreliable_pair_storage = new_storage
	end

	local hook_info = ensure_hooked_unreliable_pair(self, id)
	hook_info.networked_references[entity] = {
		tracking_storage = unreliable_pair_storage,
		networked = networked,
	}
end

local function start_relation(
	self: Server,
	entity: Entity,
	rel: Component,
	networked: NetworkedStorage,
	filter: FilterInput?
)
	local relation_storage = networked.relation_storages[rel]

	if relation_storage then
		change_tracking(self, entity, rel, networked, relation_storage, filter)
	else
		local new_storage = create_tracking_storage(self, rel, TRACK_TYPES.relation, filter) :: RelationStorage
		new_storage.dirty_targets = {}
		networked.relation_storages[rel] = new_storage

		new_storage.filter = apply_tracking_filter(self, entity, rel, networked, new_storage, filter)
		mark_tracking_storage_dirty(self, entity, rel, networked, new_storage, DIRTY_FILTER_FLAG)
		relation_storage = new_storage
	end

	local hook_info = ensure_hooked_relation(self, rel)
	hook_info.networked_references[entity] = {
		tracking_storage = relation_storage,
		networked = networked,
	}
end

local function ensure_networked(self: Server, entity: Entity): (NetworkedStorage, boolean)
	local existing = self.networked[entity]
	if existing then
		existing.is_dead = false
		return existing, true
	end

	local new_networked: NetworkedStorage = {
		filter = nil :: any,
		last_replicated = buffer.create(self.bitmask_size),
		dirty_flags = 0,
		is_dead = false,
		unreliable_count = 0,

		dirty_reliable = {},
		dirty_unreliable = {},
		dirty_pairs = {},
		dirty_unreliable_pairs = {},
		dirty_relations = {},

		reliable_storages = {},
		unreliable_storages = {},
		pair_storages = {},
		unreliable_pair_storages = {},
		relation_storages = {},
	}
	self.networked[entity] = new_networked
	return new_networked, false
end

function start_networked(self: Server, entity: Entity, filter: FilterInput?)
	local networked, revived = ensure_networked(self, entity)

	-- the removal hook on this tag is how world:delete reaches the server
	local alive_tracking = self.components.__alive_tracking__
	if not WORLD_HAS(self.world, entity, alive_tracking) then
		WORLD_ADD(self.world, entity, alive_tracking)
	end

	if revived then
		-- old filter snapshots into last_replicated, clients leaving the filter
		-- get a removal delta instead of the pending deletion
		change_networked(self, entity, networked, filter)
	else
		local bitmask: Bitmask?

		if filter then
			if filter_groups.is_filter_group(filter) then
				local group = filter :: FilterGroup
				bitmask = group:calculate_up()
				connect_networked_group(self, entity, networked, group)
			elseif typeof(filter) == "function" then
				local predicator = filter :: registry.MemberPredicator
				bitmask = self.registry:create_bitmask_from_function(predicator)

				self.function_filters[networked] = {
					predicator = predicator,
					entity = entity,
					networked = networked,
				}
			else
				bitmask = resolve_filter_bitmask(self, filter :: FilterAny)
			end
		else
			-- bitmask stays nil: replicate to all active clients, resolved at collect
		end

		networked.filter = bitmask
		mark_networked_dirty(self, entity, networked, DIRTY_FILTER_FLAG)
	end

	local postponed = self.postponed_components[entity]
	if postponed then
		self.postponed_components[entity] = nil

		for track_type, components_list in postponed do
			if track_type == TRACK_TYPES.reliable then
				for component, info in components_list do
					start_reliable(self, entity, component, networked, info.filter, info.once)
				end
			elseif track_type == TRACK_TYPES.unreliable then
				for component, info in components_list do
					start_unreliable(self, entity, component, networked, info.filter)
				end
			elseif track_type == TRACK_TYPES.pair then
				for id, info in components_list do
					start_pair(self, entity, id, networked, info.filter)
				end
			elseif track_type == TRACK_TYPES.unreliable_pair then
				for id, info in components_list do
					start_unreliable_pair(self, entity, id, networked, info.filter)
				end
			elseif track_type == TRACK_TYPES.relation then
				for rel, info in components_list do
					start_relation(self, entity, rel, networked, info.filter)
				end
			end
		end
	end

	-- a revived entity keeps its live unreliable storages (their count never
	-- dropped), so membership lost at stop_networked comes back here
	if networked.unreliable_count > 0 then
		self.unreliable_networked[entity] = true
	end
end

function change_networked(self: Server, entity: Entity, networked: NetworkedStorage, filter: FilterInput?)
	-- old filter source stops driving this storage before the new one takes over
	clear_filter_source(self, networked)

	local bitmask: Bitmask?
	if filter then
		if filter_groups.is_filter_group(filter) then
			local group = filter :: FilterGroup
			bitmask = group:calculate_up()
			connect_networked_group(self, entity, networked, group)
		elseif typeof(filter) == "function" then
			local predicator = filter :: registry.MemberPredicator
			bitmask = self.registry:create_bitmask_from_function(predicator)
			self.function_filters[networked] = {
				predicator = predicator,
				entity = entity,
				networked = networked,
			}
		else
			bitmask = resolve_filter_bitmask(self, filter :: FilterAny)
		end
	end

	edit_networked_filter(self, entity, networked, bitmask)
end

function server.set_networked(self: Server, entity: Entity, filter: FilterInput?)
	local networked = self.networked[entity]

	if networked and networked.cleaned then
		LOG_ERROR "attempted to network a dead entity"
	end

	if networked and not networked.is_dead then
		change_networked(self, entity, networked, filter)
	else
		start_networked(self, entity, filter)
	end
end

function push_postponed_component(
	postponed: PostponedComponentsList,
	track_type: TrackType,
	component: Component,
	filter: any,
	once: boolean?
)
	local postponed_list = postponed[track_type]
	if not postponed_list then
		postponed_list = {}
		postponed[track_type] = postponed_list
	end
	postponed_list[component] = { filter = filter, once = once }
end

function ensure_postponed(self: Server, entity: Entity): PostponedComponentsList
	local postponed = self.postponed_components[entity]
	if not postponed then
		postponed = {}
		self.postponed_components[entity] = postponed
	end

	return postponed
end

function server.stop_networked(self: Server, entity: Entity)
	local networked = self.networked[entity]
	-- already dead: postponing again would resurrect storages a stop_* dropped
	if not networked or networked.cleaned or networked.is_dead then
		return
	end

	networked.is_dead = true
	clear_filter_source(self, networked)
	mark_networked_dirty(self, entity, networked, DIRTY_COMPONENT_FLAG)
	-- count stays: live storages get postponed and come back on revive
	self.unreliable_networked[entity] = nil

	local postponed = ensure_postponed(self, entity)

	-- storages stopped with stop_* must not come back with the entity, so only
	-- live ones get postponed. hook references stay: world changes during the
	-- dead window keep marking the storage so a revive replicates them
	for component, reliable_storage in networked.reliable_storages do
		if reliable_storage.is_dead then
			continue
		end
		clear_filter_source(self, reliable_storage)
		push_postponed_component(
			postponed,
			TRACK_TYPES.reliable,
			component,
			reliable_storage.filter_input,
			reliable_storage.is_once
		)
	end
	for component, unreliable_storage in networked.unreliable_storages do
		if unreliable_storage.is_dead then
			continue
		end
		clear_filter_source(self, unreliable_storage)
		push_postponed_component(postponed, TRACK_TYPES.unreliable, component, unreliable_storage.filter_input)
	end
	for id, pair_storage in networked.pair_storages do
		if pair_storage.is_dead then
			continue
		end
		clear_filter_source(self, pair_storage)
		push_postponed_component(postponed, TRACK_TYPES.pair, id, pair_storage.filter_input)
	end
	for id, unreliable_pair_storage in networked.unreliable_pair_storages do
		if unreliable_pair_storage.is_dead then
			continue
		end
		-- filter_input keeps the group or predicate itself, so a later start reattaches it
		clear_filter_source(self, unreliable_pair_storage)
		push_postponed_component(postponed, TRACK_TYPES.unreliable_pair, id, unreliable_pair_storage.filter_input)
	end
	for rel, relation_storage in networked.relation_storages do
		if relation_storage.is_dead then
			continue
		end
		clear_filter_source(self, relation_storage)
		push_postponed_component(postponed, TRACK_TYPES.relation, rel, relation_storage.filter_input)
	end
end

function server.cleanup_entity(self: Server, entity: Entity)
	local networked = self.networked[entity]

	if networked then
		if not networked.is_dead then
			self:stop_networked(entity)
		end
		networked.cleaned = true
	end

	-- stop_networked postpones components for a revive; the entity is gone, drop them
	self.postponed_components[entity] = nil
	self.unreliable_networked[entity] = nil

	-- custom ids travel with the server id, so the client resolves the
	-- deletion without them; a global id is the only address the deletion
	-- delta has, so it outlives the storage until collect_updates discards it
	local options = self.entity_serialization[entity]
	if options then
		options.custom = nil
		if not networked or options.global_id == nil then
			self.entity_serialization[entity] = nil
		end
	end
end

function server.set_reliable(self: Server, entity: Entity, component: Component, filter: FilterInput?)
	local networked = self.networked[entity]

	if networked and networked.cleaned then
		LOG_ERROR "attempted to network a dead entity"
	end

	if networked and not networked.is_dead then
		start_reliable(self, entity, component, networked, filter, false)
	else
		push_postponed_component(ensure_postponed(self, entity), TRACK_TYPES.reliable, component, filter, false)
	end
end

-- the unreliable channel only carries values, so tags cannot be tracked
-- unreliably; use set_reliable for presence-only replication
function server.set_unreliable(self: Server, entity: Entity, component: Component, filter: FilterInput?)
	local networked = self.networked[entity]

	if networked and networked.cleaned then
		LOG_ERROR "attempted to network a dead entity"
	end
	if not IS_COMPONENT(self.world, component) then
		LOG_ERROR(
			"attempted to track a tag unreliably, unreliables only send values: ",
			common.log_component(self.world, component)
		)
	end

	if networked and not networked.is_dead then
		start_unreliable(self, entity, component, networked, filter)
	else
		push_postponed_component(ensure_postponed(self, entity), TRACK_TYPES.unreliable, component, filter)
	end
end

function server.set_once(self: Server, entity: Entity, component: Component, filter: FilterInput?)
	local networked = self.networked[entity]

	if networked and networked.cleaned then
		LOG_ERROR "attempted to network a dead entity"
	end

	if networked and not networked.is_dead then
		start_reliable(self, entity, component, networked, filter, true)
	else
		push_postponed_component(ensure_postponed(self, entity), TRACK_TYPES.reliable, component, filter, true)
	end
end

-- a dead storage or entity still takes the mark: it is harmless if collect
-- discards it and needed if a revive lands before then
function server.force_change(self: Server, entity: Entity, component: Component)
	local networked = self.networked[entity]
	if not networked or networked.cleaned then
		return
	end

	local reliable_storage = networked.reliable_storages[component]
	if not reliable_storage then
		return
	end
	mark_tracking_storage_dirty(self, entity, component, networked, reliable_storage, DIRTY_CHANGED_FLAG)
end

function server.set_pair(self: Server, entity: Entity, id: Component, filter: FilterInput?)
	local networked = self.networked[entity]

	if networked and networked.cleaned then
		LOG_ERROR "attempted to network a dead entity"
	end

	if networked and not networked.is_dead then
		start_pair(self, entity, id, networked, filter)
	else
		push_postponed_component(ensure_postponed(self, entity), TRACK_TYPES.pair, id, filter)
	end
end

-- unreliable pairs replicate their value reliably on add and remove; later
-- value changes are left to the unreliable channel. pair tags are rejected,
-- the channel has nothing to send for them
function server.set_unreliable_pair(self: Server, entity: Entity, id: Component, filter: FilterInput?)
	local networked = self.networked[entity]

	if networked and networked.cleaned then
		LOG_ERROR "attempted to network a dead entity"
	end
	if not IS_COMPONENT(self.world, id) then
		LOG_ERROR(
			"attempted to track a pair tag unreliably, unreliables only send values: ",
			common.log_component(self.world, id)
		)
	end

	if networked and not networked.is_dead then
		start_unreliable_pair(self, entity, id, networked, filter)
	else
		-- dead entities postpone too; a revive replays this alongside the rest
		push_postponed_component(ensure_postponed(self, entity), TRACK_TYPES.unreliable_pair, id, filter)
	end
end

function server.set_relation(self: Server, entity: Entity, relation: Component, filter: FilterInput?)
	local networked = self.networked[entity]

	if networked and networked.cleaned then
		LOG_ERROR "attempted to network a dead entity"
	end

	if networked and not networked.is_dead then
		start_relation(self, entity, relation, networked, filter)
	else
		push_postponed_component(ensure_postponed(self, entity), TRACK_TYPES.relation, relation, filter)
	end
end

-- stop_* marks the storage dead (removal goes out at the next collect) and
-- drops its postponed entry so a later start_networked does not bring it
-- back. a dead entity keeps its live storages until collect, so both happen:
-- otherwise a same-frame revive would keep the storage alive. a set_* call
-- before the collect revives the storage in place

-- resolves the networked storage a stop_* acts on; nil means only the
-- postponed entry needs dropping
local function stop_target(self: Server, entity: Entity, track_type: TrackType, component: Component): NetworkedStorage?
	local networked = self.networked[entity]
	if networked and networked.cleaned then
		return nil
	end

	if not networked or networked.is_dead then
		remove_postponed_component(self, entity, track_type, component)
	end
	return networked
end

function server.stop_reliable(self: Server, entity: Entity, component: Component)
	local networked = stop_target(self, entity, TRACK_TYPES.reliable, component)
	if not networked then
		return
	end

	local reliable_storage = networked.reliable_storages[component]
	if reliable_storage and not reliable_storage.is_dead then
		stop_tracking(self, entity, component, networked, reliable_storage)
	end
end

-- once storages live in the reliable storages, same stop path
function server.stop_once(self: Server, entity: Entity, component: Component)
	self:stop_reliable(entity, component)
end

function server.stop_unreliable(self: Server, entity: Entity, component: Component)
	local networked = stop_target(self, entity, TRACK_TYPES.unreliable, component)
	if not networked then
		return
	end

	local unreliable_storage = networked.unreliable_storages[component]
	if unreliable_storage and not unreliable_storage.is_dead then
		stop_tracking(self, entity, component, networked, unreliable_storage)
		decrement_unreliable(self, entity, networked)
	end
end

function server.stop_pair(self: Server, entity: Entity, id: Component)
	local networked = stop_target(self, entity, TRACK_TYPES.pair, id)
	if not networked then
		return
	end

	local pair_storage = networked.pair_storages[id]
	if pair_storage and not pair_storage.is_dead then
		stop_tracking(self, entity, id, networked, pair_storage)
	end
end

function server.stop_unreliable_pair(self: Server, entity: Entity, id: Component)
	local networked = stop_target(self, entity, TRACK_TYPES.unreliable_pair, id)
	if not networked then
		return
	end

	local unreliable_pair_storage = networked.unreliable_pair_storages[id]
	if unreliable_pair_storage and not unreliable_pair_storage.is_dead then
		stop_tracking(self, entity, id, networked, unreliable_pair_storage)
		decrement_unreliable(self, entity, networked)
	end
end

function server.stop_relation(self: Server, entity: Entity, relation: Component)
	local networked = stop_target(self, entity, TRACK_TYPES.relation, relation)
	if not networked then
		return
	end

	local relation_storage = networked.relation_storages[relation]
	if relation_storage and not relation_storage.is_dead then
		stop_tracking(self, entity, relation, networked, relation_storage)
	end
end

local function ensure_entity_serialization(self: Server, entity: Entity): EntitySerializationOptions
	local options = self.entity_serialization[entity]
	if not options then
		options = {} :: EntitySerializationOptions
		self.entity_serialization[entity] = options
	end
	return options
end

local function prune_entity_serialization(self: Server, entity: Entity, options: EntitySerializationOptions)
	if options.global_id == nil and options.custom == nil then
		self.entity_serialization[entity] = nil
	end
end

function server.set_global(self: Server, entity: Entity, global_id: number)
	if global_id > MAX_GLOBAL_ID then
		LOG_ERROR(`global id size exceeded, max is {MAX_GLOBAL_ID}`)
	end
	ensure_entity_serialization(self, entity).global_id = global_id
end

function server.remove_global(self: Server, entity: Entity)
	local options = self.entity_serialization[entity]
	if not options then
		return
	end
	options.global_id = nil
	prune_entity_serialization(self, entity, options)
end

function server.set_custom(self: Server, entity: Entity, custom: Component | CustomId)
	local options = ensure_entity_serialization(self, entity)
	if options.custom then
		common.log_warn("attempted to register a custom_id twice for the same entity", debug.traceback())
		return
	end

	if type(custom) ~= "number" and not self.registered_custom_ids[custom :: CustomId] then
		LOG_ERROR "attempted to use a custom id that wasn't registered, use register_custom_id first"
	end
	options.custom = custom
end

function server.remove_custom(self: Server, entity: Entity)
	local options = self.entity_serialization[entity]
	if not options then
		return
	end
	options.custom = nil
	prune_entity_serialization(self, entity, options)
end

function server.register_custom_id(self: Server, custom_id: CustomId)
	self.registered_custom_ids[custom_id] = true
	self.is_shared_dirty = true
end

local function ensure_component_serialization(self: Server, component: Component): ComponentSerializationOptions
	local options = self.component_serialization[component]
	if not options then
		options = {} :: ComponentSerializationOptions
		self.component_serialization[component] = options
	end
	return options
end

local function prune_component_serialization(self: Server, component: Component, options: ComponentSerializationOptions)
	if options.serdes == nil and options.preprocessor == nil and options.delta_serializer == nil then
		self.component_serialization[component] = nil
	end
end

function server.set_serdes(self: Server, component: Component, serdes: types.Serdes)
	ensure_component_serialization(self, component).serdes = serdes
	self.is_shared_dirty = true
end

function server.remove_serdes(self: Server, component: Component)
	local options = self.component_serialization[component]
	if not options then
		return
	end
	options.serdes = nil
	prune_component_serialization(self, component, options)
	self.is_shared_dirty = true
end

function server.set_preprocessor(self: Server, component: Component, preprocessor: types.Preprocessor)
	ensure_component_serialization(self, component).preprocessor = preprocessor
end

function server.remove_preprocessor(self: Server, component: Component)
	local options = self.component_serialization[component]
	if not options then
		return
	end
	options.preprocessor = nil
	prune_component_serialization(self, component, options)
end

function server.set_delta_serializer(self: Server, component: Component, delta_serializer: types.DeltaSerializer)
	ensure_component_serialization(self, component).delta_serializer = delta_serializer
end

function server.remove_delta_serializer(self: Server, component: Component)
	local options = self.component_serialization[component]
	if not options then
		return
	end
	options.delta_serializer = nil
	prune_component_serialization(self, component, options)
end

type ChangedSerializeEntry = {
	components: Array<Component>,
	values: Array<any>,
}

type FullRelationEntry = {
	components: {
		[Component]: {
			targets: { Entity },
			values: { any },
		},
	},
	tags: {
		[Component]: { Entity },
	},
}
type ChangedRelationEntry = {
	added: {
		[Component]: { Entity },
	},
	removed: {
		[Component]: { Entity },
	},
	changed: {
		[Component]: {
			targets: { Entity },
			values: { any },
		},
	},
}

-- every bucket is created on first push, so an entity only pays for the
-- categories it actually touched this collect
export type EntityUpdates = {
	changed: ChangedSerializeEntry?,
	added: Array<Component>?,
	removed: Array<Component>?,

	pair_changed: ChangedSerializeEntry?,
	pair_added: Array<Component>?,
	pair_removed: Array<Component>?,

	full_relations: FullRelationEntry?,
	changed_relations: ChangedRelationEntry?,
	removed_relations: Array<Component>?,
}

type GroupedKey = "added" | "removed" | "pair_added" | "pair_removed" | "removed_relations"

type MemberPacket = {
	buffer: buffer,
	variants: Array<any>,
}

export type MemberUpdatePackets = {
	-- combined byte size of every buffer in `updates`
	total_size: number,
	updates: Array<MemberPacket>,
}

type PacketIterator = () -> (Player, buffer, { { any } })

type SerializeGroupOutput = {
	buffer: buffer,
	variants: Array<any>,
}

export type SerializeGroup = {
	bitmask: Bitmask,
	deleted_entities: Array<Entity>,
	added_entities: Array<Entity>,

	updates: Map<Entity, EntityUpdates>,

	output: SerializeGroupOutput,
}

-- unreliable packets carry only current values: presence, filters and
-- relations all travel on the reliable channel
type UnreliableSerializeEntry = {
	components: ChangedSerializeEntry?,
	pairs: ChangedSerializeEntry?,
}

export type UnreliableSerializeGroup = {
	bitmask: Bitmask,
	updates: Map<Entity, UnreliableSerializeEntry>,

	outputs: Array<SerializeGroupOutput>,
}

function calculate_component_deltas(
	last_replicated: Bitmask,
	component_target: Bitmask,
	entity_target: Bitmask,
	deltas: BitmaskDeltas
)
	bitmasks.load_bitmask_deltas(deltas)
	bitmasks.calculate_bitmask_deltas(last_replicated, component_target, deltas)

	-- clients outside entity visibility get entity add/delete instead
	bitmasks.band(deltas.added, entity_target, deltas.added)
	bitmasks.band(deltas.removed, entity_target, deltas.removed)
end

function exclude_active_deltas(deltas: BitmaskDeltas, newly_active: Bitmask, newly_unactive: Bitmask)
	bitmasks.exclude(deltas.added, newly_active, deltas.added)
	bitmasks.exclude(deltas.removed, newly_active, deltas.removed)
	bitmasks.exclude(deltas.removed, newly_unactive, deltas.removed)
end

local function entity_updates(group: SerializeGroup, entity: Entity): EntityUpdates
	local entry = group.updates[entity]
	if not entry then
		entry = {} :: EntityUpdates
		group.updates[entity] = entry
	end
	return entry
end

local function push_grouped_component(entry: EntityUpdates, key: GroupedKey, component: Component)
	local list = (entry :: any)[key] :: Array<Component>?
	if not list then
		list = {}
		(entry :: any)[key] = list
	end
	table.insert(list :: Array<Component>, component)
end

local function push_changed_component(entry: EntityUpdates, is_pair: boolean, component: Component, value: any)
	local changed = if is_pair then entry.pair_changed else entry.changed
	if not changed then
		changed = { components = {}, values = {} }
		if is_pair then
			entry.pair_changed = changed
		else
			entry.changed = changed
		end
	end
	table.insert((changed :: ChangedSerializeEntry).components, component)
	table.insert((changed :: ChangedSerializeEntry).values, SET_VALUE(value))
end

local function push_unreliable_update(
	updates: Map<Entity, UnreliableSerializeEntry>,
	entity: Entity,
	is_pair: boolean,
	component: Component,
	value: any
)
	local entry = updates[entity]
	if not entry then
		entry = {} :: UnreliableSerializeEntry
		updates[entity] = entry
	end

	local changed = if is_pair then entry.pairs else entry.components
	if not changed then
		changed = { components = {}, values = {} }
		if is_pair then
			entry.pairs = changed
		else
			entry.components = changed
		end
	end

	table.insert((changed :: ChangedSerializeEntry).components, component)
	table.insert((changed :: ChangedSerializeEntry).values, SET_VALUE(value))
end

function push_storage_updates(
	storage: TrackingStorageBase,
	entry: EntityUpdates,
	is_pair: boolean,
	component: Component,
	has_component: boolean,
	value: any
)
	if storage.is_component then
		if has_component then
			push_changed_component(entry, is_pair, component, value)
		else
			push_grouped_component(entry, if is_pair then "pair_removed" else "removed", component)
		end
	else
		if has_component then
			push_grouped_component(entry, if is_pair then "pair_added" else "added", component)
		else
			push_grouped_component(entry, if is_pair then "pair_removed" else "removed", component)
		end
	end
end

function push_relation_full(
	world: World,
	storage: RelationStorage,
	entry: EntityUpdates,
	entity: Entity,
	rel: Component
)
	local bucket: FullRelationEntry = entry.full_relations or { components = {}, tags = {} }
	entry.full_relations = bucket

	if storage.is_component then
		local targets: Array<Entity> = {}
		local values: Array<any> = {}

		local index = 0
		while true do
			local target = WORLD_TARGET(world, entity, rel, index)
			if not target then
				break
			end
			index += 1

			local value = WORLD_GET(world, entity, PAIR(rel, target))
			table.insert(targets, target)
			table.insert(values, SET_VALUE(value))
		end

		bucket.components[rel] = { targets = targets, values = values }
	else
		local targets: Array<Entity> = {}

		local index = 0
		while true do
			local target = WORLD_TARGET(world, entity, rel, index)
			if not target then
				break
			end
			index += 1
			table.insert(targets, target)
		end

		bucket.tags[rel] = targets
	end
end

function push_relation_updates(
	world: World,
	storage: RelationStorage,
	entry: EntityUpdates,
	entity: Entity,
	rel: Component
)
	local bucket: ChangedRelationEntry = entry.changed_relations or { added = {}, removed = {}, changed = {} }
	entry.changed_relations = bucket

	local is_component = storage.is_component

	for target in storage.dirty_targets do
		if WORLD_HAS(world, entity, PAIR(rel, target)) then
			if is_component then
				local changed = bucket.changed[rel]
				if not changed then
					changed = { targets = {}, values = {} }
					bucket.changed[rel] = changed
				end

				local value = WORLD_GET(world, entity, PAIR(rel, target))
				table.insert(changed.targets, target)
				table.insert(changed.values, SET_VALUE(value))
			else
				local added = bucket.added[rel]
				if not added then
					added = {}
					bucket.added[rel] = added
				end
				table.insert(added, target)
			end
		else
			local removed = bucket.removed[rel]
			if not removed then
				removed = {}
				bucket.removed[rel] = removed
			end
			table.insert(removed, target)
		end
	end
end

local function setbit(mask: number, bit: number)
	return bit32.bor(mask, bit32.lshift(1, bit))
end

local function vlq_span(length: number): number
	if length < 0x80 then
		return 1
	elseif length < 0x4000 then
		return 2
	elseif length < 0x200000 then
		return 3
	else
		return 4
	end
end

local function write_vlq_bitmask(c: Cursor, value: number, mask: number, bit: number): number
	if value > 0 then
		cursor.write_vlq(c, value)
		return setbit(mask, bit)
	else
		return mask
	end
end

local function write_variant_value(
	self: Server,
	c: Cursor,
	log_component: Component,
	options: ComponentSerializationOptions?,
	value: any,
	variants: Array<any>
)
	local serialize_value = READ_VALUE(value)

	if options then
		local serdes = options.serdes
		local preprocessor = options.preprocessor

		if preprocessor then
			serialize_value = preprocessor.serialize(serialize_value)
		end

		if serdes then
			local output, serdes_variants = serdes.serialize(serialize_value)

			if serdes.includes_variants then
				if serdes_variants == nil then
					cursor.writeu8(c, VLQ_ZERO)
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
					common.log_component(self.world, log_component)
				)
			end

			local bytespan = serdes.bytespan
			cursor.write_buffer(c, output)
			if bytespan then
				if bytespan ~= buffer.len(output) then
					common.log_error(
						`bytespan: {bytespan} mismatch for buffer length: {buffer.len(output)} in component: `,
						common.log_component(self.world, log_component)
					)
				end
			else
				cursor.write_vlq(c, buffer.len(output))
			end
			return
		end
	end

	if serialize_value == nil then
		cursor.writeu8(c, VLQ_ZERO)
	else
		table.insert(variants, serialize_value)
		cursor.write_vlq(c, #variants)
	end
end

local function write_component_value(self: Server, c: Cursor, component: Component, value: any, variants: Array<any>)
	local options = self.component_serialization[component]
	write_variant_value(self, c, component, options, value, variants)
end

local function write_pair_value(
	self: Server,
	c: Cursor,
	relation: Component,
	id: Component,
	value: any,
	variants: Array<any>
)
	local options = self.component_serialization[id] or self.component_serialization[PAIR(relation, WILDCARD)]
	write_variant_value(self, c, relation, options, value, variants)
end

local function write_component_id(self: Server, c: Cursor, component: Entity)
	local shared_components = self.shared.components
	local encoded = shared_components.members[component]
	if not encoded then
		LOG_ERROR(`attempted to replicate a non-shared component `, common.log_component(self.world, component))
		return
	end
	cursor.write_span(c, encoded, #shared_components.keys)
end

-- ids are written back-to-front like the rest of the wire format: payload
-- first, then the ENTITY_ID_TYPES tag the client reads first. global ids are
-- the exception, a single byte with no tag.
local function write_entity_id(self: Server, c: Cursor, entity: Entity)
	local options = self.entity_serialization[entity]

	if options then
		local global_id = options.global_id
		if global_id then
			cursor.writeu8(c, global_id + GLOBAL_ID_OFFSET)
			return
		end

		local custom = options.custom
		if custom then
			if type(custom) == "number" then
				write_component_id(self, c, custom :: any)
				cursor.writeu40(c, entity :: any)
				cursor.writeu8(c, ENTITY_ID_TYPES.custom_id)
			else
				cursor.writeu8(c, self.shared.custom_ids.members[custom :: CustomId])
				cursor.writeu40(c, entity :: any)
				cursor.writeu8(c, ENTITY_ID_TYPES.custom_handler)
			end
			return
		end
	end

	if self.shared.components.members[entity] then
		write_component_id(self, c, entity)
		cursor.writeu8(c, ENTITY_ID_TYPES.shared)
	else
		cursor.writeu40(c, entity :: any)
		cursor.writeu8(c, ENTITY_ID_TYPES.entity)
	end
end

local function write_entity_pair_value(
	self: Server,
	world: World,
	c: Cursor,
	id: Component,
	value: any,
	variants: Array<any>
)
	local first, second = PAIR_FIRST(world, id), PAIR_SECOND(world, id)
	local pointer_start = c.offset

	write_pair_value(self, c, first, id, value, variants)

	-- if the entity is a custom id, we dont know if this has a serdes in the client, as it needs to be processed first to know the final pair
	-- we write a vlq so the client can jump in the cursor to skip this value entirely and process it later
	local pointer_offset = c.offset - pointer_start
	cursor.write_vlq(c, pointer_offset)

	write_entity_id(self, c, second)
	write_component_id(self, c, first)
end

local function write_entity_pair(self: Server, world: World, c: Cursor, id: Component)
	local first, second = PAIR_FIRST(world, id), PAIR_SECOND(world, id)
	write_entity_id(self, c, second)
	write_component_id(self, c, first)
end

local ENTITY_BITS = {
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

-- per group trailer mask
local GROUP_BITS = {
	updates = 0,
	added_entities = 1,
	deleted_entities = 2,
}

local function write_relation_targets(self: Server, c: Cursor, relation: Component, targets: Array<Entity>)
	for _, target in targets do
		write_entity_id(self, c, target)
	end
	cursor.write_vlq(c, #targets)
	write_component_id(self, c, relation)
end

local function write_relation_targets_values(
	self: Server,
	c: Cursor,
	relation: Component,
	targets: Array<Entity>,
	values: Array<any>,
	variants: Array<any>
)
	for index, target in targets do
		write_entity_id(self, c, target)
		write_component_value(self, c, relation, values[index], variants)
	end
	cursor.write_vlq(c, #targets)
	write_component_id(self, c, relation)
end

-- component ids only (tags added, anything removed): ids..., returns count
local function write_grouped_components(self: Server, c: Cursor, components: Array<Component>?): number
	if not components then
		return 0
	end
	for _, component in components do
		write_component_id(self, c, component)
	end
	return #components
end

-- pair ids only (tags added, anything removed): pairs..., returns count
local function write_grouped_pairs(self: Server, c: Cursor, ids: Array<Component>?): number
	if not ids then
		return 0
	end
	local world = self.world
	for _, id in ids do
		write_entity_pair(self, world, c, id)
	end
	return #ids
end

-- one entity block. every section is written only when non empty, its bit set
-- in the entity mask and its count vlq written right after the payload
local function serialize_entity_updates(
	self: Server,
	c: Cursor,
	entity: Entity,
	entry: EntityUpdates,
	variants: Array<any>
)
	local world = self.world
	local mask = 0

	-- relations

	local total = write_grouped_components(self, c, entry.removed_relations)
	mask = write_vlq_bitmask(c, total, mask, ENTITY_BITS.relations_removed)

	local full = entry.full_relations
	if full then
		local total_components = 0
		for relation, targets in full.components do
			write_relation_targets_values(self, c, relation, targets.targets, targets.values, variants)
			total_components += 1
		end
		cursor.write_vlq(c, total_components)

		local total_tags = 0
		for relation, targets in full.tags do
			write_relation_targets(self, c, relation, targets)
			total_tags += 1
		end
		cursor.write_vlq(c, total_tags)

		mask = setbit(mask, ENTITY_BITS.full_relations)
	end

	local changed_relations = entry.changed_relations
	if changed_relations then
		local total_changed = 0
		for relation, targets in changed_relations.changed do
			write_relation_targets_values(self, c, relation, targets.targets, targets.values, variants)
			total_changed += 1
		end
		cursor.write_vlq(c, total_changed)

		local total_added = 0
		for relation, targets in changed_relations.added do
			write_relation_targets(self, c, relation, targets)
			total_added += 1
		end
		cursor.write_vlq(c, total_added)

		local total_removed = 0
		for relation, targets in changed_relations.removed do
			write_relation_targets(self, c, relation, targets)
			total_removed += 1
		end
		cursor.write_vlq(c, total_removed)

		mask = setbit(mask, ENTITY_BITS.changed_relations)
	end

	-- pairs

	total = write_grouped_pairs(self, c, entry.pair_removed)
	mask = write_vlq_bitmask(c, total, mask, ENTITY_BITS.pair_removed)

	total = write_grouped_pairs(self, c, entry.pair_added)
	mask = write_vlq_bitmask(c, total, mask, ENTITY_BITS.pair_added)

	local pair_changed = entry.pair_changed
	if pair_changed then
		local ids = pair_changed.components
		local values = pair_changed.values
		for index, id in ids do
			write_entity_pair_value(self, world, c, id, values[index], variants)
		end
		mask = write_vlq_bitmask(c, #ids, mask, ENTITY_BITS.pair_changed)
	end

	-- reliables

	total = write_grouped_components(self, c, entry.removed)
	mask = write_vlq_bitmask(c, total, mask, ENTITY_BITS.reliable_removed)

	total = write_grouped_components(self, c, entry.added)
	mask = write_vlq_bitmask(c, total, mask, ENTITY_BITS.reliable_added)

	local changed = entry.changed
	if changed then
		local components = changed.components
		local values = changed.values
		for index, component in components do
			write_component_value(self, c, component, values[index], variants)
			write_component_id(self, c, component)
		end
		mask = write_vlq_bitmask(c, #components, mask, ENTITY_BITS.reliable_changed)
	end

	cursor.writeu16(c, mask)
	write_entity_id(self, c, entity)
end

-- layout (read order is the reverse of write order):
--   u16 group mask                         GROUP_BITS, vlq count per set bit
--   deleted entities                       entity ids
--   added entities                         entity ids
--   updates                                per entity:
--     entity id
--     u16 entity mask                      ENTITY_BITS, vlq count per set bit
--     reliable changed                     value + component id, vlq
--     reliable added / removed             component ids, vlq
--     pair changed                         pair values, vlq
--     pair added / removed                 pairs, vlq
--     changed relations                    [targets..., vlq, relation] for
--                                          changed / added / removed, each vlq counted
--     full relations                       components then tags, each vlq counted
--     relations removed                    relation ids, vlq
local function serialize_update_group(self: Server, group: SerializeGroup): (buffer, Array<any>)
	local c = cursor.new()
	local variants: Array<any> = {}
	local group_mask = 0

	local total = 0
	for entity, entry in group.updates do
		serialize_entity_updates(self, c, entity, entry, variants)
		total += 1
	end
	group_mask = write_vlq_bitmask(c, total, group_mask, GROUP_BITS.updates)

	total = 0
	for _, entity in group.added_entities do
		write_entity_id(self, c, entity)
		total += 1
	end
	group_mask = write_vlq_bitmask(c, total, group_mask, GROUP_BITS.added_entities)

	total = 0
	for _, entity in group.deleted_entities do
		write_entity_id(self, c, entity)
		total += 1
	end
	group_mask = write_vlq_bitmask(c, total, group_mask, GROUP_BITS.deleted_entities)

	cursor.writeu16(c, group_mask)

	return cursor.close(c), variants
end

-- layout (read order is the reverse of write order). packets split at
-- MAX_UNRELIABLE_PACKET_SIZE, each one self-contained.
--   vlq entity count
--   per entity: component values + ids, vlq component count,
--   pair values, vlq pair count, entity id
local function serialize_unreliable_group(
	self: Server,
	group: UnreliableSerializeGroup,
	outputs: Array<SerializeGroupOutput>
)
	local c = cursor.new()
	local world = self.world
	local variants: Array<any> = {}
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
		c.offset = checkpoint_offset
		for i = #variants, checkpoint_variants_count + 1, -1 do
			variants[i] = nil
		end
		total_entities = checkpoint_total_entities
	end

	local function commit()
		if total_entities <= 0 then
			return
		end

		cursor.write_vlq(c, total_entities)
		table.insert(outputs, {
			buffer = cursor.close(c),
			variants = variants,
		})

		c = cursor.new()
		variants = {}
		total_entities = 0
	end

	local function serialize_entity(entity: Entity, entry: UnreliableSerializeEntry)
		local components = entry.components
		if components then
			local values = components.values
			for index, component in components.components do
				write_component_value(self, c, component, values[index], variants)
				write_component_id(self, c, component)
			end
			cursor.write_vlq(c, #components.components)
		else
			cursor.write_vlq(c, 0)
		end

		local pairs = entry.pairs
		if pairs then
			local values = pairs.values
			for index, id in pairs.components do
				write_entity_pair_value(self, world, c, id, values[index], variants)
			end
			cursor.write_vlq(c, #pairs.components)
		else
			cursor.write_vlq(c, 0)
		end

		write_entity_id(self, c, entity)
		total_entities += 1
	end

	for entity, entry in group.updates do
		create_checkpoint()
		serialize_entity(entity, entry)

		if c.offset + vlq_span(total_entities) + vlq_span(1) + PACKET_TYPE_SPAN > MAX_UNRELIABLE_PACKET_SIZE then
			rollback_checkpoint()
			commit()
			serialize_entity(entity, entry)
		end
	end

	commit()
end

local function collect_updates_groups(self: Server): Map<MaskHash, SerializeGroup>
	local client_registry = self.registry
	for storage, entry in self.function_filters do
		local bitmask = client_registry:create_bitmask_from_function(entry.predicator)
		local current = storage.filter
		if current and bitmasks.equals(current, bitmask) then
			continue
		end

		local tracking_component = entry.tracking

		if tracking_component then
			-- routes to the right dirty list via the storage's track_type
			edit_tracking_filter(
				self,
				entry.entity,
				tracking_component,
				entry.networked,
				entry.tracking_storage :: TrackingStorageBase,
				bitmask
			)
		else
			edit_networked_filter(self, entry.entity, entry.networked, bitmask)
		end
	end

	local serialize_groups: Map<MaskHash, SerializeGroup> = {}
	local networked_entities = self.networked
	local world = self.world

	local function emit(bitmask: Bitmask): SerializeGroup
		local hash = bitmasks.hash(bitmask)
		local serialize = serialize_groups[hash]
		if not serialize then
			local new_serialize: SerializeGroup = {
				-- deltas are reused scratch buffers, groups need a stable copy
				bitmask = bitmasks.clone(bitmask),
				deleted_entities = {},
				added_entities = {},

				updates = {},

				variants = nil :: any,
				output = nil :: any,
			}
			serialize_groups[hash] = new_serialize
			return new_serialize
		end

		return serialize
	end

	local active = self.client_active_bitmask
	local last_active = self.last_active_bitmask
	local newly_active = self.newly_active_bitmask
	local newly_unactive = self.newly_unactive_bitmask

	local client_indexes = self.registry.client_indexes
	for player in self.pending_active do
		local index = client_indexes[player]
		if index then
			bitmasks.set(active, index)
		end
	end
	table.clear(self.pending_active)

	bitmasks.exclude(active, last_active, newly_active)
	bitmasks.exclude(last_active, active, newly_unactive)

	local is_active_dirty = not bitmasks.is_empty(newly_active) or not bitmasks.is_empty(newly_unactive)

	local entity_deltas = self.entity_bitmask_deltas
	local component_deltas = self.component_bitmask_deltas
	local draft = self.draft_bitmask
	local entity_target = self.target_bitmask

	for _, entity in self.dirty_networked do
		local networked = networked_entities[entity]

		if networked.is_dead then
			-- deletion goes to everyone who last had the entity and is still here
			local last = networked.last_replicated or networked.filter or last_active
			bitmasks.load(last, draft)
			bitmasks.band(draft, active, draft)
			bitmasks.exclude(draft, newly_active, draft)
			if not bitmasks.is_empty(draft) then
				table.insert(emit(draft).deleted_entities, entity)
			end
			clear_networked_references(self, entity, networked)
			networked_entities[entity] = nil
			if networked.cleaned then
				self.entity_serialization[entity] = nil
			end
			continue
		end

		-- filter sources (groups especially) can carry freed or never active
		-- indexes; only active clients ever receive anything. every storage
		-- target below is clipped by this one
		local target: Bitmask = active
		local entity_filter = networked.filter
		if entity_filter then
			bitmasks.load(entity_filter, entity_target)
			bitmasks.band(entity_target, active, entity_target)
			target = entity_target
		end
		local is_entity_filter_dirty = flag_test(networked.dirty_flags, DIRTY_FILTER_FLAG)

		if is_entity_filter_dirty then
			local last = networked.last_replicated or networked.filter or last_active
			bitmasks.load_bitmask_deltas(entity_deltas)
			bitmasks.calculate_bitmask_deltas(last, target, entity_deltas)
			-- newly active clients get a full snapshot at this same boundary instead;
			-- newly unactive clients are gone, nobody to send removals to
			if is_active_dirty then
				exclude_active_deltas(entity_deltas, newly_active, newly_unactive)
			end

			if not bitmasks.is_empty(entity_deltas.added) then
				table.insert(emit(entity_deltas.added).added_entities, entity)
			end
			if not bitmasks.is_empty(entity_deltas.removed) then
				table.insert(emit(entity_deltas.removed).deleted_entities, entity)
			end
			networked.last_replicated = nil
		end

		for _, component in networked.dirty_reliable do
			local reliable_storage = networked.reliable_storages[component]
			local is_component_filter_dirty = flag_test(reliable_storage.dirty_flags, DIRTY_FILTER_FLAG)

			local has_delta_source = reliable_storage.filter ~= nil or reliable_storage.last_replicated ~= nil
			local component_target = reliable_storage.filter or target
			local is_component_added = false
			local has_component = WORLD_HAS(world, entity, component)
			local has_value = has_component and reliable_storage.is_component
			-- `and/or` would turn a false value into nil
			local value = if has_value then WORLD_GET(world, entity, component) else nil

			if has_delta_source and is_component_filter_dirty then
				local last = reliable_storage.last_replicated or reliable_storage.filter :: Bitmask

				calculate_component_deltas(last, component_target, target, component_deltas)
				if is_active_dirty then
					exclude_active_deltas(component_deltas, newly_active, newly_unactive)
				end

				is_component_added = not bitmasks.is_empty(component_deltas.added)

				if is_component_added then
					local entry = entity_updates(emit(component_deltas.added), entity)
					push_storage_updates(reliable_storage, entry, false, component, has_component, value)
				end

				if not bitmasks.is_empty(component_deltas.removed) then
					local entry = entity_updates(emit(component_deltas.removed), entity)
					push_grouped_component(entry, "removed", component)
				end
				reliable_storage.last_replicated = nil
			end

			if flag_test(reliable_storage.dirty_flags, DIRTY_CHANGED_FLAG) then
				bitmasks.load(component_target, draft)
				bitmasks.band(draft, target, draft)
				if is_active_dirty then
					bitmasks.exclude(draft, newly_active, draft)
					bitmasks.exclude(draft, newly_unactive, draft)
				end

				if is_component_added then
					bitmasks.exclude(draft, component_deltas.added, draft)
				end
				if is_entity_filter_dirty then
					bitmasks.exclude(draft, entity_deltas.added, draft)
				end

				if not bitmasks.is_empty(draft) then
					local entry = entity_updates(emit(draft), entity)
					push_storage_updates(reliable_storage, entry, false, component, has_component, value)
				end
			end
			reliable_storage.dirty_flags = 0
			-- the removal delta above was its last word
			if reliable_storage.is_dead then
				clear_hook_reference(self, entity, component, reliable_storage)
				networked.reliable_storages[component] = nil
			end
		end

		for _, component in networked.dirty_unreliable do
			local unreliable_storage = networked.unreliable_storages[component]
			local is_unreliable_filter_dirty = flag_test(unreliable_storage.dirty_flags, DIRTY_FILTER_FLAG)

			local has_delta_source = unreliable_storage.filter ~= nil or unreliable_storage.last_replicated ~= nil
			local component_target = unreliable_storage.filter or target
			local is_unreliable_added = false
			local has_value = WORLD_HAS(world, entity, component)
			local value = if has_value then WORLD_GET(world, entity, component) else nil

			if has_delta_source and is_unreliable_filter_dirty then
				local last = unreliable_storage.last_replicated or unreliable_storage.filter :: Bitmask

				calculate_component_deltas(last, component_target, target, component_deltas)
				if is_active_dirty then
					exclude_active_deltas(component_deltas, newly_active, newly_unactive)
				end

				is_unreliable_added = not bitmasks.is_empty(component_deltas.added)

				if is_unreliable_added then
					local entry = entity_updates(emit(component_deltas.added), entity)
					if has_value then
						push_changed_component(entry, false, component, value)
					else
						push_grouped_component(entry, "removed", component)
					end
				end

				if not bitmasks.is_empty(component_deltas.removed) then
					local entry = entity_updates(emit(component_deltas.removed), entity)
					push_grouped_component(entry, "removed", component)
				end
				unreliable_storage.last_replicated = nil
			end

			if flag_test(unreliable_storage.dirty_flags, DIRTY_CHANGED_FLAG) then
				bitmasks.load(component_target, draft)
				bitmasks.band(draft, target, draft)
				if is_active_dirty then
					bitmasks.exclude(draft, newly_active, draft)
					bitmasks.exclude(draft, newly_unactive, draft)
				end

				if is_unreliable_added then
					bitmasks.exclude(draft, component_deltas.added, draft)
				end
				if is_entity_filter_dirty then
					bitmasks.exclude(draft, entity_deltas.added, draft)
				end

				if not bitmasks.is_empty(draft) then
					local entry = entity_updates(emit(draft), entity)
					if has_value then
						push_changed_component(entry, false, component, value)
					else
						push_grouped_component(entry, "removed", component)
					end
				end
			end
			unreliable_storage.dirty_flags = 0
			if unreliable_storage.is_dead then
				clear_hook_reference(self, entity, component, unreliable_storage)
				networked.unreliable_storages[component] = nil
			end
		end

		for _, id in networked.dirty_pairs do
			local pair_storage = networked.pair_storages[id]
			local is_pair_filter_dirty = flag_test(pair_storage.dirty_flags, DIRTY_FILTER_FLAG)

			local has_delta_source = pair_storage.filter ~= nil or pair_storage.last_replicated ~= nil
			local component_target = pair_storage.filter or target
			local is_pair_added = false
			local has_pair = WORLD_HAS(world, entity, id)
			local has_value = (has_pair and pair_storage.is_component)
			local value = if has_value then WORLD_GET(world, entity, id) else nil

			if has_delta_source and is_pair_filter_dirty then
				local last = pair_storage.last_replicated or pair_storage.filter :: Bitmask

				calculate_component_deltas(last, component_target, target, component_deltas)
				if is_active_dirty then
					exclude_active_deltas(component_deltas, newly_active, newly_unactive)
				end

				is_pair_added = not bitmasks.is_empty(component_deltas.added)

				if is_pair_added then
					local entry = entity_updates(emit(component_deltas.added), entity)
					push_storage_updates(pair_storage, entry, true, id, has_pair, value)
				end

				if not bitmasks.is_empty(component_deltas.removed) then
					local entry = entity_updates(emit(component_deltas.removed), entity)
					push_grouped_component(entry, "pair_removed", id)
				end
				pair_storage.last_replicated = nil
			end

			if flag_test(pair_storage.dirty_flags, DIRTY_CHANGED_FLAG) then
				bitmasks.load(component_target, draft)
				bitmasks.band(draft, target, draft)
				if is_active_dirty then
					bitmasks.exclude(draft, newly_active, draft)
					bitmasks.exclude(draft, newly_unactive, draft)
				end

				if is_pair_added then
					bitmasks.exclude(draft, component_deltas.added, draft)
				end
				if is_entity_filter_dirty then
					bitmasks.exclude(draft, entity_deltas.added, draft)
				end

				if not bitmasks.is_empty(draft) then
					local entry = entity_updates(emit(draft), entity)
					push_storage_updates(pair_storage, entry, true, id, has_pair, value)
				end
			end
			pair_storage.dirty_flags = 0
			if pair_storage.is_dead then
				clear_hook_reference(self, entity, id, pair_storage)
				networked.pair_storages[id] = nil
			end
		end

		for _, id in networked.dirty_unreliable_pairs do
			local unreliable_pair_storage = networked.unreliable_pair_storages[id]
			local is_pair_filter_dirty = flag_test(unreliable_pair_storage.dirty_flags, DIRTY_FILTER_FLAG)

			local has_delta_source = unreliable_pair_storage.filter ~= nil
				or unreliable_pair_storage.last_replicated ~= nil
			local component_target = unreliable_pair_storage.filter or target
			local is_pair_added = false
			local has_pair = WORLD_HAS(world, entity, id)
			local has_value = (has_pair and unreliable_pair_storage.is_component)
			local value = has_value and WORLD_GET(world, entity, id) or nil

			if has_delta_source and is_pair_filter_dirty then
				local last = unreliable_pair_storage.last_replicated or unreliable_pair_storage.filter :: Bitmask

				calculate_component_deltas(last, component_target, target, component_deltas)
				if is_active_dirty then
					exclude_active_deltas(component_deltas, newly_active, newly_unactive)
				end

				is_pair_added = not bitmasks.is_empty(component_deltas.added)

				if is_pair_added then
					local entry = entity_updates(emit(component_deltas.added), entity)
					push_storage_updates(unreliable_pair_storage, entry, true, id, has_pair, value)
				end

				if not bitmasks.is_empty(component_deltas.removed) then
					local entry = entity_updates(emit(component_deltas.removed), entity)
					push_grouped_component(entry, "pair_removed", id)
				end
				unreliable_pair_storage.last_replicated = nil
			end

			if flag_test(unreliable_pair_storage.dirty_flags, DIRTY_CHANGED_FLAG) then
				bitmasks.load(component_target, draft)
				bitmasks.band(draft, target, draft)
				if is_active_dirty then
					bitmasks.exclude(draft, newly_active, draft)
					bitmasks.exclude(draft, newly_unactive, draft)
				end

				if is_pair_added then
					bitmasks.exclude(draft, component_deltas.added, draft)
				end
				if is_entity_filter_dirty then
					bitmasks.exclude(draft, entity_deltas.added, draft)
				end

				if not bitmasks.is_empty(draft) then
					local entry = entity_updates(emit(draft), entity)
					push_storage_updates(unreliable_pair_storage, entry, true, id, has_pair, value)
				end
			end
			unreliable_pair_storage.dirty_flags = 0
			if unreliable_pair_storage.is_dead then
				clear_hook_reference(self, entity, id, unreliable_pair_storage)
				networked.unreliable_pair_storages[id] = nil
			end
		end

		for _, rel in networked.dirty_relations do
			local relation_storage = networked.relation_storages[rel]
			local is_rel_filter_dirty = flag_test(relation_storage.dirty_flags, DIRTY_FILTER_FLAG)

			local has_delta_source = relation_storage.filter ~= nil or relation_storage.last_replicated ~= nil
			local component_target = relation_storage.filter or target
			local is_rel_added = false

			if has_delta_source and is_rel_filter_dirty then
				local last = relation_storage.last_replicated or relation_storage.filter :: Bitmask

				calculate_component_deltas(last, component_target, target, component_deltas)
				if is_active_dirty then
					exclude_active_deltas(component_deltas, newly_active, newly_unactive)
				end

				is_rel_added = not bitmasks.is_empty(component_deltas.added)

				if is_rel_added then
					local entry = entity_updates(emit(component_deltas.added), entity)
					push_relation_full(world, relation_storage, entry, entity, rel)
				end

				if not bitmasks.is_empty(component_deltas.removed) then
					local entry = entity_updates(emit(component_deltas.removed), entity)
					push_grouped_component(entry, "removed_relations", rel)
				end
				relation_storage.last_replicated = nil
			end

			if flag_test(relation_storage.dirty_flags, DIRTY_CHANGED_FLAG) then
				bitmasks.load(component_target, draft)
				bitmasks.band(draft, target, draft)
				if is_active_dirty then
					bitmasks.exclude(draft, newly_active, draft)
					bitmasks.exclude(draft, newly_unactive, draft)
				end

				if is_rel_added then
					bitmasks.exclude(draft, component_deltas.added, draft)
				end
				if is_entity_filter_dirty then
					bitmasks.exclude(draft, entity_deltas.added, draft)
				end

				if not bitmasks.is_empty(draft) then
					local entry = entity_updates(emit(draft), entity)
					push_relation_updates(world, relation_storage, entry, entity, rel)
				end
			end
			relation_storage.dirty_flags = 0
			table.clear(relation_storage.dirty_targets)
			if relation_storage.is_dead then
				clear_hook_reference(self, entity, rel, relation_storage)
				networked.relation_storages[rel] = nil
			end
		end

		table.clear(networked.dirty_reliable)
		table.clear(networked.dirty_unreliable)
		table.clear(networked.dirty_pairs)
		table.clear(networked.dirty_unreliable_pairs)
		table.clear(networked.dirty_relations)
		networked.dirty_flags = 0
	end
	table.clear(self.dirty_networked)

	bitmasks.load(active, last_active)
	bitmasks.clear(newly_active)
	bitmasks.clear(newly_unactive)

	return serialize_groups
end

-- fills every group's output buffer and variants in place
local function serialize_update_groups(self: Server, groups: Map<MaskHash, SerializeGroup>)
	for _, group in groups do
		local buf, variants = serialize_update_group(self, group)
		group.output = {
			buffer = buf,
			variants = variants,
		}
	end
end

local function collect_unreliable_groups(self: Server): Map<MaskHash, UnreliableSerializeGroup>
	local unreliable_groups: Map<MaskHash, UnreliableSerializeGroup> = {}
	local world = self.world
	local active = self.client_active_bitmask
	local draft = self.draft_bitmask

	local function emit(bitmask: Bitmask): UnreliableSerializeGroup
		local hash = bitmasks.hash(bitmask)
		local group = unreliable_groups[hash]
		if not group then
			local new_group: UnreliableSerializeGroup = {
				bitmask = bitmasks.clone(bitmask),
				updates = {},

				outputs = {},
			}
			unreliable_groups[hash] = new_group
			return new_group
		end
		return group
	end

	for entity in self.unreliable_networked do
		local networked = self.networked[entity]
		local entity_filter = networked.filter

		for component, storage in networked.unreliable_storages do
			if storage.is_dead or not WORLD_HAS(world, entity, component) then
				continue
			end

			-- visibility right now: active clients inside both the entity and
			-- storage filters. no delta correction exists here, so inactive
			-- clients are always clipped out
			bitmasks.load(active, draft)
			if entity_filter then
				bitmasks.band(draft, entity_filter, draft)
			end
			local filter = storage.filter
			if filter then
				bitmasks.band(draft, filter, draft)
			end
			if bitmasks.is_empty(draft) then
				continue
			end

			push_unreliable_update(emit(draft).updates, entity, false, component, WORLD_GET(world, entity, component))
		end

		for id, storage in networked.unreliable_pair_storages do
			-- pair tags have no value to resend, their presence is reliable
			if storage.is_dead or not storage.is_component or not WORLD_HAS(world, entity, id) then
				continue
			end

			bitmasks.load(active, draft)
			if entity_filter then
				bitmasks.band(draft, entity_filter, draft)
			end
			local filter = storage.filter
			if filter then
				bitmasks.band(draft, filter, draft)
			end
			if bitmasks.is_empty(draft) then
				continue
			end

			push_unreliable_update(emit(draft).updates, entity, true, id, WORLD_GET(world, entity, id))
		end
	end

	return unreliable_groups
end

local function serialize_unreliable_groups(self: Server, groups: Map<MaskHash, UnreliableSerializeGroup>)
	for _, group in groups do
		serialize_unreliable_group(self, group, group.outputs)
	end
end

-- rebuilds the shared lookups (component ids, custom ids, serdes) when
-- flagged; no-op otherwise.
function server.resolve_dirty(self: Server)
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

local FULL_BITS = {
	tags = 0,
	components = 1,
	pair_tags = 2,
	pair_components = 3,
	relation_tags = 4,
	relation_components = 5,
}

-- full snapshot for a single player, serialized straight into one buffer.
--
-- layout in read order (sections are written in the reverse):
--   vlq entity count
--   per entity:
--     entity id
--     u8 entity mask                     FULL_BITS, vlq count per set bit
--     tags                               component ids (tags and unreliable presence)
--     components                         value + component id
--     pair tags                          pairs
--     pair components                    pair values
--     relation tags                      per relation: [targets..., vlq, relation]
--     relation components                per relation: [target + value..., vlq, relation]
local function write_full_entity(
	self: Server,
	c: Cursor,
	entity: Entity,
	networked: NetworkedStorage,
	index: number,
	variants: Array<any>
)
	local world = self.world
	local mask = 0

	-- relation components: every current target with its value
	local total = 0
	for rel, relation_storage in networked.relation_storages do
		if not relation_storage.is_component then
			continue
		end
		local filter = relation_storage.filter
		if filter and not bitmasks.test(filter, index) then
			continue
		end

		local targets: Array<Entity> = {}
		local values: Array<any> = {}
		local target_index = 0
		while true do
			local target = WORLD_TARGET(world, entity, rel, target_index)
			if not target then
				break
			end
			target_index += 1
			local value = WORLD_GET(world, entity, PAIR(rel, target))
			table.insert(targets, target)
			table.insert(values, SET_VALUE(value))
		end
		write_relation_targets_values(self, c, rel, targets, values, variants)
		total += 1
	end
	mask = write_vlq_bitmask(c, total, mask, FULL_BITS.relation_components)

	-- relation tags: every current target
	total = 0
	for rel, relation_storage in networked.relation_storages do
		if relation_storage.is_component then
			continue
		end
		local filter = relation_storage.filter
		if filter and not bitmasks.test(filter, index) then
			continue
		end

		local targets: Array<Entity> = {}
		local target_index = 0
		while true do
			local target = WORLD_TARGET(world, entity, rel, target_index)
			if not target then
				break
			end
			target_index += 1
			table.insert(targets, target)
		end
		write_relation_targets(self, c, rel, targets)
		total += 1
	end
	mask = write_vlq_bitmask(c, total, mask, FULL_BITS.relation_tags)

	-- pair components, unreliable values included
	total = 0
	for id, storage in networked.pair_storages do
		if not storage.is_component then
			continue
		end
		local filter = storage.filter
		if filter and not bitmasks.test(filter, index) then
			continue
		end
		if WORLD_HAS(world, entity, id) then
			write_entity_pair_value(self, world, c, id, WORLD_GET(world, entity, id), variants)
			total += 1
		end
	end
	for id, storage in networked.unreliable_pair_storages do
		if not storage.is_component then
			continue
		end
		local filter = storage.filter
		if filter and not bitmasks.test(filter, index) then
			continue
		end
		if WORLD_HAS(world, entity, id) then
			write_entity_pair_value(self, world, c, id, WORLD_GET(world, entity, id), variants)
			total += 1
		end
	end
	mask = write_vlq_bitmask(c, total, mask, FULL_BITS.pair_components)

	-- pair tags: reliable without a value
	total = 0
	for id, storage in networked.pair_storages do
		if storage.is_component then
			continue
		end
		local filter = storage.filter
		if filter and not bitmasks.test(filter, index) then
			continue
		end
		if WORLD_HAS(world, entity, id) then
			write_entity_pair(self, world, c, id)
			total += 1
		end
	end
	mask = write_vlq_bitmask(c, total, mask, FULL_BITS.pair_tags)

	-- components: unreliable values ride along too, a snapshot is the only
	-- reliable chance the client gets to see them
	total = 0
	for component, storage in networked.reliable_storages do
		if not storage.is_component then
			continue
		end
		local filter = storage.filter
		if filter and not bitmasks.test(filter, index) then
			continue
		end
		if WORLD_HAS(world, entity, component) then
			write_component_value(self, c, component, WORLD_GET(world, entity, component), variants)
			write_component_id(self, c, component)
			total += 1
		end
	end
	for component, storage in networked.unreliable_storages do
		local filter = storage.filter
		if filter and not bitmasks.test(filter, index) then
			continue
		end
		if WORLD_HAS(world, entity, component) then
			write_component_value(self, c, component, WORLD_GET(world, entity, component), variants)
			write_component_id(self, c, component)
			total += 1
		end
	end
	mask = write_vlq_bitmask(c, total, mask, FULL_BITS.components)

	-- tags: reliable without a value
	total = 0
	for component, storage in networked.reliable_storages do
		if storage.is_component then
			continue
		end
		local filter = storage.filter
		if filter and not bitmasks.test(filter, index) then
			continue
		end
		if WORLD_HAS(world, entity, component) then
			write_component_id(self, c, component)
			total += 1
		end
	end
	mask = write_vlq_bitmask(c, total, mask, FULL_BITS.tags)

	cursor.writeu8(c, mask)
	write_entity_id(self, c, entity)
end

function server.get_full(self: Server, player: Player): (buffer, Array<any>)
	self:resolve_dirty()

	local index = self.registry.client_indexes[player]
	if index == nil then
		LOG_ERROR "attempted to get full of a non registered client"
	end

	local is_active = bitmasks.test(self.client_active_bitmask, index)
	if not is_active then
		common.log_warn(
			"attempted to get full of a client that is not active, the packet may be incomplete.",
			"mark the player as ready first with mark_player_ready and run collect_updates"
		)
	end

	local c = cursor.new()
	local variants: Array<any> = {}
	local total_entities = 0

	for entity, networked in self.networked do
		if networked.is_dead then
			continue
		end

		local entity_filter = networked.filter
		local visible = if entity_filter then bitmasks.test(entity_filter, index) else is_active
		if not visible then
			continue
		end

		write_full_entity(self, c, entity, networked, index, variants)
		total_entities += 1
	end

	cursor.write_vlq(c, total_entities)
	cursor.writeu8(c, PACKET_TYPES.full)
	return cursor.close(c), variants
end

local function distribute_update_groups(groups: Map<MaskHash, SerializeGroup>): Map<number, MemberUpdatePackets>
	local member_updates: Map<number, MemberUpdatePackets> = {}
	for _, group in groups do
		local output = group.output

		local buf = output.buffer
		local size = buffer.len(buf)
		local update: MemberPacket = {
			buffer = buf,
			variants = output.variants :: Array<any>,
		}

		bitmasks.iter_set(group.bitmask, function(index)
			local member = member_updates[index]
			if not member then
				member = { total_size = 0, updates = {} }
				member_updates[index] = member
			end
			member.total_size += size
			table.insert(member.updates, update)
		end)
	end
	return member_updates
end

local function distribute_unreliable_groups(
	groups: Map<MaskHash, UnreliableSerializeGroup>
): Map<number, MemberUpdatePackets>
	local member_updates: Map<number, MemberUpdatePackets> = {}

	for _, group in groups do
		local outputs = group.outputs
		local updates: Array<MemberPacket> = {}

		for _, output in outputs do
			local buf = output.buffer
			local update: MemberPacket = {
				buffer = buf,
				variants = output.variants :: Array<any>,
			}
			table.insert(updates, update)
		end

		bitmasks.iter_set(group.bitmask, function(index)
			for _, update in updates do
				local buf = update.buffer
				local size = buffer.len(buf)

				local member = member_updates[index]
				if not member then
					member = { total_size = 0, updates = {} }
					member_updates[index] = member
				end
				member.total_size += size
				table.insert(member.updates, update)
			end
		end)
	end

	return member_updates
end

local function combine_packet_outputs(
	outputs: Array<MemberPacket>,
	total_size: number,
	packet_type: number
): (buffer, Array<Array<any>>)
	local count = #outputs
	local combined = buffer.create(total_size + vlq_span(count) + PACKET_TYPE_SPAN)
	local variants = table.create(count) :: Array<Array<any>>

	local offset = 0
	for _, update in outputs do
		local buf = update.buffer
		buffer.copy(combined, offset, buf)
		offset += buffer.len(buf)
		table.insert(variants, update.variants)
	end

	local tail = cursor.from_offset(combined, offset)
	cursor.write_vlq(tail, count)
	cursor.writeu8(tail, packet_type)
	return combined, variants
end

local function create_packet_iterator(
	self: Server,
	member_updates: Map<number, MemberUpdatePackets>,
	packet_type: number
): PacketIterator
	local index_clients = self.registry.index_clients
	local iterated: number? = nil
	local function iterator()
		local index, member = next(member_updates, iterated)
		if index == nil then
			return nil :: any
		end
		iterated = index

		local player = index_clients[index]
		if player == nil then
			LOG_ERROR "packet addressed to a client that is no longer registered, send packets right after collecting"
		end

		local combined, variants = combine_packet_outputs(member.updates, member.total_size, packet_type)
		return player, combined, variants
	end
	return iterator :: PacketIterator
end

export type EntitySerializeGroup = {
	bitmask: Bitmask,
	relation_components: Array<Component>,
	relation_tags: Array<Component>,
	pair_components: Array<Component>,
	pair_tags: Array<Component>,
	components: Array<Component>,
	tags: Array<Component>,
}

local function serialize_entity_group(
	self: Server,
	c: Cursor,
	entity: Entity,
	group: EntitySerializeGroup,
	variants: Array<any>
)
	local world = self.world
	local mask = 0

	local relation_components = group.relation_components
	for _, rel in relation_components do
		local targets: Array<Entity> = {}
		local values: Array<any> = {}
		local target_index = 0
		while true do
			local target = WORLD_TARGET(world, entity, rel, target_index)
			if not target then
				break
			end
			target_index += 1
			local value = WORLD_GET(world, entity, PAIR(rel, target))
			table.insert(targets, target)
			table.insert(values, SET_VALUE(value))
		end
		write_relation_targets_values(self, c, rel, targets, values, variants)
	end
	mask = write_vlq_bitmask(c, #relation_components, mask, FULL_BITS.relation_components)

	local relation_tags = group.relation_tags
	for _, rel in relation_tags do
		local targets: Array<Entity> = {}
		local target_index = 0
		while true do
			local target = WORLD_TARGET(world, entity, rel, target_index)
			if not target then
				break
			end
			target_index += 1
			table.insert(targets, target)
		end
		write_relation_targets(self, c, rel, targets)
	end
	mask = write_vlq_bitmask(c, #relation_tags, mask, FULL_BITS.relation_tags)

	local pair_components = group.pair_components
	for _, id in pair_components do
		write_entity_pair_value(self, world, c, id, WORLD_GET(world, entity, id), variants)
	end
	mask = write_vlq_bitmask(c, #pair_components, mask, FULL_BITS.pair_components)

	local pair_tags = group.pair_tags
	for _, id in pair_tags do
		write_entity_pair(self, world, c, id)
	end
	mask = write_vlq_bitmask(c, #pair_tags, mask, FULL_BITS.pair_tags)

	local components = group.components
	for _, component in components do
		write_component_value(self, c, component, WORLD_GET(world, entity, component), variants)
		write_component_id(self, c, component)
	end
	mask = write_vlq_bitmask(c, #components, mask, FULL_BITS.components)

	local tags = group.tags
	for _, component in tags do
		write_component_id(self, c, component)
	end
	mask = write_vlq_bitmask(c, #tags, mask, FULL_BITS.tags)

	cursor.writeu8(c, mask)
	write_entity_id(self, c, entity)
end

local function collect_entity_groups(self: Server, entity: Entity): Map<MaskHash, EntitySerializeGroup>
	local networked = self.networked[entity]
	if not networked or networked.is_dead then
		LOG_ERROR "attempted to collect an entity that is not networked"
	end

	local scratch = self.draft_bitmask
	local groups: Map<MaskHash, EntitySerializeGroup> = {}

	local function emit(bitmask: Bitmask): EntitySerializeGroup
		local hash = bitmasks.hash(bitmask)
		local group = groups[hash]
		if not group then
			group = {
				bitmask = bitmasks.clone(bitmask),
				relation_components = {},
				relation_tags = {},
				pair_components = {},
				pair_tags = {},
				components = {},
				tags = {},
			}
			groups[hash] = group
		end
		return group
	end

	-- everyone who sees the entity at all; storage filters clip within it
	local entity_visible = bitmasks.clone(self.client_active_bitmask)
	local entity_filter = networked.filter
	if entity_filter then
		bitmasks.band(entity_visible, entity_filter, entity_visible)
	end
	if bitmasks.is_empty(entity_visible) then
		return groups
	end
	emit(entity_visible)

	-- nil storage filters resolve to the entity's own visibility
	local function group_for(storage: StorageBase): EntitySerializeGroup?
		local filter = storage.filter
		if not filter then
			return emit(entity_visible)
		end
		bitmasks.band(filter, entity_visible, scratch)
		if bitmasks.is_empty(scratch) then
			return nil
		end
		return emit(scratch)
	end

	local world = self.world
	for rel, storage in networked.relation_storages do
		local group = group_for(storage)
		if not group then
			continue
		end
		table.insert(if storage.is_component then group.relation_components else group.relation_tags, rel)
	end
	for id, storage in networked.pair_storages do
		if not WORLD_HAS(world, entity, id) then
			continue
		end
		local group = group_for(storage)
		if not group then
			continue
		end
		table.insert(if storage.is_component then group.pair_components else group.pair_tags, id)
	end

	for id, storage in networked.unreliable_pair_storages do
		if not WORLD_HAS(world, entity, id) then
			continue
		end
		local group = group_for(storage)
		if group then
			table.insert(group.pair_components, id)
		end
	end
	for component, storage in networked.reliable_storages do
		if not WORLD_HAS(world, entity, component) then
			continue
		end
		local group = group_for(storage)
		if not group then
			continue
		end
		table.insert(if storage.is_component then group.components else group.tags, component)
	end
	for component, storage in networked.unreliable_storages do
		if not WORLD_HAS(world, entity, component) then
			continue
		end
		local group = group_for(storage)
		if group then
			table.insert(group.components, component)
		end
	end

	return groups
end

function server.collect_entity(self: Server, entity: Entity): PacketIterator
	self:resolve_dirty()
	local groups = collect_entity_groups(self, entity)

	local member_updates: Map<number, MemberUpdatePackets> = {}
	for _, group in groups do
		local c = cursor.new()
		local variants: Array<any> = {}
		serialize_entity_group(self, c, entity, group, variants)
		cursor.write_vlq(c, 1)

		local buf = cursor.close(c)
		local size = buffer.len(buf)
		local update: MemberPacket = { buffer = buf, variants = variants }

		bitmasks.iter_set(group.bitmask, function(index)
			local member = member_updates[index]
			if not member then
				member = { total_size = 0, updates = {} }
				member_updates[index] = member
			end
			member.total_size += size
			table.insert(member.updates, update)
		end)
	end

	return create_packet_iterator(self, member_updates, PACKET_TYPES.entity)
end

function server.collect_updates(self: Server): PacketIterator
	self:resolve_dirty()
	local groups = collect_updates_groups(self)
	serialize_update_groups(self, groups)

	return create_packet_iterator(self, distribute_update_groups(groups), PACKET_TYPES.updates)
end

local function create_unreliable_packet_iterator(
	self: Server,
	member_updates: Map<number, MemberUpdatePackets>
): PacketIterator
	local index_clients = self.registry.index_clients

	return coroutine.wrap(function()
		for index, member in member_updates do
			local player = index_clients[index]
			if player == nil then
				LOG_ERROR "packet addressed to a client that is no longer registered, send packets right after collecting"
			end
			local updates = member.updates

			table.sort(updates, function(a, b)
				return buffer.len(a.buffer) < buffer.len(b.buffer)
			end)
			local total_packets = #updates

			local current = 1
			while current <= total_packets do
				local sending: Array<MemberPacket> = {}
				local batch_size = 0

				while current <= total_packets do
					local packet = updates[current]
					local packet_size = buffer.len(packet.buffer)

					-- combine appends the packet count and type byte, so they
					-- count toward the budget
					local next_count = #sending + 1
					local tail = vlq_span(next_count) + PACKET_TYPE_SPAN
					if batch_size + packet_size + tail > MAX_UNRELIABLE_PACKET_SIZE and #sending > 0 then
						break
					end

					table.insert(sending, packet)
					batch_size += packet_size
					current += 1

					if batch_size + tail >= MAX_UNRELIABLE_PACKET_SIZE then
						break
					end
				end

				if #sending > 0 then
					local combined, variants = combine_packet_outputs(sending, batch_size, PACKET_TYPES.unreliable)
					coroutine.yield(player, combined, variants)
				end
			end
		end
	end)
end

function server.collect_unreliable(self: Server): PacketIterator
	self:resolve_dirty()
	local groups = collect_unreliable_groups(self)
	serialize_unreliable_groups(self, groups)
	return create_unreliable_packet_iterator(self, distribute_unreliable_groups(groups))
end

function server.register_player(self: Server, player: Player)
	self.registry:register_client(player)
end

function server.add_player_alias(self: Server, player: Player, alias: any)
	self.registry:add_alias(player, alias)
end

function server.remove_player_alias(self: Server, alias: any)
	self.registry:remove_alias(alias)
end

function server.mark_player_ready(self: Server, player: Player)
	local registry = self.registry
	registry:register_client(player)

	local index = registry.client_indexes[player]
	if index and bitmasks.test(self.client_active_bitmask, index) then
		return
	end
	self.pending_active[player] = true
end

function server.is_player_ready(self: Server, player: Player): boolean
	local index = self.registry.client_indexes[player]
	if not index then
		return false
	end
	return bitmasks.test(self.client_active_bitmask, index)
end

function server.encode_component(self: Server, component: Component): number
	self:resolve_dirty()
	local encoded = self.shared.components.members[component]
	if not encoded then
		LOG_ERROR(`attempted to encode a non-shared component `, common.log_component(self.world, component))
		return 0
	end
	return encoded
end

function server.decode_component(self: Server, encoded: number): Component?
	self:resolve_dirty()
	return self.shared.components.indexes[encoded]
end

function server.get_shared_count(self: Server): number
	self:resolve_dirty()
	return #self.shared.components.keys
end

function server.generate_handshake(self: Server): types.HandshakeInfo
	self:resolve_dirty()
	return handshake.generate_handshake(self.shared)
end

function server.verify_handshake(self: Server, client_handshake: types.HandshakeInfo): (boolean, string?)
	self:resolve_dirty()
	return handshake.verify_handshake(self.shared, client_handshake, "client", "server")
end

@native
local function invalidate_client_index(storage: StorageBase, hole_mask: number, index: number)
	local filter = storage.filter
	if filter then
		bitmasks.punch_hole_mask(filter, hole_mask, index)
	end
	local last_replicated = storage.last_replicated
	if last_replicated then
		bitmasks.punch_hole_mask(last_replicated, hole_mask, index)
	end
end

function server.remove_player(self: Server, player: Player)
	local registry = self.registry
	local index = registry.client_indexes[player]

	if index then
		bitmasks.reset(self.client_active_bitmask, index)
		bitmasks.reset(self.last_active_bitmask, index)

		local hole_mask = bitmasks.get_hole_mask(index)
		for _, networked in self.networked do
			invalidate_client_index(networked, hole_mask, index)
			for _, reliable_storage in networked.reliable_storages do
				invalidate_client_index(reliable_storage, hole_mask, index)
			end
			for _, unreliable_storage in networked.unreliable_storages do
				invalidate_client_index(unreliable_storage, hole_mask, index)
			end
			for _, pair_storage in networked.pair_storages do
				invalidate_client_index(pair_storage, hole_mask, index)
			end
			for _, unreliable_pair_storage in networked.unreliable_pair_storages do
				invalidate_client_index(unreliable_pair_storage, hole_mask, index)
			end
			for _, relation_storage in networked.relation_storages do
				invalidate_client_index(relation_storage, hole_mask, index)
			end
		end
	end

	self.pending_active[player] = nil
	registry:remove_client_aliases(player)
	registry:unregister_client(player)
end

local function hook_tracking_relation(
	self: Server,
	hook: (() -> ()) -> (),
	track_type: Component,
	set: (
		self: Server,
		entity: Entity,
		component: Component,
		filter: FilterInput?
	) -> (),
	stop: (self: Server, entity: Entity, component: Component) -> ()
)
	local world = self.world
	hook(HOOK_ADDED(world, LISTEN_RELATION(track_type), function(entity, id, filter)
		set(self, entity, PAIR_SECOND(world, id), filter)
	end))
	hook(HOOK_CHANGED(world, LISTEN_RELATION(track_type), function(entity, id, filter)
		set(self, entity, PAIR_SECOND(world, id), filter)
	end))
	hook(HOOK_REMOVED(world, LISTEN_RELATION(track_type), function(entity, id)
		stop(self, entity, PAIR_SECOND(world, id))
	end))
end

local function discover_tracking_relation(
	self: Server,
	track_type: Component,
	set: (
		self: Server,
		entity: Entity,
		component: Component,
		filter: FilterInput?
	) -> ()
)
	local world = self.world
	for entity in world.query(PAIR(track_type, WILDCARD)):iter() do
		local index = 0
		while true do
			local component = WORLD_TARGET(world, entity, track_type, index)
			if not component then
				break
			end
			index += 1
			set(self, entity, component, WORLD_GET(world, entity, PAIR(track_type, component)))
		end
	end
end

local function discover_current(self: Server)
	local world = self.world
	local components = self.components

	for component, serdes in world.query(components.serdes):iter() do
		self:set_serdes(component, serdes)
	end

	for entity, filter in world.query(components.networked):iter() do
		self:set_networked(entity, filter)
	end

	if RELATIONSHIPS then
		discover_tracking_relation(self, components.reliable, self.set_reliable)
		discover_tracking_relation(self, components.once, self.set_once)
		discover_tracking_relation(self, components.unreliable, self.set_unreliable)
		discover_tracking_relation(self, components.relation, self.set_relation)

		for entity in world.query(PAIR(components.custom, WILDCARD)):iter() do
			local handler = WORLD_TARGET(world, entity, components.custom, 0)
			if handler then
				self:set_custom(entity, handler)
			end
		end
	end
end

function server.init(self: Server, wrd: World?)
	if self.inited == true then
		return common.log_warn "attempted to init a server twice"
	end
	if self.inited == nil then
		return common.log_warn "attempted to re-init a destroyed server"
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

	hook(HOOK_ADDED(world, components.networked, function(entity, _, filter)
		self:set_networked(entity, filter)
	end))
	hook(HOOK_CHANGED(world, components.networked, function(entity, _, filter)
		self:set_networked(entity, filter)
	end))
	hook(HOOK_REMOVED(world, components.networked, function(entity)
		self:stop_networked(entity)
	end))

	if RELATIONSHIPS then
		hook_tracking_relation(self, hook, components.reliable, self.set_reliable, self.stop_reliable)
		hook_tracking_relation(self, hook, components.once, self.set_once, self.stop_once)
		hook_tracking_relation(self, hook, components.unreliable, self.set_unreliable, self.stop_unreliable)
		hook_tracking_relation(self, hook, components.relation, self.set_relation, self.stop_relation)

		hook(HOOK_ADDED(world, LISTEN_RELATION(components.custom), function(entity, id)
			if not IS_PAIR(id) then
				LOG_ERROR "replecs.custom should be used as a pair in the server: pair(custom, handler)"
			end
			self:set_custom(entity, PAIR_SECOND(world, id))
		end))
		hook(HOOK_REMOVED(world, LISTEN_RELATION(components.custom), function(entity)
			self:remove_custom(entity)
		end))
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

	hook(HOOK_REMOVED(world, components.__alive_tracking__, function(entity)
		self:cleanup_entity(entity)
	end))

	discover_current(self)

	if game and game:GetService("RunService"):IsServer() then
		local Players = game:GetService "Players"

		local added = Players.PlayerAdded:Connect(function(player)
			self:register_player(player)
		end)
		local removing = Players.PlayerRemoving:Connect(function(player)
			self:remove_player(player)
		end)
		for _, player in Players:GetPlayers() do
			self:register_player(player)
		end

		hook(function()
			added:Disconnect()
			removing:Disconnect()
		end)
	end

	self.is_shared_dirty = true
end

function server.destroy(self: Server)
	if self.inited == nil then
		return common.log_warn "attempted to destroy a server twice"
	end
	self.inited = nil
	for _, cleanup in self.cleanups do
		cleanup()
	end
	table.clear(self.cleanups)
end

function server.create(world: World?, components: types.Components?, max_clients: number?): Server
	local self = {} :: Server

	self.world = world :: any
	self.components = components or (if world then utils.create_world_components(world) else nil) :: any
	self.inited = false

	self.registry = registry.create(max_clients or DEFAULT_MAX_CLIENTS)
	self.bitmask_size = self.registry.bitmask_size
	self.ready_players_bitmask = buffer.create(self.bitmask_size)
	self.shared = {} :: types.Shared

	self.networked = {}
	self.unreliable_networked = {}
	self.postponed_components = {}
	self.entity_serialization = {}
	self.registered_custom_ids = {}
	self.component_serialization = {}
	-- starts dirty so the first resolve_dirty builds the lookups
	self.is_shared_dirty = true

	self.hooked_components = {}
	self.hooked_unreliable = {}
	self.hooked_relations = {}
	self.hooked_pairs = {}
	self.hooked_unreliable_pairs = {}

	self.dirty_networked = {}
	self.function_filters = {}

	self.empty_bitmask = buffer.create(self.bitmask_size)
	self.draft_bitmask = buffer.create(self.bitmask_size)
	self.target_bitmask = buffer.create(self.bitmask_size)
	self.filled_bitmask = buffer.create(self.bitmask_size)
	buffer.fill(self.filled_bitmask, 0, 0xFF, self.bitmask_size)

	self.client_active_bitmask = buffer.create(self.bitmask_size)
	self.last_active_bitmask = buffer.create(self.bitmask_size)
	self.newly_active_bitmask = buffer.create(self.bitmask_size)
	self.newly_unactive_bitmask = buffer.create(self.bitmask_size)
	self.pending_active = {}

	self.entity_bitmask_deltas = {
		added = buffer.create(self.bitmask_size),
		removed = buffer.create(self.bitmask_size),
	}
	self.component_bitmask_deltas = {
		added = buffer.create(self.bitmask_size),
		removed = buffer.create(self.bitmask_size),
	}

	self.cleanups = {}
	return setmetatable(self, server) :: any
end

return {
	create = server.create,

	collect_updates_groups = function(self: Server): Map<MaskHash, SerializeGroup>
		self:resolve_dirty()
		return collect_updates_groups(self)
	end,
	collect_unreliable_groups = function(self: Server): Map<MaskHash, UnreliableSerializeGroup>
		self:resolve_dirty()
		return collect_unreliable_groups(self)
	end,
	serialize_update_groups = serialize_update_groups,
	serialize_unreliable_groups = serialize_unreliable_groups,
	collect_entity_groups = function(self: Server, entity: Entity): Map<MaskHash, EntitySerializeGroup>
		self:resolve_dirty()
		return collect_entity_groups(self, entity)
	end,
}
