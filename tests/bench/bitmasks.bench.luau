--!optimize 2

local bitmasks = require "../../src/server/bitmasks"
local bench = require "./bench"

local BITS = 256
local ITERATIONS = 2 ^ 16

math.randomseed(42)

local function create_mask_with_density(bits: number, set_amount: number): (buffer, number)
	local mask = buffer.create(bitmasks.get_buffer_size(bits))
	local set_count = 0
	while set_count < set_amount do
		local index = math.random(0, bits - 1)
		if not bitmasks.test(mask, index) then
			bitmasks.set(mask, index)
			set_count += 1
		end
	end
	return mask, set_count
end

-- baseline: test every index 0..bits-1
@native
local function iter_naive(mask: buffer, bits: number, callback: (index: number) -> ())
	for index = 0, bits - 1 do
		if bitmasks.test(mask, index) then
			callback(index)
		end
	end
end

local sink = 0
local function consume(index: number)
	sink += index
end

local densities = {
	{ name = "empty", amount = 0 },
	{ name = "sparse (8/256)", amount = 8 },
	{ name = "sparse (32/256)", amount = 32 },
	{ name = "half (128/256)", amount = 128 },
	{ name = "full (256/256)", amount = 256 },
}

do
	bench.title "bitmask iter_set (256 bits)"

	for _, density in densities do
		local mask = create_mask_with_density(BITS, density.amount)

		-- sanity: both iterators must visit the same bits
		local expected, got = 0, 0
		iter_naive(mask, BITS, function(index)
			expected += index + 1
		end)
		bitmasks.iter_set(mask, function(index)
			got += index + 1
		end)
		assert(expected == got, "iter_set mismatch at density " .. density.name)

		bench.run("iter_set " .. density.name, ITERATIONS, function()
			bitmasks.iter_set(mask, consume)
		end)
		bench.run("naive test-per-index " .. density.name, ITERATIONS, function()
			iter_naive(mask, BITS, consume)
		end)
	end
end

-- keep `sink` alive so the callback body isn't dead-code eliminated
print("\nsink:", sink)
