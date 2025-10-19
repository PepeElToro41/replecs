--!native
--!optimize 2

local jecs = require "../jecs"
local utils = require "./utils"
local mask_generator = require "@self/mask_generator"

type Entity<T = any> = jecs.Entity<T>

type Bitmask = utils.Bitmask
type MaskGenerator = mask_generator.MaskGenerator
type MaskGeneratorWithBitmask = mask_generator.MaskGeneratorWithBitmask

type GivenFilter = MemberFilter | any
type MemberFilter = Set<Member>
type Member = any
type MaskHash = string

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }

export type FunctionFilter = (player: Player) -> boolean

export type ComponentIndex<T> = {
	[number]: { [Entity]: T },
}
export type EntityComponentIndex<T> = {
	[Entity]: ComponentIndex<T>,
}

type Lookup = {
	generator: MaskGenerator,
	filter: MemberFilter?,
	storage_group: StorageGroup,
}

type ComponentLookup = Lookup & {
	band_generator: MaskGenerator,
}

type EntityLookup = Lookup & {
	filtered_components: ComponentIndex<ComponentLookup>,
	components: ComponentIndex<true>,
}

export type EntityChanges = {
	tagged: { [Entity]: boolean },
	component: { [Entity]: any },
	removed: { [Entity]: boolean },
	pairs: { [Entity]: Set<Entity> },
	pairs_values: {
		changed: { [Entity]: Map<Entity, any> },
		removed: { [Entity]: Set<Entity> },
	},
}

type PostponedList = ComponentIndex<{ filter: MemberFilter? }>

type LookupsList = {
	entities: Map<Entity, EntityLookup>,

	deletions: {
		entities: Map<Entity, Lookup>,
		components: EntityComponentIndex<Lookup>,
	},
	filter_deltas: {
		entities: Map<Entity, Map<Entity, boolean>>,
		components: EntityComponentIndex<Map<Entity, boolean>>,
	},

	postponed: { [Entity]: PostponedList },
}

export type ActiveEntity = {
	components: ComponentIndex<boolean>,
	component_count: number,
	is_entity_mask: boolean,
}

type MaskInfo = {
	bitmask: Bitmask,
	hash: MaskHash,
	members: Array<Member>,
}

type StorageGroup = {
	mask: MaskInfo,
	shared_with: EntityComponentIndex<boolean>,
	is_empty: boolean,

	deletions: {
		entities: Set<Entity>,
		components: EntityComponentIndex<boolean>,
	},
	deletions_count: number,

	active: Map<Entity, ActiveEntity>, -- set of active entities
	active_count: number,

	changes: {
		added: Map<Entity, boolean>,
		added_components: EntityComponentIndex<boolean>,
		changed: Map<Entity, EntityChanges>,
	},
}

type Storages = {
	[MaskHash]: StorageGroup,
}

export type MaskingController = {
	member_count: number,

	client_indexes: { [Member]: number },
	group_indexes: { [number]: number },
	member_indexes: { [Member]: number },
	client_aliases: { [any]: Member },

	compact_count: number,
	unreplicated: Set<Member>,

	all_members_generator: MaskGeneratorWithBitmask,
	active_members_generator: MaskGenerator,
	unactive_members_generator: MaskGeneratorWithBitmask,

	storages: Storages,
	lookups: LookupsList,

	register_mask_group: (self: MaskingController, group: Member) -> (),
	unregister_mask_group: (self: MaskingController, group: Member) -> (),
	register_client: (self: MaskingController, member: Member) -> (),
	unregister_client: (self: MaskingController, member: Member) -> (),
	activate_client: (self: MaskingController, member: Member) -> (),
	member_is_active: (self: MaskingController, member: Member) -> boolean,

	register_stop_entity: (self: MaskingController, entity: Entity) -> (),
	register_stop_component: (
		self: MaskingController,
		entity: Entity,
		component: Entity,
		component_type: number
	) -> (),
	register_component_addition: (
		self: MaskingController,
		entity: Entity,
		component: Entity,
		component_type: number
	) -> (),
	unregister_component_addition: (
		self: MaskingController,
		entity: Entity,
		component: Entity,
		component_type: number
	) -> (),
	unregister_stop_entity: (self: MaskingController, entity: Entity) -> (),
	unregister_stop_component: (
		self: MaskingController,
		entity: Entity,
		component: Entity,
		component_type: number
	) -> (),

	propagate_entity_addition: (self: MaskingController, entity: Entity) -> (),

	start_entity: (self: MaskingController, entity: Entity, filter: GivenFilter?) -> (),
	set_entity: (self: MaskingController, entity: Entity, filter: GivenFilter?) -> (),
	stop_entity: (self: MaskingController, entity: Entity) -> (),
	cleanup_entity: (self: MaskingController, entity: Entity) -> (),

	start_component: (
		self: MaskingController,
		entity: Entity,
		component: Entity,
		component_type: number,
		filter: GivenFilter?
	) -> (),
	set_component: (
		self: MaskingController,
		entity: Entity,
		component: Entity,
		component_type: number,
		filter: GivenFilter?
	) -> (),
	stop_component: (self: MaskingController, entity: Entity, component: Entity, component_type: number) -> (),

	allocate_entity_addition: (
		self: MaskingController,
		entity: Entity,
		component: Entity,
		component_type: number
	) -> (),

	allocate_component_change: (self: MaskingController, entity: Entity, component: Entity, value: any) -> (),
	allocate_pair_value_change: (
		self: MaskingController,
		entity: Entity,
		relation: Entity,
		target: Entity,
		value: any
	) -> (),

	allocate_tag_addition: (self: MaskingController, entity: Entity, tag: Entity) -> (),
	allocate_pair_addition: (self: MaskingController, entity: Entity, relation: Entity, target: Entity) -> (),

	allocate_component_removal: (self: MaskingController, entity: Entity, component: Entity) -> (),
	allocate_pair_value_removal: (self: MaskingController, entity: Entity, relation: Entity, target: Entity) -> (),
	allocate_tag_removal: (self: MaskingController, entity: Entity, tag: Entity) -> (),
	allocate_pair_removal: (self: MaskingController, entity: Entity, relation: Entity, target: Entity) -> (),
}

