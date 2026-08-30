local types = require "./types"
local common = require "./common"
local customid = require "./customid"

type Component = common.Component
type Entity = common.Entity
type World = common.World

local ECS_NAME = common.ecs_name

local shared = {}

local function create_shared_lookup<T>(lookup: { [string]: T }): types.SharedInfo<T>
	local keys = {}
	local indexes = {}
	local members = {}

	for name in lookup do
		table.insert(keys, name)
	end
	table.sort(keys)

	for index, name in keys do
		local member = lookup[name]
		members[member] = index
		indexes[index] = member
	end

	return {
		lookup = lookup,
		keys = keys,
		indexes = indexes,
		members = members,
	}
end

function shared.resolve_shared(
	world: World,
	components: types.Components,
	registered_custom_ids: { [customid.CustomId]: boolean },
	serdes: { [Component]: types.Serdes }
): types.Shared
	local shared = {} :: types.Shared

	local components_lookup: { [string]: Entity } = table.clone(common.implicitly_shared)
	local custom_ids_lookup = {}

	for component, name in world:query(ECS_NAME):with(components.shared):iter() do
		if components_lookup[name] then
			common.log_error(`detected two components with the same {name} name: ({components_lookup[name]}, {component})`)
		end
		components_lookup[name] = component
	end

	for component in world:query(components.shared):without(ECS_NAME):iter() do
		common.log_warn(`shared component: {component} has no name assigned.`)
	end

	for custom in registered_custom_ids do
		custom_ids_lookup[custom.identifier] = custom
	end

	shared.serdes = serdes
	shared.components = create_shared_lookup(components_lookup)
	shared.custom_ids = create_shared_lookup(custom_ids_lookup) :: types.SharedInfo<customid.CustomId>

	return shared
end

return shared
