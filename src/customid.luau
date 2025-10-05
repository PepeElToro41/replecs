local jecs = require "../jecs"

type Entity<T = any> = jecs.Entity<T>
type Id<T = any> = jecs.Id<T>
type World = jecs.World

export type HandleContext = {
	entity_id: Entity,
	component: <T>(self: HandleContext, component: Entity<T>) -> T,
	target: (self: HandleContext, relation: jecs.Id, index: number?) -> Entity?,
	pair_value: <T>(self: HandleContext, relation: jecs.Id<T>, target: Entity) -> T?,
	has_pair: (self: HandleContext, relation: jecs.Id, target: Entity) -> boolean,

	entity: (self: HandleContext, server_entity: Entity) -> Entity,
	has: (self: HandleContext, tag: Entity) -> boolean,
}

export type CustomId = {
	identifier: string,
	handle_callback: (ctx: HandleContext) -> Entity,
}

function create(identifier: string, callback: (ctx: HandleContext) -> Entity)
	local handler = {} :: CustomId
	handler.identifier = identifier
	handler.handle_callback = callback

	return handler
end

return { create = create }
