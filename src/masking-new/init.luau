--!optimize 2
local common = require "./common"

type Member = any
type Bitmask = buffer
type BitmaskHash = string
type Bitset = number
type TrackingType = number
type BitmaskListener = () -> ()

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }

type Entity = common.Entity
type Component<T = any> = common.Component<T>

type BitmaskListenerConnections = {
	listeners: { BitmaskListener },
	listeners_indexes: { [BitmaskListener]: number },
}

type ComponentListenerGenerator = (entity_bitmask: Bitmask?) -> BitmaskListener

export type ComponentIndex<T> = {
	[TrackingType]: Map<Component, T>,
}

export type EntityComponentIndex<T> = {
	[Entity]: ComponentIndex<T>,
}

export type Lookup = {
	bitmask_listener: BitmaskListener,
	storage_group: StorageGroup,
	used_filter: any?,

	filter_bitmask: Bitmask?,
	calculated_bitmask: Bitmask?,
}

export type ComponentLookup = Lookup & {
	listener_generator: ComponentListenerGenerator,
}

export type EntityLookup = Lookup & {
	filtered_components: ComponentIndex<ComponentLookup>,
	unfiltered_components: ComponentIndex<boolean>,
	component_listeners: BitmaskListenerConnections,
}

type BitmaskDeltas = {
	added: Bitmask,
	removed: Bitmask,
}

type LastReplicatedComponentLookup = {
	bitmask: Bitmask,
	added_storage: StorageGroup?,
	removed_storage: StorageGroup?,
}

type LastReplicatedLookup = {
	bitmask: Bitmask,
	added_storage: StorageGroup?,
	removed_storage: StorageGroup?,
	components: ComponentIndex<LastReplicatedComponentLookup>,
}

type LookupsList = {
	entities: Map<Entity, EntityLookup>,

	last_replicated: Map<Entity, LastReplicatedLookup>,

	-- list of components that were started without the entity active
	postponed_components: Map<Entity, ComponentIndex<{ filter: any? }>>,
}

export type ActiveEntity = {
	components: ComponentIndex<boolean>,
	components_count: number,
	unreliable_count: number,
	is_entity_mask: boolean,
}

export type EntityChanges = {
	changed: ComponentIndex<any>,
	removed: ComponentIndex<any>,

	-- these are just aliases for changes.changed, and changes.removed
	-- changes need specific types, so you access these if you need the types, as the other ones are just arrays
	tag_removed: Set<Component>,
	component_removed: Set<Component>,
	unreliable_removed: Set<Component>,
	unreliable_pair_removed: Set<Component>,
	pair_tag_removed: Set<Component>,
	pair_component_removed: Set<Component>,
	relation_tag_removed: { [Component]: Set<Entity> },
	relation_component_removed: { [Component]: Set<Entity> },

	tag_added: Set<Component>,
	component_changed: Map<Component, any>,
	unreliable_added: Set<Component>,
	unreliable_pair_added: Set<Component>,
	pair_tag_added: Set<Component>,
	pair_component_changed: Map<Component, any>,
	relation_tag_added: { [Component]: Set<Entity> },
	relation_component_changed: { [Component]: Map<Entity, any> },
}

type StorageChanges = {
	components_deltas: EntityComponentIndex<boolean>,
	entity_added_deltas: Set<Entity>,
	entity_removed_deltas: Set<Entity>,
	entity_changes: Map<Entity, EntityChanges>,
}

type MaskInfo = {
	bitmask: Bitmask,
	hash: BitmaskHash,
	members: { Member },
}

type StorageGroup = {
	kind: Bitset,
	kind_index: number,
	mask: MaskInfo,

	shared_with: EntityComponentIndex<boolean>,

	active_entities: Map<Entity, ActiveEntity>,
	iterable: boolean,
	active_count: number,
	-- always equals the sum of unreliable_count of all attached active entities
	-- its a pain to keep this in sync, so be careful when working with this.
	unreliable_count: number,
	-- set of attached active entities with one or more unreliable components
	unreliable_entities: Set<Entity>,

	storage_changes: StorageChanges,
}

type StorageIndex = {
	[BitmaskHash]: StorageGroup,
}

-- stylua: ignore start
local STORAGE_ACTIVE_KIND =     0b001
local STORAGE_ITERABLE_KIND =  	0b010
local STORAGE_UNRELIABLE_KIND = 0b100
-- stylua: ignore end

local TRACKING_TYPES = {
	tag = 1,
	component = 2,
	pair_tag = 3,
	pair_component = 4,
	relation = 5,
	relation_component = 6,
	unreliable = 7,
	unreliable_pair = 8,
}

-- TODO: filter_groups

local TRACKING_TYPES_COUNT = TRACKING_TYPES.unreliable_pair

type MaskingControllerClass = {
	COMPACT_THRESHOLD: number,

	member_next_index: number,
	member_count: number,
	member_indexes: Map<Member, number>,

	all_members_bitmask: Bitmask,
	active_members_bitmask: Bitmask,
	unactive_members_bitmask: Bitmask,

	-- snapshot of `active_members_bitmask` as of the last replication cycle
	last_active_bitmask: Bitmask,

	-- members that became active after the last replication cycle (`active_members_bitmask` minus `last_active_bitmask`).
	-- these members are excluded from added deltas, as the user is expected to
	-- manually send them a full state when they activate
	newly_active_bitmask: Bitmask,

	-- members that became unactive after the last replication cycle (`last_active_bitmask` minus `active_members_bitmask`).
	-- these members are excluded from removed deltas, as leaving the active bitmask only
	-- happens when the client is gone, so there is nobody to send deletions to
	newly_unactive_bitmask: Bitmask,

	-- used for temporal (on the fly) operations as an intermediate value, avoids allocations
	-- use bitmask_load to set a working value to process, or bitmask_clear to reset for use.
	draft_bitmask: Bitmask,

	-- represents an empty bitmask filled with zeros, used as reference to avoid allocations. Cannot be mutated
	empty_bitmask: Bitmask,

	-- only one bitmask delta is used to avoid allocations, since result is always needed immediately
	draft_bitmask_deltas: BitmaskDeltas,

	active_bitmask_listeners: BitmaskListenerConnections,
	lookups_list: LookupsList,

	storage_index: StorageIndex,
	storage_kinds: {
		[Bitset]: Array<StorageGroup>,
	},
}

local masking_controller = {}
masking_controller.__index = masking_controller

export type MaskingController = MaskingControllerClass & typeof(masking_controller)

local BITS_PER_ENTRY = 32
local BYTES_PER_ENTRY = 4

local function connect_bitmask_listener(connections: BitmaskListenerConnections, listener: BitmaskListener)
	local index = #connections.listeners + 1
	connections.listeners[index] = listener
	connections.listeners_indexes[listener] = index
end

local function disconnect_bitmask_listener(connections: BitmaskListenerConnections, listener: BitmaskListener)
	local index = connections.listeners_indexes[listener]
	if not index then
		return
	end

	local last_listener = table.remove(connections.listeners)
	if last_listener and last_listener ~= listener then
		connections.listeners[index] = last_listener
		connections.listeners_indexes[last_listener] = index
	end
	connections.listeners_indexes[listener] = nil
end

local function run_bitmask_listeners(connections: BitmaskListenerConnections)
	for _, listener in connections.listeners do
		listener()
	end
end

local function swap_bitmask_listener(
	connections: BitmaskListenerConnections,
	old_listener: BitmaskListener,
	new_listener: BitmaskListener
)
	local index = connections.listeners_indexes[old_listener]
	if not index then
		return
	end
	connections.listeners[index] = new_listener
	connections.listeners_indexes[new_listener] = index
	connections.listeners_indexes[old_listener] = nil
end

