local replecs = require "@replecs"
local player_masking = require "@replecs/masking"
local utils = require "@replecs/utils"
local testutils = require "./utils"

local pepecs = require "@pkg/pepecs"
local testlib = require "./testlib"

type Entity<T = any> = pepecs.Entity<T>

type MemberData = {
	world: pepecs.World,
	client: replecs.Client,
	components: { pepecs.Entity },
	tags: { pepecs.Entity },
}

local plan = testlib.plan()
local expect = testlib.expect

local TEST, CASE = plan.TEST, plan.CASE
local SKIP, FOCUS = plan.SKIP, plan.FOCUS
local BEFORE_EACH, AFTER_EACH = plan.BEFORE_EACH, plan.AFTER_EACH
local CHECK = assert

TEST("bitmasking", function()
	CASE("should automatically expand", function()
		local mask = utils.bitmask.create(10)
		mask:set(5)

		expect(mask:get(5)).to.be.ok()
		mask:set(100)
		expect(mask:get(100)).to.be.ok()
		expect(mask:get(32)).never.to.be.ok()
		expect(mask:get(5)).to.be.ok()
	end)

	CASE("should get and set bits", function()
		local mask = utils.bitmask.create(100)
		mask:set(5)
		mask:set(33)
		mask:set(65)

		expect(mask:get(5)).to.be.ok()
		expect(mask:get(33)).to.be.ok()
		expect(mask:get(65)).to.be.ok()
		expect(mask:get(10)).never.to.be.ok()

		mask:clear(33)

		expect(mask:get(5)).to.be.ok()
		expect(mask:get(33)).never.to.be.ok()
		expect(mask:get(65)).to.be.ok()
	end)

	CASE("should correctly shift bits", function()
		local mask = utils.bitmask.create(100)
		mask:set(5)
		mask:set(40)
		mask:set(65)

		local left = mask:lshift(3)
		local right = mask:rshift(2)

		expect(left:get(5 + 3)).to.be.ok()
		expect(left:get(40 + 3)).to.be.ok()
		expect(left:get(65 + 3)).to.be.ok()
		expect(left:get(65)).never.to.be.ok()

		expect(right:get(5 - 2)).to.be.ok()
		expect(right:get(40 - 2)).to.be.ok()
		expect(right:get(65 - 2)).to.be.ok()
		expect(right:get(65)).never.to.be.ok()
	end)

	CASE("should correctly perform bitwise operations", function()
		local mask1 = utils.bitmask.create(100)
		local mask2 = utils.bitmask.create(100)

		mask1:set(5)
		mask1:set(10)
		mask1:set(20)
		mask1:set(40)
		mask1:set(65)

		mask2:set(10)
		mask2:set(40)
		mask2:set(50)

		local band = mask1:band(mask2)
		CHECK(band:get(5) == false)
		CHECK(band:get(10) == true)
		CHECK(band:get(20) == false)
		CHECK(band:get(40) == true)
		CHECK(band:get(50) == false)
		CHECK(band:get(65) == false)

		local bor = mask1:bor(mask2)
		CHECK(bor:get(5) == true)
		CHECK(bor:get(10) == true)
		CHECK(bor:get(20) == true)
		CHECK(bor:get(40) == true)
		CHECK(bor:get(50) == true)
		CHECK(bor:get(65) == true)
		CHECK(bor:get(100) == false)

		local bxor = mask1:bxor(mask2)
		CHECK(bxor:get(5) == true)
		CHECK(bxor:get(10) == false)
		CHECK(bxor:get(20) == true)
		CHECK(bxor:get(40) == false)
		CHECK(bxor:get(50) == true)
		CHECK(bxor:get(65) == true)
		CHECK(bxor:get(100) == false)
	end)

	CASE("should return same string, independant of buffer capacity", function()
		local small = utils.bitmask.create(32)
		local medium = utils.bitmask.create(128)
		local big = utils.bitmask.create(1024)
		local empty = utils.bitmask.create(1024)

		small:set(0)
		small:set(10)
		medium:set(0)
		medium:set(10)
		big:set(0)
		big:set(10)

		CHECK(small:tostring() == medium:tostring())
		CHECK(small:tostring() == big:tostring())
		CHECK(medium:tostring() == big:tostring())
		CHECK(empty:tostring() == "")
	end)
end)

local function register_members(masking: player_masking.MaskingController)
	local member0 = "member0"
	local member1 = "member1"
	local member2 = "member2"
	local member3 = "member3"

	masking:register_client(member0)
	masking:register_client(member1)
	masking:register_client(member2)
	masking:register_client(member3)
	return member0, member1, member2, member3
end

local function mask_hash(members: { number })
	local bitmask = utils.bitmask.create(20)
	for _, member in members do
		bitmask:set(member)
	end
	return bitmask:tostring()
end

local function active_all_members(masking: player_masking.MaskingController)
	for member in masking.client_indexes do
		masking:activate_client(member)
	end
end

TEST("mask generators", function()
	local masking: player_masking.MaskingController = nil :: any

	BEFORE_EACH(function()
		masking = player_masking.create()
	end)

	CASE("should compute an include generator", function()
		local m0, m1, m2, m3 = register_members(masking)
		local generator = masking:create_include_generator {
			[m0] = true,
			[m1] = true,
			[m2] = true,
			[m3] = true,
		}
		local check_mask = ""
		local called = 0

		generator.subscribed = function()
			called += 1
			CHECK(generator.result:tostring() == check_mask)
		end
		generator:run_subscribed()
		check_mask = mask_hash { 0 }
		masking:activate_client(m0)
		check_mask = mask_hash { 0, 3 }
		masking:activate_client(m3)
	end)

	CASE("should compute an exclude generator", function()
		local m0, m1, m2, m3 = register_members(masking)
		local generator = masking:create_exclude_generator {
			[m2] = true,
			[m1] = true,
		}

		local check_mask = ""
		local called = 0
		generator.subscribed = function()
			called += 1
			CHECK(generator.result:tostring() == check_mask)
		end
		check_mask = mask_hash { 0 }
		masking:activate_client(m0)
		check_mask = mask_hash { 0, 3 }
		masking:activate_client(m3)
		masking:activate_client(m2)
		masking:activate_client(m1)
		CHECK(called == 4)
	end)

	CASE("should destroy a generator", function()
		local m0, m1, m2, m3 = register_members(masking)

		local generator = masking:create_exclude_generator {
			[1] = true,
		}
		local called = 0
		generator.subscribed = function()
			called += 1
		end
		masking:activate_client(m0)
		generator:destroy()
		masking:activate_client(m1)
		masking:activate_client(m2)
		masking:activate_client(m3)
		CHECK(called == 1)
	end)
end)

