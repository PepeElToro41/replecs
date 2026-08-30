--!optimize 2

local pepecs = require "../../pepecs"
local server_lib = require "../../src/server"
local replecs = require "../../src"
local bench = require "./bench"

type Entity = pepecs.Entity
type Server = server_lib.Server

local AMOUNT = 2 ^ 16
local MEMBER_AMOUNT = 62
local FILTER_AMOUNT = 512
local FILTER_SIZE = MEMBER_AMOUNT // 2

math.randomseed(42)

local function create_server(): (Server, pepecs.World)
	local world = pepecs.world()
	local server = replecs.create_server(world)
	server:init()
	return server, world
end

-- components must be shared and named to be written on the wire
local shared_counter = 0
local function shared_component(world: pepecs.World): pepecs.Entity
	shared_counter += 1
	local component = world.component()
	world.add(component, replecs.shared)
	world.set(component, pepecs.Name, "component_" .. shared_counter)
	return component
end

local function ready_members(server: Server, amount: number): { any }
	local players = table.create(amount)
	for i = 1, amount do
		local player = "player_" .. i
		players[i] = player
		server:mark_player_ready(player)
	end
	-- promote activations so benches run against established active clients
	server:collect_updates()
	return players
end

local function create_entities(world: pepecs.World, amount: number): { Entity }
	local entities = table.create(amount)
	for i = 1, amount do
		entities[i] = world.entity()
	end
	return entities
end