local function to_binary(n: number): string
	if n == 0 then
		return "0"
	end

	local result = ""
	while n > 0 do
		result = (n % 2) .. result
		n = math.floor(n / 2)
	end
	return string.rep("0", 32 - #result) .. result
end

local function bitmask_get_buffer_size(bits: number)
	return math.ceil(bits / BITS_PER_ENTRY) * BYTES_PER_ENTRY
end

@native
local function bitmask_band(a: Bitmask, b: Bitmask, output: Bitmask)
	local len_a = buffer.len(a)
	local len_b = buffer.len(b)
	local len_min = math.min(len_a, len_b)

	for offset = 0, buffer.len(output) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		if offset >= len_min then
			buffer.writeu32(output, offset, 0)
		else
			local a_val = buffer.readu32(a, offset)
			local b_val = buffer.readu32(b, offset)
			buffer.writeu32(output, offset, bit32.band(a_val, b_val))
		end
	end
end

@native
local function bitmask_read_entry(bitmask: Bitmask, len: number, offset: number)
	if offset >= len then
		return 0
	else
		return buffer.readu32(bitmask, offset)
	end
end

@native
local function bitmask_bor(a: Bitmask, b: Bitmask, output: Bitmask)
	local len_a = buffer.len(a)
	local len_b = buffer.len(b)

	for offset = 0, buffer.len(output) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		local a_val = bitmask_read_entry(a, len_a, offset)
		local b_val = bitmask_read_entry(b, len_b, offset)
		buffer.writeu32(output, offset, bit32.bor(a_val, b_val))
	end
end

@native
local function bitmask_get_index(index: number): (number, number)
	local entry_index = math.floor(index / BITS_PER_ENTRY)
	local bit_position = index % BITS_PER_ENTRY
	return entry_index, bit_position
end

@native
local function bitmask_set(bitmask: Bitmask, index: number)
	local entry, offset = bitmask_get_index(index)
	local buffer_offset = entry * BYTES_PER_ENTRY
	local len = buffer.len(bitmask)
	if buffer_offset >= len then
		return
	end

	local current = buffer.readu32(bitmask, buffer_offset)
	local mask = bit32.lshift(1, offset)
	buffer.writeu32(bitmask, buffer_offset, bit32.bor(current, mask))
end

@native
local function bitmask_reset(bitmask: Bitmask, index: number)
	local entry, offset = bitmask_get_index(index)
	local buffer_offset = entry * BYTES_PER_ENTRY
	local len = buffer.len(bitmask)
	if buffer_offset >= len then
		return
	end

	local current = buffer.readu32(bitmask, buffer_offset)
	local mask = bit32.bnot(bit32.lshift(1, offset))
	buffer.writeu32(bitmask, buffer_offset, bit32.band(current, mask))
end

@native
local function bitmask_test(bitmask: Bitmask, index: number): boolean
	local entry, offset = bitmask_get_index(index)
	local buffer_offset = entry * BYTES_PER_ENTRY

	local len = buffer.len(bitmask)
	if buffer_offset >= len then
		return false
	end

	local current = buffer.readu32(bitmask, buffer_offset)
	local value = bit32.band(bit32.rshift(current, offset), 1)
	return value == 1
end

@native
local function bitmask_exclude(base: Bitmask, exclude: Bitmask, output: Bitmask)
	local len_base = buffer.len(base)
	local len_exclude = buffer.len(exclude)

	for offset = 0, buffer.len(output) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		local base_val = bitmask_read_entry(base, len_base, offset)
		local exclude_val = bitmask_read_entry(exclude, len_exclude, offset)
		buffer.writeu32(output, offset, bit32.band(base_val, bit32.bnot(exclude_val)))
	end
end

-- clones the buffer into a draft
@native
local function bitmask_load(source: Bitmask, target: Bitmask)
	local source_len = buffer.len(source)
	local target_len = buffer.len(target)

	buffer.copy(target, 0, source, 0)
	local difference = target_len - source_len
	if difference > 0 then
		buffer.fill(target, source_len, 0, difference)
	end
end

-- clones the buffer into a draft
@native
local function bitmask_clear(bitmask: Bitmask)
	buffer.fill(bitmask, 0, 0)
end

local function bitmask_clone(template: Bitmask, size: number?)
	local buf_len = buffer.len(template)
	local cloned = buffer.create((size and math.max(size, buf_len)) or buf_len)
	buffer.copy(cloned, 0, template, 0)
	return cloned
end

-- remaps bitmask indexes.
-- this can return the same bitmask if new allocation isnt necessary.
@native
local function bitmask_remap(
	bitmask: Bitmask,
	draft: Bitmask,
	from: Map<Member, number>,
	target: Map<Member, number>,
	size: number
): Bitmask
	bitmask_clear(draft)

	for member, index in target do
		local old_index = from[member]
		if old_index and bitmask_test(bitmask, old_index) then
			bitmask_set(draft, index)
		end
	end

	local needed_len = math.ceil(size / BITS_PER_ENTRY) * BYTES_PER_ENTRY
	local output = bitmask

	if needed_len > buffer.len(bitmask) then
		output = buffer.create(needed_len)
	end

	local output_len = buffer.len(output)
	local copy_len = math.min(output_len, buffer.len(draft))
	buffer.copy(output, 0, draft, 0, copy_len)

	if output_len > copy_len then
		buffer.fill(output, copy_len, 0, output_len - copy_len)
	end
	return output
end

@native
local function bitmask_invert(bitmask: Bitmask)
	for offset = 0, buffer.len(bitmask) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		buffer.writeu32(bitmask, offset, bit32.bnot(buffer.readu32(bitmask, offset)))
	end
end

@native
local function bitmask_is_empty(bitmask: Bitmask): boolean
	for offset = 0, buffer.len(bitmask) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		if buffer.readu32(bitmask, offset) ~= 0 then
			return false
		end
	end
	return true
end

local HASHING_BYTES = table.create(6)

@native
local function bitmask_hash(bitmask: Bitmask)
	local highest_entry = -1

	for i = buffer.len(bitmask) - BYTES_PER_ENTRY, 0, -BYTES_PER_ENTRY do
		local value = buffer.readu32(bitmask, i)
		if value ~= 0 then
			highest_entry = i
			break
		end
	end

	if highest_entry == -1 then
		return ""
	end

	if false then
		table.clear(HASHING_BYTES)

		for i = 0, highest_entry, BYTES_PER_ENTRY do
			table.insert(HASHING_BYTES, buffer.readu32(bitmask, i))
		end
		return table.concat(HASHING_BYTES, "-")
	else
		-- enable this to stringify to binary, easier to debug, but slower

		local hash_str = ""
		for i = 0, highest_entry, BYTES_PER_ENTRY do
			hash_str = hash_str .. to_binary(buffer.readu32(bitmask, i))
		end

		return hash_str
	end
end

@native
local function calculate_bitmask_deltas(last: Bitmask, target: Bitmask, output: BitmaskDeltas)
	local len_last = buffer.len(last)
	local len_target = buffer.len(target)
	local added = output.added
	local removed = output.removed

	-- we asume the output have been loaded, this means it has been cleared
	local len_added = buffer.len(added)
	local len_removed = buffer.len(removed)

	for offset = 0, math.max(len_added, len_removed) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		local last_val = bitmask_read_entry(last, len_last, offset)
		local target_val = bitmask_read_entry(target, len_target, offset)

		local added_delta = bit32.band(target_val, bit32.bnot(last_val))
		local removed_delta = bit32.band(last_val, bit32.bnot(target_val))

		buffer.writeu32(added, offset, added_delta)
		buffer.writeu32(removed, offset, removed_delta)
	end
end

@native
local function load_bitmask_deltas(deltas: BitmaskDeltas)
	buffer.fill(deltas.added, 0, 0)
	buffer.fill(deltas.removed, 0, 0)
end

@native
local function create_bitmask_from_function(masking: MaskingController, predicator: (Member) -> boolean): Bitmask
	local entries = math.ceil(masking.member_next_index / BITS_PER_ENTRY)
	local bitmask = buffer.create(entries * BYTES_PER_ENTRY)
	local active_bitmask = masking.active_members_bitmask

	for member, index in masking.member_indexes do
		if not bitmask_test(active_bitmask, index) then
			continue
		end

		local include = predicator(member)
		if not include then
			continue
		end

		local entry, offset = bitmask_get_index(index)
		local buffer_offset = entry * BYTES_PER_ENTRY
		local current = buffer.readu32(bitmask, buffer_offset)
		local set_mask = bit32.lshift(1, offset)
		buffer.writeu32(bitmask, buffer_offset, bit32.bor(current, set_mask))
	end
	return bitmask
end

@native
local function create_bitmask_from_set(masking: MaskingController, member_set: Map<Member, boolean>): Bitmask
	local entries = math.ceil(masking.member_next_index / BITS_PER_ENTRY)
	local bitmask = buffer.create(entries * BYTES_PER_ENTRY)
	-- TODO: use aliases

	for member in member_set do
		local index = masking.member_indexes[member]
		if not index then
			continue
		end

		local entry, offset = bitmask_get_index(index)
		local buffer_offset = entry * BYTES_PER_ENTRY
		local current = buffer.readu32(bitmask, buffer_offset)
		local set_mask = bit32.lshift(1, offset)
		buffer.writeu32(bitmask, buffer_offset, bit32.bor(current, set_mask))
	end

	return bitmask
end

@native
local function create_bitmask_from_member(masking: MaskingController, member: Member): Bitmask
	-- TODO: use aliases
	local index = masking.member_indexes[member]
	local entries = math.floor(index / BITS_PER_ENTRY) + 1
	local bitmask = buffer.create(entries * BYTES_PER_ENTRY)

	local entry, offset = bitmask_get_index(index)
	local buffer_offset = entry * BYTES_PER_ENTRY
	buffer.writeu32(bitmask, buffer_offset, bit32.lshift(1, offset))
	return bitmask
end

@native
local function get_members_from_bitmask(masking: MaskingController, bitmask: Bitmask): Array<Member>
	local members: { Member } = {}
	for member, index in masking.member_indexes do
		if bitmask_test(bitmask, index) then
			table.insert(members, member)
		end
	end
	return members
end

local function insert_storage_in_kind(masking: MaskingController, storage: StorageGroup, kind: Bitset)
	local storage_kind = masking.storage_kinds[kind]
	if storage_kind then
		table.insert(storage_kind, storage)
		storage.kind_index = #storage_kind
	else
		masking.storage_kinds[kind] = { storage }
		storage.kind_index = 1
	end
end

local function remove_storage_from_kind(masking: MaskingController, storage: StorageGroup)
	local storage_kind = masking.storage_kinds[storage.kind]
	local kind_index = storage.kind_index

	local last_storage = table.remove(storage_kind)
	if last_storage and last_storage ~= storage then
		last_storage.kind_index = kind_index
		storage_kind[kind_index] = last_storage
	end
	storage.kind_index = -1
end

@native
local function recalculate_storage_kind(masking: MaskingController, storage: StorageGroup)
	local new_kind = 0

	if storage.active_count > 0 then
		new_kind = bit32.bor(new_kind, STORAGE_ACTIVE_KIND)
	end
	if storage.iterable then
		new_kind = bit32.bor(new_kind, STORAGE_ITERABLE_KIND)
	end
	if storage.unreliable_count > 0 then
		new_kind = bit32.bor(new_kind, STORAGE_UNRELIABLE_KIND)
	end
	if new_kind == storage.kind then
		return
	end

	local kind_index = storage.kind_index
	local old_storage_kind = masking.storage_kinds[storage.kind]
	local last_storage = table.remove(old_storage_kind)

	if last_storage and storage ~= last_storage then
		last_storage.kind_index = kind_index
		old_storage_kind[kind_index] = last_storage
	end

	storage.kind = new_kind
	local new_storage_kind = masking.storage_kinds[new_kind]
	if new_storage_kind then
		table.insert(new_storage_kind, storage)
		storage.kind_index = #new_storage_kind
	else
		masking.storage_kinds[new_kind] = { storage }
		storage.kind_index = 1
	end
end

local function mark_storage_iterable(masking: MaskingController, storage: StorageGroup)
	if not storage.iterable then
		storage.iterable = true
		recalculate_storage_kind(masking, storage)
	end
end

local function recalculate_active_members_bitmask(masking: MaskingController)
	bitmask_exclude(masking.all_members_bitmask, masking.unactive_members_bitmask, masking.active_members_bitmask)
	bitmask_exclude(masking.active_members_bitmask, masking.last_active_bitmask, masking.newly_active_bitmask)
	bitmask_exclude(masking.last_active_bitmask, masking.active_members_bitmask, masking.newly_unactive_bitmask)
	run_bitmask_listeners(masking.active_bitmask_listeners)
end

local function create_bitmask_listeners(): BitmaskListenerConnections
	return {
		listeners = {},
		listeners_indexes = {},
	}
end

local function create_component_index<T>(): ComponentIndex<T>
	local indexes = {}
	for i = 1, TRACKING_TYPES_COUNT do
		indexes[i] = {}
	end
	return indexes
end

local function create_active_entity(): ActiveEntity
	return {
		components = create_component_index() :: ComponentIndex<boolean>,
		components_count = 0,
		unreliable_count = 0,
		is_entity_mask = false,
	}
end

local function create_entity_changes(): EntityChanges
	local tag_removed = {}
	local component_removed = {}
	local unreliable_removed = {}
	local unreliable_pair_removed = {}
	local pair_tag_removed = {}
	local pair_component_removed = {}
	local relation_tag_removed = {}
	local relation_component_removed = {}

	local tag_added = {}
	local component_changed = {}
	local unreliable_added = {}
	local unreliable_pair_added = {}
	local pair_tag_added = {}
	local pair_component_changed = {}
	local relation_tag_added = {}
	local relation_component_changed = {}

	local changed_changes = create_component_index() :: ComponentIndex<any>
	local removed_changes = create_component_index() :: ComponentIndex<any>

	changed_changes[TRACKING_TYPES.tag] = tag_added
	changed_changes[TRACKING_TYPES.component] = component_changed

	changed_changes[TRACKING_TYPES.unreliable] = unreliable_added
	changed_changes[TRACKING_TYPES.unreliable_pair] = unreliable_pair_added

	changed_changes[TRACKING_TYPES.pair_tag] = pair_tag_added
	changed_changes[TRACKING_TYPES.pair_component] = pair_component_changed

	changed_changes[TRACKING_TYPES.relation] = relation_tag_added
	changed_changes[TRACKING_TYPES.relation_component] = relation_component_changed

	removed_changes[TRACKING_TYPES.tag] = tag_removed
	removed_changes[TRACKING_TYPES.component] = component_removed

	removed_changes[TRACKING_TYPES.unreliable] = unreliable_removed
	removed_changes[TRACKING_TYPES.unreliable_pair] = unreliable_pair_removed

	removed_changes[TRACKING_TYPES.pair_tag] = pair_tag_removed
	removed_changes[TRACKING_TYPES.pair_component] = pair_component_removed

	removed_changes[TRACKING_TYPES.relation] = relation_tag_removed
	removed_changes[TRACKING_TYPES.relation_component] = relation_component_removed

	return {
		removed = removed_changes,
		changed = changed_changes,

		tag_removed = tag_removed,
		component_removed = component_removed,
		unreliable_removed = unreliable_removed,
		unreliable_pair_removed = unreliable_pair_removed,
		pair_tag_removed = pair_tag_removed,
		pair_component_removed = pair_component_removed,
		relation_tag_removed = relation_tag_removed,
		relation_component_removed = relation_component_removed,

		tag_added = tag_added,
		component_changed = component_changed,
		unreliable_added = unreliable_added,
		unreliable_pair_added = unreliable_pair_added,
		pair_tag_added = pair_tag_added,
		pair_component_changed = pair_component_changed,
		relation_tag_added = relation_tag_added,
		relation_component_changed = relation_component_changed,
	}
end

local function create_storage_group(
	masking: MaskingController,
	bitmask: Bitmask,
	precomputed_hash: string?
): StorageGroup
	local hash = precomputed_hash or bitmask_hash(bitmask)

	local storage: StorageGroup = {
		kind = 0,
		kind_index = -1,

		mask = {
			bitmask = bitmask_clone(bitmask, bitmask_get_buffer_size(masking.COMPACT_THRESHOLD)),
			hash = hash,
			members = get_members_from_bitmask(masking, bitmask),
		},

		iterable = false,
		active_count = 0,
		unreliable_count = 0,
		unreliable_entities = {},

		active_entities = {},
		shared_with = {},

		storage_changes = {
			components_deltas = {},
			entity_added_deltas = {},
			entity_removed_deltas = {},
			entity_changes = {},
		},
	}

	masking.storage_index[hash] = storage
	insert_storage_in_kind(masking, storage, 0)

	return storage
end

local function set_component_index_entry<T>(
	index: EntityComponentIndex<T>,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	value: T
)
	local entity_index = index[entity]
	if entity_index == nil then
		entity_index = create_component_index()
		index[entity] = entity_index
	end
	entity_index[track_type][component] = value
end

local function remove_component_index_entry(
	index: EntityComponentIndex<any>,
	entity: Entity,
	component: Component,
	track_type: TrackingType
)
	local entity_index = index[entity]
	if entity_index then
		entity_index[track_type][component] = nil
	end
end

local function is_include_filter(filter: Set<Member>): boolean
	for _, allow in filter do
		return allow
	end
	return true
end

local function get_used_filter_type(filter: any)
	if typeof(filter) == "table" then
		return is_include_filter(filter)
	else
		return true
	end
end

local function get_component_lookup(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType
): (ComponentLookup, EntityLookup)
	local entity_lookup = masking.lookups_list.entities[entity]
	if not entity_lookup then
		return nil :: any, nil :: any
	end

	return entity_lookup.filtered_components[track_type][component], entity_lookup
end

local function get_component_storage(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType
): StorageGroup
	local component_lookup, entity_lookup = get_component_lookup(masking, entity, component, track_type)

	if component_lookup then
		return component_lookup.storage_group
	elseif entity_lookup then
		return entity_lookup.storage_group
	else
		return common.log_error "attempted to use an entity that is not active"
	end
end

local function ensure_storage_group(masking: MaskingController, bitmask: Bitmask): StorageGroup
	local hash = bitmask_hash(bitmask)
	local storage = masking.storage_index[hash]

	if not storage then
		return create_storage_group(masking, bitmask, hash)
	end
	return storage
end

local function get_usable_last_replicated(masking: MaskingController, current: Bitmask?): Bitmask
	if current then
		if current == masking.empty_bitmask then
			return current
		end
		return bitmask_clone(current)
	else
		return bitmask_clone(masking.active_members_bitmask)
	end
end

local function ensure_entity_last_replicated(
	masking: MaskingController,
	entity: Entity,
	current: Bitmask?
): LastReplicatedLookup
	local lookups_list = masking.lookups_list
	local last_replicated = lookups_list.last_replicated[entity]

	if last_replicated then
		return last_replicated
	end

	local new_last_replicated: LastReplicatedLookup = {
		bitmask = get_usable_last_replicated(masking, current),
		added_storage = nil,
		removed_storage = nil,
		components = create_component_index() :: ComponentIndex<LastReplicatedComponentLookup>,
	}
	lookups_list.last_replicated[entity] = new_last_replicated
	return new_last_replicated
end

local function ensure_component_last_replicated(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	current: Bitmask?,
	entity_bitmask: Bitmask?
): LastReplicatedComponentLookup
	local last_replicated = ensure_entity_last_replicated(masking, entity, entity_bitmask)

	local last_component_replicated = last_replicated.components[track_type][component]
	if last_component_replicated then
		return last_component_replicated
	end

	local new_last_component_replicated: LastReplicatedComponentLookup = {
		bitmask = get_usable_last_replicated(masking, current),
		added_storage = nil,
		removed_storage = nil,
	}
	last_replicated.components[track_type][component] = new_last_component_replicated
	return new_last_component_replicated
end

local function ensure_active_entity(
	masking: MaskingController,
	storage: StorageGroup,
	entity: Entity,
	use_active: ActiveEntity?
): ActiveEntity
	local current_active = storage.active_entities[entity]

	if current_active == nil then
		local new_active = use_active or create_active_entity()
		storage.active_entities[entity] = new_active

		local needs_recalculate = storage.active_count <= 0
			or (storage.unreliable_count <= 0 and new_active.unreliable_count > 0)

		storage.active_count += 1
		storage.unreliable_count += new_active.unreliable_count
		if new_active.unreliable_count > 0 then
			storage.unreliable_entities[entity] = true
		end

		if needs_recalculate then
			recalculate_storage_kind(masking, storage)
		end
		return new_active
	end
	return current_active
end

-- same as ensure_active_entity, but does not recalculate storage
-- used for optimization if the active_entities storage is manipulated multiple times
local function ensure_storage_active_entity(storage: StorageGroup, entity: Entity, use_active: ActiveEntity?)
	local current_active = storage.active_entities[entity]

	if current_active == nil then
		local new_active = use_active or create_active_entity()
		storage.active_entities[entity] = new_active
		storage.unreliable_count += new_active.unreliable_count
		if new_active.unreliable_count > 0 then
			storage.unreliable_entities[entity] = true
		end

		storage.active_count += 1
		return new_active
	end
	return current_active
end

-- storage must be the storage the active is currently attached to, or nil if detached
local function ensure_active_component(
	masking: MaskingController,
	storage: StorageGroup?,
	entity: Entity,
	active: ActiveEntity,
	component: Component,
	track_type: TrackingType
): boolean
	local components = active.components[track_type]
	if components[component] == nil then
		components[component] = true
		active.components_count += 1

		if track_type == TRACKING_TYPES.unreliable or track_type == TRACKING_TYPES.unreliable_pair then
			local was_zero = active.unreliable_count <= 0
			active.unreliable_count += 1

			if storage then
				if was_zero then
					storage.unreliable_entities[entity] = true
				end

				if storage.unreliable_count <= 0 then
					storage.unreliable_count += 1
					recalculate_storage_kind(masking, storage)
				else
					storage.unreliable_count += 1
				end
			end
		end

		return true
	end
	return false
end

local function ensure_entity_changes(
	masking: MaskingController,
	storage: StorageGroup,
	entity: Entity,
	use_changes: EntityChanges?
): EntityChanges
	local storage_changed = storage.storage_changes.entity_changes[entity]
	if storage_changed == nil then
		storage_changed = use_changes or create_entity_changes()
		storage.storage_changes.entity_changes[entity] = storage_changed

		mark_storage_iterable(masking, storage)
	end
	return storage_changed
end

local function remove_active_entity(masking: MaskingController, storage: StorageGroup, entity: Entity)
	local active = storage.active_entities[entity]
	if active ~= nil then
		storage.active_entities[entity] = nil
		storage.active_count -= 1
		if active.unreliable_count > 0 then
			storage.unreliable_count -= active.unreliable_count
			storage.unreliable_entities[entity] = nil
		end

		if storage.active_count <= 0 then
			recalculate_storage_kind(masking, storage)
		end
	end
end

-- storage must be the storage the active is currently attached to, or nil if detached
local function remove_active_component(
	storage: StorageGroup?,
	entity: Entity,
	active: ActiveEntity,
	component: Component,
	track_type: TrackingType
): boolean
	local components = active.components[track_type]
	if components[component] ~= nil then
		components[component] = nil
		active.components_count -= 1

		if track_type == TRACKING_TYPES.unreliable or track_type == TRACKING_TYPES.unreliable_pair then
			active.unreliable_count -= 1
			if storage then
				storage.unreliable_count -= 1
				if active.unreliable_count <= 0 then
					storage.unreliable_entities[entity] = nil
				end
			end
		end

		return true
	end
	return false
end

local function is_active_entity_dead(active: ActiveEntity)
	return active.components_count <= 0 and not active.is_entity_mask
end

-- storage is the storage `active` is attached to; new_active is built detached
local function dissect_component_actives(
	masking: MaskingController,
	storage: StorageGroup,
	entity: Entity,
	active: ActiveEntity,
	shared_with: ComponentIndex<boolean>
): ActiveEntity?
	local new_active: ActiveEntity

	for track_type, shared_components in shared_with do
		for component in shared_components do
			new_active = new_active or create_active_entity()

			ensure_active_component(masking, nil, entity, new_active, component, track_type)
			remove_active_component(storage, entity, active, component, track_type)
		end
	end
	return new_active
end

local function dissect_component_changes(
	entity_changes: EntityChanges,
	shared_with: ComponentIndex<boolean>
): EntityChanges?
	local new_entity_changes: EntityChanges
	local new_changed: ComponentIndex<any>
	local new_removed: ComponentIndex<boolean>

	local changed = entity_changes.changed
	local removed = entity_changes.removed

	for track_type, shared_components in shared_with do
		for component in shared_components do
			local old_changed = changed[track_type][component]
			-- check to nil, because false can be a valid value
			if old_changed ~= nil then
				if not new_entity_changes then
					new_entity_changes = create_entity_changes()
					new_changed = new_entity_changes.changed
					new_removed = new_entity_changes.removed
				end

				new_changed[track_type][component] = old_changed
				changed[track_type][component] = nil
			end

			local old_removed = removed[track_type][component]
			-- check to nil, because false can be a valid value
			if old_removed ~= nil then
				if not new_entity_changes then
					new_entity_changes = create_entity_changes()
					new_changed = new_entity_changes.changed
					new_removed = new_entity_changes.removed
				end

				new_removed[track_type][component] = old_removed
				removed[track_type][component] = nil
			end
		end
	end
	return new_entity_changes
end

-- target_storage is the storage `target` is attached to, or nil if detached
local function merge_component_actives(
	masking: MaskingController,
	target_storage: StorageGroup?,
	entity: Entity,
	source: ActiveEntity,
	target: ActiveEntity
)
	for track_type, components in source.components do
		for component in components do
			ensure_active_component(masking, target_storage, entity, target, component, track_type)
		end
	end
end

local function merge_component_changes(source: EntityChanges, target: EntityChanges)
	local target_changed = target.changed
	local target_removed = target.removed

	for component_type, components_changed in source.changed do
		local destination_components = target_changed[component_type]
		for component, change in components_changed do
			destination_components[component] = change
		end
	end

	for component_type, components_removed in source.removed do
		local destination_components = target_removed[component_type]
		for component, change in components_removed do
			destination_components[component] = change
		end
	end
end

local function merge_deltas(masking: MaskingController, source_storage: StorageGroup, target_storage: StorageGroup)
	local last_replicated_lookups = masking.lookups_list.last_replicated
	local source_changes = source_storage.storage_changes
	local target_changes = target_storage.storage_changes

	if
		next(source_changes.components_deltas)
		or next(source_changes.entity_added_deltas)
		or next(source_changes.entity_removed_deltas)
	then
		mark_storage_iterable(masking, target_storage)
	end

	for entity, components_deltas in source_changes.components_deltas do
		local last_replicated = last_replicated_lookups[entity]

		for track_type, components in components_deltas do
			for component, is_added in components do
				set_component_index_entry(target_changes.components_deltas, entity, component, track_type, is_added)

				local component_last_replicated = last_replicated and last_replicated.components[track_type][component]
				if component_last_replicated then
					if is_added then
						if component_last_replicated.added_storage == source_storage then
							component_last_replicated.added_storage = target_storage
						end
					elseif component_last_replicated.removed_storage == source_storage then
						component_last_replicated.removed_storage = target_storage
					end
				end
			end
		end
	end

	for entity in source_changes.entity_added_deltas do
		target_changes.entity_added_deltas[entity] = true

		local last_replicated = last_replicated_lookups[entity]
		if last_replicated and last_replicated.added_storage == source_storage then
			last_replicated.added_storage = target_storage
		end
	end

	for entity in source_changes.entity_removed_deltas do
		target_changes.entity_removed_deltas[entity] = true

		local last_replicated = last_replicated_lookups[entity]
		if last_replicated and last_replicated.removed_storage == source_storage then
			last_replicated.removed_storage = target_storage
		end
	end
end

local function merge_storages(masking: MaskingController, source_storage: StorageGroup, target_storage: StorageGroup)
	if source_storage == target_storage then
		return
	end

	for entity, source_active in source_storage.active_entities do
		local target_active = ensure_storage_active_entity(target_storage, entity)
		merge_component_actives(masking, target_storage, entity, source_active, target_active)

		if source_active.is_entity_mask then
			local lookup = masking.lookups_list.entities[entity]
			lookup.storage_group = target_storage
			target_active.is_entity_mask = true
		end
	end

	for entity, shared_components in source_storage.shared_with do
		for component_type, components in shared_components do
			for component in components do
				set_component_index_entry(target_storage.shared_with, entity, component, component_type, true)

				local lookup = get_component_lookup(masking, entity, component, component_type)
				if lookup ~= nil then
					lookup.storage_group = target_storage
				end
			end
		end
	end

	merge_deltas(masking, source_storage, target_storage)

	for entity, source_changes in source_storage.storage_changes.entity_changes do
		local target_changes = ensure_entity_changes(masking, target_storage, entity)
		merge_component_changes(source_changes, target_changes)
	end
end

local function update_storage_delta_changes(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	delta: Bitmask,
	current: StorageGroup?,
	value: boolean
): StorageGroup?
	if bitmask_is_empty(delta) then
		if current then
			remove_component_index_entry(current.storage_changes.components_deltas, entity, component, track_type)
		end
		return nil
	else
		local destination = ensure_storage_group(masking, delta)
		if current then
			remove_component_index_entry(current.storage_changes.components_deltas, entity, component, track_type)
		end
		set_component_index_entry(destination.storage_changes.components_deltas, entity, component, track_type, value)
		mark_storage_iterable(masking, destination)
		return destination
	end
end

local function set_component_storage_deltas(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	last_replicated: LastReplicatedComponentLookup,
	deltas: BitmaskDeltas
)
	last_replicated.added_storage = update_storage_delta_changes(
		masking,
		entity,
		component,
		track_type,
		deltas.added,
		last_replicated.added_storage,
		true
	)
	last_replicated.removed_storage = update_storage_delta_changes(
		masking,
		entity,
		component,
		track_type,
		deltas.removed,
		last_replicated.removed_storage,
		false
	)
end

local function update_entity_delta_changes(
	masking: MaskingController,
	entity: Entity,
	delta: Bitmask,
	current: StorageGroup?,
	added: boolean
): StorageGroup?
	if bitmask_is_empty(delta) then
		if current then
			local current_changes = current.storage_changes
			if added then
				current_changes.entity_added_deltas[entity] = nil
			else
				current_changes.entity_removed_deltas[entity] = nil
			end
		end
		return nil
	else
		local destination = ensure_storage_group(masking, delta)
		if current then
			local current_changes = current.storage_changes
			if added then
				current_changes.entity_added_deltas[entity] = nil
			else
				current_changes.entity_removed_deltas[entity] = nil
			end
		end

		local destination_changes = destination.storage_changes
		if added then
			destination_changes.entity_added_deltas[entity] = true
		else
			destination_changes.entity_removed_deltas[entity] = true
		end
		mark_storage_iterable(masking, destination)
		return destination
	end
end

local function set_entity_storage_deltas(
	masking: MaskingController,
	entity: Entity,
	last_replicated: LastReplicatedLookup,
	deltas: BitmaskDeltas
)
	last_replicated.added_storage =
		update_entity_delta_changes(masking, entity, deltas.added, last_replicated.added_storage, true)
	last_replicated.removed_storage =
		update_entity_delta_changes(masking, entity, deltas.removed, last_replicated.removed_storage, false)
end

local function move_entity_storage(
	masking: MaskingController,
	entity: Entity,
	storage: StorageGroup,
	destination: Bitmask
)
	local destination_storage = ensure_storage_group(masking, destination)
	if destination_storage == storage then
		return storage
	end
	local shared_with = storage.shared_with[entity]

	local old_active = storage.active_entities[entity]
	if shared_with then
		local dissected_active = dissect_component_actives(masking, storage, entity, old_active, shared_with)
		if dissected_active then
			-- swap: old_active detaches with its current count, dissected_active attaches with its own
			storage.unreliable_count -= old_active.unreliable_count
			storage.unreliable_count += dissected_active.unreliable_count
			if dissected_active.unreliable_count > 0 then
				storage.unreliable_entities[entity] = true
			elseif old_active.unreliable_count > 0 then
				storage.unreliable_entities[entity] = nil
			end
			storage.active_entities[entity] = dissected_active
		else
			remove_active_entity(masking, storage, entity)
		end
	else
		remove_active_entity(masking, storage, entity)
	end

	local destination_active = ensure_active_entity(masking, destination_storage, entity, old_active)
	if old_active ~= destination_active then
		merge_component_actives(masking, destination_storage, entity, old_active, destination_active)
		destination_active.is_entity_mask = true
	end

	local storage_changes = storage.storage_changes

	local old_changes = storage_changes.entity_changes[entity]
	if old_changes then
		local destination_changes = ensure_entity_changes(masking, destination_storage, entity, old_changes)
		if shared_with then
			local dissected_changes = dissect_component_changes(old_changes, shared_with)
			if dissected_changes then
				storage_changes.entity_changes[entity] = dissected_changes
				mark_storage_iterable(masking, storage)
			else
				storage_changes.entity_changes[entity] = nil
			end
		else
			storage_changes.entity_changes[entity] = nil
		end

		if old_changes ~= destination_changes then
			merge_component_changes(old_changes, destination_changes)
		end
	end

	return destination_storage
end

local function move_component_storage(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	storage: StorageGroup,
	destination: Bitmask
)
	local destination_storage = ensure_storage_group(masking, destination)
	if destination_storage == storage then
		return storage
	end

	local old_active = storage.active_entities[entity]
	if remove_active_component(storage, entity, old_active, component, track_type) then
		if is_active_entity_dead(old_active) then
			remove_active_entity(masking, storage, entity)
		end
	end
	local new_active = ensure_active_entity(masking, destination_storage, entity)
	ensure_active_component(masking, destination_storage, entity, new_active, component, track_type)

	remove_component_index_entry(storage.shared_with, entity, component, track_type)
	set_component_index_entry(destination_storage.shared_with, entity, component, track_type, true)

	local storage_changes = storage.storage_changes

	local entity_changes = storage_changes.entity_changes[entity]
	if entity_changes then
		local change_value = entity_changes.changed[track_type][component]
		if change_value ~= nil then
			local new_entity_changes = ensure_entity_changes(masking, destination_storage, entity)
			new_entity_changes.changed[track_type][component] = change_value
		end

		local removed_value = entity_changes.removed[track_type][component]
		if removed_value ~= nil then
			local new_entity_changes = ensure_entity_changes(masking, destination_storage, entity)
			new_entity_changes.removed[track_type][component] = removed_value
		end
	end

	return destination_storage
end

local function set_entity_storage_from_bitmask(
	masking: MaskingController,
	entity: Entity,
	lookup: EntityLookup,
	bitmask: Bitmask
)
	local current_storage = lookup.storage_group
	if current_storage then
		local new_storage = move_entity_storage(masking, entity, current_storage, bitmask)
		lookup.storage_group = new_storage
	else
		local destination_storage = ensure_storage_group(masking, bitmask)
		local active_entity = ensure_active_entity(masking, destination_storage, entity)
		active_entity.is_entity_mask = true
		lookup.storage_group = destination_storage
	end
end

local function set_component_storage_from_bitmask(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	lookup: ComponentLookup,
	bitmask: Bitmask
)
	local current_storage = lookup.storage_group
	if current_storage then
		local new_storage = move_component_storage(masking, entity, component, track_type, current_storage, bitmask)
		lookup.storage_group = new_storage
	else
		local destination_storage = ensure_storage_group(masking, bitmask)
		local active = ensure_active_entity(masking, destination_storage, entity)
		ensure_active_component(masking, destination_storage, entity, active, component, track_type)
		set_component_index_entry(destination_storage.shared_with, entity, component, track_type, true)

		lookup.storage_group = destination_storage
	end
end

local function merge_component_with_entity(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	entity_lookup: EntityLookup,
	component_lookup: ComponentLookup
)
	local old_storage = component_lookup.storage_group
	local entity_bitmask = entity_lookup.calculated_bitmask or masking.active_members_bitmask

	if old_storage then
		local new_storage = move_component_storage(masking, entity, component, track_type, old_storage, entity_bitmask)
		remove_component_index_entry(new_storage.shared_with, entity, component, track_type)
	else
		set_component_storage_from_bitmask(masking, entity, component, track_type, component_lookup, entity_bitmask)
	end
	entity_lookup.filtered_components[track_type][component] = nil
	entity_lookup.unfiltered_components[track_type][component] = true
end

local function rebind_component_listeners(masking: MaskingController, entity: Entity, lookup: EntityLookup)
	local entity_bitmask = lookup.calculated_bitmask

	for track_type, lookups in lookup.filtered_components do
		for component, component_lookup in lookups do
			local listener_generator = component_lookup.listener_generator
			local old_listener = component_lookup.bitmask_listener
			local listener = listener_generator(entity_bitmask)

			component_lookup.bitmask_listener = listener
			swap_bitmask_listener(lookup.component_listeners, old_listener, listener)
		end
	end
end

local function update_entity_filter(
	masking: MaskingController,
	entity: Entity,
	lookup: EntityLookup,
	filter: Bitmask?,
	include: boolean
): BitmaskListener
	local active_bitmask = masking.active_members_bitmask
	local listeners = lookup.component_listeners

	if filter then
		local calculated_bitmask = lookup.calculated_bitmask :: Bitmask

		if include then
			return function()
				bitmask_band(active_bitmask, filter, calculated_bitmask)
				set_entity_storage_from_bitmask(masking, entity, lookup, calculated_bitmask)
				run_bitmask_listeners(listeners)
			end
		else
			return function()
				bitmask_exclude(active_bitmask, filter, calculated_bitmask)
				set_entity_storage_from_bitmask(masking, entity, lookup, calculated_bitmask)
				run_bitmask_listeners(listeners)
			end
		end
	else
		return function()
			set_entity_storage_from_bitmask(masking, entity, lookup, active_bitmask)
			run_bitmask_listeners(listeners)
		end
	end
end

local function start_entity_bitmask(
	masking: MaskingController,
	entity: Entity,
	filter: Bitmask?,
	include: boolean
): EntityLookup
	local bitmask_len = 0
	if filter then
		if include then
			bitmask_len = buffer.len(filter)
		else
			local active_bitmask = masking.active_members_bitmask
			bitmask_len = buffer.len(active_bitmask)
		end
	end

	local new_lookup: EntityLookup = {
		bitmask_listener = nil :: any,
		storage_group = nil :: any,
		filter_bitmask = filter,
		calculated_bitmask = filter and buffer.create(bitmask_len),

		filtered_components = create_component_index() :: ComponentIndex<ComponentLookup>,
		unfiltered_components = create_component_index() :: ComponentIndex<boolean>,
		component_listeners = create_bitmask_listeners(),
	}
	masking.lookups_list.entities[entity] = new_lookup
	local listener = update_entity_filter(masking, entity, new_lookup, filter, include)
	new_lookup.bitmask_listener = listener
	connect_bitmask_listener(masking.active_bitmask_listeners, listener)
	listener()

	return new_lookup
end

local function ensure_calculated_bitmask_capacity(
	masking: MaskingController,
	lookup: Lookup,
	filter: Bitmask,
	include: boolean
)
	local bitmask_len = 0
	if include then
		bitmask_len = buffer.len(filter)
	else
		bitmask_len = buffer.len(masking.active_members_bitmask)
	end
	local current_bitmask = lookup.calculated_bitmask
	if current_bitmask then
		local current_len = buffer.len(current_bitmask)
		if current_len < bitmask_len then
			-- resizing is needed
			lookup.calculated_bitmask = buffer.create(bitmask_len)
		end
	else
		lookup.calculated_bitmask = buffer.create(bitmask_len)
	end
end

local function set_entity_bitmask(
	masking: MaskingController,
	entity: Entity,
	lookup: EntityLookup,
	filter: Bitmask?,
	include: boolean
)
	if filter then
		ensure_calculated_bitmask_capacity(masking, lookup, filter, include)
	else
		lookup.calculated_bitmask = nil
	end
	lookup.filter_bitmask = filter

	local old_listener = lookup.bitmask_listener
	local listener = update_entity_filter(masking, entity, lookup, filter, include)
	lookup.bitmask_listener = listener
	swap_bitmask_listener(masking.active_bitmask_listeners, old_listener, listener)
	rebind_component_listeners(masking, entity, lookup)
	listener()
end

local function get_or_postpone_entity_lookup(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	filter: any?
): EntityLookup?
	local lookups_list = masking.lookups_list
	local lookup = lookups_list.entities[entity]
	if lookup then
		return lookup
	end

	if filter ~= nil then
		set_component_index_entry(lookups_list.postponed_components, entity, component, track_type, { filter = filter })
	else
		set_component_index_entry(lookups_list.postponed_components, entity, component, track_type, { filter = nil })
	end

	return nil
end

local function update_component_filter(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,

	lookup: ComponentLookup,
	filter: Bitmask,
	include: boolean
): ComponentListenerGenerator
	local calculated_bitmask = lookup.calculated_bitmask :: Bitmask
	local active_bitmask = masking.active_members_bitmask

	return function(entity_bitmask: Bitmask?)
		if entity_bitmask then
			if include then
				return function()
					bitmask_band(entity_bitmask, filter, calculated_bitmask)
					set_component_storage_from_bitmask(masking, entity, component, track_type, lookup, calculated_bitmask)
				end
			else
				return function()
					bitmask_exclude(entity_bitmask, filter, calculated_bitmask)
					set_component_storage_from_bitmask(masking, entity, component, track_type, lookup, calculated_bitmask)
				end
			end
		else
			if include then
				return function()
					bitmask_band(active_bitmask, filter, calculated_bitmask)
					set_component_storage_from_bitmask(masking, entity, component, track_type, lookup, calculated_bitmask)
				end
			else
				return function()
					bitmask_exclude(active_bitmask, filter, calculated_bitmask)
					set_component_storage_from_bitmask(masking, entity, component, track_type, lookup, calculated_bitmask)
				end
			end
		end
	end
end

local function start_component_bitmask(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	entity_lookup: EntityLookup,
	filter: Bitmask,
	include: boolean
): ComponentLookup
	local bitmask_len = 0
	if include then
		bitmask_len = buffer.len(filter)
	else
		local active_bitmask = masking.active_members_bitmask
		bitmask_len = buffer.len(active_bitmask)
	end

	local new_lookup: ComponentLookup = {
		bitmask_listener = nil :: any,
		storage_group = nil :: any,
		listener_generator = nil :: any,
		filter_bitmask = filter,
		calculated_bitmask = buffer.create(bitmask_len),
	}
	entity_lookup.filtered_components[track_type][component] = new_lookup

	local listener_generator = update_component_filter(
		masking,
		entity,
		component,
		track_type,
		--
		new_lookup,
		filter,
		include
	)
	local listener = listener_generator(entity_lookup.calculated_bitmask)

	new_lookup.listener_generator = listener_generator
	new_lookup.bitmask_listener = listener

	connect_bitmask_listener(entity_lookup.component_listeners, listener)
	listener()

	return new_lookup
end

local function set_component_bitmask(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	entity_lookup: EntityLookup,
	filter: Bitmask?,
	include: boolean
): ComponentLookup?
	local component_lookup = entity_lookup.filtered_components[track_type][component]
	if filter == nil then
		if component_lookup ~= nil then
			-- no filter now, filter before
			local old_listener = component_lookup.bitmask_listener
			disconnect_bitmask_listener(entity_lookup.component_listeners, old_listener)

			merge_component_with_entity(masking, entity, component, track_type, entity_lookup, component_lookup)
		end
		return nil
	end

	if component_lookup then
		-- simple filter change
		ensure_calculated_bitmask_capacity(masking, component_lookup, filter, include)
		component_lookup.filter_bitmask = filter

		local old_listener = component_lookup.bitmask_listener
		local listener_generator = update_component_filter(
			masking,
			entity,
			component,
			track_type,
			--
			component_lookup,
			filter,
			include
		)
		local listener = listener_generator(entity_lookup.calculated_bitmask)

		component_lookup.listener_generator = listener_generator
		component_lookup.bitmask_listener = listener

		swap_bitmask_listener(entity_lookup.component_listeners, old_listener, listener)

		listener()
		return component_lookup
	else
		local bitmask_len = 0
		if include then
			bitmask_len = buffer.len(filter)
		else
			local active_bitmask = masking.active_members_bitmask
			bitmask_len = buffer.len(active_bitmask)
		end

		-- no filter before, filter now
		local entity_storage = entity_lookup.storage_group
		local new_lookup: ComponentLookup = {
			filter_bitmask = filter,
			calculated_bitmask = buffer.create(bitmask_len),
			bitmask_listener = nil :: any,
			storage_group = entity_storage,
			listener_generator = nil :: any,
		}
		local listener_generator = update_component_filter(
			masking,
			entity,
			component,
			track_type,
			--
			new_lookup,
			filter,
			include
		)
		local listener = listener_generator(entity_lookup.calculated_bitmask)

		new_lookup.listener_generator = listener_generator
		new_lookup.bitmask_listener = listener

		entity_lookup.filtered_components[track_type][component] = new_lookup
		entity_lookup.unfiltered_components[track_type][component] = nil

		-- component listener should only connect to entity listeners, not active members listeners
		-- because of invariant:
		-- entity = active & entity_filter, component = entity & component_filter. So, component = (active & entity_filter) & component_filter.
		-- so component bitmask doesnt need to consider the active members
		connect_bitmask_listener(entity_lookup.component_listeners, listener)

		listener()
		local new_storage = new_lookup.storage_group
		if new_storage == entity_storage then
			-- component did not change storage, we need to force `shared_with`
			-- because `move_component_storage` wont do anything if the destination storage is equal
			set_component_index_entry(new_storage.shared_with, entity, component, track_type, true)
		end
		return new_lookup
	end
end

function masking_controller.start_entity(masking: MaskingController, entity: Entity, filter: any)
	local last_replicated = ensure_entity_last_replicated(masking, entity, masking.empty_bitmask)

	local lookup: EntityLookup
	if filter then
		local type = typeof(filter)
		if type == "table" then
			-- TODO: check for filter groups
			local bitmask = create_bitmask_from_set(masking, filter)
			lookup = start_entity_bitmask(masking, entity, bitmask, is_include_filter(filter))
		elseif type == "function" then
			local bitmask = create_bitmask_from_function(masking, filter)
			lookup = start_entity_bitmask(masking, entity, bitmask, true)
			-- list function to be called
		else
			local bitmask = create_bitmask_from_member(masking, filter)
			lookup = start_entity_bitmask(masking, entity, bitmask, true)
		end
	else
		lookup = start_entity_bitmask(masking, entity, nil, true)
	end
	lookup.used_filter = filter

	local bitmask_deltas = masking.draft_bitmask_deltas
	load_bitmask_deltas(bitmask_deltas)

	local target_bitmask = lookup.calculated_bitmask or masking.active_members_bitmask
	calculate_bitmask_deltas(last_replicated.bitmask, target_bitmask, bitmask_deltas)
	bitmask_exclude(bitmask_deltas.added, masking.newly_active_bitmask, bitmask_deltas.added)
	bitmask_exclude(bitmask_deltas.removed, masking.newly_unactive_bitmask, bitmask_deltas.removed)
	set_entity_storage_deltas(masking, entity, last_replicated, bitmask_deltas)

	-- reviving postponed components
	local postponed = masking.lookups_list.postponed_components[entity]
	if postponed then
		for track_type, postponed_components in postponed do
			for component, filter_holder in postponed_components do
				masking.start_component(masking, entity, component, track_type, filter_holder.filter)
			end
		end
		masking.lookups_list.postponed_components[entity] = nil
	end
end

function masking_controller.set_entity(masking: MaskingController, entity: Entity, filter: any)
	local lookup = masking.lookups_list.entities[entity]
	if not lookup then
		common.log_error "attempted to change the filter of an unactive entity"
	end

	local current_bitmask = lookup.calculated_bitmask or masking.active_members_bitmask
	local entity_last_replicated = ensure_entity_last_replicated(masking, entity, current_bitmask)

	for track_type, lookups in lookup.filtered_components do
		for component, component_lookup in lookups do
			-- stylua: ignore
			ensure_component_last_replicated(
				masking,
				entity,
				component,
				track_type,
				component_lookup.calculated_bitmask
			)
		end
	end
	for track_type, components in lookup.unfiltered_components do
		for component in components do
			ensure_component_last_replicated(masking, entity, component, track_type, current_bitmask)
		end
	end

	if filter then
		local type = typeof(filter)

		if type == "table" then
			-- TODO: check for filter groups
			local bitmask = create_bitmask_from_set(masking, filter)
			set_entity_bitmask(masking, entity, lookup, bitmask, is_include_filter(filter))
		elseif type == "function" then
			local bitmask = create_bitmask_from_function(masking, filter)
			set_entity_bitmask(masking, entity, lookup, bitmask, true)
			-- TODO: list function to be called
		else
			local bitmask = create_bitmask_from_member(masking, filter)
			set_entity_bitmask(masking, entity, lookup, bitmask, true)
		end
	else
		set_entity_bitmask(masking, entity, lookup, nil, true)
	end

	local bitmask_deltas = masking.draft_bitmask_deltas
	for track_type, lookups in lookup.filtered_components do
		for component, component_lookup in lookups do
			local last_replicated = ensure_component_last_replicated(masking, entity, component, track_type)
			calculate_bitmask_deltas(
				last_replicated.bitmask,
				component_lookup.calculated_bitmask :: Bitmask,
				bitmask_deltas
			)
			bitmask_exclude(bitmask_deltas.added, masking.newly_active_bitmask, bitmask_deltas.added)
			bitmask_exclude(bitmask_deltas.removed, masking.newly_unactive_bitmask, bitmask_deltas.removed)
			set_component_storage_deltas(masking, entity, component, track_type, last_replicated, bitmask_deltas)
		end
	end

	local target_bitmask = lookup.calculated_bitmask or masking.active_members_bitmask
	for track_type, components in lookup.unfiltered_components do
		for component in components do
			local last_replicated = ensure_component_last_replicated(masking, entity, component, track_type)
			calculate_bitmask_deltas(last_replicated.bitmask, target_bitmask, bitmask_deltas)
			bitmask_exclude(bitmask_deltas.added, masking.newly_active_bitmask, bitmask_deltas.added)
			bitmask_exclude(bitmask_deltas.removed, masking.newly_unactive_bitmask, bitmask_deltas.removed)
			set_component_storage_deltas(masking, entity, component, track_type, last_replicated, bitmask_deltas)
		end
	end

	calculate_bitmask_deltas(entity_last_replicated.bitmask, target_bitmask, bitmask_deltas)
	bitmask_exclude(bitmask_deltas.added, masking.newly_active_bitmask, bitmask_deltas.added)
	bitmask_exclude(bitmask_deltas.removed, masking.newly_unactive_bitmask, bitmask_deltas.removed)
	set_entity_storage_deltas(masking, entity, entity_last_replicated, bitmask_deltas)

	lookup.used_filter = filter
end

function masking_controller.stop_entity(masking: MaskingController, entity: Entity)
	local lookup = masking.lookups_list.entities[entity]
	if not lookup then
		common.log_error "attempted to stop an already unactive entity"
	end
	local current_bitmask = lookup.calculated_bitmask or masking.active_members_bitmask
	local last_replicated = ensure_entity_last_replicated(masking, entity, current_bitmask)

	local postponed = masking.lookups_list.postponed_components[entity]

	-- postponing filtered components
	for track_type, lookups in lookup.filtered_components do
		for component, component_lookup in lookups do
			-- dont need to disconnect listeners from entity_lookup.component_listeners, as the entity_lookup will be dropped anyway

			local storage = component_lookup.storage_group
			local active = storage.active_entities[entity]
			if active and remove_active_component(storage, entity, active, component, track_type) then
				if is_active_entity_dead(active) then
					remove_active_entity(masking, storage, entity)
				end
			end

			storage.shared_with[entity] = nil
			-- TODO: remove entity changes

			if postponed == nil then
				postponed = create_component_index() :: ComponentIndex<{ filter: any? }>
				masking.lookups_list.postponed_components[entity] = postponed
			end
			postponed[track_type][component] = { filter = component_lookup.used_filter }
		end
	end

	-- postponed unfiltered components
	for track_type, components in lookup.unfiltered_components do
		for component in components do
			if postponed == nil then
				postponed = create_component_index() :: ComponentIndex<{ filter: any? }>
				masking.lookups_list.postponed_components[entity] = postponed
			end
			postponed[track_type][component] = { filter = nil }
		end
	end
	disconnect_bitmask_listener(masking.active_bitmask_listeners, lookup.bitmask_listener)

	local storage = lookup.storage_group
	remove_active_entity(masking, storage, entity)

	-- removing component deltas
	for track_type, components in last_replicated.components do
		for component, component_last_replicated in components do
			local added = component_last_replicated.added_storage
			local removed = component_last_replicated.removed_storage
			if added then
				remove_component_index_entry(added.storage_changes.components_deltas, entity, component, track_type)
				component_last_replicated.added_storage = nil
			end
			if removed then
				remove_component_index_entry(removed.storage_changes.components_deltas, entity, component, track_type)
				component_last_replicated.removed_storage = nil
			end
		end
	end

	local bitmask_deltas = masking.draft_bitmask_deltas
	load_bitmask_deltas(bitmask_deltas)

	calculate_bitmask_deltas(current_bitmask, masking.empty_bitmask, bitmask_deltas)
	bitmask_exclude(bitmask_deltas.removed, masking.newly_unactive_bitmask, bitmask_deltas.removed)
	set_entity_storage_deltas(masking, entity, last_replicated, bitmask_deltas)
	-- TODO: remove entity changes
	masking.lookups_list.entities[entity] = nil
end

function masking_controller.start_component(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	filter: any
)
	local entity_lookup = get_or_postpone_entity_lookup(masking, entity, component, track_type, filter)
	if not entity_lookup then
		return
	end
	-- stylua: ignore
	local last_replicated = ensure_component_last_replicated(
		masking,
		entity,
		component,
		track_type,
		masking.empty_bitmask,
		entity_lookup.calculated_bitmask
	)
	local bitmask_deltas = masking.draft_bitmask_deltas
	load_bitmask_deltas(bitmask_deltas)

	if filter then
		local component_lookup: ComponentLookup

		local type = typeof(filter)
		if type == "table" then
			-- TODO: check for filter groups
			local bitmask = create_bitmask_from_set(masking, filter)
			local is_include = is_include_filter(filter)

			component_lookup = start_component_bitmask(
				masking,
				entity,
				component,
				track_type,
				--
				entity_lookup,
				bitmask,
				is_include
			)
		elseif type == "function" then
			local bitmask = create_bitmask_from_function(masking, filter)
			component_lookup = start_component_bitmask(
				masking,
				entity,
				component,
				track_type,
				--
				entity_lookup,
				bitmask,
				true
			)
		else
			local bitmask = create_bitmask_from_member(masking, filter)
			component_lookup = start_component_bitmask(
				masking,
				entity,
				component,
				track_type,
				---
				entity_lookup,
				bitmask,
				true
			)
		end

		component_lookup.used_filter = filter

		calculate_bitmask_deltas(last_replicated.bitmask, component_lookup.calculated_bitmask :: Bitmask, bitmask_deltas)
		bitmask_exclude(bitmask_deltas.added, masking.newly_active_bitmask, bitmask_deltas.added)
		bitmask_exclude(bitmask_deltas.removed, masking.newly_unactive_bitmask, bitmask_deltas.removed)
		set_component_storage_deltas(masking, entity, component, track_type, last_replicated, bitmask_deltas)
	else
		entity_lookup.unfiltered_components[track_type][component] = true
		local entity_storage = entity_lookup.storage_group
		local active_entity = entity_storage and entity_storage.active_entities[entity]
		if active_entity then
			ensure_active_component(masking, entity_storage, entity, active_entity, component, track_type)
		else
			common.log_error "No storage assigned to entity when starting component"
		end

		local target_bitmask = entity_lookup.calculated_bitmask or masking.active_members_bitmask
		calculate_bitmask_deltas(last_replicated.bitmask, target_bitmask, bitmask_deltas)
		bitmask_exclude(bitmask_deltas.added, masking.newly_active_bitmask, bitmask_deltas.added)
		bitmask_exclude(bitmask_deltas.removed, masking.newly_unactive_bitmask, bitmask_deltas.removed)
		set_component_storage_deltas(masking, entity, component, track_type, last_replicated, bitmask_deltas)
	end
end

function masking_controller.set_component(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType,
	filter: any
)
	local entity_lookup = get_or_postpone_entity_lookup(masking, entity, component, track_type, filter)
	if not entity_lookup then
		return
	end

	local component_lookup = entity_lookup.filtered_components[track_type][component]
	local entity_bitmask = entity_lookup.calculated_bitmask or masking.active_members_bitmask
	local current_bitmask = (component_lookup and component_lookup.calculated_bitmask) or entity_bitmask

	-- stylua: ignore
	local last_replicated = ensure_component_last_replicated(
		masking,
		entity,
		component,
		track_type,
		current_bitmask,
		entity_bitmask
	)
	local bitmask_deltas = masking.draft_bitmask_deltas
	load_bitmask_deltas(bitmask_deltas)

	if filter then
		local type = typeof(filter)
		if type == "table" then
			-- TODO: check for filter groups
			local bitmask = create_bitmask_from_set(masking, filter)
			local is_include = is_include_filter(filter)
			component_lookup = set_component_bitmask(
				masking,
				entity,
				component,
				track_type,
				--
				entity_lookup,
				bitmask,
				is_include
			)
		elseif type == "function" then
			local bitmask = create_bitmask_from_function(masking, filter)
			component_lookup = set_component_bitmask(
				masking,
				entity,
				component,
				track_type,
				--
				entity_lookup,
				bitmask,
				true
			)
		else
			local bitmask = create_bitmask_from_member(masking, filter)
			component_lookup = set_component_bitmask(
				masking,
				entity,
				component,
				track_type,
				--
				entity_lookup,
				bitmask,
				true
			)
		end

		(component_lookup :: ComponentLookup).used_filter = filter

		calculate_bitmask_deltas(
			last_replicated.bitmask,
			(component_lookup :: ComponentLookup).calculated_bitmask :: Bitmask,
			bitmask_deltas
		)
		bitmask_exclude(bitmask_deltas.added, masking.newly_active_bitmask, bitmask_deltas.added)
		bitmask_exclude(bitmask_deltas.removed, masking.newly_unactive_bitmask, bitmask_deltas.removed)
		set_component_storage_deltas(masking, entity, component, track_type, last_replicated, bitmask_deltas)
	else
		set_component_bitmask(masking, entity, component, track_type, entity_lookup, nil, true)

		calculate_bitmask_deltas(last_replicated.bitmask, entity_bitmask, bitmask_deltas)
		bitmask_exclude(bitmask_deltas.added, masking.newly_active_bitmask, bitmask_deltas.added)
		bitmask_exclude(bitmask_deltas.removed, masking.newly_unactive_bitmask, bitmask_deltas.removed)
		set_component_storage_deltas(masking, entity, component, track_type, last_replicated, bitmask_deltas)
	end
end

function masking_controller.stop_component(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	track_type: TrackingType
)
	local component_lookup, entity_lookup = get_component_lookup(masking, entity, component, track_type)
	if component_lookup then
		-- stylua: ignore
		local last_replicated = ensure_component_last_replicated(
			masking,
			entity,
			component,
			track_type,
			component_lookup.calculated_bitmask,
			entity_lookup.calculated_bitmask
		)

		local listener = component_lookup.bitmask_listener
		disconnect_bitmask_listener(entity_lookup.component_listeners, listener)

		local storage = component_lookup.storage_group
		local active = storage.active_entities[entity]
		if active and remove_active_component(storage, entity, active, component, track_type) then
			if is_active_entity_dead(active) then
				remove_active_entity(masking, storage, entity)
			end
		end
		remove_component_index_entry(storage.shared_with, entity, component, track_type)
		entity_lookup.filtered_components[track_type][component] = nil

		local bitmask_deltas = masking.draft_bitmask_deltas
		load_bitmask_deltas(bitmask_deltas)

		calculate_bitmask_deltas(last_replicated.bitmask, masking.empty_bitmask, bitmask_deltas)
		bitmask_exclude(bitmask_deltas.removed, masking.newly_unactive_bitmask, bitmask_deltas.removed)
		set_component_storage_deltas(masking, entity, component, track_type, last_replicated, bitmask_deltas)
	else
		if entity_lookup then
			local target_bitmask = entity_lookup.calculated_bitmask or masking.active_members_bitmask
			-- stylua: ignore
			local last_replicated = ensure_component_last_replicated(
				masking,
				entity,
				component,
				track_type,
				target_bitmask
			)

			local storage = entity_lookup.storage_group
			local active = storage.active_entities[entity]

			if active and remove_active_component(storage, entity, active, component, track_type) then
				if is_active_entity_dead(active) then
					remove_active_entity(masking, storage, entity)
				end
			end
			entity_lookup.unfiltered_components[track_type][component] = nil

			local bitmask_deltas = masking.draft_bitmask_deltas
			load_bitmask_deltas(bitmask_deltas)

			calculate_bitmask_deltas(last_replicated.bitmask, masking.empty_bitmask, bitmask_deltas)
			bitmask_exclude(bitmask_deltas.removed, masking.newly_unactive_bitmask, bitmask_deltas.removed)
			set_component_storage_deltas(masking, entity, component, track_type, last_replicated, bitmask_deltas)
		else
			remove_component_index_entry(masking.lookups_list.postponed_components, entity, component, track_type)
		end
	end
end

function masking_controller.allocate_tag_addition(masking: MaskingController, entity: Entity, tag: Component)
	local storage = get_component_storage(masking, entity, tag, TRACKING_TYPES.tag)
	local changes = ensure_entity_changes(masking, storage, entity)

	changes.tag_added[tag] = true
	changes.tag_removed[tag] = nil
end

function masking_controller.allocate_component_change(
	masking: MaskingController,
	entity: Entity,
	component: Component,
	value: any
)
	local storage = get_component_storage(masking, entity, component, TRACKING_TYPES.component)
	local changes = ensure_entity_changes(masking, storage, entity)

	changes.component_changed[component] = value
	changes.component_removed[component] = nil
end

function masking_controller.allocate_unreliable_addition(
	masking: MaskingController,
	entity: Entity,
	component: Component
)
	local storage = get_component_storage(masking, entity, component, TRACKING_TYPES.unreliable)
	local changes = ensure_entity_changes(masking, storage, entity)

	changes.unreliable_added[component] = true
	changes.unreliable_removed[component] = nil
end

function masking_controller.allocate_pair_tag_addition(masking: MaskingController, entity: Entity, id: Component)
	local storage = get_component_storage(masking, entity, id, TRACKING_TYPES.pair_tag)
	local changes = ensure_entity_changes(masking, storage, entity)

	changes.pair_tag_added[id] = true
	changes.pair_tag_removed[id] = nil
end

function masking_controller.allocate_pair_component_change(
	masking: MaskingController,
	entity: Entity,
	id: Component,
	value: any
)
	local storage = get_component_storage(masking, entity, id, TRACKING_TYPES.pair_component)
	local changes = ensure_entity_changes(masking, storage, entity)

	changes.pair_component_changed[id] = value
	changes.pair_component_removed[id] = nil
end

function masking_controller.allocate_relation_tag_addition(
	masking: MaskingController,
	entity: Entity,
	relation: Component,
	target: Entity
)
	local storage = get_component_storage(masking, entity, relation, TRACKING_TYPES.relation)
	local changes = ensure_entity_changes(masking, storage, entity)

	local targets = changes.relation_tag_added[relation]
	if targets == nil then
		targets = {}
		changes.relation_tag_added[relation] = targets
	end
	targets[target] = true

	local removed = changes.relation_tag_removed[relation]
	if removed then
		removed[target] = nil
	end
end

function masking_controller.allocate_relation_component_change(
	masking: MaskingController,
	entity: Entity,
	relation: Component,
	target: Entity,
	value: any
)
	local storage = get_component_storage(masking, entity, relation, TRACKING_TYPES.relation_component)
	local changes = ensure_entity_changes(masking, storage, entity)

	local values = changes.relation_component_changed[relation]
	if values == nil then
		values = {}
		changes.relation_component_changed[relation] = values
	end
	values[target] = value

	local removed = changes.relation_component_removed[relation]
	if removed then
		removed[target] = nil
	end
end

function masking_controller.allocate_tag_removal(masking: MaskingController, entity: Entity, tag: Component)
	local storage = get_component_storage(masking, entity, tag, TRACKING_TYPES.tag)
	local changes = ensure_entity_changes(masking, storage, entity)

	changes.tag_removed[tag] = true
	changes.tag_added[tag] = nil
end

function masking_controller.allocate_component_removal(masking: MaskingController, entity: Entity, component: Component)
	local storage = get_component_storage(masking, entity, component, TRACKING_TYPES.component)
	local changes = ensure_entity_changes(masking, storage, entity)

	changes.component_removed[component] = true
	changes.component_changed[component] = nil
end

function masking_controller.allocate_unreliable_removal(
	masking: MaskingController,
	entity: Entity,
	component: Component
)
	local storage = get_component_storage(masking, entity, component, TRACKING_TYPES.unreliable)
	local changes = ensure_entity_changes(masking, storage, entity)

	changes.unreliable_removed[component] = true
	changes.unreliable_added[component] = nil
end

function masking_controller.allocate_pair_tag_removal(masking: MaskingController, entity: Entity, id: Component)
	local storage = get_component_storage(masking, entity, id, TRACKING_TYPES.pair_tag)
	local changes = ensure_entity_changes(masking, storage, entity)

	changes.pair_tag_removed[id] = true
	changes.pair_tag_added[id] = nil
end

function masking_controller.allocate_pair_component_removal(masking: MaskingController, entity: Entity, id: Component)
	local storage = get_component_storage(masking, entity, id, TRACKING_TYPES.pair_component)
	local changes = ensure_entity_changes(masking, storage, entity)

	changes.pair_component_removed[id] = true
	changes.pair_component_changed[id] = nil
end

function masking_controller.allocate_relation_tag_removal(
	masking: MaskingController,
	entity: Entity,
	relation: Component,
	target: Entity
)
	local storage = get_component_storage(masking, entity, relation, TRACKING_TYPES.relation)
	local changes = ensure_entity_changes(masking, storage, entity)

	local targets = changes.relation_tag_removed[relation]
	if targets == nil then
		targets = {}
		changes.relation_tag_removed[relation] = targets
	end
	targets[target] = true

	local added = changes.relation_tag_added[relation]
	if added then
		added[target] = nil
	end
end

function masking_controller.allocate_relation_component_removal(
	masking: MaskingController,
	entity: Entity,
	relation: Component,
	target: Entity
)
	local storage = get_component_storage(masking, entity, relation, TRACKING_TYPES.relation_component)
	local changes = ensure_entity_changes(masking, storage, entity)

	local targets = changes.relation_component_removed[relation]
	if targets == nil then
		targets = {}
		changes.relation_component_removed[relation] = targets
	end
	targets[target] = true

	local values = changes.relation_component_changed[relation]
	if values then
		values[target] = nil
	end
end

function masking_controller.compact_members(masking: MaskingController)
	local old_indexes = masking.member_indexes
	local new_indexes: { [Member]: number } = {}

	local next_index = 0
	for member in old_indexes do
		new_indexes[member] = next_index
		next_index += 1
	end
	masking.member_indexes = new_indexes
	masking.member_next_index = next_index

	local draft = masking.draft_bitmask

	-- stylua: ignore
	masking.all_members_bitmask = bitmask_remap(
		masking.all_members_bitmask,
		draft,
		old_indexes,
		new_indexes,
		next_index
	)
	-- stylua: ignore
	masking.unactive_members_bitmask = bitmask_remap(
		masking.unactive_members_bitmask,
		draft,
		old_indexes,
		new_indexes,
		next_index
	)
	-- stylua: ignore
	masking.active_members_bitmask = bitmask_remap(
		masking.active_members_bitmask,
		draft,
		old_indexes,
		new_indexes,
		next_index
	)

	-- stylua: ignore
	masking.last_active_bitmask = bitmask_remap(
		masking.last_active_bitmask,
		draft,
		old_indexes,
		new_indexes,
		next_index
	)

	bitmask_exclude(masking.active_members_bitmask, masking.last_active_bitmask, masking.newly_active_bitmask)
	bitmask_exclude(masking.last_active_bitmask, masking.active_members_bitmask, masking.newly_unactive_bitmask)

	local empty_bitmask = masking.empty_bitmask
	for _, last_replicated in masking.lookups_list.last_replicated do
		if last_replicated.bitmask ~= empty_bitmask then
			last_replicated.bitmask = bitmask_remap(last_replicated.bitmask, draft, old_indexes, new_indexes, next_index)
		end

		for _, components in last_replicated.components do
			for _, component_last_replicated in components do
				if component_last_replicated.bitmask ~= empty_bitmask then
					-- stylua: ignore
					component_last_replicated.bitmask = bitmask_remap(
						component_last_replicated.bitmask,
						draft,
						old_indexes,
						new_indexes,
						next_index
					)
				end
			end
		end
	end

	for entity, entity_lookup in masking.lookups_list.entities do
		local filter_bitmask = entity_lookup.filter_bitmask
		if filter_bitmask then
			entity_lookup.filter_bitmask = bitmask_remap(filter_bitmask, draft, old_indexes, new_indexes, next_index)
		end

		local is_include = get_used_filter_type(entity_lookup.used_filter)

		local old_listener = entity_lookup.bitmask_listener
		local listener = update_entity_filter(masking, entity, entity_lookup, entity_lookup.filter_bitmask, is_include)
		entity_lookup.bitmask_listener = listener
		swap_bitmask_listener(masking.active_bitmask_listeners, old_listener, listener)

		for track_type, lookups in entity_lookup.filtered_components do
			for component, component_lookup in lookups do
				local component_filter_bitmask = component_lookup.filter_bitmask
				if component_filter_bitmask then
					-- stylua: ignore
					component_lookup.filter_bitmask = bitmask_remap(
						component_filter_bitmask,
						draft,
						old_indexes,
						new_indexes,
						next_index
					)
				end

				local old_component_listener = component_lookup.bitmask_listener
				local listener_generator = update_component_filter(
					masking,
					entity,
					component,
					track_type,
					--
					component_lookup,
					component_lookup.filter_bitmask :: Bitmask,
					get_used_filter_type(component_lookup.used_filter)
				)
				local component_listener = listener_generator(entity_lookup.calculated_bitmask)

				component_lookup.listener_generator = listener_generator
				component_lookup.bitmask_listener = component_listener
				swap_bitmask_listener(entity_lookup.component_listeners, old_component_listener, component_listener)
			end
		end
	end

	local new_storage_index: StorageIndex = {}

	for _, storage in masking.storage_index do
		local storage_mask = storage.mask
		storage_mask.bitmask = bitmask_remap(storage_mask.bitmask, draft, old_indexes, new_indexes, next_index)

		local new_hash = bitmask_hash(storage_mask.bitmask)
		storage_mask.hash = new_hash
		storage_mask.members = get_members_from_bitmask(masking, storage_mask.bitmask)

		local existing = new_storage_index[new_hash]
		if existing then
			merge_storages(masking, storage, existing)

			remove_storage_from_kind(masking, storage)
			recalculate_storage_kind(masking, existing)
		else
			new_storage_index[new_hash] = storage
		end
	end
	masking.storage_index = new_storage_index

	-- running the listeners recalculates every calculated_bitmask with the new indexes.
	-- this must happen after the storage index is rebuilt, so the recomputed hashes
	-- point to the correct storage
	for _, entity_lookup in masking.lookups_list.entities do
		entity_lookup.bitmask_listener()
	end
end

function masking_controller.register_client(masking: MaskingController, member: Member)
	if masking.member_indexes[member] then
		return
	end

	if masking.member_count >= masking.COMPACT_THRESHOLD then
		-- some global bitmasks are fixed to COMPACT_THRESHOLD size, they cannot grow
		common.log_error(
			`cannot register more members than: {masking.COMPACT_THRESHOLD}.\nConsider changing replecs.BITMASK_COMPACT_THRESHOLD to more than your max players`
		)
	end

	if masking.member_next_index >= masking.COMPACT_THRESHOLD then
		masking:compact_members()
	end

	local current = masking.member_next_index
	masking.member_indexes[member] = current
	masking.member_next_index += 1
	masking.member_count += 1

	bitmask_set(masking.unactive_members_bitmask, current)
	bitmask_set(masking.all_members_bitmask, current)
	recalculate_active_members_bitmask(masking)
end

function masking_controller.unregister_client(masking: MaskingController, member: Member)
	local index = masking.member_indexes[member]
	if index == nil then
		return
	end
	masking.member_indexes[member] = nil
	masking.member_count -= 1

	bitmask_reset(masking.all_members_bitmask, index)
	bitmask_reset(masking.unactive_members_bitmask, index)
	recalculate_active_members_bitmask(masking)
end

function masking_controller.client_is_active(masking: MaskingController, member: Member)
	local index = masking.member_indexes[member]
	if not index then
		return false
	end
	return bitmask_test(masking.active_members_bitmask, index)
end

function masking_controller.activate_client(masking: MaskingController, member: Member)
	local index = masking.member_indexes[member]
	if not index then
		common.log_error "attempted to activate a member that is not registered"
	end
	if bitmask_test(masking.active_members_bitmask, index) then
		return
	end

	bitmask_reset(masking.unactive_members_bitmask, index)
	recalculate_active_members_bitmask(masking)
end

function masking_controller.mark_replication_cycle(masking: MaskingController)
	bitmask_load(masking.active_members_bitmask, masking.last_active_bitmask)
	bitmask_clear(masking.newly_active_bitmask)
	bitmask_clear(masking.newly_unactive_bitmask)
end

local function create(compact_threshold: number): MaskingController
	local self = {} :: MaskingControllerClass

	self.COMPACT_THRESHOLD = math.max(compact_threshold, 32)
	self.COMPACT_THRESHOLD = math.ceil(self.COMPACT_THRESHOLD / BITS_PER_ENTRY) * BITS_PER_ENTRY

	local bitmask_size = bitmask_get_buffer_size(self.COMPACT_THRESHOLD)

	self.member_next_index = 0
	self.member_count = 0
	self.member_indexes = {}

	self.all_members_bitmask = buffer.create(bitmask_size)
	self.active_members_bitmask = buffer.create(bitmask_size)
	self.unactive_members_bitmask = buffer.create(bitmask_size)

	self.draft_bitmask = buffer.create(bitmask_size)
	self.empty_bitmask = buffer.create(bitmask_size)
	self.last_active_bitmask = buffer.create(bitmask_size)
	self.newly_active_bitmask = buffer.create(bitmask_size)
	self.newly_unactive_bitmask = buffer.create(bitmask_size)
	self.draft_bitmask_deltas = {
		added = buffer.create(bitmask_size),
		removed = buffer.create(bitmask_size),
	}

	self.active_bitmask_listeners = create_bitmask_listeners()
	self.lookups_list = {
		entities = {},
		last_replicated = {},
		postponed_components = {},
	}

	self.storage_index = {}
	self.storage_kinds = {}

	return setmetatable(self, masking_controller) :: any
end

-- exporting for testing purposes
masking_controller.to_binary = to_binary
masking_controller.bitmask_hash = bitmask_hash

masking_controller.start_entity_bitmask = start_entity_bitmask
masking_controller.set_entity_bitmask = set_entity_bitmask

return { create = create, masking_controller = masking_controller }
