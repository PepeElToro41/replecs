--!native
--!optimize 2

local jecs = require(script.Parent.Parent.jecs)
local common = require(script.Parent.common)

local utils = {}

export type Cursor = {
	offset: number,
	buffer: buffer,
}

local cursor = {}

function cursor.new(): Cursor
	return {
		buffer = buffer.create(100),
		offset = 0,
	}
end

function cursor.from(buf: buffer): Cursor
	return {
		buffer = buf,
		offset = buffer.len(buf),
	}
end

function cursor.tryalloc(cursor: Cursor, bytes: number)
	local buf = cursor.buffer
	local offset = cursor.offset
	local len = buffer.len(buf)

	if len < offset + bytes then
		local exponent = math.ceil(math.log((bytes + offset) / len, 1.5))
		local new = buffer.create(len * 1.5 ^ exponent)
		buffer.copy(new, 0, buf, 0)
		cursor.buffer = new
	end
end

function cursor.write_buffer(c: Cursor, buf: buffer)
	cursor.tryalloc(c, buffer.len(buf))
	buffer.copy(c.buffer, c.offset, buf, 0, buffer.len(buf))
	c.offset += buffer.len(buf)
end

function cursor.writeu8(c: Cursor, value: number)
	cursor.tryalloc(c, 1)
	buffer.writeu8(c.buffer, c.offset, value)
	c.offset += 1
end

function cursor.writeu16(c: Cursor, value: number)
	cursor.tryalloc(c, 2)
	buffer.writeu16(c.buffer, c.offset, value)
	c.offset += 2
