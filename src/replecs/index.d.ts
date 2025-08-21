import type { Entity, Pair, Tag, World } from "@rbxts/jecs";

declare namespace Replecs {
   export type SerdesTable =
      | {
           includes_variants?: false;
           serialize: (value: any) => buffer;
           deserialize: (buffer: buffer) => any;
        }
      | {
           includes_variants: true;
           serialize: (value: any) => LuaTuple<[buffer, defined[] | undefined]>;
           deserialize: (buffer: buffer, blobs: defined[] | undefined) => any;
        };

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
      custom: Entity;
      custom_handler: Entity<(value: any) => Entity>;
      global: Entity<number>;

      Shared: Tag;
      Networked: Entity<MemberFilter>;
      Reliable: Entity<MemberFilter>;
      Unreliable: Entity<MemberFilter>;
      Pair: Entity<MemberFilter>;

      Serdes: Entity<SerdesTable>;
      Bytespan: Entity<number>;
      Custom: Entity;
      CustomHandler: Entity<(value: any) => Entity>;
      Global: Entity<number>;
   }

   export interface Client {
      world: World;
      inited?: boolean;

      init(world?: World): void;
      destroy(): void;

      handle_global(handler: (id: number) => Entity): void;

      after_replication(callback: () => void): void;
      added(callback: (entity: Entity) => void): () => void;
      hook<T>(
         entity: Entity,
         action: "changed",
         relation: Pair<MemberFilter, T>,
         callback: (entity: Entity, id: Entity<T>, value: T) => void
      ): () => void;
      hook<T>(
         entity: Entity,
         action: "removed",
         relation: Pair<MemberFilter, T>,
         callback: (entity: Entity, id: Entity<T>) => void
      ): () => void;
      hook(
         entity: Entity,
         action: "deleted",
         callback: (entity: Entity) => void
      ): () => void;

      override<T>(
         entity: Entity,
         action: "changed",
         relation: Pair<MemberFilter, T>,
         callback: (entity: Entity, id: Entity<T>, value: any) => void
      ): () => void;
      override<T>(
         entity: Entity,
         action: "removed",
         relation: Pair<MemberFilter, T>,
         callback: (entity: Entity, id: Entity<T>) => void
      ): () => void;
      override(
         entity: Entity,
         action: "deleted",
         callback: (entity: Entity) => void
      ): () => void;

      encode_component(component: Entity): number;
      decode_component(encoded: number): Entity;

      get_server_entity(client_entity: Entity): number | undefined;
      get_client_entity(server_entity: number): Entity | undefined;

      apply_updates(buf: buffer, all_variants?: unknown[][]): void;
      apply_unreliable(buf: buffer, all_variants?: unknown[][]): void;
      apply_full(buf: buffer, all_variants?: unknown[][]): void;
   }

   export interface Server {
      world: World;
      inited?: boolean;

      init(world?: World): void;
      destroy(): void;

      get_full(player: Player): LuaTuple<[buffer, unknown[][]]>;
      collect_updates(): IterableFunction<
         LuaTuple<[Player, buffer, unknown[][]]>
      >;
      collect_unreliable(): IterableFunction<
         LuaTuple<[Player, buffer, unknown[][]]>
      >;

      encode_component(component: Entity): number;
      decode_component(encoded: number): Entity;

      mark_player_ready(player: Player): void;
      is_player_ready(player: Player): boolean;

      add_player_alias(client: Player, alias: defined): void;
      remove_player_alias(alias: defined): void;

      masking: MaskingController;
   }

   export interface ReplecsLib {
      client: Client;
      server: Server;

      after_replication(callback: () => void): void;
   }

   export interface Replecs extends Components {
      create: (world?: World) => ReplecsLib;
      create_server: (world?: World) => Server;
      create_client: (world?: World) => Client;
   }
}

declare const Replecs: Replecs.Replecs;

export = Replecs;
