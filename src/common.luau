local pepecs = require "../pepecs"

export type Entity = pepecs.Entity
export type World = pepecs.World
export type Component<T = any> = pepecs.Entity<T>

local common = {}

local WILDCARD = pepecs.Wildcard
local ECS_NAME = pepecs.Name
local PREREGISTRATION = true
local RELATIONSHIPS = true

local IMPLICITLY_SHARED: { [string]: Entity } = {
	["pepecs.ChildOf"] = pepecs.ChildOf,
}

function LOGERROR(...: string): never
	error("REPLECS ERROR - " .. table.concat({ ... }, " "))
end
function LOGWARN(...: string)
	warn("REPLECS WARN - " .. table.concat({ ... }, " "))
end

function LOG_COMPONENT(world: World, component: Entity)
	return ` name: {world.get(component, ECS_NAME) or "(no name)"}, id: {component}`
end

local function IS_PAIR(id: Component): boolean
	return pepecs.is_pair(id)
end

local function PAIR(relation: Entity, target: Entity): Entity
	return pepecs.pair(relation, target)
end

local function PAIR_FIRST(world: World, id: Entity): Entity
	if not IS_PAIR(id) then
		LOGERROR(`expected a pair, got: {LOG_COMPONENT(world, id)}`)
	end
	return world.pair_first(id)
end

local function PAIR_SECOND(world: World, id: Entity): Entity
	if not IS_PAIR(id) then
		LOGERROR(`expected a pair, got: {LOG_COMPONENT(world, id)}`)
	end
	return world.pair_second(id)
end

local function ADD_NAME(world: World, component: Component, name: string)
	world.set(component, ECS_NAME, name)
end

local function ADD_PREREGISTERED_NAME(component: Component, name: string)
	pepecs.meta(component, ECS_NAME, name)
end

local function ITERATE_ALL_RELATIONS(world: World, entity: Entity, relation: Component, callback: (id: Component) -> ())
	for id in world.pairs(entity, relation) do
		callback(id)
	end
end

local function WORLD_ADD(world: World, entity: Entity, id: Component)
	world.add(entity, id)
end

local function WORLD_SET<T>(world: World, entity: Entity, id: Component<T>, value: T)
	world.set(entity, id, value)
end

local function WORLD_REMOVE(world: World, entity: Entity, id: Component)
	world.remove(entity, id)
end

local function WORLD_DELETE(world: World, entity: Entity)
	world.delete(entity)
end

local function WORLD_GET<T>(world: World, entity: Entity, id: Component<T>): T
	return world.get(entity, id) :: T
end

local function WORLD_TARGET(world: World, entity: Entity, rel: Component, index: number?): Entity?
	return world.target(entity, rel, index)
end

local function WORLD_HAS(world: World, entity: Entity, id: Component)
	return world.has(entity, id)
end

local function WORLD_ENTITY(world: World)
	return world.entity()
end

local function WORLD_TAG(world: World)
	return world.entity()
end
local function WORLD_COMPONENT(world: World)
	return world.component()
end

local PREREGISTER_COMPONENT = pepecs.component
local PREREGISTER_TAG = pepecs.tag

local function IS_COMPONENT(world: World, id: Component)
	return world.is_component(id)
end

local function HOOK_ADDED(world: World, id: Component, callback: (e: Entity, id: Component, value: any) -> ()): () -> ()
	return world.added(id, callback)
end

local function HOOK_CHANGED(
	world: World,
	id: Component,
	callback: (e: Entity, id: Component, value: any) -> ()
): () -> ()
	return world.changed(id, callback)
end

local function HOOK_REMOVED(world: World, id: Component, callback: (e: Entity, id: Component) -> ()): () -> ()
	return world.removed(id, callback)
end

common.preregistration = PREREGISTRATION
common.relationships = RELATIONSHIPS
common.wildcard = WILDCARD
common.ecs_name = ECS_NAME
common.implicitly_shared = IMPLICITLY_SHARED

common.is_pair = IS_PAIR
common.pair = PAIR
common.pair_first = PAIR_FIRST
common.pair_second = PAIR_SECOND
common.add_name = ADD_NAME
common.add_preregistered_name = ADD_PREREGISTERED_NAME
common.iterate_all_relations = ITERATE_ALL_RELATIONS

common.world_set = WORLD_SET
common.world_remove = WORLD_REMOVE
common.world_delete = WORLD_DELETE
common.world_add = WORLD_ADD

common.world_get = WORLD_GET
common.world_target = WORLD_TARGET
common.world_has = WORLD_HAS

common.world_entity = WORLD_ENTITY
common.world_tag = WORLD_TAG
common.world_component = WORLD_COMPONENT
common.preregister_component = PREREGISTER_COMPONENT
common.preregister_tag = PREREGISTER_TAG

common.is_component = IS_COMPONENT

common.hook_added = HOOK_ADDED
common.hook_changed = HOOK_CHANGED
common.hook_removed = HOOK_REMOVED

common.log_error = LOGERROR
common.log_warn = LOGWARN
common.log_component = LOG_COMPONENT

return common
