local pepecs = require "./pepecs"
local common = require "@self/common"
local types = require "@self/types"
local utils = require "@self/utils"

local client = require "@self/client"
local server = require "@self/server"
local customid = require "@self/customid"
local VERSION = require "@self/ver"

export type Server = server.Server
export type Client = client.Client

type Entity = common.Entity
type World = common.World
type Component<T = any> = common.Component<T>

export type HandleContext = customid.HandleContext
export type CustomId = customid.CustomId
export type HandshakeInfo = types.HandshakeInfo
export type Serdes = types.Serdes

export type ReplecsLib = {
	server: Server,
	client: Client,
	components: types.Components,

	after_replication: (self: ReplecsLib, callback: () -> ()) -> (),
	register_custom_id: (self: ReplecsLib, custom_id: CustomId) -> (),

	set_serdes: <T>(self: ReplecsLib, id: Component<T>, serdes: types.Serdes<T>) -> (),
	remove_serdes: (self: ReplecsLib, id: Component) -> (),
	set_preprocessor: <B, A>(self: ReplecsLib, id: Component<B>, preprocessor: types.Preprocessor<B, A>) -> (),
	remove_preprocessor: (self: ReplecsLib, id: Component) -> (),
	set_delta_serializer: <T, D>(self: ReplecsLib, id: Component<T>, delta: types.DeltaSerializer<T, D>) -> (),
	remove_delta_serializer: (self: ReplecsLib, id: Component) -> (),
}

type Replecs = types.Components & {
	__index: any,
	VERSION: string,
	MAX_CLIENTS: number,

	create: (world: World?) -> ReplecsLib,

	create_server: (world: World?) -> Server,
	create_client: (world: World?) -> Client,
	create_custom_id: (identifier: string, handler: (ctx: HandleContext) -> Entity?) -> CustomId,
}

local replecs = {}
replecs.VERSION = VERSION
replecs.MAX_CLIENTS = 128
replecs.__index = replecs

local PREREGISTRATION = common.preregistration

if PREREGISTRATION then
	local components = replecs :: Replecs
	utils.create_components(common.preregister_tag, common.preregister_component, components)
	utils.add_component_names(components, common.add_preregistered_name)

	pepecs.meta(components.custom, pepecs.Exclusive)
end

local COMPONENTS: Replecs = if PREREGISTRATION then replecs else nil :: any

function replecs.create_server(world: World?): Server
	return server.create(world, COMPONENTS, replecs.MAX_CLIENTS)
end

function replecs.create_client(world: World?): Client
	return client.create(world, COMPONENTS)
end

function replecs.create(world: World?): ReplecsLib
	assert(
		game,
		"replecs.create() is only for roblox, call create_client or create_server manually depending on your setup"
	)

	local RunService = game:GetService "RunService"
	local self = {} :: ReplecsLib

	-- without preregistration the components come from the world: shared by
	-- both sides when it is known here, else created by whichever inits first
	local components = COMPONENTS or (if world then utils.create_world_components(world) else nil) :: any

	if RunService:IsServer() then
		self.server = server.create(world, components, replecs.MAX_CLIENTS)
		components = self.server.components
	end
	if RunService:IsClient() then
		self.client = client.create(world, components)
		components = self.client.components
	end
	self.components = components

	return setmetatable(self, replecs) :: any
end

function replecs.create_custom_id(identifier: string, handler: (ctx: HandleContext) -> Entity?)
	return customid.create(identifier, handler)
end

function replecs.after_replication(lib: ReplecsLib, callback: () -> ())
	local lib_client = lib.client
	if lib_client then
		lib_client:after_replication(callback)
	else
		callback()
	end
end

function replecs.register_custom_id(lib: ReplecsLib, custom_id: CustomId)
	if lib.server then
		lib.server:register_custom_id(custom_id)
	end
	if lib.client then
		lib.client:register_custom_id(custom_id)
	end
end

function replecs.set_serdes(lib: ReplecsLib, id: Component, serdes: Serdes)
	if lib.server then
		lib.server:set_serdes(id, serdes)
	end
	if lib.client then
		lib.client:set_serdes(id, serdes)
	end
end

function replecs.remove_serdes(lib: ReplecsLib, id: Component)
	if lib.server then
		lib.server:remove_serdes(id)
	end
	if lib.client then
		lib.client:remove_serdes(id)
	end
end

function replecs.set_preprocessor(lib: ReplecsLib, id: Component, preprocessor: types.Preprocessor)
	if lib.server then
		lib.server:set_preprocessor(id, preprocessor)
	end
	if lib.client then
		lib.client:set_preprocessor(id, preprocessor)
	end
end

function replecs.remove_preprocessor(lib: ReplecsLib, id: Component)
	if lib.server then
		lib.server:remove_preprocessor(id)
	end
	if lib.client then
		lib.client:remove_preprocessor(id)
	end
end

function replecs.set_delta_serializer(lib: ReplecsLib, id: Component, delta_serializer: types.DeltaSerializer)
	if lib.server then
		lib.server:set_delta_serializer(id, delta_serializer)
	end
	if lib.client then
		lib.client:set_delta_serializer(id, delta_serializer)
	end
end

function replecs.remove_delta_serializer(lib: ReplecsLib, id: Component)
	if lib.server then
		lib.server:remove_delta_serializer(id)
	end
	if lib.client then
		lib.client:remove_delta_serializer(id)
	end
end

return (replecs :: any) :: Replecs
