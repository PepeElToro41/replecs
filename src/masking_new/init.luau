local common = require "./common"
local types = require "./types"
local utils = require "./utils"

type Entity = common.Entity
type Component<T = any> = common.Component<T>

type Member = any
type ComponentEntryType = number
type BitmaskHash = string

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }

type Bitmask = utils.Bitmask
type StorageGroupInfo = {
	bitmask: Bitmask,
	hash: BitmaskHash,
	members: Array<Member>,
}

export type ComponentIndex<T> = {
	[ComponentEntryType]: { [Component]: T },
}
export type EntityComponentIndex<T> = {
	[Entity]: ComponentIndex<T>,
}

type BaseLookup = {
	filter: types.AnyFilter?,
	storage_group: StorageGroup,
}

type ComponentLookup = BaseLookup & {}

type EntityLookup = BaseLookup & {
	filtered_components: ComponentIndex<ComponentLookup>,
	unfiltered_components: ComponentIndex<true>,
}

type MaskingLookups = {
	entities: Map<Entity, EntityLookup>,
	bitmask_deltas: {
		entities: Map<Entity, BaseLookup>,
		components: EntityComponentIndex<BaseLookup>,
	},
	postponed: { [Entity]: EntityComponentIndex<{ filter: types.AnyFilter? }> },
}

export type ActiveEntity = {
	unfiltered_components: ComponentIndex<true>,
	filtered_components: ComponentIndex<true>,
	is_entity_mask: boolean,
	components_count: number,
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

export type StorageGroup = {
	info: StorageGroupInfo,

	-- contains all active entities with its components
	active: Map<Entity, ActiveEntity>,
	active_count: number,

	contains_changes: boolean,
}

export type MaskingController = {
	storage_edges: { [Member]: StorageGroup },
	masking_lookups: MaskingLookups,

	alive_storages: { [BitmaskHash]: StorageGroup },
	dead_storages: { [BitmaskHash]: StorageGroup },
	dead_storages_count: number,
}

local NONE = nil :: any
local COMPONENT_ENTRIES = {
	component = 1,
	tag = 2,
	pair = 3,
	pair_value = 4,
}

local masking_controller = {}
masking_controller.__index = masking_controller

local function create_component_indexes<T>(hint: T)
	return { {}, {}, {}, {}, {} } :: ComponentIndex<T>
end

local function is_include_filter(filter: types.PlayerFilter): boolean
	return not not next(filter)
end

local function create_active_entty(entity_mask: boolean)
	local active: ActiveEntity = {
		filtered_components = create_component_indexes(NONE :: true),
		unfiltered_components = create_component_indexes(NONE :: true),
		is_entity_mask = entity_mask,
		components_count = 0,
	}
	return active
end

local function get_component_index_entry<T>(
	index: EntityComponentIndex<T>,
	entity: Entity,
	component: Component,
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
	component: Component,
	component_type: ComponentEntryType,
	value: T
)
	local entity_index = index[entity]
	if entity_index == nil then
		entity_index = create_component_indexes(NONE :: T)
		index[entity] = entity_index
	end
	entity_index[component_type][component] = value
end

local function remove_component_index_entry(
	index: EntityComponentIndex<any>,
	entity: Entity,
	component: Component,
	component_type: ComponentEntryType
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

function masking_controller.start_entity(entity) end

function masking_controller.reactivate_postponed(entity: Entity) end

local function create(): MaskingController
	local self = {} :: MaskingController

	return setmetatable(self, masking_controller) :: any
end

return { create = create, masking_controller = masking_controller }
