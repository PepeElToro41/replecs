local jecs = require(script.Parent.Parent.roblox_packages.jecs)
local utils = require(script.Parent.utils)
local mask_generator = require(script.mask_generator)

type Bitmask = utils.Bitmask
type MaskGenerator = mask_generator.MaskGenerator

type MemberFilter = Set<Member>
type Member = any
type MaskHash = string

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }

type ComponentIndex<T> = {
	[number]: { [jecs.Entity]: T },
}
type EntityComponentIndex<T> = {
	[jecs.Entity]: ComponentIndex<T>,
}

type Lookup = {
	generator: MaskGenerator,
	-- filter in component lookups will never be nil
	filter: MemberFilter?,
	storage_group: StorageGroup,
}
type ComponentLookup = Lookup & {
	band_generator: MaskGenerator,
}

type EntityChanges = {
	tagged: { [jecs.Entity]: boolean },
	component: { [jecs.Entity]: any },
	removed: { [jecs.Entity]: boolean },
	pairs: { [jecs.Entity]: Set<jecs.Entity> },
}

type LookupsList = {
	entities: Map<jecs.Entity, Lookup>,
	components: EntityComponentIndex<ComponentLookup>,

	deletions: {
		entities: Map<jecs.Entity, Lookup>,
		components: EntityComponentIndex<Lookup>,
	},

	posponed: EntityComponentIndex<MemberFilter>,
}

type ActiveEntity = {
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
		entities: Set<jecs.Entity>,
		components: EntityComponentIndex<boolean>,
	},
	deletions_count: number,

	active: Map<jecs.Entity, ActiveEntity>, -- set of active entities
	active_count: number,

	changes: {
		added: Map<jecs.Entity, boolean>,
		changed: Map<jecs.Entity, EntityChanges>,
	},
}

type Storages = {
	[MaskHash]: StorageGroup,
}

export type MaskingController = {
	member_count: number,
	member_indexes: { [Member]: number },
	unreplicated: Set<Member>,

	all_members_generator: MaskGenerator,
	active_members_generator: MaskGenerator,
	unactive_members_generator: MaskGenerator,

	storages: Storages,
	lookups: LookupsList,

	register_stop_entity: (self: MaskingController, entity: jecs.Entity) -> (),
	register_stop_component: (
		self: MaskingController,
		entity: jecs.Entity,
		component: jecs.Entity,
		component_type: number
	) -> (),
	unregister_stop_entity: (self: MaskingController, entity: jecs.Entity) -> (),
	unregister_stop_component: (
		self: MaskingController,
		entity: jecs.Entity,
		component: jecs.Entity,
		component_type: number
	) -> (),

	propagate_entity_addition: (self: MaskingController, entity: jecs.Entity) -> (),

	start_entity: (self: MaskingController, entity: jecs.Entity, filter: MemberFilter?) -> (),
	set_entity: (self: MaskingController, entity: jecs.Entity, filter: MemberFilter?) -> (),
	stop_entity: (self: MaskingController, entity: jecs.Entity) -> (),

	start_component: (
		self: MaskingController,
		entity: jecs.Entity,
		component: jecs.Entity,
		component_type: number,
		filter: MemberFilter?
	) -> (),
	set_component: (
		self: MaskingController,
		entity: jecs.Entity,
		component: jecs.Entity,
		component_type: number,
		filter: MemberFilter?
	) -> (),
	stop_component: (
		self: MaskingController,
		entity: jecs.Entity,
		component: jecs.Entity,
		component_type: number
	) -> (),

	allocate_entity_addition: (
		self: MaskingController,
		entity: jecs.Entity,
		component: jecs.Entity,
		component_type: number
	) -> (),

	allocate_component_change: (self: MaskingController, entity: jecs.Entity, component: jecs.Entity, value: any) -> (),
	allocate_tag_addition: (self: MaskingController, entity: jecs.Entity, tag: jecs.Entity) -> (),
	allocate_pair_addition: (
		self: MaskingController,
		entity: jecs.Entity,
		relation: jecs.Entity,
		target: jecs.Entity
	) -> (),

	allocate_component_removal: (self: MaskingController, entity: jecs.Entity, component: jecs.Entity) -> (),
	allocate_tag_removal: (self: MaskingController, entity: jecs.Entity, tag: jecs.Entity) -> (),
	allocate_pair_removal: (
		self: MaskingController,
		entity: jecs.Entity,
		relation: jecs.Entity,
		target: jecs.Entity
	) -> (),
}

