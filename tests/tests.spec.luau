local masking_controller = require "@replecs/masking-new"

local jecs = require "@pkg/jecs"
local testlib = require "./testlib"

local plan = testlib.plan()
local expect = testlib.expect

local TEST, CASE = plan.TEST, plan.CASE
local SKIP, FOCUS = plan.SKIP, plan.FOCUS
local BEFORE_EACH, AFTER_EACH = plan.BEFORE_EACH, plan.AFTER_EACH
local CHECK = assert

TEST("masking controller", function()
	local masking: masking_controller.MaskingController

	local function reset_deltas(entity: any)
		masking.lookups_list.filter_deltas.entities[entity] = nil
	end

	BEFORE_EACH(function()
		masking = masking_controller.create(32)
	end)

	CASE("test", function()
		buffer.writeu32(masking.active_members_bitmask, 0, bit32.bnot(0))

		local entity: any = 10

		local filter = buffer.create(32)
		buffer.writeu32(filter, 0, 0b0_1110)

		masking.start_entity_bitmask(masking, entity, filter, true)
		reset_deltas(entity)

		buffer.writeu32(filter, 0, 0b0_0111)
		masking.set_entity_bitmask(masking, entity, filter, true)

		print("add: " .. masking.hash_bitmask(masking.lookups_list.filter_deltas.entities[entity].added))
		print("rem: " .. masking.hash_bitmask(masking.lookups_list.filter_deltas.entities[entity].removed))

		masking.stop_entity(masking, entity)

		print("add: " .. masking.hash_bitmask(masking.lookups_list.filter_deltas.entities[entity].added))
		print("rem: " .. masking.hash_bitmask(masking.lookups_list.filter_deltas.entities[entity].removed))

		buffer.writeu32(filter, 0, 0b0_0110)

		masking.start_entity_bitmask(masking, entity, filter, true)

		print("add: " .. masking.hash_bitmask(masking.lookups_list.filter_deltas.entities[entity].added))
		print("rem: " .. masking.hash_bitmask(masking.lookups_list.filter_deltas.entities[entity].removed))

		buffer.writeu32(filter, 0, 0b0_11011)

		masking.set_entity_bitmask(masking, entity, filter, true)

		print("add: " .. masking.hash_bitmask(masking.lookups_list.filter_deltas.entities[entity].added))
		print("rem: " .. masking.hash_bitmask(masking.lookups_list.filter_deltas.entities[entity].removed))
	end)
end)

local report = testlib.run(plan)
testlib.report(report)
