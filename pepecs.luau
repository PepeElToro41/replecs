local module = require "./luau_packages/pepecs"

export type Archetype = module.Archetype
export type Entity<T = any> = module.Entity<T>
export type Id<T = any> = module.Id<T>
export type Pair<P, O> = module.Pair<P, O>
export type Query<T...> = module.Query<T...>
export type World = module.World
export type ComponentRecord = module.ComponentRecord
export type EntityIndex = module.EntityIndex

return module