end
function cursor.writeu24(c: Cursor, value: number)
	cursor.tryalloc(c, 3)
	buffer.writeu8(c.buffer, c.offset, value)
	buffer.writeu16(c.buffer, c.offset + 1, value // 256)
	c.offset += 3
end

function cursor.writeu32(c: Cursor, value: number)
	cursor.tryalloc(c, 4)
	buffer.writeu32(c.buffer, c.offset, value :: any)
	c.offset += 4
end

function cursor.writei8(c: Cursor, value: number)
	cursor.tryalloc(c, 1)
	buffer.writei8(c.buffer, c.offset, value)
	c.offset += 1
end

function cursor.writei16(c: Cursor, value: number)
	cursor.tryalloc(c, 2)
	buffer.writei16(c.buffer, c.offset, value)
	c.offset += 2
end

function cursor.writei32(c: Cursor, value: number)
	cursor.tryalloc(c, 4)
	buffer.writeu32(c.buffer, c.offset, value :: any)
	c.offset += 4
end

function cursor.read_buffer(c: Cursor, len: number)
	local retrieved = buffer.create(len)
	buffer.copy(retrieved, 0, c.buffer, c.offset - len, len)
	c.offset -= len
	return retrieved
end

function cursor.readu8(c: Cursor): number
	c.offset -= 1
	return buffer.readu8(c.buffer, c.offset)
end

function cursor.readu16(c: Cursor): number
	c.offset -= 2
	return buffer.readu16(c.buffer, c.offset)
end

function cursor.readu24(c: Cursor): number
	c.offset -= 3
	local one = buffer.readu8(c.buffer, c.offset)
	local two = buffer.readu16(c.buffer, c.offset + 1)
	return one + two * 256
end
function cursor.readu32(c: Cursor): number
	c.offset -= 4
	return buffer.readu32(c.buffer, c.offset)
end

function cursor.readi8(c: Cursor): number
	c.offset -= 1
	return buffer.readi8(c.buffer, c.offset)
end

function cursor.readi16(c: Cursor): number
	c.offset -= 2
	return buffer.readi16(c.buffer, c.offset)
end
function cursor.readi32(c: Cursor): number
	c.offset -= 4
	return buffer.readi32(c.buffer, c.offset)
end

function cursor.write_vlq(c: Cursor, value: number)
	local x0 = value // 1 % 128
	local x1 = value // 0x80 % 128
	local x2 = value // 0x4000 % 128
	local x3 = value // 0x200000 % 128

	if x3 ~= 0 then
		cursor.tryalloc(c, 4)
		cursor.writeu32(c, x0 * 256 ^ 3 + x1 * 256 ^ 2 + x2 * 256 + x3 + 128)
	elseif x2 ~= 0 then
		cursor.tryalloc(c, 3)
		cursor.writeu24(c, x0 * 256 ^ 2 + x1 * 256 + x2 + 128)
	elseif x1 ~= 0 then
		cursor.tryalloc(c, 2)
		cursor.writeu16(c, x0 * 256 + x1 + 128)
	else
		cursor.tryalloc(c, 1)
		cursor.writeu8(c, x0 + 128)
	end
end

function cursor.read_vlq(c: Cursor): number
	local b = cursor.readu8(c)
	if b >= 128 then
		return b - 128
	end
	local x = b

	b = cursor.readu8(c)
	if b >= 128 then
		return x + (b - 128) * 128
	end
	x += b * 128

	b = cursor.readu8(c)
	if b >= 128 then
		return x + (b - 128) * 128 ^ 2
	end
	x += b * 128 ^ 2

	b = cursor.readu8(c)
	if b >= 128 then
		return x + (b - 128) * 128 ^ 3
	end
	x += b * 128 ^ 3

	error "vlq length too large"
end

function cursor.close(c: Cursor): buffer
	local final = buffer.create(c.offset)
	buffer.copy(final, 0, c.buffer, 0, c.offset)
	c.buffer = final
	return final
end

utils.cursor = cursor

local bitmask = {}
bitmask.__index = bitmask

export type Bitmask = {
	buffer: buffer,
	capacity: number,
	entries: number,
} & typeof(bitmask)

local BITS_PER_ENTRY = 32
local BYTES_PER_ENTRY = 4

function get_entry_bit(index: number): (number, number)
	local entry_index = math.floor(index / BITS_PER_ENTRY)
	local bit_position = index % BITS_PER_ENTRY
	return entry_index, bit_position
end

function bitmask.create(capacity: number?): Bitmask
	local entries_needed = math.ceil(capacity :: number / BITS_PER_ENTRY)
	local buffer_size = entries_needed * BYTES_PER_ENTRY

	local self = {
		buffer = buffer.create(buffer_size),
		capacity = capacity,
		entries = entries_needed,
	}

	return setmetatable(self, bitmask) :: any
end

function bitmask.from_set(indexes: { [any]: number }, filter: { [any]: boolean }, capacity: number?): Bitmask
	local newmask = bitmask.create(capacity or 32)
	for player in filter do
		local index = indexes[player]
		if index == nil then
			continue
		end
		bitmask.set(newmask, index)
	end
	return newmask
end

function bitmask.expand(self: Bitmask, capacity: number)
	if capacity <= self.capacity then
		return
	end

	local new_entries = math.ceil(capacity / BITS_PER_ENTRY)
	local new_buffer_size = new_entries * BYTES_PER_ENTRY
	local new_buffer = buffer.create(new_buffer_size)

	buffer.copy(new_buffer, 0, self.buffer, 0)

	for i = self.entries * BYTES_PER_ENTRY, new_buffer_size - 1 do
		buffer.writeu8(new_buffer, i, 0)
	end

	self.buffer = new_buffer
	self.capacity = capacity
	self.entries = new_entries
end

function bitmask.read(self: Bitmask, index: number): number
	if index >= self.entries then
		return 0
	end
	return buffer.readu32(self.buffer, index * BYTES_PER_ENTRY)
end

function bitmask.write(self: Bitmask, index: number, value: number)
	if index >= self.entries then
		--
		bitmask.expand(self, (index + 1) * BITS_PER_ENTRY)
	end
	buffer.writeu32(self.buffer, index * BYTES_PER_ENTRY, value)
end

-- BIT MANIPULATIONS

function bitmask.set(self: Bitmask, index: number)
	if index < 0 then
		error "Bit index cannot be negative"
	end

	local entry_index, bit_position = get_entry_bit(index)
	local current_value = bitmask.read(self, entry_index)
	local new_value = bit32.bor(current_value, bit32.lshift(1, bit_position))
	bitmask.write(self, entry_index, new_value)
end

function bitmask.get(self: Bitmask, index: number): boolean
	if index < 0 then
		error "Bit index cannot be negative"
	end

	local entry_index, bit_position = get_entry_bit(index)
	if entry_index >= self.entries then
		return false
	end

	local current_value = bitmask.read(self, entry_index)
	return bit32.band(current_value, bit32.lshift(1, bit_position)) ~= 0
end

function bitmask.clear(self: Bitmask, index: number)
	if index < 0 then
		error "Bit index cannot be negative"
	end

	local entry_index, bit_position = get_entry_bit(index)
	if entry_index >= self.entries then
		return
	end

	local current_value = bitmask.read(self, entry_index)
	local mask = bit32.bnot(bit32.lshift(1, bit_position))
	local new_value = bit32.band(current_value, mask)
	bitmask.write(self, entry_index, new_value)
end

-- BITWISE OPERATIONS

function bitmask.band(self: Bitmask, other: Bitmask): Bitmask
	local max_entries = math.max(self.entries, other.entries)
	local result = bitmask.create(max_entries * BITS_PER_ENTRY)

	for i = 0, max_entries - 1 do
		local value1 = bitmask.read(self, i)
		local value2 = bitmask.read(other, i)
		bitmask.write(result, i, bit32.band(value1, value2))
	end

	return result
end

function bitmask.bor(self: Bitmask, other: Bitmask): Bitmask
	local max_entries = math.max(self.entries, other.entries)
	local result = bitmask.create(max_entries * BITS_PER_ENTRY)

	for i = 0, max_entries - 1 do
		local value1 = bitmask.read(self, i)
		local value2 = bitmask.read(other, i)
		bitmask.write(result, i, bit32.bor(value1, value2))
	end

	return result
end

function bitmask.bxor(self: Bitmask, other: Bitmask): Bitmask
	local max_entries = math.max(self.entries, other.entries)
	local result = bitmask.create(max_entries * BITS_PER_ENTRY)

	for i = 0, max_entries - 1 do
		local value1 = bitmask.read(self, i)
		local value2 = bitmask.read(other, i)
		bitmask.write(result, i, bit32.bxor(value1, value2))
	end

	return result
end

function bitmask.bnot(self: Bitmask): Bitmask
	local result = bitmask.create(self.capacity)

	for i = 0, self.entries - 1 do
		local value = bitmask.read(self, i)
		bitmask.write(result, i, bit32.bnot(value))
	end

	return result
end

function bitmask.clone(self: Bitmask): Bitmask
	local result = bitmask.create(self.capacity)
	buffer.copy(result.buffer, 0, self.buffer, 0, self.entries * BYTES_PER_ENTRY)
	return result
end

function bitmask.remap(self: Bitmask, from: { [any]: number }, to: { [any]: number }, new_capacity: number?): Bitmask
	local result = bitmask.create(new_capacity or BITS_PER_ENTRY)
	for member, index in to do
		local old_index = from[member]
		if old_index then
			local old_bit = bitmask.get(self, old_index)
			if old_bit then
				bitmask.set(result, index)
			else
				bitmask.clear(result, index)
			end
		end
	end
	return result
end

function bitmask.lshift(self: Bitmask, n: number): Bitmask
	if n <= 0 then
		return bitmask.clone(self)
	end

	local entry_shift = math.floor(n / BITS_PER_ENTRY)
	local bit_shift = n % BITS_PER_ENTRY

	local result = bitmask.create(self.capacity + n)

	if bit_shift == 0 then
		for i = 0, self.entries - 1 do
			local value = bitmask.read(self, i)
			bitmask.write(result, i + entry_shift, value)
		end
	else
		local carry = 0
		for i = 0, self.entries - 1 do
			local value = bitmask.read(self, i)
			local shifted_value = bit32.lshift(value, bit_shift)
			local new_carry = bit32.rshift(value, BITS_PER_ENTRY - bit_shift)

			bitmask.write(result, i + entry_shift, bit32.bor(shifted_value, carry))
			carry = new_carry
		end

		if carry ~= 0 then
			bitmask.write(result, self.entries + entry_shift, carry)
		end
	end

	return result
end

function bitmask.rshift(self: Bitmask, n: number): Bitmask
	if n <= 0 then
		return bitmask.clone(self)
	end

	local entry_shift = math.floor(n / BITS_PER_ENTRY)
	local bit_shift = n % BITS_PER_ENTRY

	if entry_shift >= self.entries then
		return bitmask.create(32)
	end

	local result = bitmask.create(self.capacity)

	if bit_shift == 0 then
		for i = entry_shift, self.entries - 1 do
			local value = bitmask.read(self, i)
			bitmask.write(result, i - entry_shift, value)
		end
	else
		for i = entry_shift, self.entries - 1 do
			local value = bitmask.read(self, i)
			local shifted_value = bit32.rshift(value, bit_shift)

			local next_value = 0
			if i + 1 < self.entries then
				next_value = bitmask.read(self, i + 1)
			end
			local overflow = bit32.lshift(next_value, BITS_PER_ENTRY - bit_shift)

			bitmask.write(result, i - entry_shift, bit32.bor(shifted_value, overflow))
		end
	end

	return result
end

local function tobinary(n: number): string
	if n == 0 then
		return "0"
	end

	local result = ""
	while n > 0 do
		result = (n % 2) .. result
		n = math.floor(n / 2)
	end
	return string.rep("0", 8 - #result) .. result
end

function bitmask.tostring(self: Bitmask): string
	local highest_entry = -1
	for i = self.entries - 1, 0, -1 do
		local value = bitmask.read(self, i)
		if value ~= 0 then
			highest_entry = i
			break
		end
	end

	if highest_entry == -1 then
		return ""
	end

	local str = ""
	for i = 0, highest_entry do
		local value = bitmask.read(self, i)
		str ..= tobinary(value)
	end
	return str
end

utils.bitmask = {
	create = bitmask.create,
	from_set = bitmask.from_set,
}

function utils.create_shared_lookup(world: jecs.World, components: common.Components)
	local shared: common.Shared = {
		lookup = {},
		serdes = {},
		bytespan = {},
		ids = {},
		components = {},
	}
	print("COMPONENTS", components)

	for component, name in world:query(jecs.Name):with(components.shared):iter() do
		shared.lookup[name] = component
	end

	for component, serdes in world:query(components.serdes):with(components.shared, jecs.Name):iter() do
		shared.serdes[component] = serdes
	end

	for component, bytespan in world:query(components.bytespan):with(components.shared, jecs.Name):iter() do
		shared.bytespan[component] = bytespan
	end

	local keys = {}
	local component_ids = {}
	local id_components = {}

	for name in shared.lookup do
		table.insert(keys, name)
	end
	table.sort(keys)

	for id, name in keys do
		local component = shared.lookup[name]
		component_ids[shared.lookup[name]] = id
		id_components[id] = component
	end

	component_ids[jecs.ChildOf] = #keys + 1

	shared.ids = component_ids
	shared.components = id_components
	return shared
end

function utils.vlq_span(length: number): number
	if length < 0x80 then
		return 1
	elseif length < 0x4000 then
		return 2
	elseif length < 0x200000 then
		return 3
	else
		return 4
	end
end

function utils.number_span(n: number): number
	if n <= 0xFF then
		return 1
	elseif n <= 0xFFFF then
		return 2
	else
		return 4 -- cant read 24 bits
	end
end

function utils.read_number(buf: buffer, offset: number, span: number): (number, number)
	if span == 1 then
		return buffer.readu8(buf, offset), offset + 1
	elseif span == 2 then
		return buffer.readu16(buf, offset), offset + 2
	else
		return buffer.readu32(buf, offset), offset + 4
	end
end

function utils.push_vlq(buf: buffer, offset: number, length: number): number
	local b1 = length % 128
	local b2 = length // 128 % 128
	local b3 = length // 0x4000 % 128
	local b4 = length // 0x200000 % 128

	if length < 0x80 then
		buffer.writeu8(buf, offset, b1)
		return offset + 1
	elseif length < 0x4000 then
		buffer.writeu8(buf, offset, b2 + 0x80)
		buffer.writeu8(buf, offset + 1, b1)
		return offset + 2
	elseif length < 0x200000 then
		buffer.writeu8(buf, offset, b3 + 0x80)
		buffer.writeu8(buf, offset + 1, b2 + 0x80)
		buffer.writeu8(buf, offset + 2, b1)
		return offset + 3
	elseif length < 0x10000000 then
		buffer.writeu8(buf, offset, b4 + 0x80)
		buffer.writeu8(buf, offset + 1, b3 + 0x80)
		buffer.writeu8(buf, offset + 2, b2 + 0x80)
		buffer.writeu8(buf, offset + 3, b1)
		return offset + 4
	else
		error "vlq length too large"
	end
end

function utils.pop_vlq(buf: buffer, offset: number): (number, number)
	local b1 = buffer.readu8(buf, offset)
	if b1 < 128 then
		--
		return b1, offset + 1
	end
	local b2 = buffer.readu8(buf, offset + 1)
	if b2 < 128 then
		--
		return (b1 - 128) * 120 + b2, offset + 2
	end
	local b3 = buffer.readu8(buf, offset + 2)
	if b3 < 128 then
		--
		return ((b1 - 128) * 128 + (b2 - 128)) * 128 + b3, offset + 3
	end
	local b4 = buffer.readu8(buf, offset + 3)
	return (((b1 - 128) * 128 + (b2 - 128)) * 128 + (b3 - 128)) * 128 + b4, offset + 4
end

function utils.remove_all_relations(world: jecs.World, entity: jecs.Entity, relation: jecs.Entity)
	local entity_index = jecs.entity_index_try_get_fast(world.entity_index :: any, entity :: any)
	if not entity_index then
		return
	end
	local archetype = entity_index.archetype

	local wildcard = jecs.pair(relation, jecs.Wildcard) :: any
	local idr = world.component_index[wildcard]
	if not idr then
		return
	end

	local total = idr.counts[wildcard]
	if not total or total <= 0 then
		return
	end
	local start = idr.records[wildcard]
	if not start then
		return
	end

	for i = start, start + total - 1 do
		local pair = archetype.types[i]
		world:remove(entity, pair :: any)
	end
end

function utils.logerror(...: string): never
	error("REPLECS ERROR - " .. table.concat({ ... }, " "))
end
function utils.logwarn(...: string)
	warn("REPLECS WARN - " .. table.concat({ ... }, " "))
end

function utils.logcomponent(world: jecs.World, component: jecs.Entity)
	return ` name: {world:get(component, jecs.Name) or "(no name)"} id: {component}`
end

return utils