local COMPONENT_TYPES = {
	component = 1,
	tag = 2,
	pair = 3,
}

local masking_controller = {}
masking_controller.__index = masking_controller

export type MaskingInternal = MaskingController & typeof(masking_controller)

function masking_controller.get_members_from_bitmask(controller: MaskingInternal, bitmask: Bitmask): Array<Member>
	local members: { Member } = {}
	for player, index in controller.member_indexes do
		if bitmask:get(index) then
			table.insert(members, player)
		end
	end
	return members
end

local function create_component_indexes()
	return { {}, {}, {}, {} }
end

local function create_entity_changes(): EntityChanges
	return {
		tagged = {},
		component = {},
		removed = {},
		pairs = {},
	}
end

local function get_or_set_changes(storage: StorageGroup, entity: jecs.Entity)
	local changes: EntityChanges = storage.changes.changed[entity]
	if changes == nil then
		changes = create_entity_changes()
		storage.changes.changed[entity] = changes
	end

	return changes
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
			members = members or controller:get_members_from_bitmask(bitmask),
		},
		is_empty = true,
		shared_with = {},

		changes = {
			added = {},
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
	for player, allow in filter do
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
		components = create_component_indexes(),
		component_count = 0,
		is_entity_mask = false,
	}
end

local function create_new_changes(): EntityChanges
	return {
		tagged = {},
		component = {},
		removed = {},
		pairs = {},
	}
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

local function get_component_index_entry<T>(
	index: EntityComponentIndex<T>,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number
): T?
	local entity_index = index[entity]
	if entity_index == nil then
		return nil
	end
	local component_index = entity_index[component_type]

	return component_index and component_index[component]
end

local function set_component_index_entry<T>(
	index: EntityComponentIndex<T>,
	entity: jecs.Entity,
	component: jecs.Entity,
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
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number
)
	local entity_index = index[entity]
	if entity_index == nil then
		return
	end
	entity_index[component_type][component] = nil
end

masking_controller.get_component_index_entry = get_component_index_entry
masking_controller.set_component_index_entry = set_component_index_entry
masking_controller.remove_component_index_entry = remove_component_index_entry

local function get_or_set_changed(storage: StorageGroup, entity: jecs.Entity, changed: EntityChanges?): EntityChanges
	local storage_changed = storage.changes.changed[entity]
	if storage_changed == nil then
		storage_changed = changed or create_new_changes()
		storage.changes.changed[entity] = storage_changed
	end
	return storage_changed
end

local function get_or_set_active(storage: StorageGroup, entity: jecs.Entity, active: ActiveEntity?): ActiveEntity
	local storage_active = storage.active[entity]
	if storage_active == nil then
		storage_active = active or create_new_active()
		storage.active[entity] = storage_active
		storage.active_count += 1
	end
	return storage_active
end

local function remove_active(storage: StorageGroup, entity: jecs.Entity): ActiveEntity
	local active = storage.active[entity]
	if active then
		storage.active[entity] = nil
		storage.active_count -= 1
		-- todo: check if empty
		return active
	end
	error "attempted to remove an entity that wasn't active"
end

local function get_or_set_component_active(active: ActiveEntity, component: jecs.Entity, component_type: number)
	local components = active.components[component_type]
	if components[component] == nil then
		components[component] = true
		active.component_count += 1
	end
end

local function remove_component_active(
	storage: StorageGroup,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number
)
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

