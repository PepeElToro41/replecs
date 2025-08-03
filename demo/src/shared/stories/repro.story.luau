local ReplicatedStorage = game:GetService "ReplicatedStorage"
local jecs = require(ReplicatedStorage.packages.jecs)
local replecs = require(ReplicatedStorage.packages.replecs)

local world = jecs.world()

local created_components = 0
function create_component()
	local component = world:component()
	world:add(component, replecs.shared)
	world:set(component, jecs.Name, "component " .. created_components)
	created_components = created_components + 1
	return component
end

local created_tags = 0
function create_tag()
	local tag = world:entity()
	world:add(tag, replecs.shared)
	world:set(tag, jecs.Name, "tag " .. created_tags)
	created_tags = created_tags + 1
	return tag
end

local style = create_component()
local ability = create_component()
local inputAction = create_component()
local abilityOf = create_tag()

local member = newproxy()
local server = replecs.create_server(world)
server:init()

server.masking:register_member(member)
server.masking:activate_member(member)

function create_things()
	local playerEntity = world:entity()
	world:add(playerEntity, replecs.networked)

	local styleEntity = world:entity()
	world:set(styleEntity, style, "style")
	world:add(styleEntity, jecs.pair(replecs.reliable, style))
	world:add(styleEntity, jecs.pair(jecs.ChildOf, playerEntity))
	world:add(styleEntity, jecs.pair(replecs.pair, jecs.ChildOf))
	world:add(styleEntity, replecs.Networked)

	local abilityEntity = world:entity()
	world:set(abilityEntity, ability, "12312")
	world:add(abilityEntity, jecs.pair(replecs.reliable, ability))
	world:set(abilityEntity, inputAction, "steal")
	world:add(abilityEntity, jecs.pair(replecs.reliable, inputAction))
	world:add(abilityEntity, jecs.pair(abilityOf, styleEntity))
	world:add(abilityEntity, jecs.pair(replecs.pair, abilityOf))
	world:add(abilityEntity, jecs.pair(jecs.ChildOf, playerEntity))
	world:add(abilityEntity, jecs.pair(replecs.pair, jecs.ChildOf))
	world:add(abilityEntity, replecs.Networked)
end

local c_world = jecs.world()
local client = replecs.create_client(c_world)

local c_created_components = 0
function c_create_component()
	local component = c_world:component()
	c_world:add(component, replecs.shared)
	c_world:set(component, jecs.Name, "component " .. c_created_components)
	c_created_components = c_created_components + 1
	return component
end

local c_created_tags = 0
function c_create_tag()
	local tag = c_world:entity()
	c_world:add(tag, replecs.shared)
	c_world:set(tag, jecs.Name, "tag " .. c_created_tags)
	c_created_tags = c_created_tags + 1
	return tag
end

local c_style = c_create_component()
local c_ability = c_create_component()
local c_inputAction = c_create_component()
local c_abilityOf = c_create_tag()

client:init()

return function()
	server:collect_updates()
	create_things()

	for _, buf, variants in server:collect_updates() do
		client:apply_updates(buf, variants)
	end

	return function() end
end
