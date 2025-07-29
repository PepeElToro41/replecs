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
         callback: (e: Entity, id: Id<T>, value: T) => void
      ): () => void;
      removed<T>(
         this: ObserverWorld,
         component: Id<T>,
         callback: (e: Entity, id: Id<T>) => void
      ): () => void;
      changed<T>(
         this: ObserverWorld,
         component: Id<T>,
         callback: (e: Entity, id: Id<T>, value: T) => void
      ): () => void;
   }

   type MemberFilterMap = Map<Player, boolean>;
   type MemberFilter = Player | MemberFilterMap | undefined;
   type Member = unknown;

   interface MaskingController {
      register_member(member: Member): void;
      unregister_member(member: Member): void;
      active_member(member: Member): void;
      member_is_active(member: Member): boolean;
   }

   export interface Components {
      shared: Tag;
      networked: Entity<MemberFilter>;
      reliable: Entity<MemberFilter>;
      unreliable: Entity<MemberFilter>;
      pair: Entity<MemberFilter>;

      serdes: Entity<SerdesTable>;
      bytespan: Entity<number>;
      custom_id: Entity<((value: any) => Entity) | undefined>;
      global_id: Entity<number>;

      Shared: Tag;
      Networked: Entity<MemberFilter>;
      Reliable: Entity<MemberFilter>;
      Unreliable: Entity<MemberFilter>;
      Pair: Entity<MemberFilter>;

      Serdes: Entity<SerdesTable>;
      Bytespan: Entity<number>;
      CustomId: Entity<(value: any) => Entity>;
      GlobalId: Entity<number>;
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
      parse_global_id(parser: (id: number) => Entity): void;

      get_server_entity(client_entity: Entity): number | undefined;
      get_client_entity(server_entity: number): Entity | undefined;
   }

   export interface Server {
      world: ObserverWorld;
      inited?: boolean;

      init(world?: ObserverWorld): void;
      destroy(): void;

      get_full(player: Player): LuaTuple<[buffer, any[][]]>;
      collect_updates(): IterableFunction<LuaTuple<[Player, buffer, any[][]]>>;
      collect_unreliable(): IterableFunction<
         LuaTuple<[Player, buffer, any[][]]>
      >;
      mark_player_ready(player: Player): void;
      is_player_ready(player: Player): boolean;

      masking: MaskingController;
   }

   export interface ReplecsLib {
      client: Client;
      server: Server;

      after_replication(callback: () => void): void;
   }

   export interface Replecs extends Components {
      create: (world?: ObserverWorld) => ReplecsLib;
      create_server: (world?: ObserverWorld) => Server;
      create_client: (world?: ObserverWorld) => Client;
   }
}

declare const Replecs: Replecs.Replecs;

export = Replecs;
