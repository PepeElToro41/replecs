local jecs = require "../jecs"

type Entity<T = any> = jecs.Entity<T>
type Id<T = any> = jecs.Id<T>
type World = jecs.World

export type HandleContext = {
	entity_id: number,
	component: <T>(component: Entity<T>) -> T,
	target: (relation: jecs.Id, index: number?) -> Entity?,
	pair_value: <T>(relation: jecs.Id<T>, target: Entity) -> T?,
	has_pair: (relation: jecs.Id, target: Entity) -> boolean,

	entity: (server_entity: number) -> Entity,
	has: (tag: Entity) -> boolean,
}

export type CustomId = {
	identifier: string,
	handle_callback: ((ctx: HandleContext) -> Entity?)?,

	handle: (self: CustomId, handler: (ctx: HandleContext) -> Entity?) -> (),
}

local custom_id = {}

function custom_id.handle(custom: CustomId, callback: (ctx: HandleContext) -> Entity?)
	custom.handle_callback = callback
end

function create(identifier: string, callback: ((ctx: HandleContext) -> Entity?)?): CustomId
	local handler = {} :: CustomId
	handler.identifier = identifier
	handler.handle_callback = callback

	return setmetatable(handler, custom_id) :: any
end

return { create = create }
