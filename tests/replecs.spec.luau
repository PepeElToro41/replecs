--!strict

local jecs = require "../jecs"
local replecs = require "../src"
local server_lib = require "../src/server"
local client_lib = require "../src/client"
local bitmasks = require "../src/server/bitmasks"
local filter_groups = require "../src/server/filter_group"
local cursor = require "../src/cursor"
local testlib = require "./testlib"

type Server = server_lib.Server
type SerializeGroup = server_lib.SerializeGroup
type Groups = { [string]: SerializeGroup }

local plan = testlib.plan()
local TEST, CASE = plan.TEST, plan.CASE
local expect = testlib.expect

local function create_server(): (Server, jecs.World)
	local world = jecs.world()
	local server = replecs.create_server(world)
	server:init()
	return server, world
end

-- components must be shared and named to be written on the wire
local shared_counter = 0
local function shared_component(world: jecs.World): jecs.Entity
	shared_counter += 1
	local component = world:component()
	world:add(component, replecs.shared)
	world:set(component, jecs.Name, "component_" .. shared_counter)
	return component
end

-- tag variant: no jecs.Component, so replecs treats it as presence-only
local function shared_tag(world: jecs.World): jecs.Entity
	shared_counter += 1
	local tag = world:entity()
	world:add(tag, replecs.shared)
	world:set(tag, jecs.Name, "tag_" .. shared_counter)
	return tag
end

local function ready_players(server: Server, amount: number): { any }
	local players = table.create(amount)
	for i = 1, amount do
		local player = "player_" .. i
		players[i] = player
		server:mark_player_ready(player)
	end
	-- promote activations so tests run against established active clients
	server_lib.collect_updates_groups(server)
	return players
end

local function groups_for_player(server: Server, groups: Groups, player: any): { SerializeGroup }
	local index = server.registry.client_indexes[player]
	assert(index, "player is not registered")

	local found = {}
	for _, group in groups do
		if bitmasks.test(group.bitmask, index) then
			table.insert(found, group)
		end
	end
	return found
end

local EMPTY_UPDATES: server_lib.EntityUpdates = table.freeze {}

-- nil-safe entry lookup: an entity absent from the group reads as all-empty
local function updates_of(group: SerializeGroup, entity: jecs.Entity): server_lib.EntityUpdates
	return group.updates[entity] or EMPTY_UPDATES
end

local function count_groups(groups: Groups): number
	local count = 0
	for _ in groups do
		count += 1
	end
	return count
end

local function filter_set(...: any): { [any]: boolean }
	local set = {}
	for _, player in { ... } do
		set[player] = true
	end
	return set
end

TEST("initial replication", function()
	CASE("set_networked on start adds entity and all its components to serialized groups", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component_a = shared_component(world)
		local component_b = shared_component(world)

		local entity = world:entity()
		world:set(entity, component_a, 1)
		world:set(entity, component_b, 2)

		server:set_networked(entity)
		server:set_reliable(entity, component_a)
		server:set_reliable(entity, component_b)

		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local group = player_groups[1]
		expect(group.added_entities).to.contain(entity)
		expect(#group.deleted_entities).to.equal(0)

		-- value components carry presence through the changed bucket
		local added = updates_of(group, entity).changed
		expect(added).to.exist()
		assert(added)
		expect(#added.components).to.equal(2)
		expect(added.components).to.contain(component_a)
		expect(added.components).to.contain(component_b)
	end)
end)

TEST("entity filter deltas", function()
	CASE("narrowing nil filter to a player deletes for everyone else", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local entity = world:entity()
		server:set_networked(entity)
		server_lib.collect_updates_groups(server)

		server:set_networked(entity, players[1])
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		-- player 1 already had the entity, nothing for them
		expect(#groups_for_player(server, groups, players[1])).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[2])
		expect(#lost_groups).to.equal(1)
		expect(lost_groups[1].deleted_entities).to.contain(entity)
		expect(#lost_groups[1].added_entities).to.equal(0)
	end)

	CASE("widening a player filter to nil adds for everyone else", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local entity = world:entity()
		server:set_networked(entity, players[1])
		server_lib.collect_updates_groups(server)

		server:set_networked(entity)
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)
		expect(#gained_groups[1].deleted_entities).to.equal(0)
	end)

	CASE("swapping between disjoint player filters adds and deletes the entity", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local entity = world:entity()

		server:set_networked(entity, players[1])
		server_lib.collect_updates_groups(server)

		server:set_networked(entity, players[2])
		local groups = server_lib.collect_updates_groups(server)

		-- player 2 gained the entity
		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)
		expect(#gained_groups[1].deleted_entities).to.equal(0)

		-- player 1 lost the entity
		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)
		expect(lost_groups[1].deleted_entities).to.contain(entity)
		expect(#lost_groups[1].added_entities).to.equal(0)
	end)

	CASE("overlapping set filters partition into added and removed", function()
		local server, world = create_server()
		local players = ready_players(server, 3)

		local entity = world:entity()
		server:set_networked(entity, filter_set(players[1], players[2]))
		server_lib.collect_updates_groups(server)

		server:set_networked(entity, filter_set(players[2], players[3]))
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(2)

		-- player 2 kept the entity across both filters, no deltas
		expect(#groups_for_player(server, groups, players[2])).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)
		expect(lost_groups[1].deleted_entities).to.contain(entity)

		local gained_groups = groups_for_player(server, groups, players[3])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)
	end)

	CASE("multiple changes in one cycle delta against the last flushed filter", function()
		local server, world = create_server()
		local players = ready_players(server, 3)

		local entity = world:entity()
		server:set_networked(entity, players[1])
		server_lib.collect_updates_groups(server)

		-- intermediate filter never flushed, must not replicate
		server:set_networked(entity, players[2])
		server:set_networked(entity, players[3])
		local groups = server_lib.collect_updates_groups(server)

		expect(#groups_for_player(server, groups, players[2])).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)
		expect(lost_groups[1].deleted_entities).to.contain(entity)

		local gained_groups = groups_for_player(server, groups, players[3])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)
	end)

	CASE("changing back to the flushed filter in the same cycle emits nothing", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local entity = world:entity()
		server:set_networked(entity, players[1])
		server_lib.collect_updates_groups(server)

		server:set_networked(entity, players[2])
		server:set_networked(entity, players[1])
		local groups = server_lib.collect_updates_groups(server)

		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("changing the filter before the first flush only adds the final filter", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local entity = world:entity()
		server:set_networked(entity, players[1])
		server:set_networked(entity, players[2])
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)
		expect(#gained_groups[1].deleted_entities).to.equal(0)
	end)

	CASE("stop_networked deletes for everyone who last had the entity", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local entity = world:entity()
		server:set_networked(entity, players[1])
		server_lib.collect_updates_groups(server)

		server:stop_networked(entity)
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[2])).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)
		expect(lost_groups[1].deleted_entities).to.contain(entity)
	end)
end)

TEST("component filter deltas", function()
	CASE("narrowing a nil component filter to a player removes for everyone else", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:set_reliable(entity, component, players[1])
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[2])
		expect(#lost_groups).to.equal(1)

		local lost = updates_of(lost_groups[1], entity).removed
		expect(lost).to.exist()
		expect(lost).to.contain(component)
	end)

	CASE("widening a player component filter to nil adds for everyone else", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component, players[1])
		server_lib.collect_updates_groups(server)

		server:set_reliable(entity, component)
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)

		local gained = updates_of(gained_groups[1], entity).changed
		expect(gained).to.exist()
		assert(gained)
		expect(gained.components).to.contain(component)
	end)

	CASE("swapping between disjoint player filters adds and removes the component", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component, players[1])
		server_lib.collect_updates_groups(server)

		server:set_reliable(entity, component, players[2])
		local groups = server_lib.collect_updates_groups(server)

		-- player 2 gained the component
		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)

		local gained = updates_of(gained_groups[1], entity).changed
		expect(gained).to.exist()
		assert(gained)
		expect(gained.components).to.contain(component)

		-- player 1 lost the component
		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)

		local lost = updates_of(lost_groups[1], entity).removed
		expect(lost).to.exist()
		expect(lost).to.contain(component)
	end)

	CASE("component additions are clipped to entity visibility", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity, players[1])
		server:set_reliable(entity, component, players[1])
		server_lib.collect_updates_groups(server)

		-- player 2 cannot see the entity, addition must be dropped
		server:set_reliable(entity, component, players[2])
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[2])).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)

		local lost = updates_of(lost_groups[1], entity).removed
		expect(lost).to.exist()
		expect(lost).to.contain(component)
	end)

	CASE("changing a component filter back in the same cycle emits nothing", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component, players[1])
		server_lib.collect_updates_groups(server)

		server:set_reliable(entity, component, players[2])
		server:set_reliable(entity, component, players[1])
		local groups = server_lib.collect_updates_groups(server)

		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("entity filter change with a nil component filter follows the entity deltas", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity, players[1])
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		-- component inherits entity visibility: the newcomer gets its value
		-- alongside the entity, the leaver only gets the entity deletion
		server:set_networked(entity, players[2])
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(2)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)

		local gained = updates_of(gained_groups[1], entity).changed
		expect(gained).to.exist()
		assert(gained)
		expect(gained.components).to.contain(component)
		expect(gained.values).to.contain(1)

		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)
		expect(lost_groups[1].deleted_entities).to.contain(entity)
		expect(updates_of(lost_groups[1], entity).removed).to.beNil()
	end)

	CASE("entity filter widening re-sends a component that has its own filter", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		-- component filter already includes player 2, entity filter does not
		server:set_networked(entity, players[1])
		server:set_reliable(entity, component, filter_set(players[1], players[2]))
		server_lib.collect_updates_groups(server)

		-- player 2 enters entity visibility: the entity added delta does not
		-- carry filtered components, so the component must arrive as its own delta
		server:set_networked(entity, filter_set(players[1], players[2]))
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)

		local changed = updates_of(gained_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(component)
		expect(changed.values).to.contain(1)

		-- player 1 had everything already, nothing for them
		expect(#groups_for_player(server, groups, players[1])).to.equal(0)
	end)
end)

-- a tracking storage only ever replicated to `storage.filter ∩ entity.filter`,
-- so its last_replicated snapshot must be intersected with entity visibility.
-- edit_storage_filter snapshots the raw storage filter, which is only corrected
-- by snapshot_tracking_replicated when the entity filter is edited first
local function has_added_entity(groups: { SerializeGroup }, entity: jecs.Entity): boolean
	for _, group in groups do
		if table.find(group.added_entities, entity) then
			return true
		end
	end
	return false
end

local function has_changed_component(groups: { SerializeGroup }, entity: jecs.Entity, component: jecs.Entity): boolean
	for _, group in groups do
		local changed = updates_of(group, entity).changed
		if changed and table.find(changed.components, component) then
			return true
		end
	end
	return false
end

local function has_added_component(groups: { SerializeGroup }, entity: jecs.Entity, component: jecs.Entity): boolean
	for _, group in groups do
		local added = updates_of(group, entity).added
		if added and table.find(added, component) then
			return true
		end
	end
	return false
end

local function has_removed_component(groups: { SerializeGroup }, entity: jecs.Entity, component: jecs.Entity): boolean
	for _, group in groups do
		local removed = updates_of(group, entity).removed
		if removed and table.find(removed, component) then
			return true
		end
	end
	return false
end

TEST("tracking last_replicated intersects entity visibility", function()
	CASE("component filter edited before entity widening still sends the value to the newcomer", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		-- player 2 is in the component filter but outside the entity filter, so
		-- the component was only ever replicated to player 1
		server:set_networked(entity, players[1])
		server:set_reliable(entity, component, filter_set(players[1], players[2]))
		server_lib.collect_updates_groups(server)

		-- component filter edited first: last_replicated snapshots {p1, p2}
		-- although p2 never received it, then the entity widens to p2
		server:set_reliable(entity, component, players[2])
		server:set_networked(entity, filter_set(players[1], players[2]))
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(has_added_entity(gained_groups, entity)).to.equal(true)
		expect(has_changed_component(gained_groups, entity, component)).to.equal(true)
		expect(has_removed_component(gained_groups, entity, component)).to.equal(false)

		-- player 1 left the component filter, gets the removal
		local lost_groups = groups_for_player(server, groups, players[1])
		expect(has_removed_component(lost_groups, entity, component)).to.equal(true)
	end)

	CASE("entity widening edited before the component filter sends the value to the newcomer (control)", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity, players[1])
		server:set_reliable(entity, component, filter_set(players[1], players[2]))
		server_lib.collect_updates_groups(server)

		-- same edits as above, reversed order: must produce the same output
		server:set_networked(entity, filter_set(players[1], players[2]))
		server:set_reliable(entity, component, players[2])
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(has_added_entity(gained_groups, entity)).to.equal(true)
		expect(has_changed_component(gained_groups, entity, component)).to.equal(true)
		expect(has_removed_component(gained_groups, entity, component)).to.equal(false)

		local lost_groups = groups_for_player(server, groups, players[1])
		expect(has_removed_component(lost_groups, entity, component)).to.equal(true)
	end)

	CASE("stop_reliable before entity widening does not send a removal to the newcomer", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity, players[1])
		server:set_reliable(entity, component, filter_set(players[1], players[2]))
		server_lib.collect_updates_groups(server)

		-- stop snapshots {p1, p2} as last_replicated; p2 never had the component
		server:stop_reliable(entity, component)
		server:set_networked(entity, filter_set(players[1], players[2]))
		local groups = server_lib.collect_updates_groups(server)

		-- player 2 only gains the entity, there is nothing to remove for them
		local gained_groups = groups_for_player(server, groups, players[2])
		expect(has_added_entity(gained_groups, entity)).to.equal(true)
		expect(has_removed_component(gained_groups, entity, component)).to.equal(false)
		expect(has_changed_component(gained_groups, entity, component)).to.equal(false)

		-- player 1 had the component, gets the removal
		local lost_groups = groups_for_player(server, groups, players[1])
		expect(has_removed_component(lost_groups, entity, component)).to.equal(true)
	end)

	CASE("component filter narrowed and re-widened before entity widening sends the value once", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity, players[1])
		server:set_reliable(entity, component, filter_set(players[1], players[2]))
		server_lib.collect_updates_groups(server)

		-- filter ends up where it started, only the entity widening is real
		server:set_reliable(entity, component, players[1])
		server:set_reliable(entity, component, filter_set(players[1], players[2]))
		server:set_networked(entity, filter_set(players[1], players[2]))
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(has_added_entity(gained_groups, entity)).to.equal(true)
		expect(has_changed_component(gained_groups, entity, component)).to.equal(true)

		-- player 1 kept everything, nothing for them
		expect(#groups_for_player(server, groups, players[1])).to.equal(0)
	end)
end)

