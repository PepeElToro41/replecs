local jecs = require "../jecs"
local customid = require "./customid"

export type FunctionFilter = (player: Player) -> boolean
export type AnyFilter = PlayerFilter | Player
type Entity<T = any> = jecs.Entity<T>

export type PlayerFilter = {
	[Player]: boolean,
}

export type SharedInfo<T> = {
	lookup: { [string]: T },
	keys: { string },
	indexes: { [number]: T },
	members: { [T]: number },
}
export type HandshakeInfo = {
	components: { [string]: boolean },
	custom_ids: { [string]: boolean },
	serdes: { [string]: {
		includes_variants: boolean?,
		bytespan: number?,
	} },
}

export type Serdes = {
	includes_variants: boolean?,
	bytespan: number?,
	serialize: (value: any) -> (buffer, { any }?),
	deserialize: (buffer, { any }?) -> any,
}

export type Components = {
	shared: Entity,
	networked: Entity<AnyFilter?>,
	reliable: Entity<AnyFilter?>,
	unreliable: Entity<AnyFilter?>,
	pair: Entity<AnyFilter?>,

	serdes: Entity<Serdes>,
	custom: Entity,
	custom_handler: Entity<(val: any) -> Entity?>,
	global: Entity<number>,
	__alive_tracking__: Entity,
}

export type Shared = {
	components: SharedInfo<Entity>,
	custom_ids: SharedInfo<customid.CustomId>,

	serdes: { [Entity]: Serdes },
}

export type WorldHooks = {
	added: (
		world: jecs.World,
		component: Entity,
		fn: (entity: Entity, id: jecs.Id, value: any) -> ()
	) -> () -> (),
	changed: (
		world: jecs.World,
		component: Entity,
		fn: (entity: Entity, id: jecs.Id, value: any) -> ()
	) -> () -> (),
	removed: (world: jecs.World, component: Entity, fn: (entity: Entity, id: jecs.Id) -> ()) -> () -> (),
}

return nil