local COMPONENT_TYPES = {
	component = 1,
	tag = 2,
	pair = 3,
	pair_value = 4,
	unreliable = 5,
}

local masking_controller = {}
masking_controller.__index = masking_controller

export type MaskingInternal = MaskingController & typeof(masking_controller)

function masking_controller.get_clients_from_bitmask(controller: MaskingInternal, bitmask: Bitmask): Array<Member>
	local members: { Member } = {}
	for player, index in controller.client_indexes do
		if bitmask:get(index) then
			table.insert(members, player :: any)
		end
	end
	return members
end

local function get_usable_filter(filter: (MemberFilter | any)?): MemberFilter?
	if filter then
		if type(filter) == "table" then
			return filter :: MemberFilter
		else
			return { [filter] = true }
		end
	else
		return nil
	end
end

local function create_component_indexes<T>()
	return { {}, {}, {}, {}, {} } :: ComponentIndex<any>
end

local function create_entity_changes(): EntityChanges
	return {
		tagged = {},
		component = {},
		removed = {},
		pairs = {},
		pairs_values = {
			changed = {},
			removed = {},
		},
	}
end

function masking_controller.create_new_storage(
	controller: MaskingInternal,
	bitmask: Bitmask,
	hash: string?,
	members: Array<Member>?
): StorageGroup
	return {
		mask = {
			bitmask = bitmask,
			hash = hash or bitmask:tostring(),
			members = members or controller:get_clients_from_bitmask(bitmask),
		},
		is_empty = true,
		shared_with = {},

		changes = {
			added = {},
			added_components = {},
			changed = {},
		},

		active = {},
		active_count = 0,

		deletions = {
			entities = {},
			components = {},
		},
		deletions_count = 0,
	}
end

local function is_include_filter(filter: MemberFilter): boolean
	for _, allow in filter do
		if allow then
			return true
		else
			return false
		end
	end
	return true
end
local function create_new_active(): ActiveEntity
	return {
		components = create_component_indexes() :: ComponentIndex<boolean>,
		component_count = 0,
		is_entity_mask = false,
	}
end

local function get_component_index_entry<T>(
	index: EntityComponentIndex<T>,
	entity: Entity,
	component: Entity,
	component_type: number
): T?
	local entity_index = index[entity]
	if entity_index == nil then
		return nil
	end
	local component_index = entity_index[component_type]

	return component_index and component_index[component] :: T?
end

local function set_component_index_entry<T>(
	index: EntityComponentIndex<T>,
	entity: Entity,
	component: Entity,
	component_type: number,
	value: T
)
	local entity_index = index[entity]
	if entity_index == nil then
		entity_index = create_component_indexes()
		index[entity] = entity_index
	end
	entity_index[component_type][component] = value
end

local function remove_component_index_entry(
	index: EntityComponentIndex<any>,
	entity: Entity,
	component: Entity,
	component_type: number
)
	local entity_index = index[entity]
	if entity_index == nil then
		return
	end
	entity_index[component_type][component] = nil
end

local function get_bitmask_deltas(current: Bitmask, target: Bitmask): (Bitmask, Bitmask)
	local added = target:band(current:bnot())
	local removed = current:band(target:bnot())
	return added, removed
end

local function merge_bitmask_deltas(added: Bitmask, removed: Bitmask, new_added: Bitmask, new_removed: Bitmask)
	local merged_added = added:bor(new_added)
	local merged_removed = removed:bor(new_removed)
	local common = merged_added:band(merged_removed):bnot()

	local added_final = merged_added:band(common)
	local removed_final = merged_removed:band(common)
	return added_final, removed_final
end

masking_controller.get_component_index_entry = get_component_index_entry
masking_controller.set_component_index_entry = set_component_index_entry
masking_controller.remove_component_index_entry = remove_component_index_entry
masking_controller.get_bitmask_deltas = get_bitmask_deltas
masking_controller.merge_bitmask_deltas = merge_bitmask_deltas

local function get_or_set_changed(storage: StorageGroup, entity: Entity, changed: EntityChanges?): EntityChanges
	local storage_changed = storage.changes.changed[entity]
	if storage_changed == nil then
		storage_changed = changed or create_entity_changes()
		storage.changes.changed[entity] = storage_changed
	end
	return storage_changed
end

local function get_or_set_active(storage: StorageGroup, entity: Entity, active: ActiveEntity?): ActiveEntity
	local storage_active = storage.active[entity]
	if storage_active == nil then
		storage_active = active or create_new_active()
		storage.active[entity] = storage_active
		storage.active_count += 1
	end
	return storage_active
end

local function get_or_set_component_added(
	storage: StorageGroup,
	entity: Entity,
	added: ComponentIndex<boolean>?
): ComponentIndex<boolean>
	local storage_added = storage.changes.added_components[entity]
	if storage_added == nil then
		storage_added = added or create_component_indexes() :: ComponentIndex<boolean>
		storage.changes.added_components[entity] = storage_added
	end
	return storage_added
end

local function remove_active(storage: StorageGroup, entity: Entity): ActiveEntity
	local active = storage.active[entity]
	if active then
		storage.active[entity] = nil
		storage.active_count -= 1
		-- todo: check if empty
		return active
	end
	return utils.logerror "attempted to remove an entity that wasn't active"
end

local function get_or_set_component_active(active: ActiveEntity, component: Entity, component_type: number)
	local components = active.components[component_type]
	if components[component] == nil then
		components[component] = true
		active.component_count += 1
	end