TEST("member bitmasking", function()
	local masking: player_masking.MaskingController = nil :: any
	local world: pepecs.World = nil :: any

	BEFORE_EACH(function()
		masking = player_masking.create() :: player_masking.MaskingController
		world = pepecs.world()
	end)

	local function SANITY_CHECKS()
		-- heuristic sanity checks
		local entity_masks: { [pepecs.Entity]: boolean } = {}

		for hash, storage in masking.storages do
			local real_active_count = 0

			for entity, actives in storage.active do
				if actives.is_entity_mask then
					local lookup = masking.lookups.entities[entity]
					if lookup.storage_group ~= storage then
						error "marked mask entity does not match the lookup"
					end

					real_active_count += 1
					if entity_masks[entity] then
						error "duplicated base entity mask"
					end
					entity_masks[entity] = true
				elseif actives.component_count > 0 then
					real_active_count += 1
				end

				local real_component_count = 0
				for component_type, components in actives.components do
					for component in components do
						real_component_count += 1
					end
				end
				CHECK(real_component_count == actives.component_count)
			end
			CHECK(real_active_count == storage.active_count)
		end

		for hash, storage in masking.storages do
			for entity, components in storage.shared_with do
				for component_type, components in components do
					for component in components do
						local lookup = masking.lookups.entities[entity].filtered_components[component_type][component]
						CHECK(lookup.storage_group == storage)
					end
				end
			end
		end
	end

	local function check_entity_mask(entity: pepecs.Entity, hash: string)
		local storage = masking.storages[hash]
		local lookup = masking.lookups.entities[entity]

		CHECK(lookup ~= nil)
		CHECK(lookup.storage_group == storage)

		CHECK(storage.active[entity] ~= nil)
		CHECK((storage.active[entity].is_entity_mask :: any) ~= nil)

		for check_hash, check_storage in masking.storages do
			if hash == check_hash then
				continue
			end

			if check_storage.active[entity] then
				CHECK(check_storage.active[entity].is_entity_mask == false)
			end
		end
	end

	local function check_component_mask(entity: pepecs.Entity, component: pepecs.Entity, hash: string)
		local storage = masking.storages[hash]
		local lookup = masking.lookups.entities[entity].filtered_components[1][component]

		CHECK(lookup ~= nil)
		CHECK(lookup.storage_group == storage)

		CHECK(storage.active[entity] ~= nil)
		CHECK(storage.active[entity].components[1][component] ~= nil)

		CHECK(storage.shared_with[entity] ~= nil)
		CHECK(storage.shared_with[entity][1][component] ~= nil)

		for check_hash, check_storage in masking.storages do
			if hash == check_hash then
				continue
			end

			if check_storage.active[entity] then
				CHECK(check_storage.active[entity].components[1][component] == nil)
			end
			if check_storage.shared_with[entity] then
				CHECK(check_storage.shared_with[entity][1][component] == nil)
			end
		end
	end

	local function check_component_is_merged(entity: pepecs.Entity, component: pepecs.Entity, hash: string)
		local entity_lookup = masking.lookups.entities[entity :: any]
		if not entity_lookup then
			error "entity lookup not found"
		end

		CHECK(entity_lookup.storage_group == masking.storages[hash])

		CHECK(entity_lookup.filtered_components[1][component] == nil)
		CHECK(entity_lookup.storage_group.active[entity].components[1][component] ~= nil)
		CHECK(entity_lookup.storage_group.active[entity].is_entity_mask == true)

		for _, check_storage in masking.storages do
			if check_storage.shared_with[entity] then
				CHECK(check_storage.shared_with[entity][1][component] == nil)
			end
		end
	end

	local function check_component_is_not_active(entity: pepecs.Entity, component: pepecs.Entity)
		local entity_lookup = masking.lookups.entities[entity]
		if entity_lookup then
			CHECK(entity_lookup.filtered_components[1][component] == nil)
		end

		for hash, check_storage in masking.storages do
			if check_storage.shared_with[entity] then
				CHECK(check_storage.shared_with[entity][1][component] == nil)
			end
			for _, actives in check_storage.active do
				for check_component in actives.components[1] do
					if check_component == component then
						error("component found in active storage" .. ": " .. hash)
					end
				end
			end
		end
	end

	local function check_entity_is_not_active(entity: pepecs.Entity)
		CHECK(masking.lookups.entities[entity] == nil)

		for hash, check_storage in masking.storages do
			if check_storage.active[entity] then
				error("entity found in active storage" .. ": " .. hash)
			end
			if check_storage.shared_with[entity] then
				error("entity found in shared storage" .. ": " .. hash)
			end
			if check_storage.changes.added[entity] then
				error "entity addition found in lookup changes"
			end
			if check_storage.changes.changed[entity] then
				error "changes table for entity found in storage"
			end
		end
	end

	CASE("should use an entity filter", function()
		local member0, member1, member2 = register_members(masking)
		local entity = world.entity()
		masking:start_entity(entity, {
			[member0] = true,
			[member2] = true,
		})
		check_entity_mask(entity, "")
		active_all_members(masking)
		check_entity_mask(entity, mask_hash { 0, 2 })

		local entity2 = world.entity()
		masking:start_entity(entity2, {
			[member0] = false,
			[member2] = false,
		})
		check_entity_mask(entity2, mask_hash { 1, 3 })

		SANITY_CHECKS()
	end)
	--FOCUS()

	CASE("should change an entity filter", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		masking:start_entity(entity, {
			[member0] = true,
			[member2] = true,
		})
		check_entity_mask(entity, mask_hash { 0, 2 })
		masking:set_entity(entity, {
			[member0] = false,
			[member2] = false,
		})
		check_entity_mask(entity, mask_hash { 1, 3 })
		masking:set_entity(entity, nil)
		check_entity_mask(entity, mask_hash { 0, 1, 2, 3 })

		SANITY_CHECKS()
	end)

	CASE("should use the replicated filter with no explicit filter", function()
		local member0, member1, member2, member3 = register_members(masking)
		local entity = world.entity()
		masking:start_entity(entity, nil)
		check_entity_mask(entity, "")
		masking:activate_client(member0)
		check_entity_mask(entity, mask_hash { 0 })
		masking:activate_client(member1)
		check_entity_mask(entity, mask_hash { 0, 1 })
		masking:activate_client(member3)
		check_entity_mask(entity, mask_hash { 0, 1, 3 })

		SANITY_CHECKS()
	end)

	CASE("should use a component filter", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()
		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1 })

		SANITY_CHECKS()
	end)

	CASE("should use a single member filter for entity", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()

		masking:start_entity(entity, member2)
		check_entity_mask(entity, mask_hash { 2 })
		masking:set_entity(entity, {
			[member0] = true,
			[member1] = true,
		})
		check_entity_mask(entity, mask_hash { 0, 1 })

		SANITY_CHECKS()
	end)

	CASE("should a single member filter for component", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()

		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity, component, 1, member1)
		check_component_mask(entity, component, mask_hash { 1 })
		masking:set_entity(entity, member2)
		check_component_mask(entity, component, "")
		SANITY_CHECKS()
	end)

	CASE("should change a component filter", function()
		local member0, member1, member2, member3 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()
		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
			[member3] = true,
		})
		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1 })
		masking:set_component(entity, component, 1, {
			[member2] = true,
		})
		check_component_mask(entity, component, mask_hash { 2 })
		masking:set_component(entity, component, 1, {
			[member2] = false,
		})
		check_component_mask(entity, component, mask_hash { 0, 1, 3 })

		SANITY_CHECKS()
	end)

	CASE("should use the entity filter if no component filter is given", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()
		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity, component, 1, nil)
		check_component_is_merged(entity, component, mask_hash { 0, 1, 2 })
		masking:set_entity(entity, {
			[member0] = true,
		})
		check_component_is_merged(entity, component, mask_hash { 0 })
		masking:set_entity(entity, nil)
		check_component_is_merged(entity, component, mask_hash { 0, 1, 2, 3 })

		SANITY_CHECKS()
	end)

	CASE("should run band in the entity bitmask for a component filter", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()
		masking:start_entity(entity, {
			[member0] = true,
			[member2] = true,
		})

		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_mask(entity, component, mask_hash { 0 })
		masking:set_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1 })

		SANITY_CHECKS()
	end)

	CASE("should postpone a component if entity is not active", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()

		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_is_not_active(entity, component)
		CHECK(masking.lookups.postponed[entity][1][component] ~= nil)

		masking:set_component(entity, component, 1, {
			[member0] = true,
		})
		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		check_component_mask(entity, component, mask_hash { 0 })
	end)
	CASE("should merge component with entity when the filter gets removed", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()

		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1 })
		masking:set_component(entity, component, 1, nil)
		check_component_is_merged(entity, component, mask_hash { 0, 1, 2 })

		SANITY_CHECKS()
	end)

	CASE("should separate a component when a filter gets added when it wasnt added", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()
		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})

		masking:set_component(entity, component, 1, nil)
		masking:set_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1 })
		masking:set_component(entity, component, 1, nil)
		check_component_is_merged(entity, component, mask_hash { 0, 1, 2 })

		-- testing forcing to merge to the same mask
		masking:set_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1, 2 })
	end)

	CASE("should merge components and entities when they share same mask", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()

		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1 })
		masking:set_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		check_entity_mask(entity, mask_hash { 0, 1, 2 })
		check_component_mask(entity, component, mask_hash { 0, 1, 2 })

		SANITY_CHECKS()
	end)

	CASE("should dissect components from entities when they no longer share same mask", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()

		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
		})
		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_entity_mask(entity, mask_hash { 0, 1 })
		check_component_mask(entity, component, mask_hash { 0, 1 })

		-- separate the bitmasks
		masking:set_component(entity, component, 1, {
			[member0] = true,
		})
		check_component_mask(entity, component, mask_hash { 0 })
		check_entity_mask(entity, mask_hash { 0, 1 })

		-- combine again
		masking:set_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1 })
		check_entity_mask(entity, mask_hash { 0, 1 })

		-- separate them by changing the entity instead
		masking:set_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		check_entity_mask(entity, mask_hash { 0, 1, 2 })
		check_component_mask(entity, component, mask_hash { 0, 1 })

		SANITY_CHECKS()
	end)

	CASE("should stop an entity", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()

		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1 })
		masking:stop_entity(entity)
		check_component_is_not_active(entity, component)
		check_entity_is_not_active(entity)

		SANITY_CHECKS()
	end)

	CASE("should stop a component", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)
		local entity = world.entity()
		local component = world.component()

		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1 })
		masking:stop_component(entity, component, 1)
		check_component_is_not_active(entity, component)

		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1, 2 })
		check_entity_mask(entity, mask_hash { 0, 1, 2 })
		masking:stop_component(entity, component, 1)
		check_component_is_not_active(entity, component)
		check_entity_mask(entity, mask_hash { 0, 1, 2 })

		SANITY_CHECKS(SANITY_CHECKS)
	end)

	CASE("should postpone a component with no filter", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component1 = world.component()
		local component2 = world.component()

		masking:start_component(entity, component1, 1, nil)
		masking:start_component(entity, component2, 1, nil)

		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		check_component_is_merged(entity, component1, mask_hash { 0, 1, 2 })
		check_component_is_merged(entity, component2, mask_hash { 0, 1, 2 })

		SANITY_CHECKS()
	end)

	CASE("should be able to apply the same filter to an entity", function()
		local member0, member1 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()
		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
		})
		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_entity_mask(entity, mask_hash { 0, 1 })
		masking:set_entity(entity, {
			[member0] = true,
			[member1] = true,
		})
		check_entity_mask(entity, mask_hash { 0, 1 })
		check_component_mask(entity, component, mask_hash { 0, 1 })

		SANITY_CHECKS()
	end)

	CASE("should be able to apply the same filter to a component", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world.entity()
		local component = world.component()
		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1 })
		masking:set_component(entity, component, 1, {
			[member0] = true,
			[member1] = true,
		})
		check_component_mask(entity, component, mask_hash { 0, 1 })
		masking:set_component(entity, component, 1, nil)
		check_component_is_merged(entity, component, mask_hash { 0, 1, 2 })
		masking:set_component(entity, component, 1, nil)
		check_component_is_merged(entity, component, mask_hash { 0, 1, 2 })

		SANITY_CHECKS()
	end)
	CASE("should merge two masks correctly", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity1 = world.entity()
		local entity2 = world.entity()
		local component1 = world.component()
		local component2 = world.component()

		masking:start_entity(entity1, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_entity(entity2, {
			[member0] = true,
			--[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity2, component1, 1, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity1, component2, 1, {
			[member0] = true,
		})

		masking:unregister_client(member1)
		masking:compact_members()

		local compacted_hash = mask_hash { masking.client_indexes[member0], masking.client_indexes[member2] }
		check_entity_mask(entity1, compacted_hash)
		check_entity_mask(entity2, compacted_hash)

		masking:unregister_client(member2)
		masking:compact_members()

		local compacted_hash2 = mask_hash { masking.client_indexes[member0] }
		check_entity_mask(entity1, compacted_hash2)
		check_entity_mask(entity2, compacted_hash2)

		check_component_mask(entity2, component1, compacted_hash2)
		check_component_mask(entity1, component2, compacted_hash2)

		SANITY_CHECKS()
	end)
	CASE("should postpone all components when an entity stops", function()
		local member0, member1, member2, member3 = register_members(masking)
		active_all_members(masking)
		local entity = world.entity()
		local component1 = world.component()
		local component2 = world.component()
		local component3 = world.component()
		local component4 = world.component()

		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity, component1, 1, nil)
		masking:start_component(entity, component2, 1, {
			[member0] = true,
			[member1] = true,
		})
		masking:start_component(entity, component3, 1, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity, component4, 1, {
			[member0] = true,
			[member3] = true,
		})
		masking:stop_entity(entity)
		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})

		check_component_is_merged(entity, component1, mask_hash { 0, 1, 2 })
		check_component_mask(entity, component2, mask_hash { 0, 1 })
		check_component_mask(entity, component3, mask_hash { 0, 1, 2 })
		check_component_mask(entity, component4, mask_hash { 0 })

		SANITY_CHECKS()
	end)
	CASE("it should allow aliases to be used", function()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)
		local entity = world.entity()
		local component = world.component()
		masking.client_aliases["m0"] = member0
		masking.client_aliases["m1"] = member1

		masking:start_entity(entity, {
			m0 = true,
			m1 = true,
			[member2] = true,
		})
		masking:start_component(entity, component, 1, {
			m0 = false,
		})

		check_entity_mask(entity, mask_hash { 0, 1, 2 })
		check_component_mask(entity, component, mask_hash { 1, 2 })
		masking:set_entity(entity, {
			m1 = false,
		})
		check_entity_mask(entity, mask_hash { 0, 2, 3 })
		check_component_mask(entity, component, mask_hash { 2, 3 })

		SANITY_CHECKS()
	end)
