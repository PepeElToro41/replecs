local jecs = require "../jecs"

export type PlayerFilter = {
	[Player]: boolean,
}

export type Serdes = {
	includes_variants: boolean?,
	serialize: (value: any) -> (buffer, { any }?),
	deserialize: (buffer, { any }?) -> any,
}

export type Components = {
	shared: jecs.Entity,
	networked: jecs.Entity<PlayerFilter?>,
	reliable: jecs.Entity,
	unreliable: jecs.Entity,
	pair: jecs.Entity,

	serdes: jecs.Entity<Serdes>,
	bytespan: jecs.Entity<number>,
	custom_id: jecs.Entity<(value: any) -> jecs.Entity>,
	global_id: jecs.Entity<number>,
	__alive_tracking__: jecs.Entity,
}

export type Shared = {
	lookup: { [string]: jecs.Entity },

	components: { [number]: jecs.Entity },
	ids: { [jecs.Entity]: number },

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
