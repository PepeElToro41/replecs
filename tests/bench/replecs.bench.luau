local replecs = require "@replecs"
local jecs = require "@pkg/jecs"
local testkit = require "@testkit"

local BENCH, START = testkit.benchmark()

function TITLE(str: string)
	print()
	print(testkit.color.white(str))
end

local AMOUNT = 2 ^ 17
local FILTER_AMOUNT = 200
local MEMBER_AMOUNT = 62

do
	TITLE "player masking"

	local world = jecs.world()
	local server = replecs.create_server(world)
	local masking = server.masking
	local entities = table.create(AMOUNT) :: { jecs.Entity }

	local function register_members(amount: number?)
		local members = {} :: { any }
		for i = 1, amount or MEMBER_AMOUNT do
			local member = "member" .. i
			masking:register_client(member)
			members[i] = member
		end
		return members
	end

	local members = register_members()

	local function write_storage_count()
		local count = 0
		for i in masking.storages do
			count += 1
		end
		print(testkit.color.green "storage count: " .. count)
	end

	local function POST()
		write_storage_count()
		server:destroy()
		server = replecs.create_server(world)
		masking = server.masking
		members = register_members()
	end

	local function activate_members()
		for member in masking.client_indexes do
			masking:activate_client(member)
		end
	end

	local function randomize_filter(members: { any }, bool: boolean?, amount: number?)
		local filter = {}
		bool = if bool == nil then true else bool
		for i = 1, amount or (#members / 2) do
			filter[members[math.random(1, #members)]] = bool
		end
		return filter
	end

	local function create_random_filters(bool: boolean?, amount: number?)
		local filters = table.create(amount or FILTER_AMOUNT) :: { { [any]: boolean } }
		for i = 1, amount or FILTER_AMOUNT do
			filters[i] = randomize_filter(members, bool)
		end
		return filters
	end

	local random_include_filters = create_random_filters(true, FILTER_AMOUNT)
	local random_exclude_filters = create_random_filters(false, FILTER_AMOUNT)

	for i = 1, AMOUNT do
		entities[i] = world:entity()
	end

	for i = 1, FILTER_AMOUNT do
		random_include_filters[i] = randomize_filter(members)
	end
	for i = 1, FILTER_AMOUNT do
		random_exclude_filters[i] = randomize_filter(members, false)
	end

	--[[do
		register_members()
		activate_members()

		BENCH("start entity with no filter", function()
			for i = 1, START(AMOUNT) do
				masking:start_entity(entities[i])
			end
		end)
		POST()
	end

	do
		activate_members()
		local filter = random_include_filters[1]

		BENCH("start entity with include filter", function()
			for i = 1, START(AMOUNT) do
				masking:start_entity(entities[i], filter)
			end
		end)
		POST()
	end

	do
		activate_members()
		local filter = random_include_filters[1]

		BENCH("start entity with exclude filter", function()
			for i = 1, START(AMOUNT) do
				masking:start_entity(entities[i], filter)
			end
		end)
		POST()
	end

	do
		activate_members()
		local component = world:component()
		local filter = random_include_filters[1]

		for i = 1, AMOUNT do
			masking:start_entity(entities[i], filter)
		end

		BENCH("component with no filter", function()
			for i = 1, START(AMOUNT) do
				masking:start_component(entities[i], component, 1)
			end
		end)
		POST()
	end
	do
		activate_members()
		local component = world:component()
		local filter = random_include_filters[1]

		for i = 1, AMOUNT do
			masking:start_entity(entities[i], filter)
		end

		BENCH("component with same filter as entity", function()
			for i = 1, START(AMOUNT) do
				masking:start_component(entities[i], component, 1, filter)
			end
		end)
		POST()
	end
	do
		activate_members()
		local component = world:component()
		local e_filter = random_include_filters[1]
		local c_filter = random_include_filters[2]

		for i = 1, AMOUNT do
			masking:start_entity(entities[i], e_filter)
		end

		BENCH("component with random filter", function()
			for i = 1, START(AMOUNT) do
				masking:start_component(entities[i], component, 1, c_filter)
			end
		end)
		POST()
	end
	do
		activate_members()

		BENCH("random entity filters (high fragmentation)", function()
			for i = 1, START(AMOUNT) do
				masking:start_entity(entities[i], random_include_filters[i % FILTER_AMOUNT])
			end
		end)
		POST()
	end

	do
		activate_members()
		local component = world:component()

		for i = 1, AMOUNT do
			masking:start_entity(entities[i])
		end

		BENCH("random component filters (high fragmentation)", function()
			for i = 1, START(AMOUNT) do
				masking:start_component(entities[i], component, 1, random_include_filters[i % FILTER_AMOUNT])
			end
		end)
		POST()
	end

	do
		activate_members()
		local component = world:component()
		local component_filters = create_random_filters(true, FILTER_AMOUNT)

		for i = 1, AMOUNT do
			masking:start_entity(entities[i], random_include_filters[i % FILTER_AMOUNT])
		end

		BENCH("random filters in both entity and component", function()
			for i = 1, START(AMOUNT) do
				masking:start_component(entities[i], component, 1, component_filters[i % FILTER_AMOUNT])
			end
		end)
		POST()
	end
    ]]
	do
		masking:activate_client(members[1])

		for i = 1, 10000 do
			masking:start_entity(entities[i], { [members[1]] = true })
		end

		BENCH("move 10,000 entities by activating a member", function()
			for i = 2, START(MEMBER_AMOUNT) do
				masking:activate_client(members[i])
			end
		end)
		POST()
	end
end

do
	TITLE "serialization"

	TITLE "deserialization"
end
