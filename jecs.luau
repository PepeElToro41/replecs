local module = require "./luau_packages/jecs"
export type Archetype = module.Archetype
export type QueryInner = module.QueryInner
export type Entity<T = any> = module.Entity<T>
export type Id<T = any> = module.Id<T>
export type Pair<P, O> = module.Pair<P, O>
export type Item<T...> = module.Item<T...>
export type Iter<T...> = module.Iter<T...>
export type Query<T...> = module.Query<T...>
export type Observer = module.Observer
export type World = module.World
export type Record = module.Record
export type ComponentRecord = module.ComponentRecord
export type ComponentIndex = module.ComponentIndex
export type Archetypes = module.Archetypes
export type EntityIndex = module.EntityIndex
return module
