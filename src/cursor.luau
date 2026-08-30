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

function cursor.from_offset(buf: buffer, offset: number): Cursor
	return {
		buffer = buf,
		offset = offset,
	}
end

function cursor.tryalloc(c: Cursor, bytes: number)
	local buf = c.buffer
	local offset = c.offset
	local len = buffer.len(buf)

	if len < offset + bytes then
		local exponent = math.ceil(math.log((bytes + offset) / len, 1.5))
		local new_len = math.floor(len * 1.5 ^ exponent)
		if new_len < offset + bytes then
			new_len = offset + bytes
		end
		local new = buffer.create(new_len)
		buffer.copy(new, 0, buf, 0)
		c.buffer = new
	end
end

function cursor.write_buffer(c: Cursor, buf: buffer, start: number?, count: number?)
	if start == nil and count == nil then
		cursor.tryalloc(c, buffer.len(buf))
		buffer.copy(c.buffer, c.offset, buf, 0, buffer.len(buf))
		c.offset += buffer.len(buf)
	else
		local len = buffer.len(buf)
		local available = len - (start or 0)
		local write_count = count and math.min(available, count) or available

		cursor.tryalloc(c, write_count)
		buffer.copy(c.buffer, c.offset, buf, start or 0, write_count)
		c.offset += write_count
	end
end

function cursor.print(c: Cursor)
	local bytes: { any } = { string.byte(buffer.tostring(c.buffer), 1, -1) }
	local offset = 7
	for i = 1, c.offset do
		local byte = bytes[i] :: number
		local digits = if byte == 0 then 1 else math.ceil(math.log10(1 + byte))
		offset += digits + 1
	end

	local last_byte = bytes[c.offset + 1]
	if last_byte then
		local lastDigits = if last_byte == 0 then 1 else math.ceil(math.log10(1 + last_byte))
		offset += lastDigits // 2
	end
	bytes[c.offset + 1] = `[{bytes[c.offset + 1] :: number}]` :: any

	if #bytes == 0 or c.offset == buffer.len(c.buffer) then
		table.insert(bytes, " ")
	end

	return `Pos: {c.offset} / {buffer.len(c.buffer)}\nBuf: \{ {table.concat(bytes, " ")} \}`
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

function cursor.writeu40(c: Cursor, value: number)
	cursor.tryalloc(c, 5)
	buffer.writeu8(c.buffer, c.offset, value)
	buffer.writeu32(c.buffer, c.offset + 1, value // 256)
	c.offset += 5
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

function cursor.write_span(c: Cursor, value: number, span: number)
	if span <= 0xFF then
		cursor.writeu8(c, value)
	elseif span <= 0xFFFF then
		cursor.writeu16(c, value)
	elseif span <= 0xFFFFFF then
		cursor.writeu24(c, value)
	elseif span <= 0xFFFFFFFF then
		cursor.writeu32(c, value)
	else
		error "span too large"
	end
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

function cursor.readu40(c: Cursor): number
	c.offset -= 5
	local one = buffer.readu8(c.buffer, c.offset)
	local two = buffer.readu32(c.buffer, c.offset + 1)
	return one + two * 256
end

function cursor.read_span(c: Cursor, span: number): number
	if span <= 0xFF then
		return cursor.readu8(c)
	elseif span <= 0xFFFF then
		return cursor.readu16(c)
	elseif span <= 0xFFFFFF then
		return cursor.readu24(c)
	elseif span <= 0xFFFFFFFF then
		return cursor.readu32(c)
	else
		error "span too large"
	end
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
	local x0 = value // 128 ^ 0 % 128
	local x1 = value // 128 ^ 1 % 128
	local x2 = value // 128 ^ 2 % 128
	local x3 = value // 128 ^ 3 % 128

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

return cursor
