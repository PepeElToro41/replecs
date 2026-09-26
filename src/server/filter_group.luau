--!optimize 2
local types = require "../types"
local registry = require "./registry"
local bitmasks = require "./bitmasks"
local utils = require "./utils"

type Bitmask = buffer
type Player = any

type FilterSimple = types.FilterSimple
type FilterPredicator = types.FilterPredicator

type Set<T> = { [T]: boolean }
type Array<T> = { T }
type Registry = registry.Registry

local KINDS = {
	source = 1,
	predicate = 2,
	intersect = 3,
	union = 4,
	exclude = 5,
}

export type FilterNodeClass = {
	kind: number,
	registry: Registry?,

	inputs: Array<FilterNode>,
	input_versions: Array<number>,
	dependents: Set<FilterNode>,


	value: Bitmask?,
	scratch: Bitmask?,
	version: number,
	dirty: boolean,
	resolved_epoch: number,
	resolved_cycle: number,

	-- source only
	member_set: Set<Player>?,
	inverted: boolean?,
	predicator: FilterPredicator?,
}

local filter_node = {}
filter_node.__index = filter_node

export type FilterNode = FilterNodeClass & typeof(filter_node)
export type FilterOperand = FilterNode | FilterSimple

function filter_node.is_filter_node(value: any): boolean
	return typeof(value) == "table" and getmetatable(value) == filter_node
end

function filter_node.bind(node: FilterNode, reg: Registry)
	if node.registry == reg then
		return
	end
	if node.registry then
		error "filter is already bound to a different server"
	end

	node.registry = reg
	node.value = buffer.create(reg.bitmask_size)
	node.scratch = buffer.create(reg.bitmask_size)

	for _, input in node.inputs do
		filter_node.bind(input, reg)
	end
end

local function create_node(kind: number, reg: Registry?): FilterNode
	local self: FilterNodeClass = {
		kind = kind,
		registry = nil,

		inputs = {},
		input_versions = {},
		dependents = setmetatable({}, { __mode = "k" }) :: any,

		value = nil,
		scratch = nil,
		version = 0,
		dirty = true,
		resolved_epoch = -1,
		resolved_cycle = -1,

		member_set = nil,
		inverted = nil,
		predicator = nil,
	}
	setmetatable(self, filter_node)

	local node = self :: any
	if reg then
		filter_node.bind(node, reg)
	end
	return node
end

local function mark_dirty(node: FilterNode)
	if node.dirty then
		return
	end
	node.dirty = true
	for dependent in node.dependents do
		mark_dirty(dependent)
	end
end

local function assert_source(node: FilterNode, method: string)
	if node.kind ~= KINDS.source then
		error(`{method}() is only available on source filters, derived filters are read only`)
	end
end

@native
local function resolve_source(node: FilterNode, reg: Registry, scratch: Bitmask)
	bitmasks.clear(scratch)
	for member in node.member_set :: Set<Player> do
		local index = registry.resolve_member(reg, member)
		if index then
			bitmasks.set(scratch, index)
		end
	end
	if node.inverted then
		bitmasks.exclude(reg.registered_bitmask, scratch, scratch)
	end
end

@native
local function resolve_predicate(node: FilterNode, reg: Registry, scratch: Bitmask)
	bitmasks.clear(scratch)
	local predicator = node.predicator :: FilterPredicator
	for member, index in reg.client_indexes do
		if predicator(member) then
			bitmasks.set(scratch, index)
		end
	end
end

@native
local function resolve_computed(node: FilterNode, scratch: Bitmask): boolean
	local inputs = node.inputs
	local input_versions = node.input_versions

	local changed = false
	for i, input in inputs do
		filter_node.resolve(input)
		if input.version ~= input_versions[i] then
			changed = true
		end
	end
	if not changed then
		return false
	end

	for i, input in inputs do
		input_versions[i] = input.version
	end

	bitmasks.load(inputs[1].value :: Bitmask, scratch)
	local kind = node.kind
	local op: (Bitmask, Bitmask, Bitmask) -> () = if kind == KINDS.intersect
		then bitmasks.band
		elseif kind == KINDS.union then bitmasks.bor
		else bitmasks.exclude
	for i = 2, #inputs do
		op(scratch, inputs[i].value :: Bitmask, scratch)
	end
	return true
end