local function random_filter_set(players: { any }, size: number): { [any]: boolean }
	local filter = {}
	for _ = 1, size do
		filter[players[math.random(#players)]] = true
	end
	return filter
end

local function create_random_filters(players: { any }, amount: number): { { [any]: boolean } }
	local filters = table.create(amount)
	for i = 1, amount do
		filters[i] = random_filter_set(players, FILTER_SIZE)
	end
	return filters
end

do
	bench.title "start_networked"

	local server, world = create_server()
	local players = ready_members(server, MEMBER_AMOUNT)
	local filters = create_random_filters(players, FILTER_AMOUNT)

	local nil_entities = create_entities(world, AMOUNT)
	bench.run("set_networked (nil filter)", AMOUNT, function(i)
		server:set_networked(nil_entities[i])
	end)
	bench.once("collect_updates (nil filter additions)", AMOUNT, function()
		server:collect_updates()
	end)

	local player_entities = create_entities(world, AMOUNT)
	bench.run("set_networked (player filter)", AMOUNT, function(i)
		server:set_networked(player_entities[i], players[i % MEMBER_AMOUNT + 1])
	end)
	bench.once("collect_updates (player filter additions)", AMOUNT, function()
		server:collect_updates()
	end)

	local set_entities = create_entities(world, AMOUNT)
	bench.run("set_networked (set filter)", AMOUNT, function(i)
		server:set_networked(set_entities[i], filters[i % FILTER_AMOUNT + 1])
	end)
	bench.once("collect_updates (set filter additions)", AMOUNT, function()
		server:collect_updates()
	end)
end

do
	bench.title "change_networked"

	local server, world = create_server()
	local players = ready_members(server, MEMBER_AMOUNT)
	local filters = create_random_filters(players, FILTER_AMOUNT)
	local entities = create_entities(world, AMOUNT)

	for i = 1, AMOUNT do
		server:set_networked(entities[i], filters[i % FILTER_AMOUNT + 1])
	end
	server:collect_updates()

	-- first change after a cycle snapshots last_replicated (clone path)
	bench.run("set_networked change (set filter)", AMOUNT, function(i)
		server:set_networked(entities[i], filters[(i + 7) % FILTER_AMOUNT + 1])
	end)

	-- second change in the same cycle reuses the existing snapshot
	bench.run("set_networked re-change (set filter)", AMOUNT, function(i)
		server:set_networked(entities[i], filters[(i + 13) % FILTER_AMOUNT + 1])
	end)

	bench.run("set_networked change (player filter)", AMOUNT, function(i)
		server:set_networked(entities[i], players[i % MEMBER_AMOUNT + 1])
	end)

	bench.once("collect_updates (after changes)", AMOUNT, function()
		server:collect_updates()
	end)
end

do
	bench.title "collect_updates"

	-- pure filter-change serialization, fresh snapshot every cycle
	local server, world = create_server()
	local players = ready_members(server, MEMBER_AMOUNT)
	local filters = create_random_filters(players, FILTER_AMOUNT)
	local entities = create_entities(world, AMOUNT)

	for i = 1, AMOUNT do
		server:set_networked(entities[i], filters[i % FILTER_AMOUNT + 1])
	end
	server:collect_updates()

	for i = 1, AMOUNT do
		server:set_networked(entities[i], filters[(i + 3) % FILTER_AMOUNT + 1])
	end
	bench.once("all entities filter-dirty", AMOUNT, function()
		server:collect_updates()
	end)

	local tenth = AMOUNT // 10
	for i = 1, tenth do
		server:set_networked(entities[i], filters[(i + 5) % FILTER_AMOUNT + 1])
	end
	bench.once("10% entities filter-dirty", tenth, function()
		server:collect_updates()
	end)

	-- active-set change only: no dirty entities, deltas resolve empty
	server:mark_player_ready "late_player"
	bench.once("newly active player, no dirty entities", 1, function()
		server:collect_updates()
	end)

	bench.once("no-op collect", 1, function()
		server:collect_updates()
	end)
end

do
	bench.title "component deltas"

	local COMPONENT_AMOUNT = 4
	local ENTITY_AMOUNT = 2 ^ 14

	local server, world = create_server()
	local players = ready_members(server, MEMBER_AMOUNT)
	local filters = create_random_filters(players, FILTER_AMOUNT)
	local entities = create_entities(world, ENTITY_AMOUNT)

	local components = table.create(COMPONENT_AMOUNT)
	for i = 1, COMPONENT_AMOUNT do
		components[i] = shared_component(world)
	end

	for i = 1, ENTITY_AMOUNT do
		server:set_networked(entities[i], filters[i % FILTER_AMOUNT + 1])
	end

	local ops = ENTITY_AMOUNT * COMPONENT_AMOUNT
	bench.run("set_reliable (set filter)", ops, function(i)
		local entity_index = (i - 1) % ENTITY_AMOUNT + 1
		local component_index = (i - 1) // ENTITY_AMOUNT + 1
		server:set_reliable(entities[entity_index], components[component_index], filters[(i + 9) % FILTER_AMOUNT + 1])
	end)
	server:collect_updates()

	bench.run("set_reliable change (set filter)", ops, function(i)
		local entity_index = (i - 1) % ENTITY_AMOUNT + 1
		local component_index = (i - 1) // ENTITY_AMOUNT + 1
		server:set_reliable(entities[entity_index], components[component_index], filters[(i + 21) % FILTER_AMOUNT + 1])
	end)

	bench.once("collect_updates (component filter changes)", ops, function()
		server:collect_updates()
	end)
end

do
	bench.title "changed hooks"

	local ENTITY_AMOUNT = 2 ^ 16

	-- baseline: no hooks at all
	local bare_world = pepecs.world()
	local bare_component = bare_world.component()
	local bare_entities = create_entities(bare_world, ENTITY_AMOUNT)
	for i = 1, ENTITY_AMOUNT do
		bare_world.set(bare_entities[i], bare_component, i)
	end
	bench.run("world:set (no hooks)", ENTITY_AMOUNT, function(i)
		bare_world.set(bare_entities[i], bare_component, i + 1)
	end)

	-- empty hooks: same three hooks replecs registers, doing nothing
	local empty_world = pepecs.world()
	local empty_component = empty_world.component()
	local empty_entities = create_entities(empty_world, ENTITY_AMOUNT)

	empty_world.added(empty_component, function() end)
	empty_world.changed(empty_component, function() end)
	empty_world.removed(empty_component, function() end)

	for i = 1, ENTITY_AMOUNT do
		empty_world.set(empty_entities[i], empty_component, i)
	end
	bench.run("world:set (empty hooks)", ENTITY_AMOUNT, function(i)
		empty_world.set(empty_entities[i], empty_component, i + 1)
	end)

	-- replecs hooks: mark component storage dirty on every change
	local server, world = create_server()
	ready_members(server, MEMBER_AMOUNT)
	local component = shared_component(world)
	local entities = create_entities(world, ENTITY_AMOUNT)

	for i = 1, ENTITY_AMOUNT do
		server:set_networked(entities[i])
		server:set_reliable(entities[i], component)
		world.set(entities[i], component, i)
	end
	server:collect_updates()

	-- first set per cycle takes the mark-dirty path (flag set + table inserts)
	bench.run("world:set (replecs hooks, clean)", ENTITY_AMOUNT, function(i)
		world.set(entities[i], component, i + 1)
	end)

	-- second set in the same cycle early-outs on the already-set flag
	bench.run("world:set (replecs hooks, already dirty)", ENTITY_AMOUNT, function(i)
		world.set(entities[i], component, i + 2)
	end)

	bench.once("collect_updates (all changed-dirty)", ENTITY_AMOUNT, function()
		server:collect_updates()
	end)

	local tenth = ENTITY_AMOUNT // 10
	for i = 1, tenth do
		world.set(entities[i], component, i + 3)
	end
	bench.once("collect_updates (10% changed-dirty)", tenth, function()
		server:collect_updates()
	end)
end

do
	bench.title "get_full"

	local ENTITY_AMOUNT = 2 ^ 14
	local COMPONENT_AMOUNT = 4

	local server, world = create_server()
	local players = ready_members(server, MEMBER_AMOUNT)
	local filters = create_random_filters(players, FILTER_AMOUNT)
	local entities = create_entities(world, ENTITY_AMOUNT)

	local components = table.create(COMPONENT_AMOUNT)
	for i = 1, COMPONENT_AMOUNT do
		components[i] = shared_component(world)
	end
	local tag = world.entity()
	world.add(tag, replecs.shared)
	world.set(tag, pepecs.Name, "bench_tag")

	-- every entity visible to everyone, every component tracked: the whole
	-- world lands in the packet
	for i = 1, ENTITY_AMOUNT do
		local entity = entities[i]
		server:set_networked(entity)
		for c = 1, COMPONENT_AMOUNT do
			world.set(entity, components[c], i + c)
			server:set_reliable(entity, components[c])
		end
		world.add(entity, tag)
		server:set_reliable(entity, tag)
	end
	server:collect_updates()

	bench.once("get_full (nil filters, all visible)", ENTITY_AMOUNT, function()
		server:get_full(players[1])
	end)

	-- random set filters on entities and components: roughly half the entities
	-- visible, half the tracked components clipped per player
	for i = 1, ENTITY_AMOUNT do
		local entity = entities[i]
		server:set_networked(entity, filters[i % FILTER_AMOUNT + 1])
		for c = 1, COMPONENT_AMOUNT do
			server:set_reliable(entity, components[c], filters[(i + c * 7) % FILTER_AMOUNT + 1])
		end
	end
	server:collect_updates()

	bench.once("get_full (set filters, partial visibility)", ENTITY_AMOUNT, function()
		server:get_full(players[1])
	end)

	-- nothing visible: pure bitmask tests over every networked entity
	local nobody = "nobody"
	server:mark_player_ready(nobody)
	for i = 1, ENTITY_AMOUNT do
		server:set_networked(entities[i], players[i % MEMBER_AMOUNT + 1])
	end
	server:collect_updates()

	bench.once("get_full (nothing visible)", ENTITY_AMOUNT, function()
		server:get_full(nobody)
	end)
end

do
	bench.title "serdes"

	local ENTITY_AMOUNT = 2 ^ 13
	local COMPONENT_AMOUNT = 6

	-- fixed-span u32 serdes: value goes on the wire instead of the variants list
	local u32_serdes = {
		bytespan = 4,
		serialize = function(value: number): buffer
			local output = buffer.create(4)
			buffer.writeu32(output, 0, value)
			return output
		end,
		deserialize = function(input: buffer): number
			return buffer.readu32(input, 0)
		end,
	}

	local function setup(with_serdes: boolean): (Server, pepecs.World, { Entity }, { Entity })
		local server, world = create_server()
		ready_members(server, MEMBER_AMOUNT)
		local entities = create_entities(world, ENTITY_AMOUNT)

		local components = table.create(COMPONENT_AMOUNT)
		for i = 1, COMPONENT_AMOUNT do
			components[i] = shared_component(world)
			if with_serdes then
				server:set_serdes(components[i], u32_serdes)
			end
		end

		for i = 1, ENTITY_AMOUNT do
			local entity = entities[i]
			server:set_networked(entity)
			for c = 1, COMPONENT_AMOUNT do
				world.set(entity, components[c], i + c)
				server:set_reliable(entity, components[c])
			end
		end
		server:collect_updates()
		return server, world, entities, components
	end

	local ops = ENTITY_AMOUNT * COMPONENT_AMOUNT

	-- every component on every entity changed-dirty: one value write per op
	do
		local server, world, entities, components = setup(false)
		for i = 1, ENTITY_AMOUNT do
			for c = 1, COMPONENT_AMOUNT do
				world.set(entities[i], components[c], i + c + 1)
			end
		end
		bench.once("collect_updates (all changed, no serdes)", ops, function()
			server:collect_updates()
		end)
	end

	do
		local server, world, entities, components = setup(true)
		for i = 1, ENTITY_AMOUNT do
			for c = 1, COMPONENT_AMOUNT do
				world.set(entities[i], components[c], i + c + 1)
			end
		end
		bench.once("collect_updates (all changed, serdes)", ops, function()
			server:collect_updates()
		end)
	end

	-- whole world in one snapshot: same value writes, no delta bookkeeping
	do
		local server = setup(false)
		bench.once("get_full (all visible, no serdes)", ops, function()
			server:get_full "player_1"
		end)
	end

	do
		local server = setup(true)
		bench.once("get_full (all visible, serdes)", ops, function()
			server:get_full "player_1"
		end)
	end
end

do
	bench.title "mixed collect"

	local ENTITY_AMOUNT = 2 ^ 14

	local server, world = create_server()
	local players = ready_members(server, MEMBER_AMOUNT)
	local filters = create_random_filters(players, FILTER_AMOUNT)
	local component = shared_component(world)
	local entities = create_entities(world, ENTITY_AMOUNT)

	for i = 1, ENTITY_AMOUNT do
		server:set_networked(entities[i], filters[i % FILTER_AMOUNT + 1])
		server:set_reliable(entities[i], component, filters[(i + 9) % FILTER_AMOUNT + 1])
		world.set(entities[i], component, i)
	end

	server:collect_updates()

	-- every entity changed-dirty, half also entity+component filter-dirty:
	-- deltas emit added/removed groups, changed mask excludes the fresh adds
	local half = ENTITY_AMOUNT // 2
	for i = 1, half do
		server:set_networked(entities[i], filters[(i + 3) % FILTER_AMOUNT + 1])
		server:set_reliable(entities[i], component, filters[(i + 17) % FILTER_AMOUNT + 1])
	end
	for i = 1, ENTITY_AMOUNT do
		world.set(entities[i], component, i + 1)
	end
	bench.once("collect_updates (all changed, 50% filter-dirty)", ENTITY_AMOUNT, function()
		server:collect_updates()
	end)

	-- every entity both filter-dirty and changed-dirty
	for i = 1, ENTITY_AMOUNT do
		server:set_networked(entities[i], filters[(i + 5) % FILTER_AMOUNT + 1])
		server:set_reliable(entities[i], component, filters[(i + 23) % FILTER_AMOUNT + 1])
		world.set(entities[i], component, i + 2)
	end
	bench.once("collect_updates (all changed + filter-dirty)", ENTITY_AMOUNT, function()
		server:collect_updates()
	end)
end
