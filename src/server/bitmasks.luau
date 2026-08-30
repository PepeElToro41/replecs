--!optimize 2

type Bitmask = buffer

local BITS_PER_ENTRY = 32
local BYTES_PER_ENTRY = 4

@native
local function to_binary(n: number): string
	local result = ""
	while n > 0 do
		result = (n % 2) .. result
		n = math.floor(n / 2)
	end
	return string.rep("0", 32 - #result) .. result
end

@native
local function bitmask_read_entry(bitmask: Bitmask, len: number, offset: number)
	if offset >= len then
		return 0
	else
		return buffer.readu32(bitmask, offset)
	end
end

@native
local function bitmasks_band(a: Bitmask, b: Bitmask, output: Bitmask)
	local len_a = buffer.len(a)
	local len_b = buffer.len(b)
	local len_min = math.min(len_a, len_b)

	for offset = 0, buffer.len(output) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		if offset >= len_min then
			buffer.writeu32(output, offset, 0)
		else
			local a_val = buffer.readu32(a, offset)
			local b_val = buffer.readu32(b, offset)
			buffer.writeu32(output, offset, bit32.band(a_val, b_val))
		end
	end
end

@native
local function bitmasks_bor(a: Bitmask, b: Bitmask, output: Bitmask)
	local len_a = buffer.len(a)
	local len_b = buffer.len(b)

	for offset = 0, buffer.len(output) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		local a_val = if offset >= len_a then 0 else buffer.readu32(a, offset)
		local b_val = if offset >= len_b then 0 else buffer.readu32(b, offset)
		buffer.writeu32(output, offset, bit32.bor(a_val, b_val))
	end
end

@native
local function bitmasks_read_entry(bitmask: Bitmask, len: number, offset: number)
	if offset >= len then
		return 0
	else
		return buffer.readu32(bitmask, offset)
	end
end

@native
local function bitmasks_get_index(index: number): (number, number)
	local entry_index = math.floor(index / BITS_PER_ENTRY)
	local bit_position = index % BITS_PER_ENTRY
	return entry_index, bit_position
end

@native
local function bitmasks_set(bitmask: Bitmask, index: number)
	local entry, offset = bitmasks_get_index(index)
	local buffer_offset = entry * BYTES_PER_ENTRY
	local len = buffer.len(bitmask)
	if buffer_offset >= len then
		return
	end

	local current = buffer.readu32(bitmask, buffer_offset)
	local mask = bit32.lshift(1, offset)
	buffer.writeu32(bitmask, buffer_offset, bit32.bor(current, mask))
end

@native
local function bitmasks_reset(bitmask: Bitmask, index: number)
	local entry, offset = bitmasks_get_index(index)
	local buffer_offset = entry * BYTES_PER_ENTRY
	local len = buffer.len(bitmask)
	if buffer_offset >= len then
		return
	end

	local current = buffer.readu32(bitmask, buffer_offset)
	local mask = bit32.bnot(bit32.lshift(1, offset))
	buffer.writeu32(bitmask, buffer_offset, bit32.band(current, mask))
end

@native
local function bitmasks_test(bitmask: Bitmask, index: number): boolean
	local entry, offset = bitmasks_get_index(index)
	local buffer_offset = entry * BYTES_PER_ENTRY

	local len = buffer.len(bitmask)
	if buffer_offset >= len then
		return false
	end

	local current = buffer.readu32(bitmask, buffer_offset)
	local value = bit32.band(bit32.rshift(current, offset), 1)
	return value == 1
end

@native
local function bitmasks_exclude(base: Bitmask, exclude: Bitmask, output: Bitmask)
	local len_base = buffer.len(base)
	local len_exclude = buffer.len(exclude)

	for offset = 0, buffer.len(output) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		local base_val = bitmasks_read_entry(base, len_base, offset)
		local exclude_val = bitmasks_read_entry(exclude, len_exclude, offset)
		buffer.writeu32(output, offset, bit32.band(base_val, bit32.bnot(exclude_val)))
	end
end

-- clones the buffer into a draft
@native
local function bitmasks_load(source: Bitmask, target: Bitmask)
	local source_len = buffer.len(source)
	local target_len = buffer.len(target)

	buffer.copy(target, 0, source, 0)
	local difference = target_len - source_len
	if difference > 0 then
		buffer.fill(target, source_len, 0, difference)
	end
end

-- clones the buffer into a draft
@native
local function bitmasks_clear(bitmask: Bitmask)
	buffer.fill(bitmask, 0, 0)
end

local function bitmasks_clone(template: Bitmask, size: number?)
	local buf_len = buffer.len(template)
	local cloned = buffer.create((size and math.max(size, buf_len)) or buf_len)
	buffer.copy(cloned, 0, template, 0)
	return cloned
end

@native
local function bitmask_hash(bitmask: Bitmask)
	local highest_entry = -1

	for i = buffer.len(bitmask) - BYTES_PER_ENTRY, 0, -BYTES_PER_ENTRY do
		local value = buffer.readu32(bitmask, i)
		if value ~= 0 then
			highest_entry = i
			break
		end
	end

	if highest_entry == -1 then
		return ""
	end

	if true then
		-- raw bytes as the key; trailing zero entries are trimmed so equal bit
		-- sets hash the same regardless of buffer size
		return buffer.readstring(bitmask, 0, highest_entry + BYTES_PER_ENTRY)
	else
		-- enable this to stringify to binary, easier to debug, but slower

		local hash_str = ""
		for i = 0, highest_entry, BYTES_PER_ENTRY do
			hash_str = hash_str .. to_binary(buffer.readu32(bitmask, i))
		end

		return hash_str
	end
end

-- u32 with every bit set except `index`'s; precalculate once, then
-- punch_hole_mask any number of bitmasks with it
@native
local function bitmask_get_hole_mask(index: number): number
	local _, bit_position = bitmasks_get_index(index)
	return bit32.bnot(bit32.lshift(1, bit_position))
end

-- bands the entry holding `index` with a precalculated u32 hole mask,
-- single read + band + write; masks too short to hold the index are skipped
@native
local function bitmask_punch_hole_mask(bitmask: Bitmask, mask: number, index: number)
	local entry = math.floor(index / BITS_PER_ENTRY)
	local buffer_offset = entry * BYTES_PER_ENTRY
	if buffer_offset >= buffer.len(bitmask) then
		return
	end

	local current = buffer.readu32(bitmask, buffer_offset)
	buffer.writeu32(bitmask, buffer_offset, bit32.band(current, mask))
end

-- calls `callback` with the index of every set bit; zero words are skipped and
-- the inner loop runs once per set bit (countrz + clear-lowest-bit)
@native
local function bitmask_iter_set(bitmask: Bitmask, callback: (index: number) -> ())
	for offset = 0, buffer.len(bitmask) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		local word = buffer.readu32(bitmask, offset)
		local base = offset * 8 -- byte offset * 8 = bit index of entry start

		while word ~= 0 do
			callback(base + bit32.countrz(word))
			word = bit32.band(word, word - 1)
		end
	end
end

export type BitmaskDeltas = {
	added: Bitmask,
	removed: Bitmask,
}

@native
local function load_bitmask_deltas(deltas: BitmaskDeltas)
	buffer.fill(deltas.added, 0, 0)
	buffer.fill(deltas.removed, 0, 0)
end

@native
local function calculate_bitmask_deltas(last: Bitmask, target: Bitmask, output: BitmaskDeltas)
	local len_last = buffer.len(last)
	local len_target = buffer.len(target)
	local added = output.added
	local removed = output.removed

	-- we asume the output have been loaded, this means it has been cleared
	local len_added = buffer.len(added)
	local len_removed = buffer.len(removed)

	for offset = 0, math.max(len_added, len_removed) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		local last_val = bitmask_read_entry(last, len_last, offset)
		local target_val = bitmask_read_entry(target, len_target, offset)

		local added_delta = bit32.band(target_val, bit32.bnot(last_val))
		local removed_delta = bit32.band(last_val, bit32.bnot(target_val))

		buffer.writeu32(added, offset, added_delta)
		buffer.writeu32(removed, offset, removed_delta)
	end
end

@native
local function bitmask_equals(a: Bitmask, b: Bitmask): boolean
	local len_a = buffer.len(a)
	local len_b = buffer.len(b)

	for offset = 0, math.max(len_a, len_b) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		if bitmasks_read_entry(a, len_a, offset) ~= bitmasks_read_entry(b, len_b, offset) then
			return false
		end
	end
	return true
end

@native
local function bitmask_is_empty(bitmask: Bitmask): boolean
	for offset = 0, buffer.len(bitmask) - BYTES_PER_ENTRY, BYTES_PER_ENTRY do
		if buffer.readu32(bitmask, offset) ~= 0 then
			return false
		end
	end
	return true
end

@native
local function bitmask_get_buffer_size(bits: number)
	return math.ceil(bits / BITS_PER_ENTRY) * BYTES_PER_ENTRY
end

-- all bits [0, bits) set; bits in the last entry beyond `bits` stay clear so
-- hashes, deltas and is_empty dont see ghost members
@native
local function bitmask_create_filled(bits: number): Bitmask
	local size = bitmask_get_buffer_size(bits)
	local bitmask = buffer.create(size)
	buffer.fill(bitmask, 0, 0xFF)

	local tail = bits % BITS_PER_ENTRY
	if tail ~= 0 then
		buffer.writeu32(bitmask, size - BYTES_PER_ENTRY, bit32.lshift(1, tail) - 1)
	end
	return bitmask
end

return {
	band = bitmasks_band,
	bor = bitmasks_bor,
	read_entry = bitmasks_read_entry,
	get_index = bitmasks_get_index,
	set = bitmasks_set,
	reset = bitmasks_reset,
	test = bitmasks_test,
	exclude = bitmasks_exclude,
	iter_set = bitmask_iter_set,
	load = bitmasks_load,
	clear = bitmasks_clear,
	clone = bitmasks_clone,
	hash = bitmask_hash,
	equals = bitmask_equals,
	is_empty = bitmask_is_empty,
	get_buffer_size = bitmask_get_buffer_size,
	create_filled = bitmask_create_filled,
	get_hole_mask = bitmask_get_hole_mask,
	punch_hole_mask = bitmask_punch_hole_mask,

	calculate_bitmask_deltas = calculate_bitmask_deltas,
	load_bitmask_deltas = load_bitmask_deltas,
}