end)

TEST("storage moving", function()
	CASE("it should move component additions", function() end)

	CASE("it should move component changes", function() end)

	CASE("it should move component removals", function() end)

	CASE("it should move tag changes", function() end)

	CASE("it should move tag removals", function() end)

	CASE("it should move relation changes", function() end)

	CASE("it should move relation removals", function() end)

	CASE("it should move relation value changes", function() end)

	CASE("it should move relation value removals", function() end)
end)

TEST("bitmask deltas", function() end)

TEST("replecs server", function() end)

TEST("replecs client", function() end)

local function create_test_components(test_world: pepecs.World)
	local components = {} :: { pepecs.Entity<any> }
	for i = 1, 6 do
		local component = test_world.component()
		test_world.add(component, replecs.shared)
		test_world.set(component, pepecs.Name, "component" .. i)

		table.insert(components, component)
	end

	return components
end

local function filter(members: { [any]: boolean }): { [Player]: boolean }
	return members :: any
end

local function create_test_tags(test_world: pepecs.World)
	local tags = {} :: { pepecs.Entity }
	for i = 1, 6 do
		local tag = test_world.entity()
		test_world.add(tag, replecs.shared)
		test_world.set(tag, pepecs.Name, "tag" .. i)

		table.insert(tags, tag)
	end

	return tags