-- a nil-filter storage inherits entity visibility, so a client entering the
-- entity filter must receive its value. added_entities only carries the entity
-- id on the wire, so the value has to come out as a component delta
TEST("nil-filter storages follow entity widening", function()
	CASE("entity widening sends a nil-filter component value to the newcomer", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity, players[1])
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:set_networked(entity, filter_set(players[1], players[2]))
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(has_added_entity(gained_groups, entity)).to.equal(true)
		expect(has_changed_component(gained_groups, entity, component)).to.equal(true)

		-- player 1 had everything already, nothing for them
		expect(#groups_for_player(server, groups, players[1])).to.equal(0)
	end)

	CASE("entity widening sends a nil-filter tag to the newcomer", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local tag = shared_tag(world)
		local entity = world:entity()
		world:add(entity, tag)

		server:set_networked(entity, players[1])
		server:set_reliable(entity, tag)
		server_lib.collect_updates_groups(server)

		server:set_networked(entity, filter_set(players[1], players[2]))
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(has_added_entity(gained_groups, entity)).to.equal(true)
		expect(has_added_component(gained_groups, entity, tag)).to.equal(true)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)
	end)

	CASE("entity widening sends a nil-filter component to the newcomer even when it changed", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity, players[1])
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		-- the changed path excludes entity_deltas.added, so the newcomer is
		-- expected to get the value through the filter-added path instead
		server:set_networked(entity, filter_set(players[1], players[2]))
		world:set(entity, component, 5)
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(has_added_entity(gained_groups, entity)).to.equal(true)
		expect(has_changed_component(gained_groups, entity, component)).to.equal(true)

		-- player 1 only gets the change
		local changed_groups = groups_for_player(server, groups, players[1])
		expect(has_changed_component(changed_groups, entity, component)).to.equal(true)
		expect(has_added_entity(changed_groups, entity)).to.equal(false)
	end)
end)

TEST("active set interactions", function()
	CASE("newly active players are excluded from entity added deltas", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local entity = world:entity()
		server:set_networked(entity, players[1])
		server_lib.collect_updates_groups(server)

		-- player 2 activates this same cycle, gets a full snapshot instead
		local late_player = "late_player"
		server:mark_player_ready(late_player)
		server:set_networked(entity, filter_set(players[1], late_player))
		local groups = server_lib.collect_updates_groups(server)

		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("newly unactive players are excluded from entity removed deltas", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local entity = world:entity()
		server:set_networked(entity, filter_set(players[1], players[2]))
		server_lib.collect_updates_groups(server)

		-- player 2 leaves the same cycle their visibility is removed
		server:remove_player(players[2])
		server:set_networked(entity, players[1])
		local groups = server_lib.collect_updates_groups(server)

		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("newly active players are excluded from component added deltas", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component, players[1])
		server_lib.collect_updates_groups(server)

		local late_player = "late_player"
		server:mark_player_ready(late_player)
		server:set_reliable(entity, component, filter_set(players[1], late_player))
		local groups = server_lib.collect_updates_groups(server)

		expect(count_groups(groups)).to.equal(0)
	end)
end)

TEST("false component values", function()
	CASE("a false reliable value is pushed as false on start", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, false)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components[1]).to.equal(component)
		expect(changed.values[1]).to.equal(false)
	end)

	CASE("a value changing to false is pushed as false", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, true)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		world:set(entity, component, false)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.values[1]).to.equal(false)
	end)

	CASE("a false pair value is pushed as false", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:set(entity, pair_id, false)

		server:set_networked(entity)
		server:set_pair(entity, pair_id)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).pair_changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.values[1]).to.equal(false)
	end)

	CASE("a false unreliable presence value is pushed as false", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, false)

		server:set_networked(entity)
		server:set_unreliable(entity, component)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.values[1]).to.equal(false)
	end)
end)

TEST("changed component interactions", function()
	CASE("fresh component filter additions are excluded from the changed group", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component, players[1])
		server_lib.collect_updates_groups(server)

		-- player 2 receives the value through the added path, not changed
		server:set_reliable(entity, component, filter_set(players[1], players[2]))
		world:set(entity, component, 5)
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(2)

		-- player 2 receives the value through the filter-added group, kept apart
		-- from player 1's changed group
		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)

		local gained = updates_of(gained_groups[1], entity).changed
		expect(gained).to.exist()
		assert(gained)
		expect(gained.components).to.contain(component)
		expect(gained.values).to.contain(5)

		local changed_groups = groups_for_player(server, groups, players[1])
		expect(#changed_groups).to.equal(1)

		local changed = updates_of(changed_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(component)
		expect(changed.values).to.contain(5)
	end)
end)