end

local function remove_component_active(storage: StorageGroup, entity: Entity, component: Entity, component_type: number)
	local active = storage.active[entity]
	if not active then
		return
	end
	local components = active.components[component_type]

	if components[component] then
		components[component] = nil
		active.component_count -= 1

		if active.component_count <= 0 and not active.is_entity_mask then
			remove_active(storage, entity)
		end
	end
end

function masking_controller.get_or_create_storage_group(masking: MaskingInternal, bitmask: Bitmask): StorageGroup
	local hash = bitmask:tostring()
	local storage = masking.storages[hash]

	if not storage then
		storage = masking:create_new_storage(bitmask, hash)
		masking.storages[hash] = storage
	end
	return storage
end

function masking_controller.get_component_lookup(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number
): (ComponentLookup, EntityLookup)
	local entity_lookup = masking.lookups.entities[entity]
	return entity_lookup.filtered_components[component_type][component], entity_lookup
end

local function dissect_component_actives(
	storage: StorageGroup,
	entity: Entity,
	shared_index: ComponentIndex<boolean>
): ActiveEntity?
	local new_active: ActiveEntity
	local active = storage.active[entity]

	for component_type, components in active.components do
		for component in components do
			local is_shared = shared_index[component_type] and shared_index[component_type][component]
			if is_shared then
				new_active = new_active or create_new_active()

				get_or_set_component_active(new_active, component, component_type)
				remove_component_active(storage, entity, component, component_type)
			end
		end
	end
	return new_active
end

local function dissect_component_additions(added: ComponentIndex<boolean>, shared_index: ComponentIndex<boolean>)
	local new_added: ComponentIndex<boolean>

	for component_type, components in added do
		for component in components do
			local is_shared = shared_index[component_type] and shared_index[component_type][component]
			if is_shared then
				new_added = (new_added or create_component_indexes()) :: ComponentIndex<boolean>
				new_added[component_type][component] = true
				added[component_type][component] = nil
			end
		end
	end
	return new_added
end

local function dissect_component_changes(changes: EntityChanges, shared_index: ComponentIndex<boolean>)
	local new_changes: EntityChanges

	for component, change in changes.component do
		local is_shared = shared_index[COMPONENT_TYPES.component] and shared_index[COMPONENT_TYPES.component][component]
		if is_shared then
			new_changes = new_changes or create_entity_changes()
			new_changes.component[component] = change
			changes.component[component] = nil
		end
	end
	for entity, entity_changes in changes.tagged do
		local is_shared = shared_index[COMPONENT_TYPES.tag] and shared_index[COMPONENT_TYPES.tag][entity]
		if is_shared then
			new_changes = new_changes or create_entity_changes()
			new_changes.tagged[entity] = entity_changes
			changes.tagged[entity] = nil
		end
	end
	for relation, entity_changes in changes.pairs do
		local is_shared = shared_index[COMPONENT_TYPES.pair] and shared_index[COMPONENT_TYPES.pair][relation]
		if is_shared then
			new_changes = new_changes or create_entity_changes()
			new_changes.pairs[relation] = entity_changes
			changes.pairs[relation] = nil
		end
	end
	for relation, entity_changes in changes.pairs_values.changed do
		local is_shared = shared_index[COMPONENT_TYPES.pair_value]
			and shared_index[COMPONENT_TYPES.pair_value][relation]

		if is_shared then
			new_changes = new_changes or create_entity_changes()
			new_changes.pairs_values.changed[relation] = entity_changes
			changes.pairs_values.changed[relation] = nil
		end
	end
	for relation, entity_changes in changes.pairs_values.removed do
		local is_shared = shared_index[COMPONENT_TYPES.pair_value]
			and shared_index[COMPONENT_TYPES.pair_value][relation]

		if is_shared then
			new_changes = new_changes or create_entity_changes()
			new_changes.pairs_values.removed[relation] = entity_changes
			changes.pairs_values.removed[relation] = nil
		end
	end

	return new_changes
end

local function merge_component_actives(current: ActiveEntity, target: ActiveEntity)
	for component_type, components in current.components do
		for component in components do
			get_or_set_component_active(target, component, component_type)
		end
	end
end

local function merge_component_additions(current: ComponentIndex<boolean>, target: ComponentIndex<boolean>)
	for component_type, components in current do
		for component in components do
			target[component_type][component] = true
		end
	end
end

local function merge_component_changes(current: EntityChanges, target: EntityChanges)
	for component, change in current.component do
		target.component[component] = change
	end
	for entity, entity_changes in current.tagged do
		target.tagged[entity] = entity_changes
	end
	for entity, entity_changes in current.pairs do
		target.pairs[entity] = entity_changes
	end
end

function masking_controller.merge_component_filter(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number
)
	local component_lookup, entity_lookup = masking:get_component_lookup(entity, component, component_type)
	if not entity_lookup then
		utils.logerror "attempted to merge a component filter to an unactive entity"
	end

	if component_lookup ~= nil then
		local new_storage = masking:move_component_storage(
			entity,
			component,
			component_type,
			component_lookup.storage_group,
			entity_lookup.generator.result
		)
		entity_lookup.filtered_components[component_type][component] = nil
		remove_component_index_entry(new_storage.shared_with, entity, component, component_type)
	else
		get_or_set_component_active(entity_lookup.storage_group.active[entity], component, component_type)
	end
	entity_lookup.components[component_type][component] = true
end

