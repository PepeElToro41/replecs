# Replecs ⚡
Replecs is a fast, fine controlled JECS replication library 

Replecs is a feature rich, fast, flexible, powerful, and runtime/library agnostic replication library for ECS. 

- Per-entity replication
- Heavily optimized granular player filtering for entities and components
- Entity ID remapping
- Optional serdes for values
- Luau runtime agnostic
- Buffer-based replication
- Bandwidth efficient
- Supports tags and relationships
- Unreliable replication, with automatic 1kb buffer size limit

Demo place: https://www.roblox.com/games/132070456195381/
# Getting Started
### Roblox-TS
Install `@rbxts/jecs-addons` `@rbxts/replecs` `@rbxts/jecs`. 

**Make sure you install jecs as v0.8.3, not ^0.9.0** as they are not compatible. You can check the versioning by running `npm ls @rbxts/jecs`

## 🔥Setting Up

`shared/world.ts`
```ts
import { observer_add } from "@rbxts/jecs-addons"
import { world } from "@rbxts/jecs"

// you need to add the observer addon before passing it to the replicator!
export const world = observer_add(world())
```

`server/runtime.server.ts`
```ts
import { world } from "shared/world"
import { create_server } from "@rbxts/replecs"

const replicator = create_server(world)

//make sure you call replicator.init before you apply any operations
replicator.init()

//use whatever networking library you want, I am using @rbxts/remo
InitialReplecsRemotes.requestInitialPackets.connect(player => {
	if (replicator.is_player_ready(player)) return;
	replicator.mark_player_ready(player);

	const [buf, variants] = replicator.get_full(player);

	InitialReplecsRemotes.sendInitialPackets(player, buf, variants);
});
```

`client/runtime.client.ts`
```ts
import { world } from "shared/world"
import { create_client } from "@rbxts/replecs"

const replicator = create_server(world)

//make sure you call replicator.init before you apply any operations
replicator.init()

InitialReplecsRemotes.requestInitialPackets();

InitialReplecsRemotes.sendInitialPackets.connect((buf, variants) => {
	const replicator = HANDLE.getClientReplicator();

	replicator.apply_full(buf, variants);
});
```

## Using in action
Basic replicated component
```ts
const component1 = world.component<string>()
//you must add shared or Shared component to components you want to replicate
world.add(component1, shared)


const replicatedEntity = world.entity()
world.set(replicatedEntity, component1, "string")

//you must add replicatedEntity as networked and add the components you want to replicate
world.add(replicatedEntity, networked)

//this makes components appear in collect_updates
world.add(replicatedEntity, pair(reliable, component1))

//this makes components appear in collect_unreliable
world.add(replicatedEntity, pair(unreliable, component1))
```

Replication process
```ts
RunService.Heartbeat.Connect(() => {
  //this collects reliable updates
  for (const [player, buf, variants] of serverReplicator.collect_updates()) {
    //here I am using yetanothernet
    reliableRoute.send(buf, variants).to(player)
  }

  //this collects unrealible updates
  for (const [player, buf, variants] serverReplicator.collect_updates()) {
      //here I am using yetanothernet
      unreliableRoute.send(buf, variants).to(player)
  }
})
```

This is the basics of Replecs. For deeper understanding check out the demo folder files here
- [player first hydration](https://github.com/PepeElToro41/replecs/blob/main/demo/src/server/init.server.luau#L22)
- [send replication](https://github.com/PepeElToro41/replecs/blob/main/demo/src/server/systems/replecs_server.luau#L12)
- [receive replication](https://github.com/PepeElToro41/replecs/blob/main/demo/src/client/systems/replecs_client.luau)
- [setup an entity to replicate](https://github.com/PepeElToro41/replecs/blob/main/demo/src/server/controllers/spawn_cubes.luau#L10)
- custom ids: [client](https://github.com/PepeElToro41/replecs/blob/main/demo/src/shared/components/init.luau#L33) - [server](https://github.com/PepeElToro41/replecs/blob/main/demo/src/shared/players.luau#L16)
- [serdes](https://github.com/PepeElToro41/replecs/blob/main/demo/src/shared/components/init.luau#L37)
- [how you would add `shared` to all components](https://github.com/PepeElToro41/replecs/blob/main/demo/src/shared/components/init.luau#L52)
- create the replicators: [client](https://github.com/PepeElToro41/replecs/blob/main/demo/src/client/replicator.luau) - [server](https://github.com/PepeElToro41/replecs/blob/main/demo/src/server/replicator.luau)
- 
### Luau
TODO