end

TEST("custom ids", function()
	local s_world: pepecs.World = nil :: any
	local c_world: pepecs.World = nil :: any
	local server: replecs.Server = nil :: any
	local client: replecs.Client = nil :: any

	BEFORE_EACH(function()
		s_world = pepecs.world()
		c_world = pepecs.world()
		server = replecs.create_server(s_world)
		client = replecs.create_client(c_world)
	end)
	AFTER_EACH(function()
		server:destroy()
		client:destroy()
	end)

	CASE("should use custom ids", function()
		local created_entity: pepecs.Entity? = nil
		local called = 0

		local custom = replecs.create_custom_id("custom", function()
			created_entity = c_world.entity()
			called += 1
			return created_entity
		end)

		local plr = newproxy()

		client:register_custom_id(custom)
		server:register_custom_id(custom)

		server:init()
		client:init()
		server.masking:register_client(plr)
		server.masking:activate_client(plr)

		local e1 = s_world.entity()
		server:set_custom(e1, custom)
		server:set_networked(e1)
		local e2 = s_world.entity()
		server:set_networked(e2)

		local buf, var = server:get_full(plr)
		client:apply_full(buf, var)

		CHECK(called == 1)
		CHECK(client:get_client_entity(e1 :: any) == created_entity)
		CHECK(client:get_client_entity(e2 :: any) ~= created_entity)
	end)

	CASE("should find component in buffer", function()
		local foo_entity: Entity? = nil
		local baz_entity: Entity? = nil

		local s_components = create_test_components(s_world)
		local c_components = create_test_components(c_world)

		local custom = replecs.create_custom_id("custom", function(ctx)
			local entity = c_world.entity()
			if ctx.component(c_components[1]) == "foo" then
				foo_entity = entity
				return entity
			else
				baz_entity = entity
				return entity
			end
		end)

		local plr = newproxy()

		client:register_custom_id(custom)
		server:register_custom_id(custom)

		server:init()
		client:init()

		server.masking:register_client(plr)
		server.masking:activate_client(plr)

		local s_foo = s_world.entity()
		s_world.set(s_foo, s_components[1], "foo")

		server:set_custom(s_foo, custom)
		server:set_reliable(s_foo, s_components[1])
		server:set_networked(s_foo)

		local s_baz = s_world.entity()
		s_world.set(s_baz, s_components[1], "baz")

		server:set_custom(s_baz, custom)
		server:set_reliable(s_baz, s_components[1])
		server:set_networked(s_foo)

		local buf, variants = server:get_full(plr)
		client:apply_full(buf, variants)

		CHECK(client:get_client_entity(s_foo :: any) == foo_entity)
		CHECK(client:get_client_entity(s_baz :: any) == baz_entity)
	end)

	CASE("should add targets of customids to buffers", function()
		local created_entity: Entity

		local s_tags = create_test_tags(s_world)
		local c_tags = create_test_tags(c_world)

		local custom = replecs.create_custom_id("custom", function()
			created_entity = c_world.entity()
			return created_entity
		end)

		local plr = newproxy()

		client:register_custom_id(custom)
		server:register_custom_id(custom)

		server:init()
		client:init()

		server.masking:register_client(plr)
		server.masking:activate_client(plr)

		local s_target = s_world.entity()
		server:set_custom(s_target, custom)
		server:set_networked(s_target)

		local s_entity = s_world.entity()
		s_world.add(s_entity, pepecs.pair(s_tags[1], s_target))
		server:set_relation(s_entity, s_tags[1])
		server:set_networked(s_entity)

		local buf, variants = server:get_full(plr)
		client:apply_full(buf, variants)

		local c_entity = client:get_client_entity(s_entity :: any) :: Entity
		expect(c_entity).to.be.ok()

		CHECK(c_world.has(c_entity, pepecs.pair(c_tags[1], created_entity)))
	end)

	CASE("should recursively process custom id targets when applying buffers", function()
		local created_target: Entity
		local created_custom: Entity

		local s_tags = create_test_tags(s_world)
		local c_tags = create_test_tags(c_world)

		local custom = replecs.create_custom_id("custom", function()
			created_custom = c_world.entity()
			return created_custom
		end)
		local target_custom = replecs.create_custom_id("target_custom", function()
			created_target = c_world.entity()
			return created_target
		end)

		local plr = newproxy()

		client:register_custom_id(custom)
		server:register_custom_id(custom)
		client:register_custom_id(target_custom)
		server:register_custom_id(target_custom)

		server:init()
		client:init()

		server.masking:register_client(plr)
		server.masking:activate_client(plr)

		local s_target = s_world.entity()
		server:set_custom(s_target, target_custom)
		server:set_networked(s_target)

		local s_entity = s_world.entity()
		s_world.add(s_entity, pepecs.pair(s_tags[1], s_target))
		server:set_custom(s_entity, custom)
		server:set_relation(s_entity, s_tags[1])
		server:set_networked(s_entity)

		local buf, variants = server:get_full(plr)
		client:apply_full(buf, variants)

		local c_entity = client:get_client_entity(s_entity :: any) :: Entity
		CHECK(c_entity ~= nil)

		CHECK(c_entity == created_custom)
		CHECK(c_world.target(c_entity, c_tags[1]) == created_target)
	end)

	CASE("should get target from context", function()
		local s_tags = create_test_tags(s_world)
		local c_tags = create_test_tags(c_world)

		local plr = newproxy()

		server:init()
		client:init()

		server.masking:register_client(plr)
		server.masking:activate_client(plr)

		local s_target = s_world.entity()
		server:set_networked(s_target)

		local custom = replecs.create_custom_id("custom", function(ctx: replecs.HandleContext)
			if ctx.target(c_tags[1]) == client:get_client_entity(s_target :: any) then
				return c_world.entity()
			else
				error "invalid target"
			end
		end)

		client:register_custom_id(custom)
		server:register_custom_id(custom)

		local s_entity = s_world.entity()
		s_world.add(s_entity, pepecs.pair(s_tags[1], s_target))
		server:set_custom(s_entity, custom)
		server:set_relation(s_entity, s_tags[1])
		server:set_networked(s_entity)

		local buf, variants = server:get_full(plr)
		client:apply_full(buf, variants)
	end)

	CASE("should get unprocessed customid target from context", function()
		local s_tags = create_test_tags(s_world)
		local c_tags = create_test_tags(c_world)

		local plr = newproxy()

		server:init()
		client:init()

		server.masking:register_client(plr)
		server.masking:activate_client(plr)

		local target_entity: Entity
		local callstack: { number } = {}

		local target_custom = replecs.create_custom_id("target_custom", function()
			table.insert(callstack, 2)
			target_entity = c_world.entity()
			return target_entity
		end)

		local custom = replecs.create_custom_id("custom", function(ctx: replecs.HandleContext)
			table.insert(callstack, 1)
			if ctx.target(c_tags[1]) == target_entity then
				table.insert(callstack, 3)
				return c_world.entity()
			else
				error "invalid target"
			end
		end)

		client:register_custom_id(custom)
		server:register_custom_id(custom)
		client:register_custom_id(target_custom)
		server:register_custom_id(target_custom)

		local s_target = s_world.entity()
		server:set_custom(s_target, target_custom)
		server:set_networked(s_target)

		local s_entity = s_world.entity()
		s_world.add(s_entity, pepecs.pair(s_tags[1], s_target))
		server:set_custom(s_entity, custom)
		server:set_relation(s_entity, s_tags[1])
		server:set_networked(s_entity)

		local buf, variants = server:get_full(plr)
		client:apply_full(buf, variants)
		expect(callstack).to.equal { 1, 2, 3 }
	end)
end)

