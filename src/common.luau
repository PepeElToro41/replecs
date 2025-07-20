local Jecs = require(script.Parent.Parent.jecs)

export type PlayerFilter = {
	[Player]: boolean,
}

export type Serdes = {
	serialize: (value: any) -> buffer,
	deserialize: (buffer) -> any,
}

export type Components = {
	shared: Jecs.Entity,
	networked: Jecs.Entity<PlayerFilter?>,
	reliable: Jecs.Entity,
	unreliable: Jecs.Entity,
	pair: Jecs.Entity,

	serdes: Jecs.Entity<Serdes>,
	bytespan: Jecs.Entity<number>,
	custom_id: Jecs.Entity<(value: any) -> Jecs.Entity>,
	__alive_tracking__: Jecs.Entity,
}

export type Shared = {
	lookup: { [string]: Jecs.Entity },

	components: { [number]: Jecs.Entity },
	ids: { [Jecs.Entity]: number },

	bytespan: { [Jecs.Entity]: number },
	serdes: { [Jecs.Entity]: Serdes },
}

export type WorldHooks = {
	added: (
		world: Jecs.World,
		component: Jecs.Entity,
		fn: (entity: Jecs.Entity, id: Jecs.Id, value: any) -> ()
	) -> () -> (),
	changed: (
		world: Jecs.World,
		component: Jecs.Entity,
		fn: (entity: Jecs.Entity, id: Jecs.Id, value: any) -> ()
	) -> () -> (),
	removed: (world: Jecs.World, component: Jecs.Entity, fn: (entity: Jecs.Entity, id: Jecs.Id) -> ()) -> () -> (),
}

return nil