TEST("filter groups", function()
	CASE("a freed client index never reaches a group", function()
		local server, world = create_server()
		local players = ready_players(server, 3)
		local freed_index = server.registry.client_indexes[players[2]]
		server:remove_player(players[2])

		-- an unfiltered group is built from every index ever allocated
		local group = filter_groups.create(server.registry)

		local entity = world:entity()
		server:set_networked(entity, group)
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		for _, serialize_group in groups do
			expect(bitmasks.test(serialize_group.bitmask, freed_index)).to.equal(false)
		end
		expect(#groups_for_player(server, groups, players[1])).to.equal(1)
		expect(#groups_for_player(server, groups, players[3])).to.equal(1)
	end)

	CASE("the packet iterator never yields a missing player", function()
		local server, world = create_server()
		local players = ready_players(server, 3)
		server:remove_player(players[2])

		local group = filter_groups.create(server.registry)
		local entity = world:entity()
		server:set_networked(entity, group)

		local yielded = {}
		for player in server:collect_updates() do
			expect(player).to.exist()
			yielded[player] = true
		end
		expect(yielded[players[1]]).to.equal(true)
		expect(yielded[players[3]]).to.equal(true)
		expect(yielded[players[2]]).to.beNil()
	end)

	CASE("removing a player between collect and iteration errors instead of dropping members", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local entity = world:entity()
		server:set_networked(entity)

		local iterator = server:collect_updates()
		server:remove_player(players[1])

		expect(function()
			for _ in iterator do
			end
		end).to.throw()
	end)

	CASE("a group recalculated after a removal still excludes the freed index", function()
		local server, world = create_server()
		local players = ready_players(server, 3)
		local freed_index = server.registry.client_indexes[players[2]]

		local group = filter_groups.create(server.registry)
		local entity = world:entity()
		server:set_networked(entity, group)
		server_lib.collect_updates_groups(server)

		server:remove_player(players[2])
		-- recalculation rebuilds the filter from the filled base
		group:filter { [players[1]] = true, [players[3]] = true }
		server:set_networked(entity, group)
		local groups = server_lib.collect_updates_groups(server)

		for _, serialize_group in groups do
			expect(bitmasks.test(serialize_group.bitmask, freed_index)).to.equal(false)
		end
	end)

	CASE("set_networked with a filter group uses its calculated bitmask", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local group = filter_groups.create(server.registry)
		group:filter(players[1])

		local entity = world:entity()
		server:set_networked(entity, group)
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		local gained_groups = groups_for_player(server, groups, players[1])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)

		expect(#groups_for_player(server, groups, players[2])).to.equal(0)
	end)

	CASE("changing the group filter deltas like a plain filter change", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local group = filter_groups.create(server.registry)
		group:filter(players[1])

		local entity = world:entity()
		server:set_networked(entity, group)
		server_lib.collect_updates_groups(server)

		group:filter(players[2])
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)
		expect(#gained_groups[1].deleted_entities).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)
		expect(lost_groups[1].deleted_entities).to.contain(entity)
		expect(#lost_groups[1].added_entities).to.equal(0)
	end)

	CASE("changing the parent filter propagates through a derived group", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local parent_filter = filter_groups.create(server.registry)
		local child = parent_filter:derive()
		child:filter(filter_set(players[1], players[2]))

		local entity = world:entity()
		server:set_networked(entity, child)
		local groups = server_lib.collect_updates_groups(server)

		-- parent has no filter yet, child includes both players
		expect(#groups_for_player(server, groups, players[1])).to.equal(1)
		expect(#groups_for_player(server, groups, players[2])).to.equal(1)

		-- narrowing the parent intersects down into the child
		parent_filter:filter(players[1])
		groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[2])
		expect(#lost_groups).to.equal(1)
		expect(lost_groups[1].deleted_entities).to.contain(entity)
	end)

	CASE("swapping to a plain filter disconnects the old group", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local group = filter_groups.create(server.registry)
		group:filter(players[1])

		local entity = world:entity()
		server:set_networked(entity, group)
		server_lib.collect_updates_groups(server)

		server:set_networked(entity, players[1])
		server_lib.collect_updates_groups(server)

		-- the group no longer drives the entity, this must emit nothing
		group:filter(players[2])
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("a filter group on a reliable component deltas on group changes", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		local group = filter_groups.create(server.registry)
		group:filter(players[1])

		server:set_networked(entity)
		server:set_reliable(entity, component, group)
		server_lib.collect_updates_groups(server)

		group:filter(players[2])
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)

		local gained = updates_of(gained_groups[1], entity).changed
		expect(gained).to.exist()
		assert(gained)
		expect(gained.components).to.contain(component)

		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)

		local lost = updates_of(lost_groups[1], entity).removed
		expect(lost).to.exist()
		expect(lost).to.contain(component)
	end)
end)

TEST("function filters", function()
	CASE("set_networked with a predicate replicates to matching players only", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local allowed = { [players[1]] = true }
		local entity = world:entity()
		server:set_networked(entity, function(player)
			return allowed[player] == true
		end)

		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		local gained_groups = groups_for_player(server, groups, players[1])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)

		expect(#groups_for_player(server, groups, players[2])).to.equal(0)
	end)

	CASE("predicate result changes are picked up next cycle as deltas", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local allowed = { [players[1]] = true }
		local entity = world:entity()
		server:set_networked(entity, function(player)
			return allowed[player] == true
		end)
		server_lib.collect_updates_groups(server)

		allowed[players[1]] = nil
		allowed[players[2]] = true
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)
		expect(#gained_groups[1].deleted_entities).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)
		expect(lost_groups[1].deleted_entities).to.contain(entity)
		expect(#lost_groups[1].added_entities).to.equal(0)
	end)

	CASE("a steady predicate emits nothing", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local allowed = { [players[1]] = true }
		local entity = world:entity()
		server:set_networked(entity, function(player)
			return allowed[player] == true
		end)
		server_lib.collect_updates_groups(server)

		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("swapping to a plain filter detaches the predicate", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local allowed = { [players[1]] = true }
		local entity = world:entity()
		server:set_networked(entity, function(player)
			return allowed[player] == true
		end)
		server_lib.collect_updates_groups(server)

		server:set_networked(entity, players[1])
		server_lib.collect_updates_groups(server)

		-- the predicate no longer drives the entity, this must emit nothing
		allowed[players[1]] = nil
		allowed[players[2]] = true
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("a predicate on a reliable component deltas on hashmap changes", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		local allowed = { [players[1]] = true }
		server:set_networked(entity)
		server:set_reliable(entity, component, function(player)
			return allowed[player] == true
		end)
		server_lib.collect_updates_groups(server)

		allowed[players[1]] = nil
		allowed[players[2]] = true
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)

		local gained = updates_of(gained_groups[1], entity).changed
		expect(gained).to.exist()
		assert(gained)
		expect(gained.components).to.contain(component)

		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)

		local lost = updates_of(lost_groups[1], entity).removed
		expect(lost).to.exist()
		expect(lost).to.contain(component)
	end)

	CASE("a predicate picks up players registered after it was set", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local allowed = { [players[1]] = true }
		local entity = world:entity()
		server:set_networked(entity, function(player)
			return allowed[player] == true
		end)
		server_lib.collect_updates_groups(server)

		-- late player becomes active and allowed, both in the same cycle:
		-- they receive the full snapshot instead of a delta, so nothing emits
		local late_player = "late_player"
		allowed[late_player] = true
		server:mark_player_ready(late_player)
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(0)

		-- once established, dropping them from the hashmap deltas normally
		allowed[late_player] = nil
		groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		local lost_groups = groups_for_player(server, groups, late_player)
		expect(#lost_groups).to.equal(1)
		expect(lost_groups[1].deleted_entities).to.contain(entity)
	end)
end)

TEST("specific pairs", function()
	CASE("a tracked pair tag lands in the pair added bucket", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_tag(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:add(entity, pair_id)

		server:set_networked(entity)
		server:set_pair(entity, pair_id)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local added = updates_of(player_groups[1], entity).pair_added
		expect(added).to.exist()
		expect(added).to.contain(pair_id)
	end)

	CASE("a tracked pair with a value lands in the pair changed bucket", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:set(entity, pair_id, 1)

		server:set_networked(entity)
		server:set_pair(entity, pair_id)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		-- pair values carry presence through the changed bucket
		local added = updates_of(player_groups[1], entity).pair_changed
		expect(added).to.exist()
		assert(added)
		expect(added.components).to.contain(pair_id)
	end)

	CASE("a pair value change lands in the pair changed bucket", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:set(entity, pair_id, 1)

		server:set_networked(entity)
		server:set_pair(entity, pair_id)
		server_lib.collect_updates_groups(server)

		world:set(entity, pair_id, 5)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).pair_changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(pair_id)
		expect(changed.values).to.contain(5)
	end)

	CASE("removing a tracked pair replicates through the pair removed bucket", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_tag(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:add(entity, pair_id)

		server:set_networked(entity)
		server:set_pair(entity, pair_id)
		server_lib.collect_updates_groups(server)

		world:remove(entity, pair_id)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local removed = updates_of(player_groups[1], entity).pair_removed
		expect(removed).to.exist()
		expect(removed).to.contain(pair_id)
	end)

	CASE("pair additions are clipped to entity visibility", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local relation = shared_tag(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:add(entity, pair_id)

		server:set_networked(entity, players[1])
		server:set_pair(entity, pair_id, players[2])

		local groups = server_lib.collect_updates_groups(server)

		-- player 2 cannot see the entity, the pair must not reach them
		local outside_groups = groups_for_player(server, groups, players[2])
		for _, group in outside_groups do
			expect(updates_of(group, entity).pair_added).to.beNil()
		end

		-- player 1 sees the entity but not the pair
		local entity_groups = groups_for_player(server, groups, players[1])
		expect(#entity_groups).to.equal(1)
		expect(entity_groups[1].added_entities).to.contain(entity)
		expect(updates_of(entity_groups[1], entity).pair_added).to.beNil()
	end)

	CASE("two pairs of the same relation are tracked independently", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target_a = world:entity()
		local target_b = world:entity()
		local entity = world:entity()
		local pair_a = jecs.pair(relation, target_a)
		local pair_b = jecs.pair(relation, target_b)
		world:set(entity, pair_a, 1)
		world:set(entity, pair_b, 2)

		server:set_networked(entity)
		server:set_pair(entity, pair_a)
		server:set_pair(entity, pair_b)
		server_lib.collect_updates_groups(server)

		-- only pair_a changes, pair_b must stay silent
		world:set(entity, pair_a, 10)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).pair_changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(pair_a)
		expect(changed.values).to.contain(10)
		expect(#changed.components).to.equal(1)
	end)
end)

TEST("relations", function()
	CASE("existing tag targets are picked up on set_relation through full_relations", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_tag(world)
		local target_a = world:entity()
		local target_b = world:entity()
		local entity = world:entity()
		world:add(entity, jecs.pair(relation, target_a))
		world:add(entity, jecs.pair(relation, target_b))

		server:set_networked(entity)
		server:set_relation(entity, relation)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local full = updates_of(player_groups[1], entity).full_relations
		expect(full).to.exist()
		assert(full)

		local targets = full.tags[relation]
		expect(targets).to.exist()
		assert(targets)
		expect(targets).to.contain(target_a)
		expect(targets).to.contain(target_b)
	end)

	CASE("existing component targets carry their values in full_relations", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		world:set(entity, jecs.pair(relation, target), "a")

		server:set_networked(entity)
		server:set_relation(entity, relation)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local full = updates_of(player_groups[1], entity).full_relations
		expect(full).to.exist()
		assert(full)

		local relation_full = full.components[relation]
		expect(relation_full).to.exist()
		assert(relation_full)
		expect(relation_full.targets).to.contain(target)
		expect(relation_full.values).to.contain "a"
	end)

	CASE("future tag targets land in the changed_relations added bucket", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_tag(world)
		local target_a = world:entity()
		local entity = world:entity()
		world:add(entity, jecs.pair(relation, target_a))

		server:set_networked(entity)
		server:set_relation(entity, relation)
		server_lib.collect_updates_groups(server)

		local target_b = world:entity()
		world:add(entity, jecs.pair(relation, target_b))
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).changed_relations
		expect(changed).to.exist()
		assert(changed)

		local added = changed.added[relation]
		expect(added).to.exist()
		assert(added)
		expect(added).to.contain(target_b)
	end)

	CASE("removing a target lands in the changed_relations removed bucket", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_tag(world)
		local target_a = world:entity()
		local target_b = world:entity()
		local entity = world:entity()
		world:add(entity, jecs.pair(relation, target_a))
		world:add(entity, jecs.pair(relation, target_b))

		server:set_networked(entity)
		server:set_relation(entity, relation)
		server_lib.collect_updates_groups(server)

		world:remove(entity, jecs.pair(relation, target_a))
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).changed_relations
		expect(changed).to.exist()
		assert(changed)

		local removed = changed.removed[relation]
		expect(removed).to.exist()
		assert(removed)
		expect(removed).to.contain(target_a)
	end)

	CASE("relation component value changes land in the changed_relations changed bucket", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		world:set(entity, jecs.pair(relation, target), "a")

		server:set_networked(entity)
		server:set_relation(entity, relation)
		server_lib.collect_updates_groups(server)

		world:set(entity, jecs.pair(relation, target), "b")
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).changed_relations
		expect(changed).to.exist()
		assert(changed)

		local relation_changed = changed.changed[relation]
		expect(relation_changed).to.exist()
		assert(relation_changed)
		expect(relation_changed.targets).to.contain(target)
		expect(relation_changed.values).to.contain "b"
	end)

	CASE("narrowing a relation filter removes through removed_relations", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local relation = shared_tag(world)
		local target = world:entity()
		local entity = world:entity()
		world:add(entity, jecs.pair(relation, target))

		server:set_networked(entity)
		server:set_relation(entity, relation)
		server_lib.collect_updates_groups(server)

		server:set_relation(entity, relation, players[1])
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[2])
		expect(#lost_groups).to.equal(1)

		local lost = updates_of(lost_groups[1], entity).removed_relations
		expect(lost).to.exist()
		assert(lost)
		expect(lost).to.contain(relation)
	end)
end)

TEST("merged entity updates", function()
	CASE("a component, a pair and a relation on one entity share a single updates entry", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local pair_relation = shared_tag(world)
		local relation = shared_tag(world)
		local pair_target = world:entity()
		local relation_target = world:entity()

		local entity = world:entity()
		world:set(entity, component, 1)
		world:add(entity, jecs.pair(pair_relation, pair_target))
		world:add(entity, jecs.pair(relation, relation_target))

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server:set_pair(entity, jecs.pair(pair_relation, pair_target))
		server:set_relation(entity, relation)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local group = player_groups[1]
		local keys = 0
		for _ in group.updates do
			keys += 1
		end
		expect(keys).to.equal(1)

		local entry = group.updates[entity]
		expect(entry).to.exist()
		assert(entry)
		expect(entry.changed).to.exist()
		expect(entry.pair_added).to.exist()
		expect(entry.full_relations).to.exist()
		expect(entry.removed).to.beNil()
		expect(entry.pair_removed).to.beNil()
		expect(entry.removed_relations).to.beNil()

		-- trailer: u16 group mask, then vlq counts back to front
		server_lib.serialize_update_groups(server, groups)
		local buf = group.output.buffer
		local len = buffer.len(buf)
		local group_mask = buffer.readu16(buf, len - 2)
		-- updates bit 0, added_entities bit 1, no deleted entities
		expect(group_mask).to.equal(0b011)
		-- last vlq before the mask is the added entity count (single byte, < 128)
		expect(buffer.readu8(buf, len - 3) - 128).to.equal(1)
	end)
end)

TEST("once tracking", function()
	CASE("initial value replicates, later changes do not", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_once(entity, component)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local added = updates_of(player_groups[1], entity).changed
		expect(added).to.exist()
		assert(added)
		expect(added.components).to.contain(component)
		expect(added.values).to.contain(1)

		world:set(entity, component, 5)
		groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("removal of a once component still replicates", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_once(entity, component)
		server_lib.collect_updates_groups(server)

		world:remove(entity, component)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local removed = updates_of(player_groups[1], entity).removed
		expect(removed).to.exist()
		expect(removed).to.contain(component)
	end)

	CASE("re-adding a once component replicates the new value", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_once(entity, component)
		server_lib.collect_updates_groups(server)

		world:remove(entity, component)
		server_lib.collect_updates_groups(server)

		world:set(entity, component, 3)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(component)
		expect(changed.values).to.contain(3)
	end)

	CASE("a once component gaining visibility carries its current value", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_once(entity, component, players[1])
		server_lib.collect_updates_groups(server)

		world:set(entity, component, 9)
		server:set_once(entity, component)
		local groups = server_lib.collect_updates_groups(server)

		-- player 1 already had it, the in-place change is not tracked
		expect(#groups_for_player(server, groups, players[1])).to.equal(0)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)

		local changed = updates_of(gained_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(component)
		expect(changed.values).to.contain(9)
	end)

	CASE("once survives stop_networked and a revive", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_once(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_networked(entity)
		server_lib.collect_updates_groups(server)

		server:set_networked(entity)
		server_lib.collect_updates_groups(server)

		world:set(entity, component, 5)
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("set_reliable on a once component starts tracking changes", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_once(entity, component)
		server_lib.collect_updates_groups(server)

		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		world:set(entity, component, 5)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.values).to.contain(5)
	end)
end)

TEST("unreliable tracking", function()
	-- unreliable components never replicate as a bare addition: whenever the
	-- reliable channel has to say something about them (add, filter gain,
	-- revive) it carries the current value in the changed bucket
	local function expect_value(group: SerializeGroup, entity: jecs.Entity, component: jecs.Entity, value: any)
		local changed = updates_of(group, entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(component)
		expect(changed.values).to.contain(value)

		local added = updates_of(group, entity).added
		if added then
			expect(added).never.to.contain(component)
		end
	end

	CASE("a present unreliable component lands in the changed bucket with its value on start", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_unreliable(entity, component)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		expect_value(player_groups[1], entity, component, 1)
	end)

	CASE("an absent unreliable component pushes a removal on start", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()

		server:set_networked(entity)
		server:set_unreliable(entity, component)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local group = player_groups[1]
		expect(group.added_entities).to.contain(entity)
		expect(updates_of(group, entity).added).to.beNil()
		expect(updates_of(group, entity).changed).to.beNil()
		expect(updates_of(group, entity).removed).to.contain(component)
	end)

	CASE("entity widening pushes a removal for an absent unreliable component to the newcomer", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()

		server:set_networked(entity, players[1])
		server:set_unreliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:set_networked(entity, filter_set(players[1], players[2]))
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)
		expect(updates_of(gained_groups[1], entity).removed).to.contain(component)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)
	end)

	CASE("world add replicates as a value push, later value changes do not", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()

		server:set_networked(entity)
		server:set_unreliable(entity, component)
		server_lib.collect_updates_groups(server)

		world:set(entity, component, 1)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect_value(player_groups[1], entity, component, 1)

		world:set(entity, component, 2)
		groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("world remove replicates as a removal", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_unreliable(entity, component)
		server_lib.collect_updates_groups(server)

		world:remove(entity, component)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(updates_of(player_groups[1], entity).removed).to.contain(component)
	end)

	CASE("only values and removals are pushed, never a bare addition", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_unreliable(entity, component)

		-- every collect across the whole lifecycle must leave the added
		-- bucket empty for this component
		local function expect_no_additions(groups: Groups)
			for _, group in groups do
				local added = updates_of(group, entity).added
				if added then
					expect(added).never.to.contain(component)
				end
			end
		end

		-- start: the value lands in changed
		local groups = server_lib.collect_updates_groups(server)
		expect_no_additions(groups)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect_value(player_groups[1], entity, component, 1)

		-- repeated value changes produce nothing at all
		for value = 2, 5 do
			world:set(entity, component, value)
			groups = server_lib.collect_updates_groups(server)
			expect_no_additions(groups)
			expect(count_groups(groups)).to.equal(0)
		end

		-- remove then re-add with a new value: removal, then the new value
		world:remove(entity, component)
		groups = server_lib.collect_updates_groups(server)
		expect_no_additions(groups)
		player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(updates_of(player_groups[1], entity).removed).to.contain(component)
		expect(updates_of(player_groups[1], entity).changed).to.beNil()

		world:set(entity, component, 10)
		groups = server_lib.collect_updates_groups(server)
		expect_no_additions(groups)
		player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect_value(player_groups[1], entity, component, 10)
		expect(updates_of(player_groups[1], entity).removed).to.beNil()

		-- remove + re-add inside one frame collapses to the current value
		world:remove(entity, component)
		world:set(entity, component, 11)
		groups = server_lib.collect_updates_groups(server)
		expect_no_additions(groups)
		player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect_value(player_groups[1], entity, component, 11)
		expect(updates_of(player_groups[1], entity).removed).to.beNil()

		-- filter changes while the value mutates: losers get a removal, gainers
		-- get the current value, nobody gets a bare addition
		world:set(entity, component, 12)
		server:set_unreliable(entity, component, players[1])
		groups = server_lib.collect_updates_groups(server)
		expect_no_additions(groups)
		local lost_groups = groups_for_player(server, groups, players[2])
		expect(#lost_groups).to.equal(1)
		expect(updates_of(lost_groups[1], entity).removed).to.contain(component)

		world:set(entity, component, 13)
		server:set_unreliable(entity, component)
		groups = server_lib.collect_updates_groups(server)
		expect_no_additions(groups)
		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)
		expect_value(gained_groups[1], entity, component, 13)

		-- forcing a change on an unreliable is a no-op, nothing is pushed
		world:set(entity, component, 14)
		server:force_change(entity, component)
		groups = server_lib.collect_updates_groups(server)
		expect_no_additions(groups)
		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("unreliable storages are separate from reliable ones", function()
		local server, world = create_server()
		ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_unreliable(entity, component)
		server_lib.collect_updates_groups(server)

		local networked = server.networked[entity]
		assert(networked)
		expect(networked.unreliable_storages[component]).to.exist()
		expect(networked.reliable_storages[component]).to.beNil()
	end)

	CASE("narrowing an unreliable filter removes for clients that lost it", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_unreliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:set_unreliable(entity, component, players[1])
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[2])
		expect(#lost_groups).to.equal(1)
		expect(updates_of(lost_groups[1], entity).removed).to.contain(component)
	end)

	CASE("widening an unreliable filter pushes the value for clients that gained it", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_unreliable(entity, component, players[1])
		server_lib.collect_updates_groups(server)

		server:set_unreliable(entity, component)
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)
		expect_value(gained_groups[1], entity, component, 1)
	end)

	CASE("unreliable survives stop_networked and a revive", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_unreliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_networked(entity)
		server_lib.collect_updates_groups(server)

		server:set_networked(entity)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(player_groups[1].added_entities).to.contain(entity)
		expect_value(player_groups[1], entity, component, 1)
	end)
end)

TEST("unreliable pairs", function()
	CASE("a present unreliable pair component lands in the changed bucket with its value on start", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:set(entity, pair_id, 1)

		server:set_networked(entity)
		server:set_unreliable_pair(entity, pair_id)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local group = player_groups[1]
		local changed = updates_of(group, entity).pair_changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(pair_id)
		expect(changed.values).to.contain(1)
		-- value carried, never a bare addition
		expect(updates_of(group, entity).pair_added).to.beNil()
	end)

	CASE("tracking a pair tag unreliably errors", function()
		local server, world = create_server()
		ready_players(server, 1)

		local relation = shared_tag(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:add(entity, pair_id)

		server:set_networked(entity)
		expect(function()
			server:set_unreliable_pair(entity, pair_id)
		end).to.throw()
	end)

	CASE("tracking a tag unreliably errors", function()
		local server, world = create_server()
		ready_players(server, 1)

		local tag = shared_tag(world)
		local entity = world:entity()
		world:add(entity, tag)

		server:set_networked(entity)
		expect(function()
			server:set_unreliable(entity, tag)
		end).to.throw()
	end)

	CASE("a pair with a tag relation and a component target is tracked as a component", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_tag(world)
		local target = shared_component(world)
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:set(entity, pair_id, 1)

		server:set_networked(entity)
		server:set_unreliable_pair(entity, pair_id)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).pair_changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(pair_id)
		expect(changed.values).to.contain(1)
	end)

	CASE("an absent unreliable pair pushes a removal on start", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)

		server:set_networked(entity)
		server:set_unreliable_pair(entity, pair_id)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local group = player_groups[1]
		expect(group.added_entities).to.contain(entity)
		expect(updates_of(group, entity).pair_added).to.beNil()
		expect(updates_of(group, entity).pair_changed).to.beNil()
		expect(updates_of(group, entity).pair_removed).to.contain(pair_id)
	end)

	CASE("entity widening pushes a removal for an absent unreliable pair to the newcomer", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)

		server:set_networked(entity, players[1])
		server:set_unreliable_pair(entity, pair_id)
		server_lib.collect_updates_groups(server)

		server:set_networked(entity, filter_set(players[1], players[2]))
		local groups = server_lib.collect_updates_groups(server)

		local gained_groups = groups_for_player(server, groups, players[2])
		expect(#gained_groups).to.equal(1)
		expect(gained_groups[1].added_entities).to.contain(entity)
		expect(updates_of(gained_groups[1], entity).pair_removed).to.contain(pair_id)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)
	end)

	CASE("world add replicates as a value push, later value changes do not", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)

		server:set_networked(entity)
		server:set_unreliable_pair(entity, pair_id)
		server_lib.collect_updates_groups(server)

		world:set(entity, pair_id, 1)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		local changed = updates_of(player_groups[1], entity).pair_changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(pair_id)
		expect(changed.values).to.contain(1)
		expect(updates_of(player_groups[1], entity).pair_added).to.beNil()

		world:set(entity, pair_id, 2)
		groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(0)
	end)

	CASE("world remove replicates as a removal", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:set(entity, pair_id, 1)

		server:set_networked(entity)
		server:set_unreliable_pair(entity, pair_id)
		server_lib.collect_updates_groups(server)

		world:remove(entity, pair_id)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(updates_of(player_groups[1], entity).pair_removed).to.contain(pair_id)
	end)

	CASE("unreliable pair storages are separate from pair storages", function()
		local server, world = create_server()
		ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:set(entity, pair_id, 1)

		server:set_networked(entity)
		server:set_unreliable_pair(entity, pair_id)
		server_lib.collect_updates_groups(server)

		local networked = server.networked[entity]
		assert(networked)
		expect(networked.unreliable_pair_storages[pair_id]).to.exist()
		expect(networked.pair_storages[pair_id]).to.beNil()
	end)

	CASE("two unreliable pairs of the same relation are tracked independently", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target_a = world:entity()
		local target_b = world:entity()
		local entity = world:entity()
		local pair_a = jecs.pair(relation, target_a)
		local pair_b = jecs.pair(relation, target_b)
		world:set(entity, pair_a, 1)
		world:set(entity, pair_b, 1)

		server:set_networked(entity)
		server:set_unreliable_pair(entity, pair_a)
		server:set_unreliable_pair(entity, pair_b)
		server_lib.collect_updates_groups(server)

		world:remove(entity, pair_a)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local removed = updates_of(player_groups[1], entity).pair_removed
		expect(removed).to.exist()
		assert(removed)
		expect(removed).to.contain(pair_a)
		expect(#removed).to.equal(1)
	end)

	CASE("narrowing an unreliable pair filter removes for clients that lost it", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:set(entity, pair_id, 1)

		server:set_networked(entity)
		server:set_unreliable_pair(entity, pair_id)
		server_lib.collect_updates_groups(server)

		server:set_unreliable_pair(entity, pair_id, players[1])
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[1])).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[2])
		expect(#lost_groups).to.equal(1)
		expect(updates_of(lost_groups[1], entity).pair_removed).to.contain(pair_id)
	end)

	CASE("unreliable pair survives stop_networked and a revive", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:set(entity, pair_id, 1)

		server:set_networked(entity)
		server:set_unreliable_pair(entity, pair_id)
		server_lib.collect_updates_groups(server)

		server:stop_networked(entity)
		server_lib.collect_updates_groups(server)

		server:set_networked(entity)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(player_groups[1].added_entities).to.contain(entity)

		local changed = updates_of(player_groups[1], entity).pair_changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(pair_id)
		expect(changed.values).to.contain(1)
	end)
end)

TEST("force_change", function()
	CASE("resends a once value", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_once(entity, component)
		server_lib.collect_updates_groups(server)

		world:set(entity, component, 7)
		server_lib.collect_updates_groups(server)

		server:force_change(entity, component)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(component)
		expect(changed.values).to.contain(7)
	end)

	CASE("resends an unchanged reliable value", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, { x = 1 })

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:force_change(entity, component)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(component)
	end)

	CASE("is a no-op for untracked components and dead entities", function()
		local server, world = create_server()
		ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server_lib.collect_updates_groups(server)

		server:force_change(entity, component)
		expect(count_groups(server_lib.collect_updates_groups(server))).to.equal(0)

		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)
		server:stop_networked(entity)
		server_lib.collect_updates_groups(server)

		server:force_change(entity, component)
		expect(count_groups(server_lib.collect_updates_groups(server))).to.equal(0)
	end)
end)

-- packets end with a vlq count (entities for get_full, inner packets for
-- collect_entity) followed by the packet type byte; skip the type and read
-- the count back from the tail
local function full_entity_count(buf: buffer): number
	local c = cursor.from(buf)
	cursor.readu8(c)
	return cursor.read_vlq(c)
end

-- fixed_serdes is declared further down; a serdes here only needs identity
local function identity_serdes(): replecs.Serdes
	return {
		bytespan = 1,
		serialize = function(_value)
			return buffer.create(1)
		end,
		deserialize = function(_buf)
			return nil
		end,
	}
end

TEST("registry force registration", function()
	CASE("a filter naming an unknown player registers it and the bit holds once ready", function()
		local server, world = create_server()
		local players = ready_players(server, 1)
		local late = "late_player"

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component, filter_set(late))
		server_lib.collect_updates_groups(server)

		expect(server.registry.client_indexes[late]).to.be.ok()
		expect(server:is_player_ready(late)).to.equal(false)

		-- activation hands the late player a snapshot; the early filter bit
		-- decides what the snapshot holds
		server:mark_player_ready(late)
		server_lib.collect_updates_groups(server)
		local _, late_variants = server:get_full(late)
		expect(#late_variants).to.equal(1)
		local _, early_variants = server:get_full(players[1])
		expect(#early_variants).to.equal(0)
	end)

	CASE("an alias resolves to its player instead of registering itself", function()
		local server, world = create_server()
		local players = ready_players(server, 2)
		server:add_player_alias(players[2], 42)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component, filter_set(42))
		local groups = server_lib.collect_updates_groups(server)

		expect(server.registry.client_indexes[42]).never.to.be.ok()
		expect(has_changed_component(groups_for_player(server, groups, players[2]), entity, component)).to.equal(true)
		expect(has_changed_component(groups_for_player(server, groups, players[1]), entity, component)).to.equal(false)
	end)

	CASE("an alias of an unknown player force-registers the player, not the alias", function()
		local server = create_server()
		server:add_player_alias("someone", "nickname")

		local bitmask = server.registry:create_bitmask_from_member "nickname"
		local index = server.registry.client_indexes["someone"]
		expect(index).to.be.ok()
		expect(server.registry.client_indexes["nickname"]).never.to.be.ok()
		expect(bitmasks.test(bitmask, index)).to.equal(true)
	end)

	CASE("removing a player drops its aliases and removing an alias stops resolution", function()
		local server = create_server()
		local players = ready_players(server, 1)
		server:add_player_alias(players[1], "a")
		server:add_player_alias(players[1], "b")

		server:remove_player_alias "a"
		expect(server.registry.client_aliases["a"]).never.to.be.ok()
		expect(server.registry.client_aliases["b"]).to.equal(players[1])

		server:remove_player(players[1])
		expect(server.registry.client_aliases["b"]).never.to.be.ok()
	end)

	CASE("bitmasks are sized by the client cap and registration stops at it", function()
		local world = jecs.world()
		local server = server_lib.create(world, replecs :: any, 40)
		server:init()

		-- 40 bits round up to two u32 entries
		expect(server.bitmask_size).to.equal(8)
		expect(buffer.len(server.client_active_bitmask)).to.equal(8)
		expect(buffer.len(server.registry:create_bitmask_from_member "p")).to.equal(8)

		for i = 2, 40 do
			server:register_player("p" .. i)
		end
		expect(server.registry.client_count).to.equal(40)
		expect(function()
			server:register_player "one too many"
		end).to.throw()

		-- freeing a slot lets a new player in
		server:remove_player "p2"
		server:register_player "p41"
		expect(server.registry.client_indexes["p41"]).to.be.ok()
	end)

	CASE("a member bitmask for an unknown player registers it", function()
		local server = create_server()
		local index_before = server.registry.client_next_index

		local bitmask = server.registry:create_bitmask_from_member "someone"
		local index = server.registry.client_indexes["someone"]
		expect(index).to.equal(index_before)
		expect(bitmasks.test(bitmask, index)).to.equal(true)
	end)
end)

TEST("declarative components", function()
	CASE("replecs.networked and pair(replecs.reliable, C) drive tracking through world hooks", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		world:add(entity, replecs.networked)
		world:add(entity, jecs.pair(replecs.reliable, component))

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(has_added_entity(player_groups, entity)).to.equal(true)
		expect(has_changed_component(player_groups, entity, component)).to.equal(true)

		world:remove(entity, jecs.pair(replecs.reliable, component))
		groups = server_lib.collect_updates_groups(server)
		player_groups = groups_for_player(server, groups, players[1])
		expect(has_removed_component(player_groups, entity, component)).to.equal(true)

		world:remove(entity, replecs.networked)
		groups = server_lib.collect_updates_groups(server)
		player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(player_groups[1].deleted_entities).to.contain(entity)
	end)

	CASE("the pair value is the filter and changing it edits the storage filter", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		world:add(entity, replecs.networked)
		world:set(entity, jecs.pair(replecs.reliable, component), players[1])

		local groups = server_lib.collect_updates_groups(server)
		expect(has_changed_component(groups_for_player(server, groups, players[1]), entity, component)).to.equal(true)
		expect(has_changed_component(groups_for_player(server, groups, players[2]), entity, component)).to.equal(false)

		world:set(entity, jecs.pair(replecs.reliable, component), players[2])
		groups = server_lib.collect_updates_groups(server)
		expect(has_removed_component(groups_for_player(server, groups, players[1]), entity, component)).to.equal(true)
		expect(has_changed_component(groups_for_player(server, groups, players[2]), entity, component)).to.equal(true)
	end)

	CASE("deleting a networked entity from the world replicates the deletion", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local entity = world:entity()
		server:set_networked(entity)
		server_lib.collect_updates_groups(server)

		expect(world:has(entity, replecs.__alive_tracking__)).to.equal(true)
		world:delete(entity)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(player_groups[1].deleted_entities).to.contain(entity)
		expect(server.networked[entity]).never.to.be.ok()
	end)

	CASE("set_global and replecs.serdes feed entity and component serialization", function()
		local server, world = create_server()

		local component = shared_component(world)
		local serdes = identity_serdes()
		world:set(component, replecs.serdes, serdes)
		expect(server.component_serialization[component].serdes).to.equal(serdes)
		world:remove(component, replecs.serdes)
		expect(server.component_serialization[component]).never.to.be.ok()

		local entity = world:entity()
		server:set_global(entity, 3)
		expect(server.entity_serialization[entity].global_id).to.equal(3)
		server:remove_global(entity)
		expect(server.entity_serialization[entity]).never.to.be.ok()
	end)

	CASE("state tagged before init is discovered", function()
		local world = jecs.world()
		local server = replecs.create_server(world)

		local component = shared_component(world)
		local other = shared_component(world)
		local serdes = identity_serdes()
		world:set(component, replecs.serdes, serdes)

		local entity = world:entity()
		world:set(entity, component, 1)
		world:set(entity, other, 2)
		server:set_global(entity, 5)
		world:add(entity, replecs.networked)
		world:add(entity, jecs.pair(replecs.reliable, component))
		world:add(entity, jecs.pair(replecs.unreliable, other))

		server:init()
		local players = ready_players(server, 1)

		expect(server.component_serialization[component].serdes).to.equal(serdes)
		expect(server.entity_serialization[entity].global_id).to.equal(5)
		expect(world:has(entity, replecs.__alive_tracking__)).to.equal(true)

		-- globals are addressed by id, so the entity itself is not announced
		local networked = server.networked[entity]
		expect(networked).to.be.ok()
		assert(networked)
		expect(networked.reliable_storages[component]).to.be.ok()
		expect(networked.unreliable_storages[other]).to.be.ok()
		expect(#players).to.equal(1)
	end)
end)

TEST("get_full", function()
	CASE("snapshots every visible entity with its values", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local tag = shared_tag(world)

		local entity_a = world:entity()
		local entity_b = world:entity()
		world:set(entity_a, component, { x = 1 })
		world:add(entity_a, tag)
		world:set(entity_b, component, { x = 2 })

		server:set_networked(entity_a)
		server:set_reliable(entity_a, component)
		server:set_reliable(entity_a, tag)
		server:set_networked(entity_b)
		server:set_reliable(entity_b, component)
		server_lib.collect_updates_groups(server)

		local output, variants = server:get_full(players[1])
		expect(full_entity_count(output)).to.equal(2)
		-- both table values travel as variants
		expect(#variants).to.equal(2)
	end)

	CASE("uses the latest filter, skips dead entities and untracked components", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)

		local visible = world:entity()
		local hidden = world:entity()
		local dead = world:entity()
		world:set(visible, component, { x = 1 })
		world:set(hidden, component, { x = 2 })
		world:set(dead, component, { x = 3 })

		server:set_networked(visible)
		server:set_reliable(visible, component)
		server:set_networked(hidden, players[2])
		server:set_reliable(hidden, component)
		server:set_networked(dead)
		server:set_reliable(dead, component)
		server_lib.collect_updates_groups(server)

		server:stop_networked(dead)
		-- filter change not yet collected still counts: player 1 sees it now
		server:set_networked(hidden, players[1])

		local output, variants = server:get_full(players[1])
		expect(full_entity_count(output)).to.equal(2)
		expect(#variants).to.equal(2)

		local output_2, variants_2 = server:get_full(players[2])
		expect(full_entity_count(output_2)).to.equal(1)
		expect(#variants_2).to.equal(1)
	end)

	CASE("unreliable components and pairs carry their value", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		world:set(entity, component, { x = 1 })
		world:set(entity, jecs.pair(relation, target), { y = 2 })

		server:set_networked(entity)
		server:set_unreliable(entity, component)
		server:set_unreliable_pair(entity, jecs.pair(relation, target))
		server_lib.collect_updates_groups(server)

		local output, variants = server:get_full(players[1])
		expect(full_entity_count(output)).to.equal(1)
		expect(#variants).to.equal(2)
	end)

	CASE("component filters clip per player", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, { x = 1 })

		server:set_networked(entity)
		server:set_reliable(entity, component, players[1])
		server_lib.collect_updates_groups(server)

		local _, variants_1 = server:get_full(players[1])
		expect(#variants_1).to.equal(1)

		local output_2, variants_2 = server:get_full(players[2])
		expect(full_entity_count(output_2)).to.equal(1)
		expect(#variants_2).to.equal(0)
	end)
end)

type EntityGroup = server_lib.EntitySerializeGroup

local function entity_groups_for_player(server: Server, groups: { [string]: EntityGroup }, player: any): { EntityGroup }
	local index = server.registry.client_indexes[player]
	assert(index, "player is not registered")

	local found = {}
	for _, group in groups do
		if bitmasks.test(group.bitmask, index) then
			table.insert(found, group)
		end
	end
	return found
end

local function count_entity_groups(groups: { [string]: EntityGroup }): number
	local total = 0
	for _ in groups do
		total += 1
	end
	return total
end

local function group_has(list: { any }, member: any): boolean
	return table.find(list, member) ~= nil
end

TEST("collect_entity", function()
	CASE("one group holds every member when nothing is filtered", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local tag = shared_tag(world)
		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		world:set(entity, component, { x = 1 })
		world:add(entity, tag)
		world:set(entity, jecs.pair(relation, target), { y = 2 })

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server:set_reliable(entity, tag)
		server:set_pair(entity, jecs.pair(relation, target))
		server:set_relation(entity, relation)
		server_lib.collect_updates_groups(server)

		local groups = server_lib.collect_entity_groups(server, entity)
		expect(count_entity_groups(groups)).to.equal(1)

		for _, player in players do
			local found = entity_groups_for_player(server, groups, player)
			expect(#found).to.equal(1)
			local group = found[1]
			expect(group_has(group.components, component)).to.equal(true)
			expect(group_has(group.tags, tag)).to.equal(true)
			expect(group_has(group.pair_components, jecs.pair(relation, target))).to.equal(true)
			expect(group_has(group.relation_components, relation)).to.equal(true)
		end
	end)

	CASE("respects the entity filter and skips inactive players", function()
		local server, world = create_server()
		local players = ready_players(server, 2)
		local late = "late_player"
		server:mark_player_ready(late)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, { x = 1 })

		server:set_networked(entity, players[2])
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		local groups = server_lib.collect_entity_groups(server, entity)
		expect(count_entity_groups(groups)).to.equal(1)
		expect(#entity_groups_for_player(server, groups, players[1])).to.equal(0)
		expect(#entity_groups_for_player(server, groups, players[2])).to.equal(1)
		expect(#entity_groups_for_player(server, groups, late)).to.equal(0)
	end)

	CASE("groups members by filter, entity group may be empty", function()
		local server, world = create_server()
		local players = ready_players(server, 3)

		local component = shared_component(world)
		local other = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, { x = 1 })
		world:set(entity, other, { y = 2 })

		server:set_networked(entity)
		server:set_reliable(entity, component, filter_set(players[1], players[2]))
		server:set_reliable(entity, other, players[1])
		server_lib.collect_updates_groups(server)

		local groups = server_lib.collect_entity_groups(server, entity)
		expect(count_entity_groups(groups)).to.equal(3)

		-- player 1: entity group + component group + other group
		local found_1 = entity_groups_for_player(server, groups, players[1])
		expect(#found_1).to.equal(3)
		-- player 2: entity group + component group
		local found_2 = entity_groups_for_player(server, groups, players[2])
		expect(#found_2).to.equal(2)
		-- player 3: entity group alone, still announces the entity
		local found_3 = entity_groups_for_player(server, groups, players[3])
		expect(#found_3).to.equal(1)
		expect(#found_3[1].components).to.equal(0)

		local function members(found: { EntityGroup }): { [any]: boolean }
			local set = {}
			for _, group in found do
				for _, member in group.components do
					set[member] = true
				end
			end
			return set
		end
		expect(members(found_1)[component]).to.equal(true)
		expect(members(found_1)[other]).to.equal(true)
		expect(members(found_2)[component]).to.equal(true)
		expect(members(found_2)[other]).never.to.be.ok()
	end)

	CASE("component filters clip to the entity filter", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, { x = 1 })

		server:set_networked(entity, players[1])
		-- filter wider than the entity: player 2 never sees the entity at all
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		local groups = server_lib.collect_entity_groups(server, entity)
		expect(count_entity_groups(groups)).to.equal(1)
		expect(#entity_groups_for_player(server, groups, players[2])).to.equal(0)
		local found = entity_groups_for_player(server, groups, players[1])
		expect(#found).to.equal(1)
		expect(group_has(found[1].components, component)).to.equal(true)
	end)

	CASE("unreliable members ride along as components", function()
		local server, world = create_server()
		ready_players(server, 1)

		local component = shared_component(world)
		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		world:set(entity, component, { x = 1 })
		world:set(entity, jecs.pair(relation, target), { y = 2 })

		server:set_networked(entity)
		server:set_unreliable(entity, component)
		server:set_unreliable_pair(entity, jecs.pair(relation, target))
		server_lib.collect_updates_groups(server)

		local groups = server_lib.collect_entity_groups(server, entity)
		local _, group = next(groups)
		assert(group)
		expect(group_has(group.components, component)).to.equal(true)
		expect(group_has(group.pair_components, jecs.pair(relation, target))).to.equal(true)
	end)

	CASE("yields nothing when no player sees the entity", function()
		local server, world = create_server()
		ready_players(server, 1)

		local entity = world:entity()
		server:set_networked(entity, filter_set())
		server_lib.collect_updates_groups(server)

		local groups = server_lib.collect_entity_groups(server, entity)
		expect(count_entity_groups(groups)).to.equal(0)
		local player = server:collect_entity(entity)()
		expect(player).never.to.be.ok()
	end)

	CASE("serializes one single-entity record per group into each member packet", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, { x = 1 })

		server:set_networked(entity)
		server:set_reliable(entity, component, players[1])
		server_lib.collect_updates_groups(server)

		local packets = {}
		for player, buf, variants in server:collect_entity(entity) do
			packets[player] = { buffer = buf, variants = variants }
		end
		-- player 1: entity group + component group; player 2: entity group
		expect(#packets[players[1]].variants).to.equal(2)
		expect(#packets[players[2]].variants).to.equal(1)
		expect(full_entity_count(packets[players[1]].buffer)).to.equal(2)
		expect(full_entity_count(packets[players[2]].buffer)).to.equal(1)
	end)
end)

-- trailing vlq of a self-contained unreliable output: entity count (< 128)
local function trailing_count(buf: buffer): number
	return buffer.readu8(buf, buffer.len(buf) - 1) - 128
end

local function fixed_serdes(size: number): replecs.Serdes
	return {
		bytespan = size,
		serialize = function(_value)
			return buffer.create(size)
		end,
		deserialize = function(_buf)
			return nil
		end,
	}
end

local function unreliable_outputs(server: Server): { { buffer: buffer, variants: { any } } }
	local groups = server_lib.collect_unreliable_groups(server)
	server_lib.serialize_unreliable_groups(server, groups)

	local outputs = {}
	for _, group in groups do
		for _, output in group.outputs do
			table.insert(outputs, output)
		end
	end
	return outputs
end

TEST("unreliable serialization split", function()
	CASE("entities past the packet budget roll back into a fresh output", function()
		local server, world = create_server()
		ready_players(server, 1)

		local component = shared_component(world)
		-- ~400 bytes each: two fit under 900, the third rolls back
		server:set_serdes(component, fixed_serdes(400))

		for _ = 1, 3 do
			local entity = world:entity()
			world:set(entity, component, 1)
			server:set_networked(entity)
			server:set_unreliable(entity, component)
		end
		server_lib.collect_updates_groups(server)

		local outputs = unreliable_outputs(server)
		expect(#outputs).to.equal(2)

		local counts = { trailing_count(outputs[1].buffer), trailing_count(outputs[2].buffer) }
		table.sort(counts)
		expect(counts[1]).to.equal(1)
		expect(counts[2]).to.equal(2)
		for _, output in outputs do
			expect(buffer.len(output.buffer) <= 902).to.equal(true)
		end
	end)

	CASE("an entity over the budget by itself goes out alone", function()
		local server, world = create_server()
		ready_players(server, 1)

		local big = shared_component(world)
		local small = shared_component(world)
		server:set_serdes(big, fixed_serdes(1200))
		server:set_serdes(small, fixed_serdes(10))

		local big_entity = world:entity()
		world:set(big_entity, big, 1)
		server:set_networked(big_entity)
		server:set_unreliable(big_entity, big)

		local small_entity = world:entity()
		world:set(small_entity, small, 1)
		server:set_networked(small_entity)
		server:set_unreliable(small_entity, small)
		server_lib.collect_updates_groups(server)

		local outputs = unreliable_outputs(server)
		expect(#outputs).to.equal(2)
		for _, output in outputs do
			expect(trailing_count(output.buffer)).to.equal(1)
		end

		local sizes = { buffer.len(outputs[1].buffer), buffer.len(outputs[2].buffer) }
		table.sort(sizes)
		expect(sizes[1] < 100).to.equal(true)
		expect(sizes[2] > 1200).to.equal(true)
	end)

	CASE("variants roll back with the buffer and stay aligned per output", function()
		local server, world = create_server()
		ready_players(server, 1)

		local padding = shared_component(world)
		local tagged = shared_component(world)
		-- padding forces every entity after the first to roll back
		server:set_serdes(padding, fixed_serdes(500))

		local values = {}
		for i = 1, 3 do
			local entity = world:entity()
			local value = { id = i }
			values[value] = true
			world:set(entity, padding, 1)
			world:set(entity, tagged, value)
			server:set_networked(entity)
			server:set_unreliable(entity, padding)
			server:set_unreliable(entity, tagged)
		end
		server_lib.collect_updates_groups(server)

		local outputs = unreliable_outputs(server)
		expect(#outputs).to.equal(3)

		local seen = {}
		for _, output in outputs do
			expect(trailing_count(output.buffer)).to.equal(1)
			-- exactly one variant per entity in this output, none duplicated by
			-- the rolled back attempt
			expect(#output.variants).to.equal(1)
			local variant = output.variants[1]
			expect(values[variant]).to.equal(true)
			expect(seen[variant]).to.beNil()
			seen[variant] = true
		end
	end)

	CASE("a serdes is invoked again for a rolled back entity", function()
		local server, world = create_server()
		ready_players(server, 1)

		local component = shared_component(world)
		local calls = 0
		server:set_serdes(component, {
			bytespan = 500,
			serialize = function(_value)
				calls += 1
				return buffer.create(500)
			end,
			deserialize = function(_buf)
				return nil
			end,
		})

		for _ = 1, 2 do
			local entity = world:entity()
			world:set(entity, component, 1)
			server:set_networked(entity)
			server:set_unreliable(entity, component)
		end
		server_lib.collect_updates_groups(server)

		local outputs = unreliable_outputs(server)
		expect(#outputs).to.equal(2)
		-- first entity once, second entity twice (attempt + re-serialize)
		expect(calls).to.equal(3)
	end)
end)

-- a dead entity keeps its live storages until collect, so stop_* in the dead
-- window must kill the storage itself, not only its postponed entry
TEST("stops during a dead window", function()
	CASE("stop_reliable after stop_networked does not survive a same-frame revive", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_networked(entity)
		server:stop_reliable(entity, component)
		server:set_networked(entity)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(updates_of(player_groups[1], entity).removed).to.contain(component)
		expect(updates_of(player_groups[1], entity).changed).to.beNil()
		expect(server.networked[entity].reliable_storages[component]).to.beNil()

		-- fully gone: later world changes produce nothing
		world:set(entity, component, 2)
		expect(count_groups(server_lib.collect_updates_groups(server))).to.equal(0)
	end)

	CASE("stop_unreliable after stop_networked releases the unreliable count on revive", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_unreliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_networked(entity)
		server:stop_unreliable(entity, component)
		server:set_networked(entity)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(updates_of(player_groups[1], entity).removed).to.contain(component)

		local networked = server.networked[entity]
		expect(networked.unreliable_storages[component]).to.beNil()
		expect(networked.unreliable_count).to.equal(0)
		expect(server.unreliable_networked[entity]).to.beNil()
		expect(#unreliable_outputs(server)).to.equal(0)
	end)

	CASE("stop_networked twice does not resurrect a storage stopped in between", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_networked(entity)
		server:stop_reliable(entity, component)
		server:stop_networked(entity)
		server:set_networked(entity)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(updates_of(player_groups[1], entity).removed).to.contain(component)
		expect(server.networked[entity].reliable_storages[component]).to.beNil()
	end)

	CASE("stop_reliable after stop_networked without a revive only deletes the entity", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_networked(entity)
		server:stop_reliable(entity, component)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(player_groups[1].deleted_entities).to.contain(entity)
		expect(updates_of(player_groups[1], entity).removed).to.beNil()
		expect(server.networked[entity]).to.beNil()

		-- the postponed entry is gone too: a later revive brings nothing back
		server:set_networked(entity)
		groups = server_lib.collect_updates_groups(server)
		player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(player_groups[1].added_entities).to.contain(entity)
		expect(updates_of(player_groups[1], entity).changed).to.beNil()
	end)
end)

-- a stopped storage keeps its hook reference until collect discards it, so a
-- world change in the dead window is not lost if the storage revives first
TEST("world changes during a dead window", function()
	CASE("stop_reliable, world change, set_reliable in one frame replicates the change", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_reliable(entity, component)
		world:set(entity, component, 5)
		server:set_reliable(entity, component)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.values[1]).to.equal(5)
		expect(updates_of(player_groups[1], entity).removed).to.beNil()
	end)

	CASE("stop_networked, world change, set_networked in one frame replicates the change", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_networked(entity)
		world:set(entity, component, 5)
		server:set_networked(entity)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(#player_groups[1].added_entities).to.equal(0)
		expect(#player_groups[1].deleted_entities).to.equal(0)

		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.values[1]).to.equal(5)
	end)

	CASE("stop_pair, world change, set_pair in one frame replicates the change", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(relation, target)
		world:set(entity, pair_id, 1)

		server:set_networked(entity)
		server:set_pair(entity, pair_id)
		server_lib.collect_updates_groups(server)

		server:stop_pair(entity, pair_id)
		world:set(entity, pair_id, 5)
		server:set_pair(entity, pair_id)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)

		local changed = updates_of(player_groups[1], entity).pair_changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.values[1]).to.equal(5)
	end)

	CASE("force_change during a dead window is kept for the revive", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_once(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_once(entity, component)
		server:force_change(entity, component)
		server:set_once(entity, component)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(updates_of(player_groups[1], entity).changed).to.exist()
	end)

	CASE("a world change on a stopped storage without a revive emits nothing", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_reliable(entity, component)
		world:set(entity, component, 5)
		local groups = server_lib.collect_updates_groups(server)

		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(updates_of(player_groups[1], entity).removed).to.contain(component)
		expect(updates_of(player_groups[1], entity).changed).to.beNil()

		-- reference dropped with the storage: nothing dirties after this
		world:set(entity, component, 6)
		expect(count_groups(server_lib.collect_updates_groups(server))).to.equal(0)
		expect(#server.dirty_networked).to.equal(0)
	end)

	CASE("a world change after a collected stop_networked does not dirty the dropped entity", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_networked(entity)
		server_lib.collect_updates_groups(server)
		expect(server.networked[entity]).to.beNil()

		world:set(entity, component, 5)
		expect(#server.dirty_networked).to.equal(0)
		expect(count_groups(server_lib.collect_updates_groups(server))).to.equal(0)

		-- postponed storages come back fresh with the current value
		server:set_networked(entity)
		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(player_groups[1].added_entities).to.contain(entity)

		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.values[1]).to.equal(5)
	end)
end)

TEST("stop tracking", function()
	CASE("stop_reliable removes for everyone who last had the component", function()
		local server, world = create_server()
		local players = ready_players(server, 2)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component, players[1])
		server_lib.collect_updates_groups(server)

		server:stop_reliable(entity, component)
		local groups = server_lib.collect_updates_groups(server)
		expect(count_groups(groups)).to.equal(1)

		expect(#groups_for_player(server, groups, players[2])).to.equal(0)

		local lost_groups = groups_for_player(server, groups, players[1])
		expect(#lost_groups).to.equal(1)
		expect(updates_of(lost_groups[1], entity).removed).to.contain(component)

		-- storage is gone: later world changes produce nothing
		world:set(entity, component, 2)
		expect(count_groups(server_lib.collect_updates_groups(server))).to.equal(0)

		-- and the full snapshot no longer carries it
		local _, variants = server:get_full(players[1])
		expect(#variants).to.equal(0)
	end)

	CASE("set_reliable before the collect revives the stopped storage with no output", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_reliable(entity, component)
		server:set_reliable(entity, component)
		expect(count_groups(server_lib.collect_updates_groups(server))).to.equal(0)

		-- still tracked: changes keep flowing
		world:set(entity, component, 5)
		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.values).to.contain(5)
	end)

	CASE("set_reliable after the collect re-adds the component", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:set_reliable(entity, component)
		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		local changed = updates_of(player_groups[1], entity).changed
		expect(changed).to.exist()
		assert(changed)
		expect(changed.components).to.contain(component)
	end)

	CASE("stop before set_networked drops the postponed component", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_reliable(entity, component)
		server:stop_reliable(entity, component)
		server:set_networked(entity)

		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(player_groups[1].added_entities).to.contain(entity)
		expect(updates_of(player_groups[1], entity).changed).to.beNil()
	end)

	CASE("stopped component does not come back with a revived entity", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local entity = world:entity()
		world:set(entity, component, 1)

		server:set_networked(entity)
		server:set_reliable(entity, component)
		server_lib.collect_updates_groups(server)

		server:stop_reliable(entity, component)
		server:stop_networked(entity)
		server_lib.collect_updates_groups(server)

		server:set_networked(entity)
		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(player_groups[1].added_entities).to.contain(entity)
		expect(updates_of(player_groups[1], entity).changed).to.beNil()
	end)

	CASE("stop_pair and stop_relation remove through their buckets", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local relation = shared_tag(world)
		local pair_relation = shared_tag(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(pair_relation, target)
		world:add(entity, jecs.pair(relation, target))
		world:add(entity, pair_id)

		server:set_networked(entity)
		server:set_relation(entity, relation)
		server:set_pair(entity, pair_id)
		server_lib.collect_updates_groups(server)

		server:stop_relation(entity, relation)
		server:stop_pair(entity, pair_id)
		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(updates_of(player_groups[1], entity).removed_relations).to.contain(relation)
		expect(updates_of(player_groups[1], entity).pair_removed).to.contain(pair_id)

		world:remove(entity, pair_id)
		expect(count_groups(server_lib.collect_updates_groups(server))).to.equal(0)
	end)

	CASE("stop_unreliable and stop_unreliable_pair remove presence", function()
		local server, world = create_server()
		local players = ready_players(server, 1)

		local component = shared_component(world)
		local pair_relation = shared_component(world)
		local target = world:entity()
		local entity = world:entity()
		local pair_id = jecs.pair(pair_relation, target)
		world:set(entity, component, 1)
		world:set(entity, pair_id, 1)

		server:set_networked(entity)
		server:set_unreliable(entity, component)
		server:set_unreliable_pair(entity, pair_id)
		server_lib.collect_updates_groups(server)

		server:stop_unreliable(entity, component)
		server:stop_unreliable_pair(entity, pair_id)
		local groups = server_lib.collect_updates_groups(server)
		local player_groups = groups_for_player(server, groups, players[1])
		expect(#player_groups).to.equal(1)
		expect(updates_of(player_groups[1], entity).removed).to.contain(component)
		expect(updates_of(player_groups[1], entity).pair_removed).to.contain(pair_id)
	end)
end)

-- ids are written the way the server's write_entity_id lays them out: payload
-- first, then the type tag; the client reads them back-to-front
local ENTITY_ID_TYPES = {
	entity = 1,
	custom_handler = 2,
	custom_id = 3,
	shared = 4,
}
local GLOBAL_ID_OFFSET = 10

local function create_client(): (replecs.Client, jecs.World)
	local world = jecs.world()
	local client = replecs.create_client(world)
	client:init()
	client:resolve_dirty()
	return client, world
end

local function id_cursor(write: (cursor.Cursor) -> ()): cursor.Cursor
	local c = cursor.new()
	write(c)
	return cursor.from(cursor.close(c))
end

TEST("client entity ids", function()
	CASE("a plain entity is created by process_entity and never by find_entity", function()
		local client = create_client()
		local server_id = 1234

		local c = id_cursor(function(w)
			cursor.writeu40(w, server_id)
			cursor.writeu8(w, ENTITY_ID_TYPES.entity)
		end)
		local found_entity, found_id = client_lib.find_entity(client, c)
		expect(found_entity).to.beNil()
		expect(found_id).to.equal(server_id)
		expect(c.offset).to.equal(0)
		expect(client:get_client_entity(server_id)).to.beNil()

		c = id_cursor(function(w)
			cursor.writeu40(w, server_id)
			cursor.writeu8(w, ENTITY_ID_TYPES.entity)
		end)
		local processed: jecs.Entity? = nil
		client_lib.process_entity(client, c, {}, function(entity)
			processed = entity
		end)
		expect(processed).to.exist()
		expect(client:get_client_entity(server_id)).to.equal(processed)
		expect(client:get_server_entity(processed :: any)).to.equal(server_id)
		expect(c.offset).to.equal(0)

		-- a second read resolves to the same entity
		c = id_cursor(function(w)
			cursor.writeu40(w, server_id)
			cursor.writeu8(w, ENTITY_ID_TYPES.entity)
		end)
		local entity, id, id_type = client_lib.read_entity_id(client, c)
		expect(entity).to.equal(processed)
		expect(id).to.equal(server_id)
		expect(id_type).to.equal(ENTITY_ID_TYPES.entity)
	end)

	CASE("a shared id resolves to the shared component", function()
		local client, world = create_client()
		local component = shared_component(world)
		client:resolve_dirty()

		local encoded = client.shared.components.members[component]
		expect(encoded).to.exist()
		local span = #client.shared.components.keys

		local c = id_cursor(function(w)
			cursor.write_span(w, encoded, span)
			cursor.writeu8(w, ENTITY_ID_TYPES.shared)
		end)
		local entity, id, id_type = client_lib.read_entity_id(client, c)
		expect(entity).to.equal(component)
		expect(id).to.beNil()
		expect(id_type).to.equal(ENTITY_ID_TYPES.shared)
		expect(c.offset).to.equal(0)
	end)

	CASE("global ids go through handle_global, including id 0", function()
		local client, world = create_client()
		local globals = { [0] = world:entity(), [5] = world:entity() }
		client:handle_global(function(id)
			return globals[id]
		end)

		for global_id, expected in globals do
			local c = id_cursor(function(w)
				cursor.writeu8(w, global_id + GLOBAL_ID_OFFSET)
			end)
			local entity, id = client_lib.read_entity_id(client, c)
			expect(entity).to.equal(expected)
			expect(id).to.beNil()
			expect(c.offset).to.equal(0)
		end
	end)

	CASE("an unknown custom_id records its handler component and buffers the entity", function()
		local client, world = create_client()
		local handler_component = shared_component(world)
		client:resolve_dirty()

		local encoded = client.shared.components.members[handler_component]
		local span = #client.shared.components.keys
		local server_id = 77

		local function write(w: cursor.Cursor)
			cursor.write_span(w, encoded, span)
			cursor.writeu40(w, server_id)
			cursor.writeu8(w, ENTITY_ID_TYPES.custom_id)
		end

		-- find_entity skips the payload and creates nothing
		local c = id_cursor(write)
		local found_entity, found_id = client_lib.find_entity(client, c)
		expect(found_entity).to.beNil()
		expect(found_id).to.equal(server_id)
		expect(c.offset).to.equal(0)

		c = id_cursor(write)
		local custom_ids = {}
		local processed: any = nil
		local active_during = false
		client_lib.process_entity(client, c, custom_ids, function(entity)
			processed = entity
			active_during = client.command_buffers_active
		end)
		expect(processed).to.equal(-server_id)
		expect(active_during).to.equal(true)
		expect(client.command_buffers_active).to.equal(false)
		expect(custom_ids[server_id]).to.equal(handler_component)
		expect(client:get_client_entity(server_id)).to.beNil()
		expect(c.offset).to.equal(0)
	end)

	CASE("an unknown custom_handler records the registered custom id", function()
		local client = create_client()
		local custom = replecs.create_custom_id("test_custom", function()
			return nil
		end)
		client:register_custom_id(custom)
		client:resolve_dirty()

		local encoded = client.shared.custom_ids.members[custom]
		expect(encoded).to.exist()
		local server_id = 91

		local c = id_cursor(function(w)
			cursor.writeu8(w, encoded)
			cursor.writeu40(w, server_id)
			cursor.writeu8(w, ENTITY_ID_TYPES.custom_handler)
		end)
		local custom_ids = {}
		local processed: any = nil
		client_lib.process_entity(client, c, custom_ids, function(entity)
			processed = entity
		end)
		expect(processed).to.equal(-server_id)
		expect(custom_ids[server_id]).to.equal(custom)
		expect(c.offset).to.equal(0)
	end)

	CASE("a known custom id entity skips its payload and is handed over directly", function()
		local client, world = create_client()
		local handler_component = shared_component(world)
		client:resolve_dirty()

		local encoded = client.shared.components.members[handler_component]
		local span = #client.shared.components.keys
		local server_id = 12
		local existing = world:entity()
		client:register_entity(existing, server_id)

		local c = id_cursor(function(w)
			cursor.write_span(w, encoded, span)
			cursor.writeu40(w, server_id)
			cursor.writeu8(w, ENTITY_ID_TYPES.custom_id)
		end)
		local custom_ids = {}
		local processed: any = nil
		client_lib.process_entity(client, c, custom_ids, function(entity)
			processed = entity
		end)
		expect(processed).to.equal(existing)
		expect((next(custom_ids))).to.beNil()
		expect(c.offset).to.equal(0)
	end)
end)

TEST("client serialization options", function()
	local serdes: replecs.Serdes = {
		serialize = function(value)
			return buffer.create(0)
		end,
		deserialize = function()
			return nil
		end,
	}
	local preprocessor = {
		serialize = function(value)
			return value
		end,
		deserialize = function(value)
			return value
		end,
	}
	local delta_serializer = {
		delta = function(_old, curr)
			return curr
		end,
		apply = function(_curr, delta)
			return delta
		end,
	}

	CASE("options share one entry per component and prune when emptied", function()
		local client, world = create_client()
		local component = shared_component(world)

		client:set_serdes(component, serdes)
		client:set_preprocessor(component, preprocessor)
		client:set_delta_serializer(component, delta_serializer)

		local options = client.component_serialization[component]
		expect(options).to.exist()
		assert(options)
		expect(options.serdes).to.equal(serdes)
		expect(options.preprocessor).to.equal(preprocessor)
		expect(options.delta_serializer).to.equal(delta_serializer)

		client:remove_serdes(component)
		client:remove_preprocessor(component)
		expect(client.component_serialization[component]).to.equal(options)
		client:remove_delta_serializer(component)
		expect(client.component_serialization[component]).to.beNil()

		-- removing from a component with no options is a no-op
		client:remove_serdes(component)
		client:remove_preprocessor(component)
		client:remove_delta_serializer(component)
		expect(client.component_serialization[component]).to.beNil()
	end)

	CASE("only serdes reach the shared lookups and flag them dirty", function()
		local client, world = create_client()
		local component = shared_component(world)
		client:resolve_dirty()

		client:set_preprocessor(component, preprocessor)
		client:set_delta_serializer(component, delta_serializer)
		expect(client.is_shared_dirty).to.equal(false)

		client:set_serdes(component, serdes)
		expect(client.is_shared_dirty).to.equal(true)
		client:resolve_dirty()
		expect(client.shared.serdes[component]).to.equal(serdes)
		expect(client:generate_handshake().serdes[world:get(component, jecs.Name) :: any]).to.exist()

		client:remove_serdes(component)
		expect(client.is_shared_dirty).to.equal(true)
		client:resolve_dirty()
		expect(client.shared.serdes[component]).to.beNil()
		-- preprocessor and delta survive the serdes removal
		expect(client.component_serialization[component]).to.exist()
	end)
end)

-- values are written the way the server's write_variant_value lays them out
-- (payload first, then the size/index bytes) and read back-to-front
TEST("client value reading", function()
	local function u8_serdes(bytespan: number?): replecs.Serdes
		return {
			bytespan = bytespan,
			serialize = function(value)
				local buf = buffer.create(1)
				buffer.writeu8(buf, 0, value)
				return buf
			end,
			deserialize = function(buf)
				return buffer.readu8(buf, 0)
			end,
		}
	end

	CASE("a plain value is a variant index, 0 is nil", function()
		local client, world = create_client()
		local component = shared_component(world)
		local variants = { "first", "second" }

		local c = id_cursor(function(w)
			cursor.write_vlq(w, 2)
		end)
		expect(client_lib.read_component_value(client, component, c, variants)).to.equal "second"
		expect(c.offset).to.equal(0)

		c = id_cursor(function(w)
			cursor.write_vlq(w, 0)
		end)
		expect(client_lib.read_component_value(client, component, c, variants)).to.beNil()
		expect(c.offset).to.equal(0)
	end)

	CASE("a fixed bytespan serdes reads exactly its bytes", function()
		local client, world = create_client()
		local component = shared_component(world)
		client:set_serdes(component, u8_serdes(1))

		local c = id_cursor(function(w)
			cursor.writeu8(w, 42)
		end)
		expect(client_lib.read_component_value(client, component, c, nil)).to.equal(42)
		expect(c.offset).to.equal(0)
	end)

	CASE("a dynamic serdes reads its length prefix", function()
		local client, world = create_client()
		local component = shared_component(world)
		client:set_serdes(component, u8_serdes(nil))

		local c = id_cursor(function(w)
			cursor.writeu8(w, 7)
			cursor.write_vlq(w, 1)
		end)
		expect(client_lib.read_component_value(client, component, c, nil)).to.equal(7)
		expect(c.offset).to.equal(0)
	end)

	CASE("a serdes with variants receives its slice of the packet variants", function()
		local client, world = create_client()
		local component = shared_component(world)
		local received: any = nil
		client:set_serdes(component, {
			includes_variants = true,
			bytespan = 1,
			serialize = function()
				return buffer.create(1)
			end,
			deserialize = function(buf, serdes_variants)
				received = serdes_variants
				return buffer.readu8(buf, 0)
			end,
		})
		local variants = { "a", "b", "c", "d" }

		-- server: size, then start + 1 (1-based index into variants), then the buffer
		local c = id_cursor(function(w)
			cursor.write_vlq(w, 2)
			cursor.write_vlq(w, 2)
			cursor.writeu8(w, 9)
		end)
		expect(client_lib.read_component_value(client, component, c, variants)).to.equal(9)
		expect(received).to.equal { "b", "c" }
		expect(c.offset).to.equal(0)

		-- no variants provided by the serializer: a lone zero
		received = "untouched"
		c = id_cursor(function(w)
			cursor.write_vlq(w, 0)
			cursor.writeu8(w, 3)
		end)
		expect(client_lib.read_component_value(client, component, c, variants)).to.equal(3)
		expect(received).to.beNil()
		expect(c.offset).to.equal(0)
	end)

	CASE("a preprocessor undoes itself after the value is read", function()
		local client, world = create_client()
		local component = shared_component(world)
		client:set_preprocessor(component, {
			serialize = function(value)
				return value * 2
			end,
			deserialize = function(value)
				return value / 2
			end,
		})

		local c = id_cursor(function(w)
			cursor.write_vlq(w, 1)
		end)
		expect(client_lib.read_component_value(client, component, c, { 10 })).to.equal(5)

		-- stacked with a serdes, the serdes output is what gets preprocessed
		client:set_serdes(component, u8_serdes(1))
		c = id_cursor(function(w)
			cursor.writeu8(w, 8)
		end)
		expect(client_lib.read_component_value(client, component, c, nil)).to.equal(4)
	end)

	CASE("pair values resolve the exact pair first, then the relation wildcard", function()
		local client, world = create_client()
		local relation = shared_component(world)
		local target_a = world:entity()
		local target_b = world:entity()
		client:set_serdes(jecs.pair(relation, jecs.Wildcard), u8_serdes(1))
		client:set_preprocessor(jecs.pair(relation, target_a), {
			serialize = function(value)
				return value
			end,
			deserialize = function(value)
				return -value
			end,
		})

		-- exact pair: the preprocessor only, so this is a plain variant index
		local c = id_cursor(function(w)
			cursor.write_vlq(w, 1)
		end)
		local pair_id, value = client_lib.read_pair_value(client, relation, target_a, c, { 6 })
		expect(pair_id).to.equal(jecs.pair(relation, target_a))
		expect(value).to.equal(-6)
		expect(c.offset).to.equal(0)

		-- other target: falls back to the wildcard serdes
		c = id_cursor(function(w)
			cursor.writeu8(w, 11)
		end)
		pair_id, value = client_lib.read_pair_value(client, relation, target_b, c, nil)
		expect(pair_id).to.equal(jecs.pair(relation, target_b))
		expect(value).to.equal(11)
		expect(c.offset).to.equal(0)
	end)
end)

-- server and client live in different worlds; shared components pair up by
-- name, so both sides create them under the same names
local function named_component(world: jecs.World, name: string, is_tag: boolean?): jecs.Entity
	local component = if is_tag then world:entity() else world:component()
	world:add(component, replecs.shared)
	world:set(component, jecs.Name, name)
	return component
end

TEST("client full entity", function()
	CASE("a full snapshot round-trips tags, components, pairs and relations", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_tag = named_component(server_world, "tag", true)
		local s_component = named_component(server_world, "component")
		local s_pair_tag = named_component(server_world, "pair_tag", true)
		local s_pair_component = named_component(server_world, "pair_component")
		local s_relation_tag = named_component(server_world, "relation_tag", true)
		local s_relation_component = named_component(server_world, "relation_component")

		local c_tag = named_component(client_world, "tag", true)
		local c_component = named_component(client_world, "component")
		local c_pair_tag = named_component(client_world, "pair_tag", true)
		local c_pair_component = named_component(client_world, "pair_component")
		local c_relation_tag = named_component(client_world, "relation_tag", true)
		local c_relation_component = named_component(client_world, "relation_component")

		local entity = server_world:entity()
		local target_a = server_world:entity()
		local target_b = server_world:entity()
		local pair_target = server_world:entity()

		server_world:add(entity, s_tag)
		server_world:set(entity, s_component, "value")
		server_world:add(entity, jecs.pair(s_pair_tag, pair_target))
		server_world:set(entity, jecs.pair(s_pair_component, pair_target), "pair value")
		server_world:add(entity, jecs.pair(s_relation_tag, target_a))
		server_world:add(entity, jecs.pair(s_relation_tag, target_b))
		server_world:set(entity, jecs.pair(s_relation_component, target_a), 1)
		server_world:set(entity, jecs.pair(s_relation_component, target_b), 2)

		server:set_networked(entity)
		server:set_reliable(entity, s_tag)
		server:set_reliable(entity, s_component)
		server:set_pair(entity, jecs.pair(s_pair_tag, pair_target))
		server:set_pair(entity, jecs.pair(s_pair_component, pair_target))
		server:set_relation(entity, s_relation_tag)
		server:set_relation(entity, s_relation_component)
		server_lib.collect_updates_groups(server)

		local buf, variants = server:get_full(players[1])
		client:apply_full(buf, variants)

		local c_entity = client:get_client_entity(entity :: any)
		expect(c_entity).to.exist()
		assert(c_entity)
		local c_target_a = client:get_client_entity(target_a :: any)
		local c_target_b = client:get_client_entity(target_b :: any)
		local c_pair_target = client:get_client_entity(pair_target :: any)
		expect(c_target_a).to.exist()
		expect(c_target_b).to.exist()
		expect(c_pair_target).to.exist()
		assert(c_target_a and c_target_b and c_pair_target)

		expect(client_world:has(c_entity, c_tag)).to.equal(true)
		expect(client_world:get(c_entity, c_component)).to.equal "value"
		expect(client_world:has(c_entity, jecs.pair(c_pair_tag, c_pair_target))).to.equal(true)
		expect(client_world:get(c_entity, jecs.pair(c_pair_component, c_pair_target))).to.equal "pair value"
		expect(client_world:has(c_entity, jecs.pair(c_relation_tag, c_target_a))).to.equal(true)
		expect(client_world:has(c_entity, jecs.pair(c_relation_tag, c_target_b))).to.equal(true)
		expect(client_world:get(c_entity, jecs.pair(c_relation_component, c_target_a))).to.equal(1)
		expect(client_world:get(c_entity, jecs.pair(c_relation_component, c_target_b))).to.equal(2)
	end)

	CASE("relation hooks fire per target and overrides skip the world write", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_relation = named_component(server_world, "relation")
		local c_relation = named_component(client_world, "relation")

		local entity = server_world:entity()
		local target = server_world:entity()
		server_world:set(entity, jecs.pair(s_relation, target), 5)
		server:set_networked(entity)
		server:set_relation(entity, s_relation)
		server_lib.collect_updates_groups(server)

		local seen = {}
		client:override("changed", jecs.pair(replecs.relation, c_relation), function(e, id, value)
			table.insert(seen, { e, id, value })
		end)

		local buf, variants = server:get_full(players[1])
		client:apply_full(buf, variants)

		local c_entity = client:get_client_entity(entity :: any) :: jecs.Entity
		local c_target = client:get_client_entity(target :: any) :: jecs.Entity
		expect(#seen).to.equal(1)
		expect(seen[1][1]).to.equal(c_entity)
		expect(seen[1][2]).to.equal(jecs.pair(c_relation, c_target))
		expect(seen[1][3]).to.equal(5)
		expect(client_world:has(c_entity, jecs.pair(c_relation, c_target))).to.equal(false)
	end)

	CASE("a pair value targeting an unresolved custom id is postponed with its cursor", function()
		local client, world = create_client()
		local relation = shared_component(world)
		local handler_component = shared_component(world)
		client:resolve_dirty()

		local span = #client.shared.components.keys
		local relation_encoded = client.shared.components.members[relation]
		local handler_encoded = client.shared.components.members[handler_component]
		local target_id = 55
		local entity = world:entity()
		client.command_buffers = {}

		-- write order: value (variant 1), vlq value size, target id (custom_id), relation
		local c = id_cursor(function(w)
			cursor.write_vlq(w, 1)
			cursor.write_vlq(w, 1)
			cursor.write_span(w, handler_encoded, span)
			cursor.writeu40(w, target_id)
			cursor.writeu8(w, ENTITY_ID_TYPES.custom_id)
			cursor.write_span(w, relation_encoded, span)
		end)
		local custom_ids = {}
		local variants = { "postponed" }
		client_lib.process_entity_pair_value(client, entity, c, custom_ids, variants)

		expect(c.offset).to.equal(0)
		expect(custom_ids[target_id]).to.equal(handler_component)
		expect(client.command_buffers_active).to.equal(false)

		local command_buffer = (client.command_buffers :: any)[entity]
		expect(command_buffer).to.exist()
		local unprocessed = command_buffer.pairs_unprocessed[relation][-target_id]
		expect(unprocessed).to.exist()
		expect(unprocessed.variants).to.equal(variants)
		-- the frozen cursor sits right after the value: reading it yields the variant
		expect(cursor.read_vlq(unprocessed.cursor)).to.equal(1)
		expect(unprocessed.cursor.offset).to.equal(0)
	end)
end)

TEST("client apply_entity", function()
	CASE("a collect_entity packet round-trips every member of the entity", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_tag = named_component(server_world, "tag", true)
		local s_component = named_component(server_world, "component")
		local s_pair_component = named_component(server_world, "pair_component")
		local s_relation_tag = named_component(server_world, "relation_tag", true)

		local c_tag = named_component(client_world, "tag", true)
		local c_component = named_component(client_world, "component")
		local c_pair_component = named_component(client_world, "pair_component")
		local c_relation_tag = named_component(client_world, "relation_tag", true)

		local entity = server_world:entity()
		local target = server_world:entity()
		local pair_target = server_world:entity()

		server_world:add(entity, s_tag)
		server_world:set(entity, s_component, "value")
		server_world:set(entity, jecs.pair(s_pair_component, pair_target), "pair value")
		server_world:add(entity, jecs.pair(s_relation_tag, target))

		server:set_networked(entity)
		server:set_reliable(entity, s_tag)
		server:set_reliable(entity, s_component)
		server:set_pair(entity, jecs.pair(s_pair_component, pair_target))
		server:set_relation(entity, s_relation_tag)
		server_lib.collect_updates_groups(server)

		local applied = 0
		for player, buf, variants in server:collect_entity(entity) do
			expect(player).to.equal(players[1])
			client:apply_entity(buf, variants)
			applied += 1
		end
		expect(applied).to.equal(1)

		local c_entity = client:get_client_entity(entity :: any)
		local c_target = client:get_client_entity(target :: any)
		local c_pair_target = client:get_client_entity(pair_target :: any)
		expect(c_entity).to.exist()
		expect(c_target).to.exist()
		expect(c_pair_target).to.exist()
		assert(c_entity and c_target and c_pair_target)

		expect(client_world:has(c_entity, c_tag)).to.equal(true)
		expect(client_world:get(c_entity, c_component)).to.equal "value"
		expect(client_world:get(c_entity, jecs.pair(c_pair_component, c_pair_target))).to.equal "pair value"
		expect(client_world:has(c_entity, jecs.pair(c_relation_tag, c_target))).to.equal(true)
	end)

	CASE("several filter groups in one packet merge into the same client entity", function()
		local server, server_world = create_server()
		local players = ready_players(server, 2)
		local client_1, client_world_1 = create_client()
		local client_2, client_world_2 = create_client()

		local s_component = named_component(server_world, "component")
		local s_other = named_component(server_world, "other")
		local s_tag = named_component(server_world, "tag", true)

		local c_component_1 = named_component(client_world_1, "component")
		local c_other_1 = named_component(client_world_1, "other")
		local c_tag_1 = named_component(client_world_1, "tag", true)
		local c_component_2 = named_component(client_world_2, "component")
		local c_other_2 = named_component(client_world_2, "other")
		local c_tag_2 = named_component(client_world_2, "tag", true)

		local entity = server_world:entity()
		server_world:set(entity, s_component, "component value")
		server_world:set(entity, s_other, "other value")
		server_world:add(entity, s_tag)

		server:set_networked(entity)
		server:set_reliable(entity, s_tag)
		server:set_reliable(entity, s_component, filter_set(players[1], players[2]))
		server:set_reliable(entity, s_other, players[1])
		server_lib.collect_updates_groups(server)

		local clients = { [players[1]] = client_1, [players[2]] = client_2 }
		for player, buf, variants in server:collect_entity(entity) do
			-- the component filter equals the entity visibility, so it shares the
			-- entity group: player 1 receives 2 inner packets, player 2 receives 1
			expect(#variants).to.equal(if player == players[1] then 2 else 1)
			clients[player]:apply_entity(buf, variants)
		end

		local c_entity_1 = client_1:get_client_entity(entity :: any)
		local c_entity_2 = client_2:get_client_entity(entity :: any)
		expect(c_entity_1).to.exist()
		expect(c_entity_2).to.exist()
		assert(c_entity_1 and c_entity_2)

		expect(client_world_1:has(c_entity_1, c_tag_1)).to.equal(true)
		expect(client_world_1:get(c_entity_1, c_component_1)).to.equal "component value"
		expect(client_world_1:get(c_entity_1, c_other_1)).to.equal "other value"

		expect(client_world_2:has(c_entity_2, c_tag_2)).to.equal(true)
		expect(client_world_2:get(c_entity_2, c_component_2)).to.equal "component value"
		expect(client_world_2:has(c_entity_2, c_other_2)).to.equal(false)
	end)
end)

local function apply_all_updates(server: Server, clients: { [any]: replecs.Client }): number
	local applied = 0
	for player, buf, variants in server:collect_updates() do
		clients[player]:apply_updates(buf, variants)
		applied += 1
	end
	return applied
end

TEST("client apply_updates", function()
	CASE("the first collect adds the entity with every tracked member", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_tag = named_component(server_world, "tag", true)
		local s_component = named_component(server_world, "component")
		local s_pair_tag = named_component(server_world, "pair_tag", true)
		local s_pair_component = named_component(server_world, "pair_component")
		local s_relation_tag = named_component(server_world, "relation_tag", true)
		local s_relation_component = named_component(server_world, "relation_component")

		local c_tag = named_component(client_world, "tag", true)
		local c_component = named_component(client_world, "component")
		local c_pair_tag = named_component(client_world, "pair_tag", true)
		local c_pair_component = named_component(client_world, "pair_component")
		local c_relation_tag = named_component(client_world, "relation_tag", true)
		local c_relation_component = named_component(client_world, "relation_component")

		local entity = server_world:entity()
		local target = server_world:entity()
		local pair_target = server_world:entity()

		server_world:add(entity, s_tag)
		server_world:set(entity, s_component, "value")
		server_world:add(entity, jecs.pair(s_pair_tag, pair_target))
		server_world:set(entity, jecs.pair(s_pair_component, pair_target), "pair value")
		server_world:add(entity, jecs.pair(s_relation_tag, target))
		server_world:set(entity, jecs.pair(s_relation_component, target), 1)

		server:set_networked(entity)
		server:set_reliable(entity, s_tag)
		server:set_reliable(entity, s_component)
		server:set_pair(entity, jecs.pair(s_pair_tag, pair_target))
		server:set_pair(entity, jecs.pair(s_pair_component, pair_target))
		server:set_relation(entity, s_relation_tag)
		server:set_relation(entity, s_relation_component)

		expect(apply_all_updates(server, { [players[1]] = client })).to.equal(1)

		local c_entity = client:get_client_entity(entity :: any)
		local c_target = client:get_client_entity(target :: any)
		local c_pair_target = client:get_client_entity(pair_target :: any)
		expect(c_entity).to.exist()
		expect(c_target).to.exist()
		expect(c_pair_target).to.exist()
		assert(c_entity and c_target and c_pair_target)

		expect(client_world:has(c_entity, c_tag)).to.equal(true)
		expect(client_world:get(c_entity, c_component)).to.equal "value"
		expect(client_world:has(c_entity, jecs.pair(c_pair_tag, c_pair_target))).to.equal(true)
		expect(client_world:get(c_entity, jecs.pair(c_pair_component, c_pair_target))).to.equal "pair value"
		expect(client_world:has(c_entity, jecs.pair(c_relation_tag, c_target))).to.equal(true)
		expect(client_world:get(c_entity, jecs.pair(c_relation_component, c_target))).to.equal(1)
	end)

	CASE("later collects apply changes, removals and relation deltas", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_tag = named_component(server_world, "tag", true)
		local s_component = named_component(server_world, "component")
		local s_pair_tag = named_component(server_world, "pair_tag", true)
		local s_relation_tag = named_component(server_world, "relation_tag", true)
		local s_relation_component = named_component(server_world, "relation_component")

		local c_tag = named_component(client_world, "tag", true)
		local c_component = named_component(client_world, "component")
		local c_pair_tag = named_component(client_world, "pair_tag", true)
		local c_relation_tag = named_component(client_world, "relation_tag", true)
		local c_relation_component = named_component(client_world, "relation_component")

		local entity = server_world:entity()
		local target_a = server_world:entity()
		local target_b = server_world:entity()
		local pair_target = server_world:entity()

		server_world:add(entity, s_tag)
		server_world:set(entity, s_component, "before")
		server_world:add(entity, jecs.pair(s_pair_tag, pair_target))
		server_world:add(entity, jecs.pair(s_relation_tag, target_a))
		server_world:set(entity, jecs.pair(s_relation_component, target_a), 1)

		server:set_networked(entity)
		server:set_reliable(entity, s_tag)
		server:set_reliable(entity, s_component)
		server:set_pair(entity, jecs.pair(s_pair_tag, pair_target))
		server:set_relation(entity, s_relation_tag)
		server:set_relation(entity, s_relation_component)

		local clients = { [players[1]] = client }
		apply_all_updates(server, clients)

		local c_entity = client:get_client_entity(entity :: any)
		local c_target_a = client:get_client_entity(target_a :: any)
		local c_pair_target = client:get_client_entity(pair_target :: any)
		assert(c_entity and c_target_a and c_pair_target)

		-- value change, tag removal, pair removal, relation target swap + value change
		server_world:set(entity, s_component, "after")
		server_world:remove(entity, s_tag)
		server_world:remove(entity, jecs.pair(s_pair_tag, pair_target))
		server_world:remove(entity, jecs.pair(s_relation_tag, target_a))
		server_world:add(entity, jecs.pair(s_relation_tag, target_b))
		server_world:set(entity, jecs.pair(s_relation_component, target_a), 2)

		expect(apply_all_updates(server, clients)).to.equal(1)

		local c_target_b = client:get_client_entity(target_b :: any)
		expect(c_target_b).to.exist()
		assert(c_target_b)

		expect(client_world:get(c_entity, c_component)).to.equal "after"
		expect(client_world:has(c_entity, c_tag)).to.equal(false)
		expect(client_world:has(c_entity, jecs.pair(c_pair_tag, c_pair_target))).to.equal(false)
		expect(client_world:has(c_entity, jecs.pair(c_relation_tag, c_target_a))).to.equal(false)
		expect(client_world:has(c_entity, jecs.pair(c_relation_tag, c_target_b))).to.equal(true)
		expect(client_world:get(c_entity, jecs.pair(c_relation_component, c_target_a))).to.equal(2)

		-- stop tracking a relation: relations removed clears every target
		server:stop_relation(entity, s_relation_component)
		apply_all_updates(server, clients)
		expect(client_world:has(c_entity, jecs.pair(c_relation_component, c_target_a))).to.equal(false)

		-- nothing dirty: no packet at all
		expect(apply_all_updates(server, clients)).to.equal(0)

		-- deletion
		server_world:delete(entity)
		expect(apply_all_updates(server, clients)).to.equal(1)
		expect(client:get_client_entity(entity :: any)).to.beNil()
		expect(client_world:contains(c_entity)).to.equal(false)
	end)

	CASE("a component tracked unreliably still arrives through the reliable channel on add", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_component = named_component(server_world, "component")
		local c_component = named_component(client_world, "component")

		local entity = server_world:entity()
		server_world:set(entity, s_component, 3)
		server:set_networked(entity)
		server:set_unreliable(entity, s_component)

		apply_all_updates(server, { [players[1]] = client })

		local c_entity = client:get_client_entity(entity :: any)
		expect(c_entity).to.exist()
		assert(c_entity)
		expect(client_world:get(c_entity, c_component)).to.equal(3)
	end)
end)

local function apply_all_unreliable(server: Server, clients: { [any]: replecs.Client }): number
	local applied = 0
	for player, buf, variants in server:collect_unreliable() do
		clients[player]:apply_unreliable(buf, variants)
		applied += 1
	end
	return applied
end

TEST("client apply_unreliable", function()
	CASE("values reach components and pairs the client already has", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_component = named_component(server_world, "component")
		local s_pair_component = named_component(server_world, "pair_component")
		local c_component = named_component(client_world, "component")
		local c_pair_component = named_component(client_world, "pair_component")

		local entity = server_world:entity()
		local pair_target = server_world:entity()
		server_world:set(entity, s_component, 1)
		server_world:set(entity, jecs.pair(s_pair_component, pair_target), "a")

		server:set_networked(entity)
		server:set_unreliable(entity, s_component)
		server:set_unreliable_pair(entity, jecs.pair(s_pair_component, pair_target))

		local clients = { [players[1]] = client }
		apply_all_updates(server, clients)

		local c_entity = client:get_client_entity(entity :: any)
		local c_pair_target = client:get_client_entity(pair_target :: any)
		assert(c_entity and c_pair_target)
		expect(client_world:get(c_entity, c_component)).to.equal(1)
		expect(client_world:get(c_entity, jecs.pair(c_pair_component, c_pair_target))).to.equal "a"

		server_world:set(entity, s_component, 2)
		server_world:set(entity, jecs.pair(s_pair_component, pair_target), "b")
		expect(apply_all_unreliable(server, clients)).to.equal(1)

		expect(client_world:get(c_entity, c_component)).to.equal(2)
		expect(client_world:get(c_entity, jecs.pair(c_pair_component, c_pair_target))).to.equal "b"
	end)

	CASE("an unknown entity is skipped without being created", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_component = named_component(server_world, "component")
		local s_other = named_component(server_world, "other")
		local c_component = named_component(client_world, "component")
		named_component(client_world, "other")

		local unknown = server_world:entity()
		server_world:set(unknown, s_component, 1)
		server:set_networked(unknown)
		server:set_unreliable(unknown, s_component)

		local known = server_world:entity()
		server_world:set(known, s_other, 1)
		server:set_networked(known)
		server:set_reliable(known, s_other)
		server:set_unreliable(known, s_component)

		-- the reliable add for `unknown` never reaches the client
		server_lib.collect_updates_groups(server)
		local buf, variants = server:get_full(players[1])
		client:apply_full(buf, variants)
		local c_known = client:get_client_entity(known :: any)
		local c_unknown = client:get_client_entity(unknown :: any)
		assert(c_known and c_unknown)
		client:unregister_entity(c_unknown)
		client_world:delete(c_unknown)

		server_world:set(unknown, s_component, 5)
		server_world:set(known, s_component, 7)
		-- the packet holds both entities: the unknown one must be skipped and
		-- the cursor still lands on the known one
		expect(apply_all_unreliable(server, { [players[1]] = client })).to.equal(1)

		expect(client:get_client_entity(unknown :: any)).to.beNil()
		-- `component` was never added on the client for `known`: no creation
		expect(client_world:has(c_known, c_component)).to.equal(false)
	end)

	CASE("a component the client lacks is not created by an unreliable value", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_component = named_component(server_world, "component")
		local s_tag = named_component(server_world, "tag", true)
		local c_component = named_component(client_world, "component")
		named_component(client_world, "tag", true)

		local entity = server_world:entity()
		server_world:add(entity, s_tag)
		server_world:set(entity, s_component, 1)
		server:set_networked(entity)
		server:set_reliable(entity, s_tag)

		local clients = { [players[1]] = client }
		apply_all_updates(server, clients)
		local c_entity = client:get_client_entity(entity :: any)
		assert(c_entity)

		-- tracked after the client already holds the entity; only the
		-- unreliable value goes out this frame
		server:set_unreliable(entity, s_component)
		expect(apply_all_unreliable(server, clients)).to.equal(1)
		expect(client_world:has(c_entity, c_component)).to.equal(false)

		-- the reliable add lands, later values apply
		apply_all_updates(server, clients)
		expect(client_world:get(c_entity, c_component)).to.equal(1)
		server_world:set(entity, s_component, 2)
		apply_all_unreliable(server, clients)
		expect(client_world:get(c_entity, c_component)).to.equal(2)
	end)
end)

TEST("client deleted hook", function()
	CASE("delete_entity fires the deleted hooks then deletes the entity", function()
		local client, client_world = create_client()
		local entity = client_world:entity()
		client:register_entity(entity, 7)

		local fired: jecs.Entity? = nil
		client:hook("deleted", entity, function(deleted)
			fired = deleted
		end)

		client_lib.delete_entity(client, entity, 7)
		expect(fired).to.equal(entity)
		expect(client_world:contains(entity)).to.equal(false)
		expect(client:get_client_entity(7)).never.to.be.ok()
		expect(client:get_server_entity(entity)).never.to.be.ok()
	end)

	CASE("an override keeps the entity alive but drops its server id", function()
		local client, client_world = create_client()
		local entity = client_world:entity()
		client:register_entity(entity, 7)

		local fired = false
		client:override("deleted", entity, function()
			fired = true
		end)

		client_lib.delete_entity(client, entity, 7)
		expect(fired).to.equal(true)
		expect(client_world:contains(entity)).to.equal(true)
		expect(client:get_client_entity(7)).never.to.be.ok()
		expect(client:get_server_entity(entity)).never.to.be.ok()
	end)

	CASE("a local world:delete unbinds the server id", function()
		local client, client_world = create_client()
		local entity = client_world:entity()
		client:register_entity(entity, 7)
		expect(client_world:has(entity, replecs.__alive_tracking__)).to.equal(true)

		client_world:delete(entity)
		expect(client:get_client_entity(7)).never.to.be.ok()
	end)
end)

TEST("client command buffer hooks", function()
	CASE("buffered components of a custom id entity go through changed hooks and overrides", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_handle = named_component(server_world, "handle")
		local s_component = named_component(server_world, "component")
		local s_tag = named_component(server_world, "tag", true)
		local c_handle = named_component(client_world, "handle")
		local c_component = named_component(client_world, "component")
		local c_tag = named_component(client_world, "tag", true)

		client_world:set(c_handle, replecs.custom_handler, function()
			return client_world:entity()
		end)

		local hooked_value: any = nil
		client:override("changed", jecs.pair(replecs.reliable, c_component), function(_, _, value)
			hooked_value = value
		end)
		local hooked_tag = false
		client:hook("changed", jecs.pair(replecs.reliable, c_tag), function()
			hooked_tag = true
		end)

		local entity = server_world:entity()
		server_world:set(entity, s_handle, 1)
		server_world:set(entity, s_component, "value")
		server_world:add(entity, s_tag)
		server:set_networked(entity)
		server:set_reliable(entity, s_handle)
		server:set_reliable(entity, s_component)
		server:set_reliable(entity, s_tag)
		server:set_custom(entity, s_handle)
		server_lib.collect_updates_groups(server)

		local buf, variants = server:get_full(players[1])
		client:apply_full(buf, variants)

		local c_entity = client:get_client_entity(entity :: any)
		expect(c_entity).to.exist()
		assert(c_entity)
		-- the override consumed the value, the world never saw it
		expect(hooked_value).to.equal "value"
		expect(client_world:has(c_entity, c_component)).to.equal(false)
		-- a plain hook observes and the world still gets the tag
		expect(hooked_tag).to.equal(true)
		expect(client_world:has(c_entity, c_tag)).to.equal(true)
	end)
end)

TEST("component encoding", function()
	CASE("server and client agree on wire ids and shared count", function()
		local server, server_world = create_server()
		local client, client_world = create_client()
		-- implicitly shared components (names...) are already counted
		local base = server:get_shared_count()
		expect(client:get_shared_count()).to.equal(base)

		local s_a = named_component(server_world, "a")
		local s_b = named_component(server_world, "b")
		local c_a = named_component(client_world, "a")
		local c_b = named_component(client_world, "b")

		expect(server:get_shared_count()).to.equal(base + 2)
		expect(client:get_shared_count()).to.equal(base + 2)

		expect(server:encode_component(s_a)).to.equal(client:encode_component(c_a))
		expect(server:encode_component(s_b)).to.equal(client:encode_component(c_b))
		expect(server:encode_component(s_a)).never.to.equal(server:encode_component(s_b))

		expect(server:decode_component(server:encode_component(s_a))).to.equal(s_a)
		expect(client:decode_component(client:encode_component(c_b))).to.equal(c_b)
		expect(server:decode_component(999)).never.to.be.ok()
	end)

	CASE("a component shared after creation is picked up by the next call", function()
		local server, world = create_server()
		local base = server:get_shared_count()

		local component = named_component(world, "late")
		expect(server:get_shared_count()).to.equal(base + 1)
		expect(server:decode_component(server:encode_component(component))).to.equal(component)
	end)

	CASE("encoding a non-shared component errors", function()
		local server, world = create_server()
		local component = world:component()
		expect(function()
			server:encode_component(component)
		end).to.throw()
	end)
end)

TEST("client apply_full", function()
	CASE("a custom id entity is created by its handler from its buffered state", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_component = named_component(server_world, "component")
		local s_tag = named_component(server_world, "tag", true)
		local c_component = named_component(client_world, "component")
		local c_tag = named_component(client_world, "tag", true)

		local s_custom = replecs.create_custom_id("custom", function()
			return nil
		end)
		local created: jecs.Entity? = nil
		local seen_id: number? = nil
		local c_custom = replecs.create_custom_id("custom", function(ctx)
			seen_id = ctx.entity_id
			expect(ctx.component(c_component)).to.equal "value"
			expect(ctx.has(c_tag)).to.equal(true)
			local entity = client_world:entity()
			created = entity
			return entity
		end)
		server:register_custom_id(s_custom)
		client:register_custom_id(c_custom)

		local entity = server_world:entity()
		server_world:set(entity, s_component, "value")
		server_world:add(entity, s_tag)
		server:set_networked(entity)
		server:set_reliable(entity, s_component)
		server:set_reliable(entity, s_tag)
		server:set_custom(entity, s_custom)
		server_lib.collect_updates_groups(server)

		local buf, variants = server:get_full(players[1])
		client:apply_full(buf, variants)

		expect(created).to.exist()
		expect(seen_id).to.equal(entity)
		expect(client:get_client_entity(entity :: any)).to.equal(created)
		expect(client:get_server_entity(created :: any)).to.equal(entity)
		expect(client_world:get(created :: any, c_component)).to.equal "value"
		expect(client_world:has(created :: any, c_tag)).to.equal(true)
		expect(client.command_buffers).to.beNil()
		expect(client.is_replicating).to.equal(false)
	end)

	CASE("a component custom handler receives the buffered component value", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_handle = named_component(server_world, "handle")
		local c_handle = named_component(client_world, "handle")

		local created: jecs.Entity? = nil
		local received: any = nil
		client_world:set(c_handle, replecs.custom_handler, function(value)
			received = value
			local entity = client_world:entity()
			created = entity
			return entity
		end)

		local entity = server_world:entity()
		server_world:set(entity, s_handle, 123)
		server:set_networked(entity)
		server:set_reliable(entity, s_handle)
		server:set_custom(entity, s_handle)
		server_lib.collect_updates_groups(server)

		local buf, variants = server:get_full(players[1])
		client:apply_full(buf, variants)

		expect(received).to.equal(123)
		expect(client:get_client_entity(entity :: any)).to.equal(created)
		expect(client_world:get(created :: any, c_handle)).to.equal(123)
	end)

	CASE("a pair value targeting a custom id entity resolves once the target does", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_relation = named_component(server_world, "relation")
		local c_relation = named_component(client_world, "relation")

		local s_custom = replecs.create_custom_id("custom", function()
			return nil
		end)
		local c_custom = replecs.create_custom_id("custom", function()
			return client_world:entity()
		end)
		server:register_custom_id(s_custom)
		client:register_custom_id(c_custom)

		local target = server_world:entity()
		server:set_networked(target)
		server:set_custom(target, s_custom)

		local entity = server_world:entity()
		server_world:set(entity, jecs.pair(s_relation, target), "pair value")
		server:set_networked(entity)
		server:set_pair(entity, jecs.pair(s_relation, target))
		server_lib.collect_updates_groups(server)

		local buf, variants = server:get_full(players[1])
		client:apply_full(buf, variants)

		local c_entity = client:get_client_entity(entity :: any)
		local c_target = client:get_client_entity(target :: any)
		expect(c_entity).to.exist()
		expect(c_target).to.exist()
		expect(client_world:get(c_entity :: any, jecs.pair(c_relation, c_target :: any))).to.equal "pair value"
	end)

	CASE("a custom id handler can resolve another custom id through its context", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client, client_world = create_client()

		local s_relation = named_component(server_world, "relation", true)
		local c_relation = named_component(client_world, "relation", true)

		local s_custom = replecs.create_custom_id("custom", function()
			return nil
		end)
		local resolved_target: jecs.Entity? = nil
		local c_custom = replecs.create_custom_id("custom", function(ctx)
			local entity = client_world:entity()
			local ctx_target = ctx.target(c_relation)
			if ctx_target then
				resolved_target = ctx_target
			end
			return entity
		end)
		server:register_custom_id(s_custom)
		client:register_custom_id(c_custom)

		local target = server_world:entity()
		server:set_networked(target)
		server:set_custom(target, s_custom)

		local entity = server_world:entity()
		server_world:add(entity, jecs.pair(s_relation, target))
		server:set_networked(entity)
		server:set_custom(entity, s_custom)
		server:set_relation(entity, s_relation)
		server_lib.collect_updates_groups(server)

		local buf, variants = server:get_full(players[1])
		client:apply_full(buf, variants)

		local c_entity = client:get_client_entity(entity :: any)
		local c_target = client:get_client_entity(target :: any)
		expect(c_entity).to.exist()
		expect(c_target).to.exist()
		expect(resolved_target).to.equal(c_target)
		expect(client_world:has(c_entity :: any, jecs.pair(c_relation, c_target :: any))).to.equal(true)
	end)

	CASE("after_replication defers callbacks until the packet is applied", function()
		local server, server_world = create_server()
		local players = ready_players(server, 1)
		local client = create_client()

		local entity = server_world:entity()
		server:set_networked(entity)
		server_lib.collect_updates_groups(server)

		local ran_during = false
		local ran_after = false
		client:added(function()
			client:after_replication(function()
				ran_after = true
				expect(client.is_replicating).to.equal(false)
			end)
			ran_during = ran_after
		end)

		local buf, variants = server:get_full(players[1])
		client:apply_full(buf, variants)

		expect(ran_during).to.equal(false)
		expect(ran_after).to.equal(true)
		expect(client:get_client_entity(entity :: any)).to.exist()
	end)
end)

local report = testlib.run(plan)
testlib.report(report)
