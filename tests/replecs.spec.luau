local ReplicatedStorage = game:GetService "ReplicatedStorage"
local replecs = require(ReplicatedStorage.replecs)
local player_masking = require(ReplicatedStorage.replecs.masking)
local utils = require(ReplicatedStorage.replecs.utils)
local jecs = require(ReplicatedStorage.roblox_packages.jecs)

local function table_size(t: {}): number
	local count = 0
	for _ in t do
		count += 1
	end
	return count
end

return function()
	local server: replecs.Server = nil :: any

	beforeEach(function()
		-- server = rejecs.create(world, "server").server
		-- server:init()
	end)
	afterEach(function()
		-- server:destroy()
	end)

	describe("bitmasking", function()
		it("should automatically expand", function()
			local mask = utils.bitmask.create(10)
			mask:set(5)

			expect(mask:get(5)).to.be.equal(true)
			mask:set(100)
			expect(mask:get(100)).to.be.equal(true)
			expect(mask:get(32)).to.be.equal(false)
			expect(mask:get(5)).to.be.equal(true)
		end)
		it("should get and set bits", function()
			local mask = utils.bitmask.create(100)
			mask:set(5)
			mask:set(33)
			mask:set(65)

			expect(mask:get(5)).to.be.equal(true)
			expect(mask:get(33)).to.be.equal(true)
			expect(mask:get(65)).to.be.equal(true)
			expect(mask:get(10)).to.be.equal(false)

			mask:clear(33)
			expect(mask:get(5)).to.be.equal(true)
			expect(mask:get(33)).to.be.equal(false)
			expect(mask:get(65)).to.be.equal(true)
		end)
		it("should correctly shift bits", function()
			local mask = utils.bitmask.create(100)
			mask:set(5)
			mask:set(40)
			mask:set(65)

			local left = mask:lshift(3)
			local right = mask:rshift(2)

			expect(left:get(5 + 3)).to.be.equal(true)
			expect(left:get(40 + 3)).to.be.equal(true)
			expect(left:get(65 + 3)).to.be.equal(true)
			expect(left:get(65)).to.be.equal(false)

			expect(right:get(5 - 2)).to.be.equal(true)
			expect(right:get(40 - 2)).to.be.equal(true)
			expect(right:get(65 - 2)).to.be.equal(true)
			expect(right:get(65)).to.be.equal(false)
		end)
		it("should correctly perform bitwise operations", function()
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
			expect(band:get(5)).to.be.equal(false)
			expect(band:get(10)).to.be.equal(true)
			expect(band:get(20)).to.be.equal(false)
			expect(band:get(40)).to.be.equal(true)
			expect(band:get(50)).to.be.equal(false)
			expect(band:get(65)).to.be.equal(false)

			local bor = mask1:bor(mask2)
			expect(bor:get(5)).to.be.equal(true)
			expect(bor:get(10)).to.be.equal(true)
			expect(bor:get(20)).to.be.equal(true)
			expect(bor:get(40)).to.be.equal(true)
			expect(bor:get(50)).to.be.equal(true)
			expect(bor:get(65)).to.be.equal(true)
			expect(bor:get(100)).to.be.equal(false)

			local bxor = mask1:bxor(mask2)
			expect(bxor:get(5)).to.be.equal(true)
			expect(bxor:get(10)).to.be.equal(false)
			expect(bxor:get(20)).to.be.equal(true)
			expect(bxor:get(40)).to.be.equal(false)
			expect(bxor:get(50)).to.be.equal(true)
			expect(bxor:get(65)).to.be.equal(true)
			expect(bxor:get(100)).to.be.equal(false)
		end)
		it("should return same string, independant of buffer capacity", function()
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

			expect(small:tostring()).to.be.equal(medium:tostring())
			expect(small:tostring()).to.be.equal(big:tostring())
			expect(medium:tostring()).to.be.equal(big:tostring())
			expect(empty:tostring()).to.be.equal ""
		end)
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

	describe("mask generators", function()
		local masking: player_masking.MaskingInternal = nil :: any

		beforeEach(function()
			masking = player_masking.create() :: player_masking.MaskingInternal
		end)

		it("should create a mask generator", function()
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
		end)
		it("should compute an include generator", function()
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
				called = called + 1
				expect(generator.bitmask:tostring()).to.be.equal(check_mask)
			end
			generator:run_subscribed()
			check_mask = mask_hash { 0 }
			masking:activate_member(m0)
			check_mask = mask_hash { 0, 3 }
			masking:activate_member(m3)
		end)
		it("should compute an exclude generator", function()
			local m0, m1, m2, m3 = register_members(masking)
			local generator = masking:create_exclude_generator {
				[m2] = true,
				[m1] = true,
			}

			local check_mask = ""
			local called = 0
			generator.subscribed = function()
				called = called + 1
				expect(generator.bitmask:tostring()).to.be.equal(check_mask)
			end
			check_mask = mask_hash { 0 }
			masking:activate_member(m0)
			check_mask = mask_hash { 0, 3 }
			masking:activate_member(m3)
			masking:activate_member(m2)
			masking:activate_member(m1)
			expect(called).to.be.equal(4)
		end)
		it("should destroy a generator", function()
			local m0, m1, m2, m3 = register_members(masking)

			local generator = masking:create_exclude_generator {
				[1] = true,
			}
			local called = 0
			generator.subscribed = function()
				called = called + 1
			end
			masking:activate_member(m0)
			generator:destroy()
			masking:activate_member(m1)
			masking:activate_member(m2)
			masking:activate_member(m3)
			expect(called).to.be.equal(1)
		end)
	end)

	describe("member bitmasking", function()
		local masking: player_masking.MaskingInternal = nil :: any
		local world: jecs.World = nil :: any

		beforeEach(function()
			masking = player_masking.create() :: player_masking.MaskingInternal
			world = jecs.world()
		end)

		afterEach(function()
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
					expect(real_component_count).to.be.equal(actives.component_count)
				end
				expect(real_active_count).to.be.equal(storage.active_count)
			end

			for hash, storage in masking.storages do
				for entity, components in storage.shared_with do
					for component_type, components in components do
						for component in components do
							local lookup = masking.lookups.components[entity][component_type][component]
							expect(lookup.storage_group).to.be.equal(storage)
						end
					end
				end
			end
		end)

		local function check_entity_mask(entity: jecs.Entity, hash: string)
			local storage = masking.storages[hash]
			local lookup = masking.lookups.entities[entity]

			expect(lookup).to.be.ok()
			expect(lookup.storage_group).to.be.equal(storage)

			expect(storage.active[entity]).to.be.ok()
			expect(storage.active[entity].is_entity_mask).to.be.ok()

			for check_hash, check_storage in masking.storages do
				if hash == check_hash then
					continue
				end

				if check_storage.active[entity] then
					expect(check_storage.active[entity].is_entity_mask).to.be.equal(false)
				end
			end
		end
		local function check_component_mask(entity: jecs.Entity, component: jecs.Entity, hash: string)
			local storage = masking.storages[hash]
			local lookup = masking.lookups.components[entity][1][component]

			expect(lookup).to.be.ok()
			expect(lookup.storage_group).to.be.equal(storage)

			expect(storage.active[entity]).to.be.ok()
			expect(storage.active[entity].components[1][component]).to.be.ok()

			expect(storage.shared_with[entity]).to.be.ok()
			expect(storage.shared_with[entity][1][component]).to.be.ok()

			for check_hash, check_storage in masking.storages do
				if hash == check_hash then
					continue
				end

				if check_storage.active[entity] then
					expect(check_storage.active[entity].components[1][component]).to.never.be.ok()
				end
				if check_storage.shared_with[entity] then
					expect(check_storage.shared_with[entity][1][component]).to.never.be.ok()
				end
			end
		end

		local function check_component_is_merged(entity: jecs.Entity, component: jecs.Entity<number>, hash: string)
			local entity_lookup = masking.lookups.entities[entity]
			if not entity_lookup then
				error "entity lookup not found"
			end

			expect(entity_lookup.storage_group).to.be.equal(masking.storages[hash])

			if masking.lookups.components[entity] then
				expect(masking.lookups.components[entity][1][component]).to.never.be.ok()
			end
			expect(entity_lookup.storage_group.active[entity].components[1][component]).to.be.ok()
			expect(entity_lookup.storage_group.active[entity].is_entity_mask).to.be.equal(true)

			for _, check_storage in masking.storages do
				if check_storage.shared_with[entity] then
					expect(check_storage.shared_with[entity][1][component]).to.never.be.ok()
				end
			end
		end

		local function check_component_is_not_active(entity: jecs.Entity, component: jecs.Entity<number>)
			local entities = masking.lookups.components[entity]
			if entities then
				expect(entities[1][component]).to.never.be.ok()
			end

			for hash, check_storage in masking.storages do
				if check_storage.shared_with[entity] then
					expect(check_storage.shared_with[entity][1][component]).to.never.be.ok()
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

		it("should use an entity filter", function()
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
		end)
		it("should change an entity filter", function()
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
		end)
		it("should use the replicated filter with no explicit filter", function()
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
		end)
		it("should use a component filter", function()
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
		end)
		it("should change a component filter", function()
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
		end)
		it("should use the entity filter if no component filter is given", function()
			local member0, member1, member2 = register_members(masking)
			active_all_members(masking)

			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>
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
		end)
		it("should run band in the entity bitmask for a component filter", function()
			local member0, member1, member2 = register_members(masking)
			active_all_members(masking)

			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>
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
		end)
		it("should pospone a component if entity is not active", function()
			local member0, member1, member2 = register_members(masking)
			active_all_members(masking)

			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>

			masking:start_component(entity, component, 1, {
				[member0] = true,
				[member1] = true,
			})
			check_component_is_not_active(entity, component)
			expect(masking.lookups.posponed[entity][1][component]).to.be.ok()

			masking:start_component(entity, component, 1, {
				[member0] = true,
			})
			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			check_component_mask(entity, component, mask_hash { 0 })
		end)
		it("should merge component with entity when the filter gets removed", function()
			local member0, member1, member2 = register_members(masking)
			active_all_members(masking)

			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>

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
		end)
		it("should merge components and entities when they share same mask", function(context)
			local member0, member1, member2 = register_members(masking)
			active_all_members(masking)

			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>

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
		end)
		it("should dissect components from entities when they no longer share same mask", function(context)
			local member0, member1, member2 = register_members(masking)
			active_all_members(masking)

			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>

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
		end)
		it("should stop an entity", function() end)
		it("should stop a component", function() end)
		it("should be able to apply the same filter to an entity", function() end)
		it("should be able to apply the same filter to a component", function() end)
		it("should merge two masks correctly", function() end)
		it("should pospone all components when an entity stops", function() end)
	end)

	describeSKIP("player filtering bitmasking old", function()
		local masking: player_masking.MaskingInternal = nil :: any
		local world: jecs.World = nil :: any

		beforeEach(function()
			masking = player_masking.create() :: player_masking.MaskingInternal
			world = jecs.world()
		end)

		local function check_component_in(
			entity: jecs.Entity,
			component: jecs.Entity,
			component_type: number,
			hash: string
		)
			local mask = masking.active_masks[hash]
			local active_mask = mask.active[entity]
			expect(active_mask).to.be.ok()
			expect(active_mask.components[component_type][component]).to.be.ok()
			expect(masking.lookup_list.components[entity][component_type][component]).to.be.ok()
			expect(masking.lookup_list.components[entity][component_type][component].mask_storage).to.be.equal(
				masking.active_masks[hash]
			)
			expect(masking.lookup_list.components[entity][component_type][component].active_entity).to.be.equal(
				masking.active_masks[hash].active[entity]
			)

			local entity_lookup = masking.lookup_list.entities[entity]
			if entity_lookup then
				if entity_lookup.mask_storage ~= mask then
					local active = entity_lookup.mask_storage.active[entity]
					if active then
						expect(active.components[component_type][component]).to.never.be.ok()
					end
				end
			end
		end
		local function check_entity_in(entity: jecs.Entity, hash: string)
			expect(masking.active_masks[hash].active[entity]).to.be.ok()
			expect(masking.lookup_list.entities[entity]).to.be.ok()
			expect(masking.lookup_list.entities[entity].mask_storage).to.be.equal(masking.active_masks[hash])
			expect(masking.lookup_list.entities[entity].active_entity).to.be.equal(
				masking.active_masks[hash].active[entity]
			)
		end

		local function check_component_is_merged(
			entity: jecs.Entity,
			component: jecs.Entity<number>,
			component_type: number
		)
			local entity_lookup = masking.lookup_list.entities[entity]

			if masking.lookup_list.components[entity] then
				local components = masking.lookup_list.components[entity][component_type]
				if components then
					expect(components[component]).to.never.be.ok()
				end
			end
			expect(entity_lookup.mask_storage.active[entity].components[component_type][component]).to.be.ok()
		end

		local function check_entity_not_in(entity: jecs.Entity, hash: string)
			local lookup = masking.lookup_list.entities[entity]
			if not lookup then
				return
			end
			expect(lookup.mask_storage).to.never.be.equal(masking.active_masks[hash])
		end

		local function check_component_not_in(
			entity: jecs.Entity,
			component: jecs.Entity,
			component_type: number,
			hash: string
		)
			local mask = masking.active_masks[hash]
			if not mask then
				return
			end
			local active_mask = mask.active[entity]
			if not active_mask then
				return
			end
			expect(active_mask.components[component_type][component]).to.never.be.ok()
		end

		local function add_members()
			local member0 = newproxy()
			local member1 = newproxy()
			local member2 = newproxy()
			local member3 = newproxy()

			masking:add_member(member0)
			masking:add_member(member1)
			masking:add_member(member2)
			masking:add_member(member3)
			return member0, member1, member2, member3
		end
		local function mask_hash(members: { number })
			local bitmask = utils.bitmask.create(3)
			for _, member in members do
				bitmask:set(member)
			end
			return bitmask:tostring()
		end
		it("should be able to add members to bitmask index", function()
			local member0, member1, member2, member3 = add_members()
			expect(masking.player_index_count).to.be.equal(4)
			expect(masking.player_indexes[member0]).to.be.equal(0)
			expect(masking.player_indexes[member1]).to.be.equal(1)
			expect(masking.player_indexes[member2]).to.be.equal(2)
			expect(masking.player_indexes[member3]).to.be.equal(3)
		end)
		it("should use replicated filter if no entity filter is given", function()
			local member0, member1, member2 = add_members()
			local entity = world:entity()
			local component = world:component()

			masking:set_replicated_member(member0)
			masking:set_replicated_member(member1)
			masking:start_entity(entity, nil)
			masking:start_component(entity, component, 1, nil)

			local entity_hash1 = mask_hash { 0, 1 }
			check_entity_in(entity, entity_hash1)
			expect(table_size(masking.active_masks)).to.be.equal(1)
			local entity_hash2 = mask_hash { 0, 1, 2 }

			masking:set_replicated_member(member2)
			check_entity_in(entity, entity_hash2)
			expect(table_size(masking.active_masks)).to.be.equal(1)
		end)
		it("should start an entity with filter", function()
			local member0, _, member2 = add_members()
			local entity = world:entity()
			masking:start_entity(entity, {
				[member0] = true,
				[member2] = true,
			})
			local set_hash = mask_hash { 0, 2 }
			check_entity_in(entity, set_hash)
		end)
		it("should change an entity filter", function()
			local member0, member1, member2 = add_members()
			local entity = world:entity()
			masking:start_entity(entity, {
				[member0] = true,
				[member2] = true,
			})
			masking:set_entity(entity, {
				[member1] = true,
			})
			local start_hash = mask_hash { 0, 2 }
			local changed_hash = mask_hash { 1 }

			check_entity_in(entity, changed_hash)
			check_entity_not_in(entity, start_hash)
			expect(table_size(masking.active_masks)).to.be.equal(1)
		end)
		it("should start a component with filter", function()
			local member0, member1, member2 = add_members()
			local entity = world:entity()
			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			local component = world:component() :: jecs.Entity<number>
			masking:start_component(entity, component, 1, {
				[member1] = true,
			})
			local component_hash = mask_hash { 1 }
			check_component_in(entity, component, 1, component_hash)
			expect(table_size(masking.active_masks)).to.be.equal(2)
		end)
		it("should change a component filter", function()
			local member0, member1, member2 = add_members()
			local entity = world:entity()
			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			local component = world:component() :: jecs.Entity<number>
			masking:start_component(entity, component, 1, {
				[member1] = true,
			})
			expect(table_size(masking.active_masks)).to.be.equal(2)
			masking:set_component(entity, component, 1, {
				[member2] = true,
			})
			local component_hash = mask_hash { 1 }
			local component_changed_hash = mask_hash { 2 }

			check_component_in(entity, component, 1, component_changed_hash)
			check_component_not_in(entity, component, 1, component_hash)
			expect(table_size(masking.active_masks)).to.be.equal(2)
		end)
		it("should use the entity filter if no component filter is given", function()
			local member0, member1, member2 = add_members()
			local entity = world:entity()
			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			local component = world:component() :: jecs.Entity<number>
			masking:start_component(entity, component, 1, nil)

			check_component_is_merged(entity, component, 1)
			expect(table_size(masking.active_masks)).to.be.equal(1)
		end)
		it("should merge component mask to entity if filter is removed", function()
			local member0, member1, member2 = add_members()
			local entity = world:entity()
			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			local component = world:component() :: jecs.Entity<number>
			masking:start_component(entity, component, 1, {
				[member1] = true,
			})
			expect(table_size(masking.active_masks)).to.be.equal(2)
			check_component_in(entity, component, 1, mask_hash { 1 })
			masking:set_component(entity, component, 1, nil)
			local entity_hash = mask_hash { 0, 1, 2 }
			local component_hash = mask_hash { 1 }

			check_entity_in(entity, entity_hash)
			check_component_not_in(entity, component, 1, component_hash)
			check_component_is_merged(entity, component, 1)
			expect(table_size(masking.active_masks)).to.be.equal(1)
		end)
		it("should compute component mask with band of entity mask", function()
			local member0, member1, member2, member3 = add_members()
			local entity = world:entity()
			masking:start_entity(entity, {
				[member0] = true,
				----------------
				[member2] = true,
				[member3] = true,
			})
			local component = world:component() :: jecs.Entity<number>
			masking:start_component(entity, component, 1, {
				[member1] = true, -- should ignore this
				[member2] = true,
			})

			local component_hash = mask_hash { 1, 2 }
			local component_band_hash = mask_hash { 2 }

			check_component_in(entity, component, 1, component_band_hash)
			check_component_not_in(entity, component, 1, component_hash)
			expect(table_size(masking.active_masks)).to.be.equal(2)
		end)
		it("should recompute band of component when entity filter changes", function()
			local member0, member1, member2, member3 = add_members()
			local entity = world:entity()
			masking:start_entity(entity, {
				[member0] = true,
				----------------
				[member2] = true,
				[member3] = true,
			})
			local component = world:component() :: jecs.Entity<number>
			masking:start_component(entity, component, 1, {
				[member1] = true, -- should ignore this
				[member2] = true,
			})

			local component_hash = mask_hash { 1, 2 }
			local component_band_hash = mask_hash { 2 }
			check_component_in(entity, component, 1, component_band_hash)
			check_component_not_in(entity, component, 1, component_hash)
			expect(table_size(masking.active_masks)).to.be.equal(2)

			masking:set_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
				[member3] = true,
			})
			check_component_in(entity, component, 1, component_hash)
			expect(table_size(masking.active_masks)).to.be.equal(2)
			-- this would make the component bitmask empty
			masking:set_entity(entity, {
				[member0] = true,
			})

			-- empty string: a mask that has no members
			check_component_in(entity, component, 1, "")
			check_component_not_in(entity, component, 1, component_band_hash)
			check_component_not_in(entity, component, 1, component_hash)
			expect(table_size(masking.active_masks)).to.be.equal(2)
		end)
		it("should merge entities and components that share masks", function()
			local member0, member1 = add_members()
			local entity = world:entity()
			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
			})
			local component = world:component() :: jecs.Entity<number>
			masking:start_component(entity, component, 1, {
				[member0] = true,
			})
			local component_hash = mask_hash { 0 }
			check_component_in(entity, component, 1, component_hash)

			masking:set_component(entity, component, 1, {
				[member0] = true,
				[member1] = true,
			})

			local both_hash = mask_hash { 0, 1 }
			check_entity_in(entity, both_hash)
			check_component_in(entity, component, 1, both_hash)
			expect(table_size(masking.active_masks)).to.be.equal(1)
		end)
		it("should separate components that shared same mask when no longer do", function()
			local member0, member1, member2 = add_members()
			local entity = world:entity()
			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
			})
			local component = world:component() :: jecs.Entity<number>
			masking:start_component(entity, component, 1, {
				[member0] = true,
				[member1] = true,
			})
			local both_hash = mask_hash { 0, 1 }
			check_component_in(entity, component, 1, both_hash)
			check_entity_in(entity, both_hash)
			expect(table_size(masking.active_masks)).to.be.equal(1)

			masking:set_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			local entity_hash = mask_hash { 0, 1, 2 }

			check_entity_not_in(entity, both_hash)
			check_component_in(entity, component, 1, both_hash)
			check_component_not_in(entity, component, 1, entity_hash)
			expect(table_size(masking.active_masks)).to.be.equal(2)
		end)
		it("should pospone a component if entity is not active", function()
			local member0, member1, member2 = add_members()

			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>
			masking:start_component(entity, component, 1, {
				[member0] = true,
				[member1] = true,
			})
			local component_hash = mask_hash { 0, 1 }

			expect(table_size(masking.active_masks)).to.be.equal(0)
			expect(masking.active_masks[mask_hash { 0, 1 }]).to.never.be.ok()
			check_component_not_in(entity, component, 1, component_hash)

			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			check_component_in(entity, component, 1, component_hash)
			expect(table_size(masking.active_masks)).to.be.equal(2)
		end)
		it("should update posponed component filters", function()
			local member0, member1, member2, member4 = add_members()
			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>
			masking:start_component(entity, component, 1, {
				[member0] = true,
				[member1] = true,
			})
			local component_hash = mask_hash { 0, 1 }
			local component_hash2 = mask_hash { 2 }

			masking:set_component(entity, component, 1, {
				[member2] = true,
			})
			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			check_component_in(entity, component, 1, component_hash2)
			check_component_not_in(entity, component, 1, component_hash)
			expect(table_size(masking.active_masks)).to.be.equal(2)
		end)
		it("should stop a component", function()
			local member0, member1, member2 = add_members()
			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>

			local component_hash = mask_hash { 0, 1 }

			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			masking:start_component(entity, component, 1, {
				[member0] = true,
				[member1] = true,
			})
			check_component_in(entity, component, 1, component_hash)
			expect(table_size(masking.active_masks)).to.be.equal(2)

			check_component_in(entity, component, 1, component_hash)
			masking:stop_component(entity, component, 1)
			check_component_not_in(entity, component, 1, component_hash)
			expect(masking.lookup_list.components[entity][1][component]).to.never.be.ok()
			expect(table_size(masking.active_masks)).to.be.equal(1)
		end)
		it("should stop an entity", function()
			local member0, member1, member2 = add_members()
			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>

			local component_hash = mask_hash { 0, 1 }
			local entity_hash = mask_hash { 0, 1, 2 }

			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			masking:start_component(entity, component, 1, {
				[member0] = true,
				[member1] = true,
			})
			masking:stop_entity(entity)

			expect(masking.active_masks[component_hash].active[entity]).to.never.be.ok()
			expect(masking.active_masks[entity_hash].active[entity]).to.never.be.ok()
			expect(masking.lookup_list.entities[entity]).to.never.be.ok()
			expect(masking.lookup_list.components[entity]).to.never.be.ok()
		end)
		it("should pospone components again when the entity is stopped", function()
			local member0, member1, member2 = add_members()
			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>

			local component_hash = mask_hash { 0, 1 }
			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			masking:start_component(entity, component, 1, {
				[member0] = true,
				[member1] = true,
			})
			check_component_in(entity, component, 1, component_hash)
			expect(masking.active_masks[component_hash].active[entity].components[1][component]).to.be.ok()
			masking:stop_entity(entity)
			expect(masking.active_masks[component_hash].active[entity]).to.never.be.ok()
			expect(masking.lookup_list.components[entity]).to.never.be.ok()
			expect(masking.lookup_list.posponed[entity]).to.be.ok()
			expect(masking.lookup_list.posponed[entity][1][component]).to.be.ok()

			masking:start_entity(entity, {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			})
			check_component_in(entity, component, 1, component_hash)
		end)
		it("should handle mask collisions between entities and components", function()
			local member0, member1, member2, member3 = add_members()
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
			print(masking.active_masks)

			check_entity_in(entity, mask_hash { 0, 1, 2, 3 })
			check_component_in(entity, component, 1, mask_hash { 0, 1 })

			masking:set_entity(entity, {
				[member0] = true,
				[member1] = true,
			})
			print(masking.active_masks)
			check_entity_in(entity, mask_hash { 0, 1 })
			check_component_in(entity, component, 1, mask_hash { 0, 1 })
		end)
		it("should handle same filters correctly for entities", function()
			local member0, member1, member2 = add_members()
			local entity1 = world:entity()
			local filter = {
				[member0] = true,
				[member1] = true,
				[member2] = true,
			}
			local entity_hash = mask_hash { 0, 1, 2 }
			masking:start_entity(entity1, filter)
			check_entity_in(entity1, entity_hash)
			masking:set_entity(entity1, table.clone(filter))

			check_entity_in(entity1, entity_hash)

			local entity2 = world:entity()
			masking:start_entity(entity2, nil)
			check_entity_in(entity2, "")
			masking:set_entity(entity2, nil)
			check_entity_in(entity2, "")
		end)
		it("should handle same filters correctly for components", function()
			local member0, member1, member2 = add_members()
			local entity = world:entity()
			local component = world:component()
			local filter = {
				[member0] = true, -- shared
				[member1] = true,
			}
			local component_filter = {
				[member0] = true, -- shared
				[member2] = true,
			}
			local component_hash = mask_hash { 0 }
			masking:start_entity(entity, filter)
			masking:start_component(entity, component, 1, component_filter)
			check_component_in(entity, component, 1, component_hash)
			masking:set_component(entity, component, 1, component_filter)
			check_component_in(entity, component, 1, component_hash)
			masking:set_component(entity, component, 1, component_filter)
			check_component_in(entity, component, 1, component_hash)

			print(masking.active_masks)

			masking:set_component(entity, component, 1, nil)
			check_component_is_merged(entity, component, 1)
			masking:set_component(entity, component, 1, nil)
			check_component_is_merged(entity, component, 1)
		end)
		it("should merge masks correctly", function() end)
	end)

	describe("server", function()
		itSKIP("should create a lookup of shared components", function() end)
		-- NETWORK
		it("should detect network additions", function()
			local entity1 = world:entity()
			local entity2 = world:entity()

			world:add(entity1, server.components.networked)
			world:add(entity2, server.components.networked)

			expect(server.changes.added[entity1]).to.be.ok()
			expect(server.changes.added[entity2]).to.be.ok()
			expect(table_size(server.changes.added)).to.be.equal(2)
		end)
		it("should detect network removals", function()
			local entity1 = world:entity()
			local entity2 = world:entity()

			world:add(entity1, server.components.networked)
			world:add(entity2, server.components.networked)

			expect(server.changes.added[entity2]).to.be.ok()
			world:remove(entity2, server.components.networked)
			expect(server.changes.added[entity2]).to.never.be.ok()
			expect(table_size(server.changes.added)).to.be.equal(1)
		end)
		-- FULL STORAGE
		it("should storage reliably tracked components", function()
			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>

			world:set(entity, component, 1)
			world:add(entity, jecs.pair(server.components.reliable, component))

			expect(server.storage[entity].values[component]).to.be.equal(1)
			world:set(entity, component, 2)
			expect(server.storage[entity].values[component]).to.be.equal(2)
			expect(table_size(server.storage[entity].values)).to.be.equal(1)
		end)
		it("should storage reliably tracked tag separately", function()
			local entity = world:entity()
			local tag = world:entity()

			world:add(entity, jecs.pair(server.components.reliable, tag))
			expect(server.storage[entity].tags[tag]).to.be.ok()
			expect(server.storage[entity].values[tag]).to.never.be.ok()
		end)
		it("should storage reliably tracked pairs", function()
			local entity = world:entity()
			local relation = world:entity()
			local target = world:entity()

			world:add(entity, jecs.pair(server.components.pair, relation))

			world:add(entity, jecs.pair(relation, target))
			expect(server.storage[entity].pairs[relation]).to.be.equal(target)
			expect(table_size(server.storage[entity].pairs)).to.be.equal(1)
		end)
		it("should clear component storage when reliable relation is removed", function()
			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>

			world:set(entity, component, 1)
			world:add(entity, jecs.pair(server.components.reliable, component))

			world:remove(entity, jecs.pair(server.components.reliable, component))
			expect(server.storage[entity].values[component]).to.never.be.ok()
		end)
		it("should clear tag storage when reliable relation is removed", function()
			local entity = world:entity()
			local tag = world:entity()

			world:add(entity, jecs.pair(server.components.reliable, tag))
			world:remove(entity, jecs.pair(server.components.reliable, tag))
			expect(server.storage[entity].tags[tag]).to.never.be.ok()
		end)
		it("should clear pair storage when reliable relation is removed", function()
			local entity = world:entity()
			local relation = world:entity()
			local target = world:entity()

			world:add(entity, jecs.pair(server.components.pair, relation))
			world:add(entity, jecs.pair(relation, target))
			world:remove(entity, jecs.pair(server.components.pair, relation))
			expect(server.storage[entity].pairs[relation]).to.never.be.ok()
			expect(table_size(server.storage[entity].pairs)).to.be.equal(0)
		end)
		-- CHANGES
		it("should detect changes to reliably replicated components", function()
			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>
			world:add(entity, server.components.networked)
			server.changes.added[entity] = nil -- added will block changes

			world:set(entity, component, 1)
			world:add(entity, jecs.pair(server.components.reliable, component))
			world:set(entity, component, 2)

			expect(server.changes.changed[entity].component[component]).to.be.equal(2)
			world:set(entity, component, 3)
			expect(server.changes.changed[entity].component[component]).to.be.equal(3)
		end)
		it("should detect changes to reliably replicated tags", function()
			local entity = world:entity()
			local tag = world:entity()
			world:add(entity, server.components.networked)
			server.changes.added[entity] = nil -- added will block changes

			world:add(entity, jecs.pair(server.components.reliable, tag))
			world:add(entity, tag)

			expect(server.changes.changed[entity].tagged[tag]).to.be.ok()
			expect(server.changes.changed[entity].component).to.never.be.ok()
			world:remove(entity, tag)
			expect(server.changes.changed[entity].tagged[tag]).to.never.be.ok()
		end)
		it("should detect changes to reliably replicated pairs", function()
			local entity = world:entity()
			local relation = world:entity()
			world:add(entity, server.components.networked)
			server.changes.added[entity] = nil -- added will block changes

			local target1 = world:entity()
			local target2 = world:entity()

			world:add(entity, jecs.pair(server.components.pair, relation))
			world:add(entity, jecs.pair(relation, target1))

			expect(server.changes.changed[entity].pairs[relation]).to.be.equal(target1)

			world:remove(entity, jecs.pair(relation, target1))
			expect(server.changes.changed[entity].pairs[relation]).to.never.be.equal()
			world:add(entity, jecs.pair(relation, target2))
			expect(server.changes.changed[entity].pairs[relation]).to.be.equal(target2)
		end)
		it("should omit changes for added entities", function()
			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>
			world:add(entity, server.components.networked)
			server.changes.added[entity] = true

			world:add(entity, jecs.pair(server.components.reliable, component))
			world:set(entity, component, 1)

			expect(server.changes.changed[entity]).to.never.be.ok()
		end)
		it("should omit changes for non networked entities", function()
			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>

			world:add(entity, jecs.pair(server.components.reliable, component))
			world:set(entity, component, 1)

			expect(server.changes.changed[entity]).to.never.be.ok()
		end)
		it("should delete changes when the entity is removed", function()
			local entity = world:entity()
			local component = world:component() :: jecs.Entity<number>
			world:add(entity, server.components.networked)
			server.changes.added[entity] = nil -- unlocks changes

			world:add(entity, jecs.pair(server.components.reliable, component))
			world:set(entity, component, 1)

			expect(server.changes.changed[entity].component[component]).to.be.equal(1)

			world:remove(entity, server.components.networked)
			expect(server.changes.changed[entity]).to.never.be.ok()
		end)
	end)
end