function filter_node.resolve(node: FilterNode): Bitmask
	local reg = node.registry
	if not reg then
		error "filter is not bound to a server, pass it to a set_* call first"
	end
	local value = node.value :: Bitmask
	local kind = node.kind

	if kind == KINDS.predicate then
		if node.resolved_cycle == reg.cycle then
			return value
		end
		node.resolved_cycle = reg.cycle
	elseif not node.dirty and node.resolved_epoch == reg.epoch then
		return value
	end
	node.dirty = false
	node.resolved_epoch = reg.epoch

	local scratch = node.scratch :: Bitmask
	if kind == KINDS.source then
		resolve_source(node, reg, scratch)
	elseif kind == KINDS.predicate then
		resolve_predicate(node, reg, scratch)
	elseif not resolve_computed(node, scratch) then
		return value
	end

	if bitmasks.equals(scratch, value) then
		return value
	end
	node.value = scratch
	node.scratch = value
	node.version += 1
	return scratch
end

function filter_node.set(self: FilterNode, filter: FilterSimple)
	assert_source(self, "set")

	local members: Set<Player> = {}
	local inverted = false
	if typeof(filter) == "table" then
		inverted = not utils.is_include_filter(filter)
		for member, allow in filter :: Set<Player> do
			if allow == inverted then
				error "a filter set cannot mix included and excluded players"
			end
			members[member] = true
		end
	else
		members[filter] = true
	end

	self.member_set = members
	self.inverted = inverted
	mark_dirty(self)
end

function filter_node.add(self: FilterNode, player: Player)
	assert_source(self, "add")
	local members = self.member_set :: Set<Player>
	if members[player] then
		return
	end
	members[player] = true
	mark_dirty(self)
end

function filter_node.remove(self: FilterNode, player: Player)
	assert_source(self, "remove")
	local members = self.member_set :: Set<Player>
	if not members[player] then
		return
	end
	members[player] = nil
	mark_dirty(self)
end

function filter_node.clear(self: FilterNode)
	assert_source(self, "clear")
	local members = self.member_set :: Set<Player>
	if next(members) == nil then
		return
	end
	table.clear(members)
	mark_dirty(self)
end


function filter_node.create_source(reg: Registry?, initial: FilterSimple?): FilterNode
	local node = create_node(KINDS.source, reg)
	node.member_set = {}
	node.inverted = false
	if initial ~= nil then
		filter_node.set(node, initial)
	end
	return node
end

function filter_node.create_everyone(reg: Registry?): FilterNode
	local node = create_node(KINDS.source, reg)
	node.member_set = {}
	node.inverted = true
	return node
end

function filter_node.create_predicate(reg: Registry?, predicator: FilterPredicator): FilterNode
	local node = create_node(KINDS.predicate, reg)
	node.predicator = predicator
	return node
end

local function to_node(operand: FilterOperand): FilterNode
	if filter_node.is_filter_node(operand) then
		return operand :: FilterNode
	end
	return filter_node.create_source(nil, operand :: FilterSimple)
end

local function create_computed(kind: number, base: FilterNode, operands: Array<FilterOperand>): FilterNode
	local node = create_node(kind, nil)
	local inputs = node.inputs
	local input_versions = node.input_versions

	inputs[1] = base
	input_versions[1] = -1
	local reg = base.registry

	for i, operand in operands do
		local input = to_node(operand)
		inputs[i + 1] = input
		input_versions[i + 1] = -1
		reg = reg or input.registry
	end

	for _, input in inputs do
		input.dependents[node] = true
	end
	if reg then
		filter_node.bind(node, reg)
	end
	return node
end

function filter_node.filter(self: FilterNode, ...: FilterOperand): FilterNode
	return create_computed(KINDS.intersect, self, { ... })
end

function filter_node.extend(self: FilterNode, ...: FilterOperand): FilterNode
	return create_computed(KINDS.union, self, { ... })
end

function filter_node.exclude(self: FilterNode, ...: FilterOperand): FilterNode
	return create_computed(KINDS.exclude, self, { ... })
end


function filter_node.members(self: FilterNode): Set<Player>
	local value = filter_node.resolve(self)
	local index_clients = (self.registry :: Registry).index_clients

	local members: Set<Player> = {}
	bitmasks.iter_set(value, function(index)
		local client = index_clients[index]
		if client ~= nil then
			members[client] = true
		end
	end)
	return members
end

local function lookup_index(reg: Registry, player: Player): number?
	local index = reg.client_indexes[player]
	if index then
		return index
	end
	local aliased = reg.client_aliases[player]
	if aliased == nil then
		return nil
	end
	return reg.client_indexes[aliased]
end

function filter_node.contains(self: FilterNode, player: Player): boolean
	local value = filter_node.resolve(self)
	local index = lookup_index(self.registry :: Registry, player)
	if index == nil then
		return false
	end
	return bitmasks.test(value, index)
end

return filter_node
