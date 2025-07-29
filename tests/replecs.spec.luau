local replecs = require "@replecs"
local client = require "@replecs/client"
local player_masking = require "@replecs/masking"
local utils = require "@replecs/utils"
local jecs = require "@pkg/jecs"
local observers = require "./observers"
local testkit = require "./testkit"

type Entity<T = any> = jecs.Entity<T>

type MemberData = {
	world: observers.PatchedWorld,
	client: client.Client,
	components: { jecs.Entity },
	tags: { jecs.Entity },
}

local it = testkit.test()
local TEST, CASE = it.TEST, it.CASE
local CHECK, FINISH = it.CHECK, it.FINISH
local SKIP, FOCUS = it.SKIP, it.FOCUS
local CHECK_EXPECT_ERR = it.CHECK_EXPECT_ERR

local deep_eq = testkit.deq

TEST("bitmasking", function()
	do
		CASE "should automatically expand"
		local mask = utils.bitmask.create(10)
		mask:set(5)

		CHECK(mask:get(5) == true)
		mask:set(100)
		CHECK(mask:get(100) == true)
		CHECK(mask:get(32) == false)
		CHECK(mask:get(5) == true)
	end

	do
		CASE "should get and set bits"
		local mask = utils.bitmask.create(100)
		mask:set(5)
		mask:set(33)
		mask:set(65)

		CHECK(mask:get(5) == true)
		CHECK(mask:get(33) == true)
		CHECK(mask:get(65) == true)
		CHECK(mask:get(10) == false)

		mask:clear(33)
		CHECK(mask:get(5) == true)
		CHECK(mask:get(33) == false)
		CHECK(mask:get(65) == true)
	end

	do
		CASE "should correctly shift bits"
		local mask = utils.bitmask.create(100)
		mask:set(5)
		mask:set(40)
		mask:set(65)

		local left = mask:lshift(3)
		local right = mask:rshift(2)

		CHECK(left:get(5 + 3) == true)
		CHECK(left:get(40 + 3) == true)
		CHECK(left:get(65 + 3) == true)
		CHECK(left:get(65) == false)

		CHECK(right:get(5 - 2) == true)
		CHECK(right:get(40 - 2) == true)
		CHECK(right:get(65 - 2) == true)
		CHECK(right:get(65) == false)
	end

	do
		CASE "should correctly perform bitwise operations"
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
	end

	do
		CASE "should return same string, independant of buffer capacity"
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
	end
end)

local function register_members(masking: player_masking.MaskingInternal)
	local member0 = newproxy()
	local member1 = newproxy()
	local member2 = newproxy()
	local member3 = newproxy()

	masking:register_member(member0)
	masking:register_member(member1)
	masking:register_member(member2)
	masking:register_member(member3)
	return member0, member1, member2, member3
end

local function mask_hash(members: { number })
	local bitmask = utils.bitmask.create(20)
	for _, member in members do
		bitmask:set(member)
	end
	return bitmask:tostring()
end

local function active_all_members(masking: player_masking.MaskingInternal)
	for member in masking.member_indexes do
		masking:activate_member(member)
	end
end