function masking_controller.move_entity_storage(
	masking: MaskingInternal,
	entity: Entity,
	storage: StorageGroup,
	target: Bitmask
)
	local target_storage = masking:get_or_create_storage_group(target)
	if target_storage == storage then
		return storage
	end
	local shared_with = storage.shared_with[entity]

	local old_active = storage.active[entity]
	local new_active = get_or_set_active(target_storage, entity, old_active)

	new_active.is_entity_mask = true

	if shared_with then
		local dissected_active = dissect_component_actives(storage, entity, shared_with)
		if dissected_active then
			storage.active[entity] = dissected_active
		else
			remove_active(storage, entity)
		end
	else
		remove_active(storage, entity)
	end

	if old_active ~= new_active then
		merge_component_actives(old_active, new_active)
	end

	local old_component_added = storage.changes.added_components[entity]
	if old_component_added then
		local new_component_added = get_or_set_component_added(target_storage, entity, old_component_added)

		if shared_with then
			local dissected_added = dissect_component_additions(old_component_added, shared_with)
			if dissected_added then
				storage.changes.added_components[entity] = dissected_added
			else
				storage.changes.added_components[entity] = nil
			end
		end

		if old_component_added ~= new_component_added then
			merge_component_additions(old_component_added, new_component_added)
		end
	end

	local old_changes = storage.changes.changed[entity]
	if old_changes then
		local new_changes = get_or_set_changed(target_storage, entity, old_changes)

		if shared_with then
			local dissected_changes = dissect_component_changes(old_changes, shared_with)
			if dissected_changes then
				storage.changes.changed[entity] = dissected_changes
			else
				storage.changes.changed[entity] = nil
			end
		end

		if old_changes ~= new_changes then
			merge_component_changes(old_changes, new_changes)
		end
	end

	if storage.changes.added[entity] then
		target_storage.changes.added[entity] = true
		storage.changes.added[entity] = nil
	end

	return target_storage
end

function masking_controller.remove_component_in_storage(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number,
	storage: StorageGroup
)
	remove_component_active(storage, entity, component, component_type)
	remove_component_index_entry(storage.shared_with, entity, component, component_type)
end

function masking_controller.move_component_storage(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number,
	storage: StorageGroup,
	target: Bitmask
)
	local target_storage = masking:get_or_create_storage_group(target)
	if target_storage == storage then
		return storage
	end

	local new_active = get_or_set_active(target_storage, entity)

	remove_component_active(storage, entity, component, component_type)
	get_or_set_component_active(new_active, component, component_type)

	set_component_index_entry(target_storage.shared_with, entity, component, component_type, true)
	remove_component_index_entry(storage.shared_with, entity, component, component_type)

	local component_added =
		get_component_index_entry(storage.changes.added_components, entity, component, component_type)
	if component_added then
		remove_component_index_entry(target_storage.changes.added_components, entity, component, component_type)
		set_component_index_entry(target_storage.changes.added_components, entity, component, component_type, true)
	end

	local changes = storage.changes.changed[entity]
	if changes then
		local target_changes = get_or_set_changed(target_storage, entity)
		if component_type == COMPONENT_TYPES.tag then
			target_changes.tagged[component] = changes.tagged[component]
			target_changes.removed[component] = changes.removed[component]

			changes.tagged[component] = nil
			changes.removed[component] = nil
		elseif component_type == COMPONENT_TYPES.component then
			target_changes.component[component] = changes.component[component]
			target_changes.removed[component] = changes.removed[component]

			changes.component[component] = nil
			changes.removed[component] = nil
		elseif component_type == COMPONENT_TYPES.pair then
			target_changes.pairs[component] = changes.pairs[component]
			changes.pairs[component] = nil
		elseif component_type == COMPONENT_TYPES.pair_value then
			local target_pairs = target_changes.pairs_values
			local pairs = changes.pairs_values

			target_pairs.changed[component] = pairs.changed[component]
			target_pairs.removed[component] = pairs.removed[component]

			pairs.changed[component] = nil
			pairs.removed[component] = nil
		end
	end

	--todo: move changes

	return target_storage
end

function masking_controller.bind_component_generator(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number,
	base_generator: MaskGenerator
)
	local component_lookup, entity_lookup = masking:get_component_lookup(entity, component, component_type)
	local generator = mask_generator.create(nil, function()
		return entity_lookup.generator.result:band(base_generator.result)
	end)

	local function subscribed()
		if not component_lookup then
			component_lookup = entity_lookup.filtered_components[component_type][component]
		end

		local current_storage = component_lookup.storage_group
		local new_storage =
			masking:move_component_storage(entity, component, component_type, current_storage, generator.result)

		component_lookup.storage_group = new_storage
	end

	generator:track(base_generator)
	generator:track(masking.active_members_generator)
	generator.subscribed = subscribed

	return generator
end

function masking_controller.rebind_component_generators(masking: MaskingInternal, entity: Entity)
	local entity_lookup = masking.lookups.entities[entity]
	if entity_lookup then
		for component_type, lookups in entity_lookup.filtered_components do
			for component, lookup in lookups do
				lookup.band_generator:destroy()

				local binded_generator =
					masking:bind_component_generator(entity, component, component_type, lookup.generator)
				lookup.band_generator = binded_generator
				binded_generator:run_subscribed()
			end
		end
	end
end

function masking_controller.get_or_postpone_entity_lookup(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number,
	filter: MemberFilter?
): EntityLookup?
	local lookup = masking.lookups.entities[entity]
	if lookup then
		return lookup
	end

	if filter ~= nil then
		set_component_index_entry(masking.lookups.postponed, entity, component, component_type, { filter = filter })
	else
		set_component_index_entry(masking.lookups.postponed, entity, component, component_type, { filter = nil })
	end

	return nil
end

function masking_controller.register_stop_entity(masking: MaskingInternal, entity: Entity)
	local lookup = masking.lookups.entities[entity]
	if not lookup then
		return
	end
	local storage = lookup.storage_group

	if storage.deletions.entities[entity] then
		return
	end
	storage.deletions.entities[entity] = true
end