TEST("server -> client replication", function()
	local world: pepecs.World = nil :: any
	local server: replecs.Server = nil :: any

	BEFORE_EACH(function()
		world = pepecs.world()
		server = replecs.create_server(world)
	end)

	AFTER_EACH(function()
		server:destroy()
	end)

	local function client_entity(member: MemberData, server_entity: pepecs.Entity): pepecs.Entity?
		local entity = member.client.server_ids[server_entity :: any]
		if entity and member.world.exists(entity) then
			return entity
		end
		return nil
	end

	local function client_component(member: MemberData, server_entity: pepecs.Entity, component_index: number)
		local component = member.components[component_index]
		local entity = client_entity(member, server_entity)
		if entity then
			return member.world.get(entity, component)
		end
		return nil
	end
	local function client_has_component(member: MemberData, server_entity: pepecs.Entity, component_index: number)
		local component = member.components[component_index]
		local entity = client_entity(member, server_entity)
		if entity then
			return member.world.has(entity, component)
		end
		return false
	end
	local function client_tag(member: MemberData, server_entity: pepecs.Entity, tag_index: number): boolean?
		local tag = member.tags[tag_index]
		local entity = client_entity(member, server_entity)
		if entity then
			return member.world.has(entity, tag)
		end
		return false
	end

	local function client_relation_value(
		member: MemberData,
		server_entity: pepecs.Entity,
		relation_index: number,
		target_server: pepecs.Entity
	): any?
		local relation = member.components[relation_index]
		local target = client_entity(member, target_server)

		local entity = client_entity(member, server_entity)
		if entity and target then
			return member.world.get(entity, pepecs.pair(relation, target))
		end
		return nil
	end

	local function client_pair_value(
		member: MemberData,
		server_entity: pepecs.Entity,
		relation_index: number,
		target_index: number
	): any?
		local relation = member.components[relation_index]
		local target = member.tags[target_index]

		local entity = client_entity(member, server_entity)
		if entity and target then
			return member.world.get(entity, pepecs.pair(relation, target))
		end
		return nil
	end

	local function client_relation(
		member: MemberData,
		server_entity: pepecs.Entity,
		relation_index: number,
		target_server: pepecs.Entity
	): boolean?
		local relation = member.tags[relation_index]
		local target = client_entity(member, target_server)

		local entity = client_entity(member, server_entity)
		if entity and target then
			return member.world.has(entity, pepecs.pair(relation, target))
		end
		return false
	end

	local function client_pair(
		member: MemberData,
		server_entity: pepecs.Entity,
		relation_index: number,
		target_index: number
	): boolean?
		local relation = member.tags[relation_index]
		local target = member.tags[target_index]

		local entity = client_entity(member, server_entity)
		if entity and target then
			return member.world.has(entity, pepecs.pair(relation, target))
		end
		return nil
	end

	local function client_global_pair(
		member: MemberData,
		server_entity: pepecs.Entity,
		relation: pepecs.Entity,
		target_server: pepecs.Entity
	): boolean
		local target = client_entity(member, target_server)
		local entity = client_entity(member, server_entity)
		if entity and target then
			return member.world.has(entity, pepecs.pair(relation, target))
		end
		return false
	end

	local function create_members_data(count: number?)
		local members = {} :: { MemberData }
		local lookup = {}
		local worlds = {}
		local c_components = {}
		local c_tags = {}

		for i = 1, (count or 3) do
			local new_world = pepecs.world()
			local components = create_test_components(new_world)
			local tags = create_test_tags(new_world)
			local replicator = replecs.create_client(new_world)

			local member_mt = {
				world = new_world,
				client = replicator,
				components = components,
				tags = tags,
			}
			local member = newproxy(true)
			getmetatable(member).__index = member_mt

			server.masking:register_client(member)
			table.insert(members, member :: MemberData)
			table.insert(worlds, new_world)
			table.insert(c_components, components)
			table.insert(c_tags, tags)
			lookup[member] = i
		end
		return members, worlds, c_components, c_tags, lookup
	end
	local function init_member_clients(members: { MemberData })
		for _, member in members do
			member.client:init()
		end
	end

	local function activate_members(members: { MemberData })
		for _, member in members do
			server.masking:activate_client(member)
		end
	end

	CASE("should send full components to all players", function()
		local components = create_test_components(world)
		server:init()

		local members = create_members_data()
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		local entity2 = world.entity()

		server:set_networked(entity1)

		server:set_reliable(entity1, components[1])
		world.set(entity1, components[1], "foo")

		server:set_networked(entity2)
		server:set_reliable(entity2, components[2])
		world.set(entity2, components[2], "bar")

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			local client = member.client
			client:apply_full(buf, variants)

			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_component(member, entity1, 1) == "foo")
			CHECK(client_component(member, entity2, 2) == "bar")

			CHECK(client_component(member, entity1, 2) == nil)
			CHECK(client_component(member, entity2, 1) == nil)
		end
	end)

	CASE("should send full tags to all players", function()
		create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data()
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		local entity2 = world.entity()

		server:set_networked(entity1)
		server:set_reliable(entity1, tags[1])
		world.add(entity1, tags[1])

		server:set_networked(entity2)
		server:set_reliable(entity2, tags[2])
		world.add(entity2, tags[2])

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)

			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_entity(member, entity2) ~= nil)

			CHECK(client_tag(member, entity1, 1) == true)
			CHECK(client_tag(member, entity2, 2) == true)

			CHECK(client_tag(member, entity1, 2) == false)
			CHECK(client_tag(member, entity2, 1) == false)
		end
	end)

	CASE("should send full pairs with shared targets to all players", function()
		create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data()
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		local entity2 = world.entity()

		server:set_networked(entity1)
		server:set_networked(entity2)

		server:set_pair(entity1, pepecs.pair(tags[1], tags[2]))
		world.add(entity1, pepecs.pair(tags[1], tags[2]))
		world.add(entity1, pepecs.pair(tags[1], tags[3]))

		server:set_pair(entity2, pepecs.pair(tags[2], tags[3]))
		world.add(entity2, pepecs.pair(tags[1], tags[2]))
		world.add(entity1, pepecs.pair(tags[2], tags[1]))
		world.add(entity2, pepecs.pair(tags[2], tags[3]))

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)

			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_entity(member, entity2) ~= nil)

			CHECK(client_pair(member, entity1, 1, 2) == true)
			CHECK(client_pair(member, entity1, 1, 3) == false)

			CHECK(client_pair(member, entity2, 1, 2) == false)
			CHECK(client_pair(member, entity2, 2, 1) == false)
			CHECK(client_pair(member, entity2, 2, 3) == true)
		end
	end)

	CASE("should send full pairs with networked targets to all players", function()
		create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data()
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		local entity2 = world.entity()

		local target1 = world.entity()
		local target2 = world.entity()

		server:set_networked(entity1)
		server:set_networked(entity2)
		server:set_networked(target1)
		server:set_networked(target2)

		world.add(entity1, pepecs.pair(tags[1], target1))
		world.add(entity1, pepecs.pair(tags[1], target2))
		server:set_pair(entity1, pepecs.pair(tags[1], target1))

		world.add(entity2, pepecs.pair(tags[1], target1))
		world.add(entity2, pepecs.pair(tags[2], target1))
		world.add(entity2, pepecs.pair(tags[2], target2))
		server:set_pair(entity2, pepecs.pair(tags[2], target2))

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)

			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_entity(member, entity2) ~= nil)

			CHECK(client_relation(member, entity1, 1, target1) == true)
			CHECK(client_relation(member, entity1, 1, target2) == false)

			CHECK(client_relation(member, entity2, 1, target1) == false)
			CHECK(client_relation(member, entity2, 2, target1) == false)
			CHECK(client_relation(member, entity2, 2, target2) == true)
		end
	end)

	CASE("should send full pairs with values to all players", function()
		local components = create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data()
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		local entity2 = world.entity()

		server:set_networked(entity1)
		server:set_networked(entity2)

		world.set(entity1, pepecs.pair(components[1], tags[1]), "yes")
		world.set(entity1, pepecs.pair(components[1], tags[2]), "no")
		server:set_pair(entity1, pepecs.pair(components[1], tags[1]))

		world.set(entity2, pepecs.pair(components[1], tags[1]), "no")
		world.set(entity2, pepecs.pair(components[2], tags[1]), "no")
		world.set(entity2, pepecs.pair(components[2], tags[3]), "yes")
		server:set_pair(entity2, pepecs.pair(components[2], tags[3]))

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)

			print(client_entity(member, entity1) ~= nil)
			print(client_entity(member, entity2) ~= nil)

			print(client_pair_value(member, entity1, 1, 1) == "yes")
			print(client_pair_value(member, entity1, 1, 2) == nil)

			print(client_pair_value(member, entity2, 1, 1) == nil)
			print(client_pair_value(member, entity2, 2, 1) == nil)
			print(client_pair_value(member, entity2, 2, 3) == "yes")
		end
	end)

	CASE("should send full relations to all players", function()
		create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data()
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		local entity2 = world.entity()

		local target1 = world.entity()
		server:set_networked(target1)
		local target2 = world.entity()
		server:set_networked(target2)
		local target3 = world.entity()
		server:set_networked(target3)
		local target4 = world.entity()
		server:set_networked(target4)

		server:set_networked(entity1)
		server:set_relation(entity1, tags[1])
		server:set_relation(entity1, pepecs.ChildOf)

		server:set_networked(entity2)
		server:set_relation(entity2, tags[2])

		world.add(entity1, pepecs.pair(tags[1], target1))
		world.add(entity1, pepecs.pair(tags[1], target2))
		world.add(entity1, pepecs.pair(tags[1], target3))
		world.add(entity1, pepecs.pair(pepecs.ChildOf, target3))

		world.add(entity2, pepecs.pair(tags[2], target3))
		world.add(entity2, pepecs.pair(tags[2], target4))

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)

			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_entity(member, entity2) ~= nil)

			CHECK(client_relation(member, entity1, 1, target1) == true)
			CHECK(client_global_pair(member, entity1, pepecs.ChildOf, target3) == true)
			CHECK(client_relation(member, entity1, 1, target2) == true)
			CHECK(client_relation(member, entity1, 1, target3) == true)
			CHECK(client_relation(member, entity2, 2, target3) == true)
			CHECK(client_relation(member, entity2, 2, target4) == true)

			CHECK(client_relation(member, entity1, 2, target3) == false)
			CHECK(client_relation(member, entity1, 2, target4) == false)
			CHECK(client_relation(member, entity1, 2, target1) == false)
			CHECK(client_relation(member, entity2, 1, target2) == false)
			CHECK(client_relation(member, entity2, 1, target3) == false)
		end
	end)
	CASE("should send full entity to players in filter", function()
		local components = create_test_components(world)
		create_test_tags(world)
		server:init()

		local members = create_members_data(4)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		local entity2 = world.entity()

		server:set_networked(
			entity1,
			filter {
				[members[1]] = true,
				[members[2]] = true,
			}
		)

		server:set_reliable(entity1, components[1])
		world.set(entity1, components[1], "foo")

		server:set_networked(
			entity2,
			filter {
				[members[3]] = true,
				[members[4]] = true,
			}
		)

		server:set_reliable(entity2, components[2])
		world.set(entity2, components[2], "bar")

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end

		CHECK(client_entity(members[1], entity1) ~= nil)
		CHECK(client_entity(members[2], entity1) ~= nil)
		CHECK(client_entity(members[1], entity2) == nil)
		CHECK(client_entity(members[2], entity2) == nil)

		CHECK(client_entity(members[3], entity2) ~= nil)
		CHECK(client_entity(members[4], entity2) ~= nil)
		CHECK(client_entity(members[3], entity1) == nil)
		CHECK(client_entity(members[4], entity1) == nil)

		CHECK(client_component(members[1], entity1, 1) == "foo")
		CHECK(client_component(members[2], entity1, 1) == "foo")
		CHECK(client_component(members[3], entity2, 2) == "bar")
		CHECK(client_component(members[4], entity2, 2) == "bar")
	end)

	CASE("should send full entity with component filters", function()
		local components = create_test_components(world)
		create_test_tags(world)
		server:init()

		local members = create_members_data(4)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		local entity2 = world.entity()

		server:set_networked(entity1)
		server:set_reliable(
			entity1,
			components[1],
			filter {
				[members[1]] = true,
				[members[2]] = true,
				[members[3]] = true,
			}
		)
		world.set(entity1, components[1], "foo")

		server:set_networked(entity2)
		server:set_reliable(
			entity2,
			components[2],
			filter {
				[members[3]] = true,
				[members[4]] = true,
			}
		)
		world.set(entity2, components[2], "bar")

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end

		CHECK(client_component(members[1], entity1, 1) == "foo")
		CHECK(client_component(members[2], entity1, 1) == "foo")
		CHECK(client_component(members[3], entity1, 1) == "foo")

		CHECK(client_component(members[1], entity1, 2) == nil)
		CHECK(client_component(members[2], entity1, 2) == nil)
		CHECK(client_component(members[1], entity2, 1) == nil)
		CHECK(client_component(members[2], entity2, 1) == nil)

		CHECK(client_component(members[3], entity2, 2) == "bar")
		CHECK(client_component(members[4], entity2, 2) == "bar")
	end)

	CASE("should correctly send nil values in components", function()
		local components = create_test_components(world)
		create_test_tags(world)
		server:init()

		local members = create_members_data(4)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		world.add(entity1, server.components.networked)
		world.add(entity1, pepecs.pair(server.components.reliable, components[1]))
		world.set(entity1, components[1], nil)

		local buf, variants = server:get_full(members[1] :: any)
		members[1].client:apply_full(buf, variants)

		CHECK(client_component(members[1], entity1, 1) == nil)
		CHECK(client_has_component(members[1], entity1, 1) == true)
	end)

	CASE("should allow custom serdes for component values", function()
		local serdes: replecs.Serdes = {
			serialize = function(value: vector)
				local buf = buffer.create(3)
				buffer.writeu8(buf, 0, value.x)
				buffer.writeu8(buf, 1, value.y)
				buffer.writeu8(buf, 2, value.z)
				return buf
			end,
			deserialize = function(buf: buffer)
				-- lets write it backwards to know this function was called
				return vector.create(buffer.readu8(buf, 2), buffer.readu8(buf, 1), buffer.readu8(buf, 0))
			end,
		}

		local components = create_test_components(world)
		world.set(components[1], replecs.serdes, serdes)
		--world.set(components[1], replecs.bytespan, 3)
		create_test_tags(world)
		server:init()

		local members = create_members_data(1)
		members[1].world.set(members[1].components[1], replecs.serdes, serdes)
		--members[1].world.set(members[1].components[1], replecs.bytespan, 3)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		world.add(entity1, server.components.networked)
		world.add(entity1, pepecs.pair(server.components.reliable, components[1]))
		world.set(entity1, components[1], vector.create(10, 20, 30))

		local buf, variants = server:get_full(members[1] :: any)
		members[1].client:apply_full(buf, variants)

		CHECK(client_component(members[1], entity1, 1) == vector.create(30, 20, 10))
	end)

	CASE("should send component changes to all players", function()
		local components = create_test_components(world)
		create_test_tags(world)
		server:init()

		local members = create_members_data(2)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		world.add(entity1, server.components.networked)
		world.add(entity1, pepecs.pair(server.components.reliable, components[1]))
		world.set(entity1, components[1], "one")

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end

		world.set(entity1, components[1], "two")
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_component(member, entity1, 1) == "two")
		end
		world.set(entity1, components[1], "three")
		world.set(entity1, components[1], "four")
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_component(member, entity1, 1) == "four")
		end
	end)

	CASE("should send tag changes to all players", function()
		create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data(4)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		world.add(entity1, server.components.networked)
		world.set(entity1, pepecs.pair(server.components.reliable, tags[1]), nil)
		world.set(entity1, pepecs.pair(server.components.reliable, tags[2]), nil)
		world.set(entity1, pepecs.pair(server.components.reliable, tags[3]), nil)

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end

		world.add(entity1, tags[1])
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_tag(member, entity1, 1) == true)
			CHECK(client_tag(member, entity1, 2) == false)
		end
		world.add(entity1, tags[2])
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_tag(member, entity1, 1) == true)
			CHECK(client_tag(member, entity1, 2) == true)
		end

		world.remove(entity1, tags[1])
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_tag(member, entity1, 1) == false)
			CHECK(client_tag(member, entity1, 2) == true)
		end

		world.remove(entity1, tags[2])

		world.add(entity1, tags[3])
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_tag(member, entity1, 1) == false)
			CHECK(client_tag(member, entity1, 2) == false)
			CHECK(client_tag(member, entity1, 3) == true)
		end
	end)

	CASE("should send relation changes", function()
		create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data(2)
		activate_members(members)
		init_member_clients(members)

		local entity = world.entity()
		world.add(entity, server.components.networked)

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end

		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
		end

		for _ = 1, 10 do
			local target = world.entity()
			world.add(target, server.components.networked)
			world.add(target, pepecs.pair(replecs.relation, pepecs.ChildOf))
			world.add(target, pepecs.pair(pepecs.ChildOf, entity))
		end
	end)

	CASE("should send relation changes to all players", function()
		create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data(4)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()

		world.add(entity1, server.components.networked)
		world.add(entity1, pepecs.pair(server.components.relation, tags[1]))
		world.add(entity1, pepecs.pair(server.components.relation, pepecs.ChildOf))

		local r1 = world.entity()
		local r2 = world.entity()
		local r3 = world.entity()
		world.add(r1, server.components.networked)
		world.add(r2, server.components.networked)
		world.add(r3, server.components.networked)
		world.add(entity1, pepecs.pair(tags[1], r1))

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end

		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_relation(member, entity1, 1, r1) == true)
			CHECK(client_relation(member, entity1, 1, r2) == false)
			CHECK(client_relation(member, entity1, 1, r2) == false)
		end
		world.add(entity1, pepecs.pair(tags[1], r2))
		world.add(entity1, pepecs.pair(pepecs.ChildOf, r2))

		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_relation(member, entity1, 1, r1) == true)
			CHECK(client_relation(member, entity1, 1, r2) == true)
			CHECK(client_relation(member, entity1, 1, r3) == false)
			CHECK(client_global_pair(member, entity1, pepecs.ChildOf, r2) == true)
		end
		world.remove(entity1, pepecs.pair(tags[1], r1))
		world.add(entity1, pepecs.pair(tags[1], r3))

		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_relation(member, entity1, 1, r1) == false)
			CHECK(client_relation(member, entity1, 1, r2) == true)
			CHECK(client_relation(member, entity1, 1, r3) == true)
		end
	end)

	CASE("should remove entity when networked component is removed", function()
		local components = create_test_components(world)
		create_test_tags(world)
		server:init()

		local members = create_members_data(2)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		world.add(entity1, server.components.networked)
		world.add(entity1, pepecs.pair(server.components.reliable, components[1]))
		world.set(entity1, components[1], "foo")

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end
		world.remove(entity1, server.components.networked)

		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_entity(member, entity1) == nil)
		end
		world.add(entity1, server.components.networked)
		world.remove(entity1, server.components.networked)
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_entity(member, entity1) == nil)
		end
	end)

	CASE("should remove all data when component stops", function()
		local components = create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data(1)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world.entity()
		world.add(entity1, server.components.networked)
		world.add(entity1, pepecs.pair(server.components.reliable, components[1]))
		world.add(entity1, pepecs.pair(server.components.reliable, tags[1]))
		world.add(entity1, pepecs.pair(server.components.relation, tags[2]))

		local r1 = world.entity()
		local r2 = world.entity()
		world.add(r1, server.components.networked)
		world.add(r2, server.components.networked)

		world.set(entity1, components[1], "foo")
		world.add(entity1, tags[1])
		world.add(entity1, pepecs.pair(tags[2], r1))
		world.add(entity1, pepecs.pair(tags[2], r2))

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
		end

		world.remove(entity1, pepecs.pair(server.components.reliable, components[1]))
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_has_component(member, entity1, 1) == false)
			CHECK(client_tag(member, entity1, 1) == true)
			CHECK(client_relation(member, entity1, 2, r1) == true)
			CHECK(client_relation(member, entity1, 2, r2) == true)
		end

		world.remove(entity1, pepecs.pair(server.components.reliable, tags[1]))
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_has_component(member, entity1, 1) == false)
			CHECK(client_tag(member, entity1, 1) == false)
			CHECK(client_relation(member, entity1, 2, r1) == true)
			CHECK(client_relation(member, entity1, 2, r2) == true)
		end

		world.remove(entity1, pepecs.pair(server.components.relation, tags[2]))
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_has_component(member, entity1, 1) == false)
			CHECK(client_tag(member, entity1, 1) == false)
			CHECK(client_relation(member, entity1, 2, r1) == false)
			CHECK(client_relation(member, entity1, 2, r2) == false)
		end
	end)
end)

local report = testlib.run(plan)

testlib.report(report)
