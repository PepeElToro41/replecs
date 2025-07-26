import type { Entity, Id, Tag, World } from "@rbxts/jecs";

declare namespace Replecs {
  export interface SerdesTable {
    serialize: (value: any) => buffer;
    deserialize: (buffer: buffer) => any;
  }

  export interface ObserverWorld extends World {
    added<T>(
      this: ObserverWorld,
      component: Id<T>,
      callback: (e: Entity, id: Id<T>, value?: T) => void,
    ): () => void;
    removed<T>(
      this: ObserverWorld,
      component: Id<T>,
      callback: (e: Entity, id: Id<T>) => void,
    ): () => void;
    changed<T>(
      this: ObserverWorld,
      component: Id<T>,
      callback: (e: Entity, id: Id<T>, value?: T) => void,
    ): () => void;
  }

  type MemberFilter = Map<Player, boolean>;

  export interface Components {
    shared: Tag;
    networked: Entity<MemberFilter | undefined>;
    reliable: Entity<MemberFilter | undefined>;
    unreliable: Entity<MemberFilter | undefined>;
    pair: Tag;

    serdes: Entity<SerdesTable>;
    bytespan: Entity<number>;
    custom_id: Entity<(value: any) => Entity>;
    __alive_tracking__: Tag;

    Shared: Tag;
    Networked: Entity<MemberFilter | undefined>;
    Reliable: Entity<MemberFilter | undefined>;
    Unreliable: Entity<MemberFilter | undefined>;
    Pair: Tag;

    Serdes: Entity<SerdesTable>;
    Bytespan: Entity<number>;
    CustomId: Entity<(value: any) => Entity>;
  }

  export interface Client {
    world: ObserverWorld;
    inited?: boolean;

    init(world?: ObserverWorld): void;
    destroy(): void;
    after_replication(callback: () => void): void;

    apply_updates(buf: buffer, all_variants?: any[][]): void;
    apply_unreliable(buf: buffer, all_variants?: any[][]): void;
    apply_full(buf: buffer, all_variants?: any[][]): void;
  }

  export interface Server {
    world: ObserverWorld;
    inited?: boolean;

    init(world?: ObserverWorld): void;
    destroy(): void;

    get_full(player: Player): LuaTuple<[buffer, any[][]]>;
    collect_updates(): () => LuaTuple<[Player, buffer, any[][]]>;
    collect_unreliable(): () => LuaTuple<[Player, buffer, any[][]]>;
    mark_player_ready(player: Player): void;
    is_player_ready(player: Player): boolean;
  }

  export interface Replecs extends Components {
    client: Client;
    server: Server;

    after_replication(world: ObserverWorld): void;

    create_server(world: ObserverWorld | undefined): Server;
    create_client(world: ObserverWorld | undefined): Client;
    create(world: ObserverWorld | undefined): Replecs;
  }
}

declare const Replecs: Replecs.Replecs;

export = Replecs;