function masking_controller.register_stop_component(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number
)
	local storage = masking:get_component_storage_group(entity, component, component_type) :: StorageGroup
	if not storage then
		return
	end

	local deletions = storage.deletions.components[entity]
	if deletions == nil then
		deletions = create_component_indexes() :: ComponentIndex<boolean>
		deletions[component_type][component] = true
		storage.deletions.components[entity] = deletions
	else
		if deletions[component_type][component] then
			return
		end
		deletions[component_type][component] = true
	end
end

function masking_controller.register_component_addition(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number
)
	local storage = masking:get_component_storage_group(entity, component, component_type)
	local additions = get_or_set_component_added(storage, entity)
	additions[component_type][component] = true
end

function masking_controller.unregister_stop_entity(masking: MaskingInternal, entity: Entity)
	local deletion_lookup = masking.lookups.deletions.entities[entity]
	if not deletion_lookup then
		return
	end
	local storage = deletion_lookup.storage_group

	if storage.deletions.entities[entity] then
		storage.deletions.entities[entity] = nil
		storage.deletions_count -= 1
	end
end

function masking_controller.unregister_stop_component(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number
)
	local deletion_lookup =
		get_component_index_entry(masking.lookups.deletions.components, entity, component, component_type)
	if deletion_lookup == nil then
		return
	end
	local storage = deletion_lookup.storage_group

	local deletions = storage.deletions.components[entity]
	if deletions then
		if deletions[component_type][component] then
			deletions[component_type][component] = nil
		end
	end
end

function masking_controller.unregister_component_addition(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number
)
	local storage: StorageGroup = masking:get_component_storage_group(entity, component, component_type)
	local additions = storage.changes.added_components[entity]
	if additions then
		additions[component_type][component] = nil
	end
end

function masking_controller.propagate_entity_addition(masking: MaskingInternal, entity: Entity)
	local entity_lookup = masking.lookups.entities[entity]
	if entity_lookup then
		entity_lookup.storage_group.changes.added[entity] = true

		for _, lookups in entity_lookup.filtered_components do
			for _, lookup in lookups do
				lookup.storage_group.changes.added[entity] = true
			end
		end
	end
end

function masking_controller.update_entity_filter(
	masking: MaskingInternal,
	entity: Entity,
	filter: MemberFilter?
): MaskGenerator
	local generator: MaskGenerator
	if filter then
		generator = masking:create_generator_from_filter(filter)
	else
		generator = mask_generator.follow(masking.active_members_generator)
	end

	local lookup = masking.lookups.entities[entity]

	local function subscribed()
		if not lookup then
			lookup = masking.lookups.entities[entity]
		end
		local current_storage = lookup.storage_group

		local new_storage = masking:move_entity_storage(entity, current_storage, generator.result)
		lookup.storage_group = new_storage
	end
	generator.subscribed = subscribed
	return generator
end

function masking_controller.start_entity(masking: MaskingInternal, entity: Entity, given_filter: GivenFilter?)
	local filter = get_usable_filter(given_filter)
	local generator = masking:update_entity_filter(entity, filter)

	local storage_group = masking:get_or_create_storage_group(generator.result)
	local active = get_or_set_active(storage_group, entity)
	active.is_entity_mask = true

	local new_lookup: EntityLookup = {
		generator = generator,
		filter = filter,
		storage_group = storage_group,
		filtered_components = create_component_indexes(),
		components = create_component_indexes(),
	}
	masking.lookups.entities[entity] = new_lookup

	local postponed = masking.lookups.postponed[entity]
	if postponed then
		for component_type, components in postponed do
			for component, postponed_info in components do
				masking:start_component(entity, component, component_type, postponed_info.filter)
			end
		end
		masking.lookups.postponed[entity] = nil
	end
end

function masking_controller.set_entity(masking: MaskingInternal, entity: Entity, given_filter: GivenFilter?)
	local filter = get_usable_filter(given_filter)
	local lookup = masking.lookups.entities[entity]
	if not lookup then
		utils.logerror "attempted to modify the filter of an unactive entity"
	end
	lookup.generator:destroy()

	local generator = masking:update_entity_filter(entity, filter)

	lookup.generator = generator
	lookup.filter = filter

	generator:run_subscribed()
	masking:rebind_component_generators(entity)
end

function masking_controller.stop_entity(masking: MaskingInternal, entity: Entity)
	local lookup = masking.lookups.entities[entity]
	if not lookup then
		utils.logerror "attemped to stop an unactive entity"
	end

	local postponed = masking.lookups.postponed[entity]

	for component_type, lookups in lookup.filtered_components do
		for component, component_lookup in lookups do
			component_lookup.band_generator:destroy()
			component_lookup.generator:destroy()
			remove_component_active(component_lookup.storage_group, entity, component, component_type)

			local component_storage = component_lookup.storage_group
			component_storage.shared_with[entity] = nil
			component_storage.changes.added[entity] = nil
			component_storage.changes.changed[entity] = nil
			component_storage.changes.added_components[entity] = nil

			if postponed == nil then
				postponed = create_component_indexes() :: PostponedList
				masking.lookups.postponed[entity] = postponed
			end
			postponed[component_type][component] = { filter = component_lookup.filter }
		end
	end
	for component_type, components in lookup.components do
		for component in components do
			if postponed == nil then
				postponed = create_component_indexes() :: PostponedList
				masking.lookups.postponed[entity] = postponed
			end
			postponed[component_type][component] = { filter = nil :: MemberFilter? }
		end
	end

	lookup.generator:destroy()
	remove_active(lookup.storage_group, entity)
	lookup.storage_group.changes.added[entity] = nil
	lookup.storage_group.changes.changed[entity] = nil
	lookup.storage_group.changes.added_components[entity] = nil

	masking.lookups.entities[entity] = nil
end

function masking_controller.cleanup_entity(masking: MaskingInternal, entity: Entity)
	masking.lookups.entities[entity] = nil
	masking.lookups.postponed[entity] = nil
	masking.lookups.deletions.entities[entity] = nil
	masking.lookups.deletions.components[entity] = nil
