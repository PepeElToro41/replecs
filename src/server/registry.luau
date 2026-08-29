--!optimize 2
local bitmasks = require "./bitmasks"
local utils = require "../utils"

type Set<T> = { [T]: boolean }
type Map<K, V> = { [K]: V }
type Array<T> = { T }
type Bitmask = buffer

type Client = any
export type MemberPredicator = (Client) -> boolean

type RegistryClass = {
	client_indexes: Map<Client, number>,
	-- reverse of client_indexes, kept in sync by register/unregister
	index_clients: Map<number, Client>,

	client_next_index: number,
	client_count: number,

	-- indexes released by unregister, reused before growing client_next_index
	free_indexes: Array<number>,

	-- alternate keys a filter may use for a client (a user id, a name...);
	-- resolved to the client before registration is considered
	client_aliases: Map<any, Client>,

	-- hard cap on registered clients: every bitmask is allocated to hold
	-- exactly this many bits, so an index past it would fall off the buffer
	max_clients: number,
	bitmask_size: number,
}

local registry = {}
registry.__index = registry

export type Registry = RegistryClass & typeof(registry)

-- a filter can name a player before it joined the registry: register it on
-- the spot so the bit is stable once the player is ready. a player that
-- already left is never registered, its bit would leak into every mask
local function resolve_member(self: Registry, member: Client): number?
	local index = self.client_indexes[member]
	if index then
		return index
	end

	-- an alias stands for its client: registered or not, the client is what
	-- gets the bit, the alias itself is never registered
	local aliased = self.client_aliases[member]
	if aliased ~= nil then
		member = aliased
		index = self.client_indexes[member]
		if index then
			return index
		end
	end

	if not utils.is_client_valid(member) then
		return nil
	end

	registry.register_client(self, member)
	return self.client_indexes[member]
end

function registry.add_alias(self: Registry, client: Client, alias: any)
	self.client_aliases[alias] = client
end

function registry.remove_alias(self: Registry, alias: any)
	self.client_aliases[alias] = nil
end

-- drops every alias pointing at the client
function registry.remove_client_aliases(self: Registry, client: Client)
	local aliases = self.client_aliases
	for alias, aliased in aliases do
		if aliased == client then
			aliases[alias] = nil
		end
	end
end

@native
function registry.create_bitmask_from_set(self: Registry, member_set: Map<Client, boolean>): Bitmask
	local resolved_members: Array<number> = {}
	for member in member_set do
		local resolved = resolve_member(self, member)
		if resolved then
			table.insert(resolved_members, resolved)
		end
	end

	local bitmask = buffer.create(self.bitmask_size)

	for _, index in resolved_members do
		bitmasks.set(bitmask, index)
	end

	return bitmask
end

@native
function registry.create_bitmask_from_member(self: Registry, member: Client): Bitmask
	local bitmask = buffer.create(self.bitmask_size)
	local index = resolve_member(self, member)
	if index then
		bitmasks.set(bitmask, index)
	end
	return bitmask
end

@native
function registry.create_bitmask_from_function(self: Registry, predicator: MemberPredicator)
	local bitmask = buffer.create(self.bitmask_size)

	for member, index in self.client_indexes do
		if predicator(member) then
			bitmasks.set(bitmask, index)
		end
	end

	return bitmask
end

function registry.register_client(self: Registry, member: Client)
	if self.client_indexes[member] then
		return
	end
	if self.client_count >= self.max_clients then
		error(`client limit of {self.max_clients} reached, raise BITMASK_COMPACT_THRESHOLD to register more`)
	end

	local reused = table.remove(self.free_indexes)
	local index: number
	if reused then
		index = reused
	else
		index = self.client_next_index
		self.client_next_index += 1
	end
	self.client_indexes[member] = index
	self.index_clients[index] = member
	self.client_count += 1
end

function registry.unregister_client(self: Registry, member: Client)
	local index = self.client_indexes[member]
	if not index then
		return
	end

	table.insert(self.free_indexes, index)
	self.client_indexes[member] = nil
	self.index_clients[index] = nil
	self.client_count -= 1
end

local DEFAULT_MAX_CLIENTS = 128

function registry.create(max_clients: number?): Registry
	local self = {} :: Registry

	local cap = max_clients or DEFAULT_MAX_CLIENTS
	self.max_clients = cap
	self.bitmask_size = bitmasks.get_buffer_size(cap)
	self.client_indexes = {}
	self.index_clients = {}
	self.client_next_index = 0
	self.client_count = 0
	self.free_indexes = {}
	self.client_aliases = {}

	return setmetatable(self, registry) :: any
end

return registry