TEST("mask generators", function()
	local masking: player_masking.MaskingInternal = nil :: any

	local function PRE()
		masking = player_masking.create() :: player_masking.MaskingInternal
	end

	do
		CASE "should create a mask generator"
		PRE()

		local m1, m2, m3, m4 = register_members(masking)
		masking:create_include_generator {
			[m1] = true,
			[m2] = true,
			[m3] = true,
		}
		masking:create_exclude_generator {
			[m2] = true,
			[m4] = true,
		}
	end

	do
		CASE "should compute an include generator"
		PRE()

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
			CHECK(generator.bitmask:tostring() == check_mask)
		end
		generator:run_subscribed()
		check_mask = mask_hash { 0 }
		masking:activate_member(m0)
		check_mask = mask_hash { 0, 3 }
		masking:activate_member(m3)
	end

	do
		CASE "should compute an exclude generator"
		PRE()

		local m0, m1, m2, m3 = register_members(masking)
		local generator = masking:create_exclude_generator {
			[m2] = true,
			[m1] = true,
		}

		local check_mask = ""
		local called = 0
		generator.subscribed = function()
			called += 1
			local s = generator.bitmask:tostring()
			if s ~= check_mask then
				print(s)
			end
			CHECK(generator.bitmask:tostring() == check_mask)
		end
		check_mask = mask_hash { 0 }
		masking:activate_member(m0)
		check_mask = mask_hash { 0, 3 }
		masking:activate_member(m3)
		masking:activate_member(m2)
		masking:activate_member(m1)
		CHECK(called == 4)
	end

	do
		CASE "should destroy a generator"
		PRE()

		local m0, m1, m2, m3 = register_members(masking)

		local generator = masking:create_exclude_generator {
			[1] = true,
		}
		local called = 0
		generator.subscribed = function()
			called += 1
		end
		masking:activate_member(m0)
		generator:destroy()
		masking:activate_member(m1)
		masking:activate_member(m2)
		masking:activate_member(m3)
		CHECK(called == 1)
	end
end)

TEST("member bitmasking", function()
	local masking: player_masking.MaskingInternal = nil :: any
	local world: jecs.World = nil :: any

	local function PRE()
		masking = player_masking.create() :: player_masking.MaskingInternal
		world = jecs.world()
	end

	local function POST()
		-- heuristic sanity checks
		local entity_masks: { [jecs.Entity]: boolean } = {}

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

	local function check_entity_mask(entity: jecs.Entity, hash: string)
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
	local function check_component_mask(entity: jecs.Entity, component: jecs.Entity, hash: string)
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

	local function check_component_is_merged(entity: jecs.Entity, component: jecs.Entity, hash: string)
		local entity_lookup = masking.lookups.entities[entity]
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

	local function check_component_is_not_active(entity: jecs.Entity, component: jecs.Entity)
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

	local function check_entity_is_not_active(entity: jecs.Entity)
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

	do
		CASE "should use an entity filter"
		PRE()

		local member0, member1, member2 = register_members(masking)
		local entity = world:entity()
		masking:start_entity(entity, {
			[member0] = true,
			[member2] = true,
		})
		check_entity_mask(entity, "")
		active_all_members(masking)
		check_entity_mask(entity, mask_hash { 0, 2 })

		local entity2 = world:entity()
		masking:start_entity(entity2, {
			[member0] = false,
			[member2] = false,
		})
		check_entity_mask(entity2, mask_hash { 1, 3 })

		POST()
	end

	do
		CASE "should change an entity filter"
		PRE()

		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
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

		POST()
	end

	do
		CHECK "should use the replicated filter with no explicit filter"
		PRE()

		local member0, member1, member2, member3 = register_members(masking)
		local entity = world:entity()
		masking:start_entity(entity, nil)
		check_entity_mask(entity, "")
		masking:activate_member(member0)
		check_entity_mask(entity, mask_hash { 0 })
		masking:activate_member(member1)
		check_entity_mask(entity, mask_hash { 0, 1 })
		masking:activate_member(member3)
		check_entity_mask(entity, mask_hash { 0, 1, 3 })

		POST()
	end

	do
		CASE "should use a component filter"
		PRE()

		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()
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

		POST()
	end
	do
		CASE "should use a single member filter for entity"
		PRE()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()

		masking:start_entity(entity, member2)
		check_entity_mask(entity, mask_hash { 2 })
		masking:set_entity(entity, {
			[member0] = true,
			[member1] = true,
		})
		check_entity_mask(entity, mask_hash { 0, 1 })

		POST()
	end
	do
		CASE "should a single member filter for component"
		PRE()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()

		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		masking:start_component(entity, component, 1, member1)
		check_component_mask(entity, component, mask_hash { 1 })
		masking:set_entity(entity, member2)
		check_component_mask(entity, component, "")
		POST()
	end
	do
		CASE "should change a component filter"
		PRE()

		local member0, member1, member2, member3 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()
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

		POST()
	end
	do
		CASE "should use the entity filter if no component filter is given"
		PRE()
		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()
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

		POST()
	end

	do
		CASE "should run band in the entity bitmask for a component filter"
		PRE()

		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()
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

		POST()
	end

	do
		CASE "should postpone a component if entity is not active"
		PRE()

		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()

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

		POST()
	end

	do
		CASE "should merge component with entity when the filter gets removed"
		PRE()

		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()

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

		POST()
	end

	do
		CASE "should separate a component when a filter gets added when it wasnt added"
		PRE()

		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()
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

		POST()
	end

	do
		CASE "should merge components and entities when they share same mask"
		PRE()

		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()

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

		POST()
	end

	do
		CASE "should dissect components from entities when they no longer share same mask"
		PRE()

		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()

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

		POST()
	end

	do
		CASE "should stop an entity"
		PRE()

		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()

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

		POST()
	end

	do
		CASE "should stop a component"
		PRE()

		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)
		local entity = world:entity()
		local component = world:component()

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

		POST()
	end

	do
		CASE "should postpone a component with no filter"
		PRE()

		local member0, member1, member2, member3 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component1 = world:component()
		local component2 = world:component()

		masking:start_component(entity, component1, 1, nil)
		masking:start_component(entity, component2, 1, nil)

		masking:start_entity(entity, {
			[member0] = true,
			[member1] = true,
			[member2] = true,
		})
		check_component_is_merged(entity, component1, mask_hash { 0, 1, 2 })
		check_component_is_merged(entity, component2, mask_hash { 0, 1, 2 })

		POST()
	end

	do
		CASE "should be able to apply the same filter to an entity"
		PRE()

		local member0, member1 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()
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

		POST()
	end

	do
		CASE "should be able to apply the same filter to a component"
		PRE()

		local member0, member1, member2 = register_members(masking)
		active_all_members(masking)

		local entity = world:entity()
		local component = world:component()
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

		POST()
	end

	do
		CASE "should merge two masks correctly"
	end
	do
		CASE "should postpone all components when an entity stops"
	end
