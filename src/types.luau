local customid = require "./customid"
local common = require "./common"

export type FunctionFilter = (player: Player) -> boolean
export type AnyFilter = PlayerFilter | Player | FunctionFilter

type Entity = common.Entity
type World = common.World
type Component<T = any> = common.Component<T>

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
	Shared: Entity,
	networked: Component<AnyFilter?>,
	Networked: Component<AnyFilter?>,
	reliable: Component<AnyFilter?>,
	Reliable: Component<AnyFilter?>,
	unreliable: Component<AnyFilter?>,
	Unreliable: Component<AnyFilter?>,
	pair: Component<AnyFilter?>,
	Pair: Component<AnyFilter?>,

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

	serdes: { [Entity]: Serdes },
}

return nil
