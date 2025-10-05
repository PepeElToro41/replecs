local jecs = require "../jecs"
local customid = require "./customid"

export type FunctionFilter = (player: Player) -> boolean
export type AnyFilter = PlayerFilter | Player

export type PlayerFilter = {
	[Player]: boolean,
}

export type SharedInfo<T> = {
	lookup: { [string]: T },
	indexes: { [number]: T },
	members: { [T]: number },
}

export type Serdes = {
	includes_variants: boolean?,
	serialize: (value: any) -> (buffer, { any }?),
	deserialize: (buffer, { any }?) -> any,
}

export type Components = {
	shared: jecs.Entity,
	networked: jecs.Entity<AnyFilter?>,
	reliable: jecs.Entity<AnyFilter?>,
	unreliable: jecs.Entity<AnyFilter?>,
	pair: jecs.Entity<AnyFilter?>,

	serdes: jecs.Entity<Serdes>,
	bytespan: jecs.Entity<number>,
	custom: jecs.Entity<customid.CustomId>,
	global: jecs.Entity<number>,
	__alive_tracking__: jecs.Entity,
}

export type Shared = {
	components: SharedInfo<jecs.Entity>,
	custom_ids: SharedInfo<customid.CustomId>,

	bytespan: { [jecs.Entity]: number },
	serdes: { [jecs.Entity]: Serdes },
}

export type WorldHooks = {
	added: (
		world: jecs.World,
		component: jecs.Entity,
		fn: (entity: jecs.Entity, id: jecs.Id, value: any) -> ()
	) -> () -> (),
	changed: (
		world: jecs.World,
		component: jecs.Entity,
		fn: (entity: jecs.Entity, id: jecs.Id, value: any) -> ()
	) -> () -> (),
	removed: (world: jecs.World, component: jecs.Entity, fn: (entity: jecs.Entity, id: jecs.Id) -> ()) -> () -> (),
}

return nil
