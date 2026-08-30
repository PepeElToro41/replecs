local types = require "../types"
local registry = require "./registry"
local bitmasks = require "./bitmasks"
local utils = require "./utils"
local common = require "../common"

type Bitmask = buffer

type FilterSimple = types.FilterSimple

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }

type Listener = (Bitmask) -> ()

type ListenerConnections = {
	listeners: { Listener },
	listeners_indexes: { [Listener]: number },
}

export type FilterMode = number

export type FilterEntry = {
	mode: FilterMode,
	filter: FilterSimple,
}

export type FilterGroupClass = {
	registry: registry.Registry,
	parent: FilterGroup?,

	derived: Set<FilterGroup>,
	assigned_filter: FilterEntry?,
	connected_listeners: ListenerConnections,
}

local FILTER_MODES = {
	extend = 1,
	exclude = 2,
	include = 3,
}

local filter_group = {}
filter_group.__index = filter_group

export type FilterGroup = FilterGroupClass & typeof(filter_group)

function filter_group.is_filter_group(value: any): boolean
	return typeof(value) == "table" and getmetatable(value) == filter_group
end

local function fire_listeners(self: FilterGroup, bitmask: Bitmask)
	for _, listener in self.connected_listeners.listeners do
		listener(bitmask)
	end
end

function filter_group.connect(self: FilterGroup, listener: Listener)
	local connected = self.connected_listeners
	local index = #connected.listeners + 1
	connected.listeners[index] = listener
	connected.listeners_indexes[listener] = index
end

function filter_group.disconnect(self: FilterGroup, listener: Listener)
	local connected = self.connected_listeners
	local index = connected.listeners_indexes[listener]
	if not index then
		return
	end

	local last_listener = table.remove(connected.listeners)
	if last_listener and last_listener ~= listener then
		connected.listeners[index] = last_listener
		connected.listeners_indexes[last_listener] = index
	end
	connected.listeners_indexes[listener] = nil
end

local function create_filter_bitmask(self: FilterGroup, filter: FilterSimple): Bitmask
	if typeof(filter) == "table" then
		return self.registry:create_bitmask_from_set(filter)
	else
		return self.registry:create_bitmask_from_member(filter)
	end
end

-- the filter bitmask is resolved from the raw filter here, at calculation
-- time, so clients registered after the filter was assigned still resolve
function filter_group.apply_filter(self: FilterGroup, bitmask: Bitmask)
	local filter = self.assigned_filter
	if not filter then
		return
	end

	local filter_bitmask = create_filter_bitmask(self, filter.filter)

	if filter.mode == FILTER_MODES.extend then
		bitmasks.bor(bitmask, filter_bitmask, bitmask)
	elseif filter.mode == FILTER_MODES.exclude then
		bitmasks.exclude(bitmask, filter_bitmask, bitmask)
	elseif filter.mode == FILTER_MODES.include then
		bitmasks.band(bitmask, filter_bitmask, bitmask)
	end
end

function filter_group.calculate_up(self: FilterGroup): Bitmask
	local parent = self.parent
	local bitmask: Bitmask
	if parent then
		bitmask = filter_group.calculate_up(parent)
	else
		bitmask = bitmasks.create_filled(self.registry.client_next_index)
	end

	filter_group.apply_filter(self, bitmask)
	return bitmask
end

function filter_group.calculate_down(self: FilterGroup, parent_bitmask: Bitmask)
	local bitmask = bitmasks.clone(parent_bitmask, bitmasks.get_buffer_size(self.registry.client_next_index))
	filter_group.apply_filter(self, bitmask)

	fire_listeners(self, bitmask)

	for derived in self.derived do
		filter_group.calculate_down(derived, bitmask)
	end
end

local function recalculate_filter_group(group: FilterGroup)
	local parent = group.parent

	local parent_bitmask: Bitmask
	if parent then
		parent_bitmask = filter_group.calculate_up(parent)
	else
		parent_bitmask = bitmasks.create_filled(group.registry.client_next_index)
	end

	filter_group.calculate_down(group, parent_bitmask)
end

function filter_group.extend(self: FilterGroup, filter: FilterSimple)
	if not utils.get_used_filter_type(filter) then
		common.log_error "extend() only accepts include filters"
	end

	self.assigned_filter = {
		mode = FILTER_MODES.extend,
		filter = filter,
	}
	recalculate_filter_group(self)
end

function filter_group.filter(self: FilterGroup, filter: FilterSimple)
	local mode = FILTER_MODES.exclude

	if utils.get_used_filter_type(filter) then
		mode = FILTER_MODES.include
	end

	self.assigned_filter = {
		mode = mode,
		filter = filter,
	}
	recalculate_filter_group(self)
end

function filter_group.create(client_registry: registry.Registry): FilterGroup
	local self: FilterGroupClass = {
		registry = client_registry,

		parent = nil,
		connected_listeners = {
			listeners = {},
			listeners_indexes = {},
		},
		derived = setmetatable({}, { __mode = "k" }) :: any,
		assigned_filter = nil,
	}

	setmetatable(self, filter_group)
	return self :: any
end

function filter_group.derive(self: FilterGroup): FilterGroup
	local derived = filter_group.create(self.registry)
	derived.parent = self

	self.derived[derived] = true
	return derived
end

return filter_group