end

function masking_controller.update_component_filter(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number,
	filter: MemberFilter
)
	local generator = masking:create_generator_from_filter(filter)
	local band_generator = masking:bind_component_generator(entity, component, component_type, generator)
	return generator, band_generator
end

function masking_controller.start_component(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number,
	given_filter: GivenFilter?
)
	local filter = get_usable_filter(given_filter)
	local lookup = masking:get_or_postpone_entity_lookup(entity, component, component_type, filter)
	if lookup == nil then
		return
	end

	if filter == nil then
		lookup.components[component_type][component] = true
		get_or_set_component_active(lookup.storage_group.active[entity], component, component_type)
		return
	end

	local generator, band_generator = masking:update_component_filter(entity, component, component_type, filter)
	local storage_group = masking:get_or_create_storage_group(band_generator.result)
	local active = get_or_set_active(storage_group, entity)

	get_or_set_component_active(active, component, component_type)
	set_component_index_entry(storage_group.shared_with, entity, component, component_type, true)

	local component_lookup: ComponentLookup = {
		generator = generator,
		band_generator = band_generator,
		filter = filter :: MemberFilter?, -- what
		storage_group = storage_group,
	}
	lookup.filtered_components[component_type][component] = component_lookup
end

function masking_controller.set_component(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number,
	given_filter: GivenFilter?
)
	local filter = get_usable_filter(given_filter)
	local lookup = masking:get_or_postpone_entity_lookup(entity, component, component_type, filter)
	if lookup == nil then
		return
	end
	local component_lookup = lookup.filtered_components[component_type][component]

	if filter == nil then
		if component_lookup ~= nil then
			component_lookup.band_generator:destroy()
			component_lookup.generator:destroy()

			masking:merge_component_filter(entity, component, component_type)
		end
		return
	end

	local generator, band_generator = masking:update_component_filter(entity, component, component_type, filter)

	if component_lookup ~= nil then
		component_lookup.band_generator:destroy()
		component_lookup.generator:destroy()

		component_lookup.band_generator = band_generator
		component_lookup.generator = generator
		component_lookup.filter = filter

		band_generator:run_subscribed()
	else
		local desired_storage = masking:get_or_create_storage_group(band_generator.result)
		local new_storage: StorageGroup

		if desired_storage and desired_storage == lookup.storage_group then
			new_storage = lookup.storage_group
			set_component_index_entry(desired_storage.shared_with, entity, component, component_type, true)
		else
			new_storage = masking:move_component_storage(
				entity,
				component,
				component_type,
				lookup.storage_group,
				band_generator.result
			)
		end
		local new_lookup: ComponentLookup = {
			generator = generator,
			band_generator = band_generator,
			filter = filter :: MemberFilter?,
			storage_group = new_storage,
		}
		lookup.filtered_components[component_type][component] = new_lookup
		lookup.components[component_type][component] = nil
	end
end

function masking_controller.stop_component(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number
)
	local component_lookup, entity_lookup = masking:get_component_lookup(entity, component, component_type)
	if component_lookup ~= nil then
		component_lookup.band_generator:destroy()
		component_lookup.generator:destroy()

		remove_component_active(component_lookup.storage_group, entity, component, component_type)
		remove_component_index_entry(component_lookup.storage_group.shared_with, entity, component, component_type)
		entity_lookup.filtered_components[component_type][component] = nil
	else
		if entity_lookup then
			remove_component_active(entity_lookup.storage_group, entity, component, component_type)
		end
		entity_lookup.components[component_type][component] = nil
	end
end

function masking_controller.get_component_storage_group(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number
): StorageGroup
	local component_lookup, entity_lookup = masking:get_component_lookup(entity, component, component_type)

	if component_lookup ~= nil then
		return component_lookup.storage_group
	elseif entity_lookup then
		return entity_lookup.storage_group
	else
		error "attempted to use an entity that is not active"
	end
end

function masking_controller.allocate_entity_addition(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	component_type: number
)
	local lookup = masking:get_component_lookup(entity, component, component_type)
	if lookup ~= nil then
		lookup.storage_group.changes.added[entity] = true
	end
end

function masking_controller.allocate_component_change(
	masking: MaskingInternal,
	entity: Entity,
	component: Entity,
	value: any
)
	local storage = masking:get_component_storage_group(entity, component, COMPONENT_TYPES.component)
	local changes = get_or_set_changed(storage, entity)
	changes.component[component] = value
	changes.removed[component] = nil
end

function masking_controller.allocate_pair_value_change(
	masking: MaskingInternal,
	entity: Entity,
	relation: Entity,
	target: Entity,
	value: any
)
	local storage = masking:get_component_storage_group(entity, relation, COMPONENT_TYPES.pair_value)
	local changes = get_or_set_changed(storage, entity)
	local values = changes.pairs_values.changed[relation]
	if values == nil then
		values = {}
		changes.pairs_values.changed[relation] = values
	end
	values[target] = value

	local removed = changes.pairs_values.removed[relation]
	if removed ~= nil then
		removed[target] = nil
	end
end

function masking_controller.allocate_tag_addition(masking: MaskingInternal, entity: Entity, tag: Entity)
	local storage = masking:get_component_storage_group(entity, tag, COMPONENT_TYPES.tag)
	local changes = get_or_set_changed(storage, entity)
	changes.tagged[tag] = true
	changes.removed[tag] = nil
end

function masking_controller.allocate_pair_addition(
	masking: MaskingInternal,
	entity: Entity,
	relation: Entity,
	target: Entity
)
	local storage = masking:get_component_storage_group(entity, relation, COMPONENT_TYPES.pair)
	local changes = get_or_set_changed(storage, entity)
	local targets = changes.pairs[relation]
	if targets == nil then
		targets = {}
		changes.pairs[relation] = targets
	end
	targets[target] = true
