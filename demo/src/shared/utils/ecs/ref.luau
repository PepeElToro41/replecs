--!optimize 2
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Jecs = require(ReplicatedStorage.packages.jecs)
local world = require(ReplicatedStorage.code.world)
local refs: { [any]: any } = {}

--- Gets an entity the given key references to.
--- If the key is nil, an entirely new entity is created and returned.
--- If the key doesn't reference an entity, a new entity is made for it to reference and returned.
--- @param key any
local function ref(key: any, initer: ((entity: Jecs.Entity) -> ())?): Jecs.Entity
	if not key then
		return world:entity()
	end

	local entity = refs[key]
	if not entity then
		entity = world:entity()

		if initer then
			initer(entity)
		end

		refs[key] = entity
	end

	return entity
end

-- For the `__call`` metamethod
local function __call(_, key: any, initer: (entity: Jecs.Entity) -> ())
	return ref(key, initer)
end

local function search(key: any)
	if not key then
		return nil
	end
	local entity = refs[key]

	if not entity then
		return nil
	end

	return entity
end

function set(key: any, entity: Jecs.Entity)
	refs[key] = entity
end

function unlist(key: any)
	if not key then
		return
	end
	refs[key] = nil
end

local metatable = {
	__call = __call,
}

local lib = {
	set = set,
	search = search,
	unlist = unlist,
}

local REF = (setmetatable :: any)(lib, metatable) :: typeof(ref) & typeof(setmetatable(lib, metatable))

return REF
