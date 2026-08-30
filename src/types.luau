local customid = require "./customid"
local common = require "./common"

type Entity = common.Entity
type World = common.World
type Component<T = any> = common.Component<T>

type Player = any

export type FilterSet = {
	[Player]: boolean,
}
export type FilterPlayer = Player
export type FilterPredicator = (Player) -> boolean
export type FilterAny = FilterPlayer | FilterSet | FilterPredicator
export type FilterSimple = FilterPlayer | FilterSet

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

export type Preprocessor<B = any, A = any> = {
	serialize: (B) -> A,
	deserialize: (A) -> B,
}

export type DeltaSerializer<T = any, D = T> = {
	snapshot: ((value: T) -> T)?,
	delta: (old: T, curr: T) -> D,
	apply: (curr: T, delta: D) -> T,
}

export type Components = {
	shared: Entity,
	Shared: Entity,
	networked: Component<any?>,
	Networked: Component<FilterAny?>,
	reliable: Component<FilterAny?>,
	Reliable: Component<FilterAny?>,
	unreliable: Component<FilterAny?>,
	Unreliable: Component<FilterAny?>,
	once: Component<FilterAny?>,
	Once: Component<FilterAny?>,
	relation: Component<FilterAny?>,
	Relation: Component<FilterAny?>,

	serdes: Component<Serdes>,
	Serdes: Component<Serdes>,
	custom: Entity,
	Custom: Entity,
	custom_handler: Component<(val: any) -> Entity?>,
	CustomHandler: Component<(val: any) -> Entity?>,
	__alive_tracking__: Entity,
}

export type Shared = {
	components: SharedInfo<Entity>,
	custom_ids: SharedInfo<customid.CustomId>,

	serdes: { [Component]: Serdes },
}

return nil
