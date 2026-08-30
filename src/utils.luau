--!optimize 2
--!native

local pepecs = require "../pepecs"
local common = require "./common"
local types = require "./types"

type World = common.World
type Entity = common.Entity
type Component = common.Component

local RELATIONSHPIS = common.relationships

local utils = {}

function utils.create_components(tag: () -> Component, component: () -> Component, push: types.Components?)
	local components = push or {} :: types.Components
	components.shared = tag()
	components.networked = component()

	if RELATIONSHPIS then
		components.reliable = component()
		components.unreliable = component()
		components.once = component()
		components.relation = component()

		components.custom = tag()
	end
	components.custom_handler = component()
	components.serdes = component()
	components.__alive_tracking__ = tag()

	components.Shared = components.shared
	components.Networked = components.networked
	if RELATIONSHPIS then
		components.Reliable = components.reliable
		components.Unreliable = components.unreliable
		components.Once = components.once
		components.Relation = components.relation

		components.Custom = components.custom
	end
	components.CustomHandler = components.custom_handler
	components.Serdes = components.serdes
	return components
end

function utils.add_component_names(components: types.Components, set: (component: Component, name: string) -> ())
	set(components.shared, "replecs.shared")
	if RELATIONSHPIS then
		set(components.networked, "replecs.networked")
		set(components.reliable, "replecs.reliable")
		set(components.unreliable, "replecs.unreliable")
		set(components.once, "replecs.once")
		set(components.relation, "replecs.relation")

		set(components.custom, "replecs.custom")
	end
	set(components.custom_handler, "replecs.custom_handler")
	set(components.serdes, "replecs.serdes")

	set(components.__alive_tracking__, "replecs.__alive_tracking__")
end

function utils.component_factory(world: World)
	return function()
		return common.world_component(world)
	end
end

function utils.tag_factory(world: World)
	return function()
		return common.world_tag(world)
	end
end

-- without preregistration the replecs components live in the world itself;
-- created once the world is known (create or init), named and given the same
-- metadata the preregistered set gets
function utils.create_world_components(world: World): types.Components
	local components = utils.create_components(utils.tag_factory(world), utils.component_factory(world))
	utils.add_component_names(components, function(component, name)
		common.add_name(world, component, name)
	end)
	pepecs.meta(components.custom, pepecs.Exclusive)
	return components
end

function utils.is_client_valid(player: any): boolean
	if game then
		if typeof(player) == "Instance" then
			return player.ClassName == "Player" and player:IsDescendantOf(game:GetService "Players")
		else
			return false
		end
	end
	return true
end

return utils
