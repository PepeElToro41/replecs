import type { Entity, Id, Pair, Tag, World } from "@rbxts/jecs";

declare namespace Replecs {
   export type SerdesTable =
      | {
           bytespan?: number;
           includes_variants?: false;
           serialize: (value: any) => buffer;
           deserialize: (buffer: buffer) => any;
        }
      | {
           bytespan?: number;
           includes_variants: true;
           serialize: (value: any) => LuaTuple<[buffer, defined[] | undefined]>;
           deserialize: (buffer: buffer, blobs: defined[] | undefined) => any;
        };

   type MemberFilterMap = Map<Player, boolean>;
   type MemberFilter = Player | MemberFilterMap | undefined;
   type Member = unknown;

   export interface SharedInfo<T> {
      lookup: Record<string, T>;
      keys: string[];
      indexes: [T];
      members: Map<T, number>;
   }
   export interface HandleContext {
      entity_id: number;
      component: <T>(component: Entity<T>) => T;
      target: (relation: Id, index?: number) => Entity | undefined;
      pair_value: <T>(relation: Id<T>, target: Entity) => T | undefined;
      has_pair: (relation: Id, target: Entity) => boolean;

      entity: (server_entity: number) => Entity | undefined;
      has: (tag: Entity) => boolean;
   }
   export interface CustomId {
      identifier: string;
      handle_callback: (ctx: HandleContext) => Entity;
      handle(handler: (ctx: HandleContext) => Entity): void;
   }

   export interface Shared {
      components: SharedInfo<Entity>;
      custom_ids: SharedInfo<CustomId>;
   }
   interface HandshakeSerdesInfo {
      includes_variants?: boolean;
      bytespan?: number;
   }

   export interface HandshakeInfo {
      components: Record<string, boolean>;
      custom_ids: Record<string, boolean>;
      serdes: Record<string, HandshakeSerdesInfo>;
   }

   export interface Components {
      shared: Tag;
      networked: Entity<MemberFilter>;
      reliable: Entity<MemberFilter>;
      unreliable: Entity<MemberFilter>;
      pair: Entity<MemberFilter>;

      serdes: Entity<SerdesTable>;
      custom: Entity;
      custom_handler: Entity<(value: any) => Entity>;
      global: Entity<number>;

      Shared: Tag;
      Networked: Entity<MemberFilter>;
      Reliable: Entity<MemberFilter>;
      Unreliable: Entity<MemberFilter>;
      Pair: Entity<MemberFilter>;

      Serdes: Entity<SerdesTable>;
      Custom: Entity;
      CustomHandler: Entity<(value: any) => Entity>;
      Global: Entity<number>;
   }

   export interface Client {
      world: World;
      inited?: boolean;

      is_relicating: boolean;
      after_relication_callbacks: [() => void];

      components: Components;

      init(world?: World): void;
      destroy(): void;

      handle_global(handler: (id: number) => Entity): void;

      get_server_entity(client_entity: Entity): number | undefined;
      get_client_entity(server_entity: number): Entity | undefined;

      register_entity(entity: Entity, server_entity: number): void;
      unregister_entity(entity: Entity): void;

      after_replication(callback: () => void): void;
      added(callback: (entity: Entity) => void): () => void;

      hook<T>(
         action: "changed",
         relation: Pair<MemberFilter, T>,
         callback: (entity: Entity, id: Id<T>, value: T) => void
      ): () => void;
      hook<T>(
         action: "removed",
         relation: Pair<MemberFilter, T>,
         callback: (entity: Entity, id: Id<T>) => void
      ): () => void;
      hook(
         action: "deleted",
         entity: Entity,
         callback: (entity: Entity) => void
      ): () => void;

      override<T>(
         action: "changed",
         relation: Pair<MemberFilter, T>,
         callback: (entity: Entity, id: Id<T>, value: any) => void
      ): () => void;
      override<T>(
         action: "removed",
         relation: Pair<MemberFilter, T>,
         callback: (entity: Entity, id: Id<T>) => void
      ): () => void;
      override(
         action: "deleted",
         entity: Entity,
         callback: (entity: Entity) => void
      ): () => void;

      encode_component(component: Entity): number;
      decode_component(encoded: number): Entity;
      register_custom_id(custom_id: CustomId): void;

      apply_updates(buf: buffer, all_variants?: unknown[][]): void;
      apply_unreliable(buf: buffer, all_variants?: unknown[][]): void;
      apply_full(buf: buffer, all_variants?: unknown[][]): void;

      generate_handshake(): HandshakeInfo;
      verify_handshake(
         handshake: HandshakeInfo
      ): LuaTuple<[true]> | LuaTuple<[false, string]>;
   }

   export interface ServerImp {
      set_networked(
         server: Server,
         entity: Entity,
         filter?: MemberFilter
      ): void;
      stop_networked(server: Server, entity: Entity): void;

      set_reliable(
         server: Server,
         entity: Entity,
         component: Entity,
         filter?: MemberFilter
      ): void;
      set_unreliable(
         server: Server,
         entity: Entity,
         component: Entity,
         filter?: MemberFilter
      ): void;
      set_pair(
         server: Server,
         entity: Entity,
         relation: Entity,
         filter?: MemberFilter
      ): void;
      set_custom(
         server: Server,
         entity: Entity,
         handler: Entity | CustomId
      ): void;

      stop_reliable(server: Server, entity: Entity, component: Entity): void;
      stop_unreliable(server: Server, entity: Entity, component: Entity): void;
      stop_pair(server: Server, entity: Entity, relation: Entity): void;
      remove_custom(server: Server, entity: Entity): void;
   }

   export interface Server extends ServerImp {
      world: World;
      inited?: boolean;

      init(world?: World): void;
      destroy(): void;

      encode_component(component: Entity): number;
      decode_component(encoded: number): Entity;
      register_custom_id(custom_id: CustomId): void;

      get_full(player: Player): LuaTuple<[buffer, unknown[][]]>;
      collect_updates(): IterableFunction<
         LuaTuple<[Player, buffer, unknown[][]]>
      >;
      collect_unreliable(): IterableFunction<
         LuaTuple<[Player, buffer, unknown[][]]>
      >;

      mark_player_ready(player: Player): void;
      is_player_ready(player: Player): boolean;

      add_player_alias(client: Player, alias: defined): void;
      remove_player_alias(alias: defined): void;

      generate_handshake(): HandshakeInfo;
      verify_handshake(
         handshake: HandshakeInfo
      ): LuaTuple<[true]> | LuaTuple<[false, string]>;
   }

   export interface ReplecsLib {
      client: Client;
      server: Server;

      after_replication(callback: () => void): void;
      register_custom_id(custom_id: CustomId): void;
   }

   export interface Replecs extends Components {
      VERSION: string;

      create: (world?: World) => ReplecsLib;
      create_server: (world?: World) => Server;
      create_client: (world?: World) => Client;
      create_custom_id: (
         identifier: string,
         handler?: (ctx: HandleContext) => Entity
      ) => CustomId;
   }
}

declare const Replecs: Replecs.Replecs;

export = Replecs;