local function dissect_component_actives(
	storage: StorageGroup,
	entity: jecs.Entity,
	shared_index: ComponentIndex<boolean>
): ActiveEntity?
	local new_active
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
function dissect_component_changes(changes: EntityChanges, shared_index: ComponentIndex<boolean>)
	local new_changes

	for component, change in changes.component do
		local is_shared = shared_index[COMPONENT_TYPES.component] and shared_index[COMPONENT_TYPES.component][component]
		if is_shared then
			new_changes = new_changes or create_new_changes()
			new_changes.component[component] = change
			changes.component[component] = nil
		end
	end
	for entity, entity_changes in changes.tagged do
		local is_shared = shared_index[COMPONENT_TYPES.tag]
		if is_shared then
			new_changes = new_changes or create_new_changes()
			new_changes.tagged[entity] = entity_changes
			changes.tagged[entity] = nil
		end
	end
	for entity, entity_changes in changes.pairs do
		local is_shared = shared_index[COMPONENT_TYPES.pair]
		if is_shared then
			new_changes = new_changes or create_new_changes()
			new_changes.pairs[entity] = entity_changes
			changes.pairs[entity] = nil
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
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number
)
	local component_lookup = get_component_index_entry(masking.lookups.components, entity, component, component_type)
	local entity_lookup = masking.lookups.entities[entity]
	if not entity_lookup then
		error "attempted to merge a component filter to an unactive entity"
	end

	if component_lookup then
		local new_storage = masking:move_component_storage(
			entity,
			component,
			component_type,
			component_lookup.storage_group,
			entity_lookup.generator.bitmask
		)
		remove_component_index_entry(masking.lookups.components, entity, component, component_type)
		remove_component_index_entry(new_storage.shared_with, entity, component, component_type)
	else
		get_or_set_component_active(entity_lookup.storage_group.active[entity], component, component_type)
	end
end