end

function masking_controller.allocate_component_removal(masking: MaskingInternal, entity: Entity, component: Entity)
	local storage = masking:get_component_storage_group(entity, component, COMPONENT_TYPES.component)
	local changes = get_or_set_changed(storage, entity)

	changes.component[component] = nil
	changes.removed[component] = true
end

function masking_controller.allocate_tag_removal(masking: MaskingInternal, entity: Entity, tag: Entity)
	local storage = masking:get_component_storage_group(entity, tag, COMPONENT_TYPES.tag)
	local changes = get_or_set_changed(storage, entity)

	changes.tagged[tag] = nil
	changes.removed[tag] = true
end

function masking_controller.allocate_pair_removal(
	masking: MaskingInternal,
	entity: Entity,
	relation: Entity,
	target: Entity
)
	local storage = masking:get_component_storage_group(entity, relation, COMPONENT_TYPES.pair)
	local changes = get_or_set_changed(storage, entity)
	local targets = changes.pairs[relation]
	if targets == nil then
		targets = {}
		changes.pairs[relation] = targets
	end
	targets[target] = false
end

function masking_controller.allocate_pair_value_removal(
	masking: MaskingInternal,
	entity: Entity,
	relation: Entity,
	target: Entity
)
	local storage = masking:get_component_storage_group(entity, relation, COMPONENT_TYPES.pair_value)
	local changes = get_or_set_changed(storage, entity)
	local removed = changes.pairs_values.removed[relation]
	if removed == nil then
		removed = {}
		changes.pairs_values.removed[relation] = removed
	end
	removed[target] = true

	local values = changes.pairs_values.changed[relation]
	if values ~= nil then
		values[target] = nil
	end
end

local function remap_bitmask(
	bitmask: Bitmask,
	from: { [Member]: number },
	target: { [Member]: number },
	size: number?
): Bitmask
	local result = utils.bitmask.create(size)
	for member, index in target do
		local old_index = from[member]
		if old_index then
			local old_bit = bitmask:get(old_index)
			if old_bit then
				result:set(index, old_bit)
			else
				result:clear(index)
			end
		end
	end
	return result
end

local function bitmask_from_set(masking: MaskingInternal, member_set: { [Member]: boolean }): utils.Bitmask
	local new_bitmask = utils.bitmask.create(masking.member_count)
	for member: Member in member_set do
		local index = masking.member_indexes[member]
		if not index then
			if utils.is_client_valid(member) then
				masking_controller.register_client(masking, member)
				index = masking.member_indexes[member]
			else
				index = masking.member_indexes[masking.client_aliases[member]]
			end
		end
		if index then
			new_bitmask:set(index)
		end
	end
	return new_bitmask
end

function masking_controller.merge_storages(
	masking: MaskingInternal,
	old_storage: StorageGroup,
	new_storage: StorageGroup
)
	if new_storage == old_storage then
		return
	end
	for entity, active in old_storage.active do
		local new_active = get_or_set_active(new_storage, entity)
		merge_component_actives(active, new_active)

		if active.is_entity_mask then
			local lookup = masking.lookups.entities[entity]
			lookup.storage_group = new_storage
			new_active.is_entity_mask = true
		end
	end
	for entity, shared_components in old_storage.shared_with do
		for component_type, components in shared_components do
			for component in components do
				set_component_index_entry(new_storage.shared_with, entity, component, component_type, true)

				local lookup = masking:get_component_lookup(entity, component, component_type)
				if lookup ~= nil then
					lookup.storage_group = new_storage
				end
			end
		end
	end
	for entity, added_components in old_storage.changes.added_components do
		local new_added_components = get_or_set_component_added(new_storage, entity)
		merge_component_additions(new_added_components, added_components)
	end
	for entity, changes in old_storage.changes.changed do
		local new_changes = get_or_set_changed(new_storage, entity)
		merge_component_changes(new_changes, changes)
	end
	for entity in old_storage.changes.added do
		new_storage.changes.added[entity] = true
	end
	for entity in old_storage.deletions.entities do
		new_storage.deletions.entities[entity] = true
	end
	for entity, deleted_components in old_storage.deletions.components do
		for component_type, components in deleted_components do
			for component in components do
				set_component_index_entry(new_storage.deletions.components, entity, component, component_type, true)
			end
		end
	end
end

function masking_controller.compact_members(masking: MaskingInternal)
	-- we dont recompute as nothing should've changed
	-- so this should be hopefully quite cheap
	local old_indexes = masking.member_indexes
	local new_indexes: { [Member]: number } = {}

	local new_count = 0
	for member in old_indexes do
		new_indexes[member] = new_count

		if masking.client_indexes[member] then
			masking.client_indexes[member] = new_count
		end
		if masking.group_indexes[new_count] then
			masking.group_indexes[new_count] = member
		end

		new_count += 1
	end
	masking.member_indexes = new_indexes
	masking.member_count = new_count

	for _, entity_lookup in masking.lookups.entities do
		local entity_generator = entity_lookup.generator
		local entity_bitmask = entity_generator.bitmask
		if entity_bitmask then
			entity_generator.bitmask = remap_bitmask(entity_bitmask, old_indexes, new_indexes, new_count)
		end
		entity_generator.result = remap_bitmask(entity_generator.result, old_indexes, new_indexes, new_count)

		for _, lookups in entity_lookup.filtered_components do
			for _, component_lookup in lookups do
				local component_generator = component_lookup.generator

				local component_bitmask = component_generator.bitmask
				if component_bitmask then
					component_generator.bitmask = remap_bitmask(component_bitmask, old_indexes, new_indexes, new_count)
				end
				component_generator.result =
					remap_bitmask(component_generator.result, old_indexes, new_indexes, new_count)

				local band_generator = component_lookup.band_generator
				local band_bitmask = band_generator.bitmask
				if band_bitmask then
					band_generator.bitmask = remap_bitmask(band_bitmask, old_indexes, new_indexes, new_count)
				end
				band_generator.result = remap_bitmask(band_generator.result, old_indexes, new_indexes, new_count)
			end
		end
	end

	local all = masking.all_members_generator
	local unactive = masking.unactive_members_generator
	local active = masking.active_members_generator

	all.bitmask = remap_bitmask(all.bitmask, old_indexes, new_indexes, new_count)
	unactive.bitmask = remap_bitmask(unactive.bitmask, old_indexes, new_indexes, new_count)
	active.result = remap_bitmask(active.result, old_indexes, new_indexes, new_count)

	local new_storages: Storages = {}

	for _, storage in masking.storages do
		local new_bitmask = remap_bitmask(storage.mask.bitmask, old_indexes, new_indexes, new_count)
		storage.mask.bitmask = new_bitmask
		local new_hash = new_bitmask:tostring()
		storage.mask.hash = new_hash
		storage.mask.members = masking:get_clients_from_bitmask(new_bitmask)

		local existing = new_storages[new_hash]
		if existing then
			masking:merge_storages(storage, existing)
		else
			new_storages[new_hash] = storage
		end
	end
	masking.storages = new_storages
