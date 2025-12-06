local common = require "./common"

type Entity = common.Entity
type Component<T = any> = common.Component<T>
type World = common.World

export type HandleContext = {
	entity_id: number,
	component: <T>(component: Component<T>) -> T,
	target: (relation: Component, index: number?) -> Entity?,
	pair_value: <T>(relation: Component<T>, target: Entity) -> T?,
	has_pair: (relation: Component, target: Entity) -> boolean,

	entity: (server_entity: number) -> Entity,
	has: (tag: Entity) -> boolean,
}

export type CustomId = {
	identifier: string,
	handle_callback: ((ctx: HandleContext) -> Entity?)?,

	handle: (self: CustomId, handler: (ctx: HandleContext) -> Entity?) -> (),
}

local custom_id = {}
custom_id.__index = custom_id

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
