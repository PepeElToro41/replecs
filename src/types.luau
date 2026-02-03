local customid = require "./customid"
local common = require "./common"

export type PlayerFilter = {
	[Player]: boolean,
}

export type FunctionFilter = (player: Player) -> boolean
export type AnyFilter = PlayerFilter | Player

type Entity = common.Entity
type World = common.World
type Component<T = any> = common.Component<T>

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

export type Serdes<T = any> = {
	includes_variants: boolean?,
	bytespan: number?,
	serialize: (value: T) -> (buffer, ...{ any }),
	deserialize: (buffer, ...{ any }) -> T,
}

export type Components = {
	shared: Entity,
	Shared: Entity,
	networked: Component<any?>,
	Networked: Component<AnyFilter?>,
	reliable: Component<AnyFilter?>,
	Reliable: Component<AnyFilter?>,
	unreliable: Component<AnyFilter?>,
	Unreliable: Component<AnyFilter?>,
	relation: Component<AnyFilter?>,
	Relation: Component<AnyFilter?>,

	serdes: Component<Serdes>,
	Serdes: Component<Serdes>,
	custom: Entity,
	Custom: Entity,
	custom_handler: Component<(val: any) -> Entity?>,
	CustomHandler: Component<(val: any) -> Entity?>,
	global: Component<number>,
	Global: Component<number>,
	__alive_tracking__: Entity,
}

export type Shared = {
	components: SharedInfo<Entity>,
	custom_ids: SharedInfo<customid.CustomId>,

	serdes: { [Component]: Serdes },
}

return nil