function masking_controller.move_entity_storage(
	masking: MaskingInternal,
	entity: jecs.Entity,
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

	local old_changes = storage.changes.changed[entity]
	if old_changes then
		local new_changes = get_or_set_changed(target_storage, entity)

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
	return target_storage
end

function masking_controller.move_component_storage(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
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

	return target_storage
end

function masking_controller.bind_component_generator(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number,
	base_generator: MaskGenerator
)
	local entity_lookup = masking.lookups.entities[entity]
	local component_lookups = masking.lookups.components[entity]
	local component_lookup = component_lookups and component_lookups[component_type][component]
	local generator = mask_generator.create(nil, function()
		return entity_lookup.generator.bitmask:band(base_generator.bitmask)
	end)

	local function subscribed()
		if not component_lookup then
			component_lookup = component_lookups and component_lookups[component_type][component]
		end

		local current_storage = component_lookup.storage_group
		local new_storage =
			masking:move_component_storage(entity, component, component_type, current_storage, generator.bitmask)

		component_lookup.storage_group = new_storage
	end

	generator:track(base_generator)
	generator:track(masking.active_members_generator)
	generator.subscribed = subscribed

	return generator
end

function masking_controller.rebind_component_generators(masking: MaskingInternal, entity: jecs.Entity)
	local component_lookups = masking.lookups.components[entity]
	if component_lookups then
		for component_type, lookups in component_lookups do
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

function masking_controller.get_or_pospone_entity_lookup(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number,
	filter: MemberFilter?
): Lookup?
	local lookup = masking.lookups.entities[entity]
	if lookup then
		return lookup
	end

	if filter == nil then
		return nil
	end

	set_component_index_entry(masking.lookups.posponed, entity, component, component_type, filter)
	return nil
end

function masking_controller.register_stop_entity(masking: MaskingInternal, entity: jecs.Entity)
	local lookup = masking.lookups.entities[entity]
	local storage = lookup.storage_group

	if storage.deletions.entities[entity] then
		return
	end
	storage.deletions.entities[entity] = true
	storage.deletions_count += 1
end

function masking_controller.register_stop_component(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number
)
	local lookup =
		get_component_index_entry(masking.lookups.components, entity, component, component_type) :: ComponentLookup
	local storage = lookup.storage_group

	local deletions = storage.deletions.components[entity]
	if deletions == nil then
		deletions = create_component_indexes()
		deletions[component_type][component] = true
		storage.deletions.components[entity] = deletions
		storage.deletions_count += 1
	else
		if deletions[component_type][component] then
			return
		end
		deletions[component_type][component] = true
		storage.deletions_count += 1
	end
end
function masking_controller.unregister_stop_entity(masking: MaskingInternal, entity: jecs.Entity)
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
	entity: jecs.Entity,
	component: jecs.Entity,
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
			storage.deletions_count -= 1
		end
	end
end

function masking_controller.propagate_entity_addition(masking: MaskingInternal, entity: jecs.Entity)
	local entity_lookup = masking.lookups.entities[entity]
	if entity_lookup then
		entity_lookup.storage_group.changes.added[entity] = true
	end

	local component_lookups = masking.lookups.components[entity]
	if component_lookups then
		for component_type, lookups in component_lookups do
			for component, lookup in lookups do
				lookup.storage_group.changes.added[entity] = true
			end
		end
	end
end

function masking_controller.update_entity_filter(masking: MaskingInternal, entity: jecs.Entity, filter: MemberFilter?)
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

		local new_storage = masking:move_entity_storage(entity, current_storage, generator.bitmask)
		lookup.storage_group = new_storage
	end
	generator.subscribed = subscribed
	return generator
end

function masking_controller.start_entity(masking: MaskingInternal, entity: jecs.Entity, filter: MemberFilter?)
	local generator = masking:update_entity_filter(entity, filter)

	local storage_group = masking:get_or_create_storage_group(generator.bitmask)
	local active = get_or_set_active(storage_group, entity)
	active.is_entity_mask = true

	masking.lookups.entities[entity] = {
		generator = generator,
		filter = filter,
		storage_group = storage_group,
	}

	local posponed = masking.lookups.posponed[entity]
	if posponed then
		for component_type, components in posponed do
			for component, component_filter in components do
				masking:start_component(entity, component, component_type, component_filter)
			end
		end
	end
end

function masking_controller.set_entity(masking: MaskingInternal, entity: jecs.Entity, filter: MemberFilter?)
	local lookup = masking.lookups.entities[entity]
	if not lookup then
		error "attempted to modify the filter of an unactive entity"
	end
	lookup.generator:destroy()

	local generator = masking:update_entity_filter(entity, filter)

	lookup.generator = generator
	lookup.filter = filter

	generator:run_subscribed()
	masking:rebind_component_generators(entity)
end

function masking_controller.stop_entity(masking: MaskingInternal, entity: jecs.Entity)
	local lookup = masking.lookups.entities[entity]
	if not lookup then
		error "attemped to stop an unactive entity"
	end

	local posponed = masking.lookups.posponed[entity]

	local components_lookup = masking.lookups.components[entity]
	if components_lookup then
		for component_type, lookups in components_lookup do
			for component, component_lookup in lookups do
				component_lookup.band_generator:destroy()
				component_lookup.generator:destroy()
				remove_component_active(component_lookup.storage_group, entity, component, component_type)

				if posponed == nil then
					posponed = create_component_indexes()
					masking.lookups.posponed[entity] = posponed
				end
				posponed[component_type][component] = component_lookup.filter :: MemberFilter
			end
		end
	end

	lookup.generator:destroy()
	remove_active(lookup.storage_group, entity)
	lookup.storage_group.changes.added[entity] = nil
	lookup.storage_group.changes.changed[entity] = nil

	masking.lookups.components[entity] = nil
	masking.lookups.entities[entity] = nil
end

function masking_controller.update_component_filter(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number,
	filter: MemberFilter
)
	local generator = masking:create_generator_from_filter(filter)
	local band_generator = masking:bind_component_generator(entity, component, component_type, generator)
	return generator, band_generator
end

function masking_controller.start_component(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number,
	filter: MemberFilter?
)
	local lookup = masking:get_or_pospone_entity_lookup(entity, component, component_type, filter)
	if lookup == nil then
		return
	end

	if filter == nil then
		get_or_set_component_active(lookup.storage_group.active[entity], component, component_type)
		return
	end

	local generator, band_generator = masking:update_component_filter(entity, component, component_type, filter)
	local storage_group = masking:get_or_create_storage_group(band_generator.bitmask)
	local active = get_or_set_active(storage_group, entity)

	get_or_set_component_active(active, component, component_type)
	set_component_index_entry(storage_group.shared_with, entity, component, component_type, true)

	set_component_index_entry(masking.lookups.components, entity, component, component_type, {
		generator = generator,
		band_generator = band_generator,
		filter = filter,
		storage_group = storage_group,
	})
end

function masking_controller.set_component(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number,
	filter: MemberFilter?
)
	local lookup = masking:get_or_pospone_entity_lookup(entity, component, component_type, filter)
	if lookup == nil then
		return
	end

	local component_lookup = get_component_index_entry(masking.lookups.components, entity, component, component_type)
	if component_lookup == nil then
		error "attempted to modify the filter of an unactive component"
	end

	component_lookup.band_generator:destroy()
	component_lookup.generator:destroy()

	if filter == nil then
		masking:merge_component_filter(entity, component, component_type)
		return
	end

	local generator, band_generator = masking:update_component_filter(entity, component, component_type, filter)

	component_lookup.band_generator = band_generator
	component_lookup.generator = generator
	component_lookup.filter = filter

	band_generator:run_subscribed()
end

function masking_controller.stop_component(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number
)
	local lookup = get_component_index_entry(masking.lookups.components, entity, component, component_type)
	if lookup then
		lookup.band_generator:destroy()
		lookup.generator:destroy()

		remove_component_active(lookup.storage_group, entity, component, component_type)
		remove_component_index_entry(lookup.storage_group.shared_with, entity, component, component_type)
		remove_component_index_entry(masking.lookups.components, entity, component, component_type)
	else
		local entity_lookup = masking.lookups.entities[entity]
		if entity_lookup then
			remove_component_active(entity_lookup.storage_group, entity, component, component_type)
		end
	end
end

function masking_controller.get_component_storage_group(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number
)
	local component_lookup = masking_controller.get_component_index_entry(
		masking.lookups.components,
		entity,
		component,
		COMPONENT_TYPES.component
	)
	if component_lookup then
		return component_lookup.storage_group
	else
		local entity_lookup = masking.lookups.entities[entity]
		if not entity_lookup then
			error "attempted to use an entity that is not active"
		end
		return entity_lookup.storage_group
	end
end

function masking_controller.allocate_entity_addition(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number
)
	local lookup = get_component_index_entry(masking.lookups.components, entity, component, component_type)
	if lookup then
		lookup.storage_group.changes.added[entity] = true
	end
end

function masking_controller.allocate_component_change(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	value: any
)
	local storage = masking:get_component_storage_group(entity, component, COMPONENT_TYPES.component)
	local changes = get_or_set_changes(storage, entity)
	changes.component[component] = value
end

function masking_controller.allocate_tag_addition(masking: MaskingInternal, entity: jecs.Entity, tag: jecs.Entity)
	local storage = masking:get_component_storage_group(entity, tag, COMPONENT_TYPES.tag)
	local changes = get_or_set_changes(storage, entity)
	changes.tagged[tag] = true
end

function masking_controller.allocate_pair_addition(
	masking: MaskingInternal,
	entity: jecs.Entity,
	relation: jecs.Entity,
	target: jecs.Entity
)
	local storage = masking:get_component_storage_group(entity, relation, COMPONENT_TYPES.pair)
	local changes = get_or_set_changes(storage, entity)
	local targets = changes.pairs[relation]
	if targets == nil then
		targets = {}
		changes.pairs[relation] = targets
	end
	targets[target] = true
end

function masking_controller.allocate_component_removal(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity
)
	local storage = masking:get_component_storage_group(entity, component, COMPONENT_TYPES.component)
	local changes = get_or_set_changes(storage, entity)

	if changes.component[component] then
		changes.component[component] = nil
	end
	changes.removed[component] = true
end

function masking_controller.allocate_tag_removal(masking: MaskingInternal, entity: jecs.Entity, tag: jecs.Entity)
	local storage = masking:get_component_storage_group(entity, tag, COMPONENT_TYPES.tag)
	local changes = get_or_set_changes(storage, entity)

	if changes.tagged[tag] then
		changes.tagged[tag] = nil
	end
	changes.removed[tag] = true
end

function masking_controller.allocate_pair_removal(
	masking: MaskingInternal,
	entity: jecs.Entity,
	relation: jecs.Entity,
	target: jecs.Entity
)
	local storage = masking:get_component_storage_group(entity, relation, COMPONENT_TYPES.pair)
	local changes = get_or_set_changes(storage, entity)
	local targets = changes.pairs[relation]
	if targets == nil then
		targets = {}
		changes.pairs[relation] = targets
	end
	targets[target] = false
end

function masking_controller.mark_entity_deletion(masking: MaskingInternal, entity: jecs.Entity) end

function masking_controller.mark_component_deletion(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number
)
end

function masking_controller.revive_entity(masking: MaskingInternal, entity: jecs.Entity) end

function masking_controller.revive_component(
	masking: MaskingInternal,
	entity: jecs.Entity,
	component: jecs.Entity,
	component_type: number
)
end

function masking_controller.create_generator_from_filter(masking: MaskingInternal, filter: MemberFilter): MaskGenerator
	local is_include = is_include_filter(filter)
	if is_include then
		return masking:create_include_generator(filter)
	else
		return masking:create_exclude_generator(filter)
	end
end

function masking_controller.create_exclude_generator(masking: MaskingInternal, exclude: MemberFilter): MaskGenerator
	local bitmask = utils.bitmask.from_set(masking.member_indexes, exclude, masking.member_count)
	local active = masking.active_members_generator

	local generator = mask_generator.create(nil, function()
		return active.bitmask:band(bitmask:bnot())
	end)
	generator:track(active)

	return generator
end

function masking_controller.create_include_generator(masking: MaskingInternal, filter: MemberFilter): MaskGenerator
	local bitmask = utils.bitmask.from_set(masking.member_indexes, filter, masking.member_count)
	local active = masking.active_members_generator

	local generator = mask_generator.create(nil, function()
		return bitmask:band(active.bitmask)
	end)
	generator:track(active)

	return generator
end
function masking_controller.create_all_members_generator(masking: MaskingInternal): MaskGenerator
	local filter: MemberFilter = {}
	for member in masking.member_indexes do
		filter[member] = true
	end
	local bitmask = utils.bitmask.from_set(masking.member_indexes, filter, masking.member_count)
	return mask_generator.create(bitmask)
end
function masking_controller.create_unactive_generator(masking: MaskingController): MaskGenerator
	local bitmask = utils.bitmask.from_set(masking.member_indexes, masking.unreplicated, masking.member_count)
	return mask_generator.create(bitmask)
end
function masking_controller.create_active_generator(masking: MaskingController): MaskGenerator
	local all = masking.all_members_generator
	local unactive = masking.unactive_members_generator

	local new_generator = mask_generator.create(nil, function()
		return all.bitmask:band(unactive.bitmask:bnot())
	end)
	new_generator:track(all)
	new_generator:track(unactive)

	return new_generator
end

function masking_controller.register_member(masking: MaskingInternal, member: Member)
	local current = masking.member_count
	masking.member_indexes[member] = current
	masking.member_count += 1

	masking.unreplicated[member] = true
	masking.unactive_members_generator.bitmask:set(current)
	masking.all_members_generator.bitmask:set(current)
	masking.active_members_generator:compute()
end

function masking_controller.activate_member(masking: MaskingInternal, member: Member)
	local index = masking.member_indexes[member]
	if index == nil then
		masking:register_member(member)
		index = masking.member_indexes[member]
	end

	masking.unreplicated[member] = nil
	masking.unactive_members_generator.bitmask:clear(index)
	masking.active_members_generator:compute()
end

local function create(): MaskingController
	local self = {} :: MaskingInternal

	self.member_indexes = {}
	self.member_count = 0
	self.storages = {}
	self.lookups = {
		entities = {},
		components = {},
		deletions = {
			entities = {},
			components = {},
		},
		posponed = {},
	}
	self.unreplicated = {}
	self.all_members_generator = masking_controller.create_all_members_generator(self)
	self.unactive_members_generator = masking_controller.create_unactive_generator(self)
	self.active_members_generator = masking_controller.create_active_generator(self)

	return setmetatable(self, masking_controller) :: any
end

return { create = create, masking_controller = masking_controller, COMPONENT_TYPES = COMPONENT_TYPES }