end)

TEST("replecs server", function() end)

TEST("replecs client", function() end)

TEST("server -> client replication", function()
	local world: jecs.World = nil :: any
	local server: replecs.Server = nil :: any

	local function PRE()
		world = observers(jecs.world())
		server = replecs.create_server(world)
	end

	local function POST()
		server:destroy()
	end

	local function create_test_components(test_world: jecs.World)
		local components = {} :: { jecs.Entity<any> }
		for i = 1, 6 do
			local component = test_world:component()
			test_world:add(component, replecs.shared)
			test_world:set(component, jecs.Name, "component" .. i)

			table.insert(components, component)
		end

		return components
	end

	local function create_test_tags(test_world: jecs.World)
		local tags = {} :: { jecs.Entity<number> }
		for i = 1, 6 do
			local tag = test_world:entity()
			test_world:add(tag, replecs.shared)
			test_world:set(tag, jecs.Name, "tag" .. i)

			table.insert(tags, tag)
		end

		return tags
	end

	local function client_entity(member: MemberData, server_entity: jecs.Entity): jecs.Entity?
		local entity = member.client.server_ids[server_entity :: any]
		if entity and member.world:contains(entity) then
			return entity
		end
		return nil
	end

	local function client_component(member: MemberData, server_entity: jecs.Entity, component_index: number)
		local component = member.components[component_index]
		local entity = client_entity(member, server_entity)
		if entity then
			return member.world:get(entity, component)
		end
		return nil
	end
	local function client_has_component(member: MemberData, server_entity: jecs.Entity, component_index: number)
		local component = member.components[component_index]
		local entity = client_entity(member, server_entity)
		if entity then
			return member.world:has(entity, component)
		end
		return false
	end
	local function client_tag(member: MemberData, server_entity: jecs.Entity, tag_index: number): boolean?
		local tag = member.tags[tag_index]
		local entity = client_entity(member, server_entity)
		if entity then
			return member.world:has(entity, tag)
		end
		return false
	end
	local function client_pair(
		member: MemberData,
		server_entity: jecs.Entity,
		relation_index: number,
		target_server: jecs.Entity
	): boolean?
		local target = client_entity(member, target_server)
		local relation = member.tags[relation_index]

		local entity = client_entity(member, server_entity)
		if entity and target then
			return member.world:has(entity, jecs.pair(relation, target))
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
			local new_world = observers(jecs.world())
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

			server.masking:register_member(member)
			table.insert(members, member)
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
			server.masking:activate_member(member)
		end
	end

	do
		CASE "should send full components to all players"
		PRE()

		local components = create_test_components(world)
		server:init()

		local members = create_members_data()
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		local entity2 = world:entity()

		world:add(entity1, server.components.networked)

		world:add(entity1, jecs.pair(server.components.reliable, components[1]))
		world:set(entity1, components[1], "foo")

		world:add(entity2, server.components.networked)

		world:add(entity2, jecs.pair(server.components.reliable, components[2]))
		world:set(entity2, components[2], "bar")

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)

			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_component(member, entity1, 1) == "foo")
			CHECK(client_component(member, entity2, 2) == "bar")

			CHECK(client_component(member, entity1, 2) == nil)
			CHECK(client_component(member, entity2, 1) == nil)
		end

		POST()
	end

	do
		CASE "should send full tags to all players"
		PRE()

		create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data()
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		local entity2 = world:entity()

		world:add(entity1, server.components.networked)
		world:add(entity1, jecs.pair(server.components.reliable, tags[1]))
		world:add(entity1, tags[1])

		world:add(entity2, server.components.networked)
		world:add(entity2, jecs.pair(server.components.reliable, tags[2]))
		world:add(entity2, tags[2])

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

		POST()
	end

	do
		CASE "should send full pairs to all players"
		PRE()

		create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data()
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		local entity2 = world:entity()

		local target1 = world:entity()
		world:add(target1, server.components.networked)
		local target2 = world:entity()
		world:add(target2, server.components.networked)
		local target3 = world:entity()
		world:add(target3, server.components.networked)
		local target4 = world:entity()
		world:add(target4, server.components.networked)

		world:add(entity1, server.components.networked)
		world:add(entity1, jecs.pair(server.components.pair, tags[1]))
		world:add(entity2, server.components.networked)
		world:add(entity2, jecs.pair(server.components.pair, tags[2]))

		world:add(entity1, jecs.pair(tags[1], target1))
		world:add(entity1, jecs.pair(tags[1], target2))
		world:add(entity1, jecs.pair(tags[1], target3))

		world:add(entity2, jecs.pair(tags[2], target3))
		world:add(entity2, jecs.pair(tags[2], target4))

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)

			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_entity(member, entity2) ~= nil)

			CHECK(client_pair(member, entity1, 1, target1) == true)
			CHECK(client_pair(member, entity1, 1, target2) == true)
			CHECK(client_pair(member, entity1, 1, target3) == true)
			CHECK(client_pair(member, entity2, 2, target3) == true)
			CHECK(client_pair(member, entity2, 2, target4) == true)

			CHECK(client_pair(member, entity1, 2, target3) == false)
			CHECK(client_pair(member, entity1, 2, target4) == false)
			CHECK(client_pair(member, entity1, 2, target1) == false)
			CHECK(client_pair(member, entity2, 1, target2) == false)
			CHECK(client_pair(member, entity2, 1, target3) == false)
		end

		POST()
	end

	do
		CASE "should send full entity to players in filter"
		PRE()

		local components = create_test_components(world)
		create_test_tags(world)
		server:init()

		local members = create_members_data(4)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		local entity2 = world:entity()

		world:set(entity1, server.components.networked, {
			[members[1]] = true,
			[members[2]] = true,
		})
		world:add(entity1, jecs.pair(server.components.reliable, components[1]))
		world:set(entity1, components[1], "foo")

		world:set(entity2, server.components.networked, {
			[members[3]] = true,
			[members[4]] = true,
		})
		world:add(entity2, jecs.pair(server.components.reliable, components[2]))
		world:set(entity2, components[2], "bar")

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

		POST()
	end
	do
		CASE "should send full entity with component filters"
		PRE()

		local components = create_test_components(world)
		create_test_tags(world)
		server:init()

		local members = create_members_data(4)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		local entity2 = world:entity()

		world:add(entity1, server.components.networked)
		world:set(entity1, jecs.pair(server.components.reliable, components[1]), {
			[members[1]] = true,
			[members[2]] = true,
			[members[3]] = true,
		})
		world:set(entity1, components[1], "foo")

		world:add(entity2, server.components.networked)
		world:set(entity2, jecs.pair(server.components.reliable, components[2]), {
			[members[3]] = true,
			[members[4]] = true,
		})
		world:set(entity2, components[2], "bar")

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

		POST()
	end

	do
		CASE "should correctly send nil values in components"
		PRE()

		local components = create_test_components(world)
		create_test_tags(world)
		server:init()

		local members = create_members_data(4)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		world:add(entity1, server.components.networked)
		world:add(entity1, jecs.pair(server.components.reliable, components[1]))
		world:set(entity1, components[1], nil)

		local buf, variants = server:get_full(members[1] :: any)
		members[1].client:apply_full(buf, variants)

		CHECK(client_component(members[1], entity1, 1) == nil)
		CHECK(client_has_component(members[1], entity1, 1) == true)

		POST()
	end

	do
		CASE "should allow custom serdes for component values"
		PRE()

		local serdes = {
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
		world:set(components[1], replecs.serdes, serdes)
		--world:set(components[1], replecs.bytespan, 3)
		create_test_tags(world)
		server:init()

		local members = create_members_data(1)
		members[1].world:set(members[1].components[1], replecs.serdes, serdes)
		--members[1].world:set(members[1].components[1], replecs.bytespan, 3)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		world:add(entity1, server.components.networked)
		world:add(entity1, jecs.pair(server.components.reliable, components[1]))
		world:set(entity1, components[1], vector.create(10, 20, 30))

		local buf, variants = server:get_full(members[1] :: any)
		members[1].client:apply_full(buf, variants)

		CHECK(client_component(members[1], entity1, 1) == vector.create(30, 20, 10))

		POST()
	end

	do
		CASE "should send component changes to all players"
		PRE()

		local components = create_test_components(world)
		create_test_tags(world)
		server:init()

		local members = create_members_data(2)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		world:add(entity1, server.components.networked)
		world:add(entity1, jecs.pair(server.components.reliable, components[1]))
		world:set(entity1, components[1], "one")

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end

		world:set(entity1, components[1], "two")
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_component(member, entity1, 1) == "two")
		end
		world:set(entity1, components[1], "three")
		world:set(entity1, components[1], "four")
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_component(member, entity1, 1) == "four")
		end

		POST()
	end

	do
		CASE "shoud send tag changes to all players"
		PRE()

		create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data(2)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		world:add(entity1, server.components.networked)
		world:set(entity1, jecs.pair(server.components.reliable, tags[1]))
		world:set(entity1, jecs.pair(server.components.reliable, tags[2]))
		world:set(entity1, jecs.pair(server.components.reliable, tags[3]))

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end

		world:add(entity1, tags[1])
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_tag(member, entity1, 1) == true)
			CHECK(client_tag(member, entity1, 2) == false)
		end
		world:add(entity1, tags[2])
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_tag(member, entity1, 1) == true)
			CHECK(client_tag(member, entity1, 2) == true)
		end

		world:remove(entity1, tags[1])
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_tag(member, entity1, 1) == false)
			CHECK(client_tag(member, entity1, 2) == true)
		end

		world:remove(entity1, tags[2])

		world:add(entity1, tags[3])
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_tag(member, entity1, 1) == false)
			CHECK(client_tag(member, entity1, 2) == false)
			CHECK(client_tag(member, entity1, 3) == true)
		end

		POST()
	end

	do
		CASE "should send pair changes to all players"
		PRE()

		create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data(4)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		world:add(entity1, server.components.networked)
		world:add(entity1, jecs.pair(server.components.pair, tags[1]))

		local r1 = world:entity()
		local r2 = world:entity()
		local r3 = world:entity()
		world:add(r1, server.components.networked)
		world:add(r2, server.components.networked)
		world:add(r3, server.components.networked)

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end

		world:add(entity1, jecs.pair(tags[1], r1))

		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_pair(member, entity1, 1, r1) == true)
			CHECK(client_pair(member, entity1, 1, r2) == false)
			CHECK(client_pair(member, entity1, 1, r2) == false)
		end
		world:add(entity1, jecs.pair(tags[1], r2))

		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_pair(member, entity1, 1, r1) == true)
			CHECK(client_pair(member, entity1, 1, r2) == true)
			CHECK(client_pair(member, entity1, 1, r3) == false)
		end
		world:remove(entity1, jecs.pair(tags[1], r1))
		world:add(entity1, jecs.pair(tags[1], r3))

		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_pair(member, entity1, 1, r1) == false)
			CHECK(client_pair(member, entity1, 1, r2) == true)
			CHECK(client_pair(member, entity1, 1, r3) == true)
		end

		POST()
	end

	do
		CASE "should remove entity when networked component is removed"
		PRE()

		local components = create_test_components(world)
		create_test_tags(world)
		server:init()

		local members = create_members_data(2)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		world:add(entity1, server.components.networked)
		world:add(entity1, jecs.pair(server.components.reliable, components[1]))
		world:set(entity1, components[1], "foo")

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end
		world:remove(entity1, server.components.networked)

		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_entity(member, entity1) == nil)
		end
		world:add(entity1, server.components.networked)
		world:remove(entity1, server.components.networked)
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_entity(member, entity1) == nil)
		end

		POST()
	end

	do
		CASE "should remove all data when component stops"
		PRE()

		local components = create_test_components(world)
		local tags = create_test_tags(world)
		server:init()

		local members = create_members_data(1)
		activate_members(members)
		init_member_clients(members)

		local entity1 = world:entity()
		world:add(entity1, server.components.networked)
		world:add(entity1, jecs.pair(server.components.reliable, components[1]))
		world:add(entity1, jecs.pair(server.components.reliable, tags[1]))
		world:add(entity1, jecs.pair(server.components.pair, tags[2]))

		local r1 = world:entity()
		local r2 = world:entity()
		world:add(r1, server.components.networked)
		world:add(r2, server.components.networked)

		world:set(entity1, components[1], "foo")
		world:add(entity1, tags[1])
		world:add(entity1, jecs.pair(tags[2], r1))
		world:add(entity1, jecs.pair(tags[2], r2))

		for _, member in members do
			local buf, variants = server:get_full(member :: any)
			member.client:apply_full(buf, variants)
		end
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
		end

		world:remove(entity1, jecs.pair(server.components.reliable, components[1]))
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_has_component(member, entity1, 1) == false)
			CHECK(client_tag(member, entity1, 1) == true)
			CHECK(client_pair(member, entity1, 2, r1) == true)
			CHECK(client_pair(member, entity1, 2, r2) == true)
		end

		world:remove(entity1, jecs.pair(server.components.reliable, tags[1]))
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_has_component(member, entity1, 1) == false)
			CHECK(client_tag(member, entity1, 1) == false)
			CHECK(client_pair(member, entity1, 2, r1) == true)
			CHECK(client_pair(member, entity1, 2, r2) == true)
		end

		world:remove(entity1, jecs.pair(server.components.pair, tags[2]))
		for player, buf, changes in server:collect_updates() do
			local member: MemberData = player :: any
			member.client:apply_updates(buf, changes)
			CHECK(client_entity(member, entity1) ~= nil)
			CHECK(client_has_component(member, entity1, 1) == false)
			CHECK(client_tag(member, entity1, 1) == false)
			CHECK(client_pair(member, entity1, 2, r1) == false)
			CHECK(client_pair(member, entity1, 2, r2) == false)
		end
	end
end)

return FINISH()