end

function masking_controller.create_generator_from_filter(masking: MaskingInternal, filter: MemberFilter): MaskGenerator
	local is_include = is_include_filter(filter)
	if is_include then
		return masking:create_include_generator(filter) :: MaskGenerator
	else
		return masking:create_exclude_generator(filter) :: MaskGenerator
	end
end

function masking_controller.create_exclude_generator(masking: MaskingInternal, exclude: MemberFilter)
	local bitmask = bitmask_from_set(masking, exclude)
	local active_members = masking.active_members_generator

	local new_generator = mask_generator.create(bitmask, function(generator)
		local current = generator.bitmask :: utils.Bitmask
		return active_members.result:band(current:bnot())
	end)
	new_generator:track(active_members)

	return new_generator
end

-- TODO: check for players existing and register them if they don't
function masking_controller.create_include_generator(masking: MaskingInternal, include: MemberFilter): MaskGenerator
	local bitmask = bitmask_from_set(masking, include)
	local active_members = masking.active_members_generator

	local new_generator = mask_generator.create(bitmask, function(generator)
		local current = generator.bitmask :: utils.Bitmask
		return current:band(active_members.result)
	end)
	new_generator:track(active_members)

	return new_generator
end

function masking_controller.create_all_members_generator(masking: MaskingInternal)
	local filter: MemberFilter = {}
	for member in masking.member_indexes do
		filter[member] = true
	end
	local bitmask = utils.bitmask.from_set(masking.member_indexes, filter, masking.member_count)
	return mask_generator.create(bitmask) :: MaskGeneratorWithBitmask
end
function masking_controller.create_unactive_generator(masking: MaskingController)
	local bitmask = utils.bitmask.from_set(masking.member_indexes, masking.unreplicated, masking.member_count)
	return mask_generator.create(bitmask) :: MaskGeneratorWithBitmask
end
function masking_controller.create_active_generator(masking: MaskingController): MaskGenerator
	local all = masking.all_members_generator
	local unactive = masking.unactive_members_generator

	local new_generator = mask_generator.create(nil, function()
		return all.result:band(unactive.result:bnot())
	end)
	new_generator:track(all)
	new_generator:track(unactive)

	return new_generator
end

--function masking_controller.register_mask_group(masking: MaskingInternal, group: Member) end

--function masking_controller.unregister_mask_group(masking: MaskingInternal, group: Member) end

function masking_controller.register_client(masking: MaskingInternal, member: Member)
	if masking.member_indexes[member] then
		return
	end

	local current = masking.member_count
	masking.client_indexes[member] = current
	masking.member_indexes[member] = current
	masking.member_count += 1

	masking.unreplicated[member] = true
	masking.unactive_members_generator.bitmask:set(current)
	masking.all_members_generator.bitmask:set(current)
	masking.active_members_generator:compute()

	if masking.member_count >= masking.compact_count then
		masking:compact_members()
	end
end

function masking_controller.unregister_client(masking: MaskingInternal, member: Member)
	local index = masking.member_indexes[member]
	if index == nil then
		return
	end
	masking.client_indexes[member] = nil
	masking.member_indexes[member] = nil
	masking.member_count -= 1
	masking.all_members_generator.bitmask:clear(index)
	masking.active_members_generator:compute()
end

function masking_controller.activate_client(masking: MaskingInternal, member: Member)
	local index = masking.client_indexes[member]

	masking.unreplicated[member] = nil
	masking.unactive_members_generator.bitmask:clear(index)
	masking.active_members_generator:compute()
end

function masking_controller.member_is_active(masking: MaskingInternal, member: Member): boolean
	local index = masking.client_indexes[member]
	if index == nil then
		return false
	end

	return masking.active_members_generator.result:get(index)
end

local function create(): MaskingController
	local self = {} :: MaskingInternal

	self.member_indexes = {}
	self.client_indexes = {}
	self.group_indexes = {}
	self.client_aliases = {}
	self.member_count = 0
	self.compact_count = 100
	self.storages = {}
	self.lookups = {
		entities = {},
		components = {},
		deletions = {
			entities = {},
			components = {},
		},
		filter_deltas = {
			entities = {},
			components = {},
		},
		postponed = {},
	}
	self.unreplicated = {}
	self.all_members_generator = masking_controller.create_all_members_generator(self)
	self.unactive_members_generator = masking_controller.create_unactive_generator(self)
	self.active_members_generator = masking_controller.create_active_generator(self)

	return setmetatable(self, masking_controller) :: any
end

return { create = create, masking_controller = masking_controller, COMPONENT_TYPES = COMPONENT_TYPES }
