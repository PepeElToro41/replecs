--!strict

-- Type definitions
export type Expectation = {
	value: any,
	inverted: boolean,
	to: To,
	never: Expectation,
}

export type To = {
	be: Be,
	equal: (expected: any) -> (),
	exist: () -> (),
	beNil: () -> (),
	beNaN: () -> (),
	throw: (expectedMessage: string?) -> (),
	contain: (expected: any) -> (),
	match: (pattern: string) -> (),
}

export type Be = {
	ok: () -> (),
	a: (typeName: string) -> (),
	an: (typeName: string) -> (),
	number: () -> (),
	string: () -> (),
	boolean: () -> (),
	table: () -> (),
	["function"]: () -> (),
	thread: () -> (),
	userdata: () -> (),
	truthy: () -> (),
	falsy: () -> (),
	equal: (expected: any) -> (),
	near: (expected: number, epsilon: number?) -> (),
	greaterThan: (expected: number) -> (),
	lessThan: (expected: number) -> (),
	greaterThanOrEqual: (expected: number) -> (),
	lessThanOrEqual: (expected: number) -> (),
}

-- Helper functions
local function formatValue(value: any): string
	local valueType = type(value)

	if valueType == "nil" then
		return "nil"
	elseif valueType == "string" then
		return `"{value}"`
	elseif valueType == "number" then
		return tostring(value)
	elseif valueType == "boolean" then
		return tostring(value)
	elseif valueType == "table" then
		local items = {}
		for k, v in pairs(value) do
			table.insert(items, `{formatValue(k)} = {formatValue(v)}`)
		end
		return `\{{table.concat(items, ", ")}}`
	elseif valueType == "function" then
		return "function"
	else
		return `{valueType}: {tostring(value)}`
	end
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end

	local typeA = type(a)
	local typeB = type(b)

	if typeA ~= typeB then
		return false
	end

	if typeA == "table" then
		-- Check if tables have same keys
		for k in pairs(a) do
			if b[k] == nil then
				return false
			end
		end

		for k in pairs(b) do
			if a[k] == nil then
				return false
			end
		end

		-- Check if all values are equal
		for k, v in pairs(a) do
			if not deepEqual(v, b[k]) then
				return false
			end
		end

		return true
	end

	return false
end

local function isNaN(value: any): boolean
	return type(value) == "number" and value ~= value
end

-- Expectation implementation
local function createExpectation(value: any, inverted: boolean): Expectation
	local function assert(condition: boolean, message: string, expected: any?, got: any?)
		if inverted then
			condition = not condition
		end

		if not condition then
			local errorMsg = message
			if expected ~= nil or got ~= nil then
				errorMsg = errorMsg .. `\nExpected: {formatValue(expected)}` .. `\nGot: {formatValue(got or value)}`
			end
			error(errorMsg, 3)
		end
	end

	local function typeCheck(expectedType: string)
		local actualType = typeof(value)
		assert(actualType == expectedType, `Expected value to be a {expectedType}`, expectedType, actualType)
	end

	local expectation: Expectation = {
		value = value,
		inverted = inverted,
		to = nil :: any,
		never = nil :: any,
	}

	-- Create "never" (inverted) version
	if not inverted then
		expectation.never = createExpectation(value, true)
	end

	-- Create "to" chain
	local to: To = {
		be = nil :: any,

		equal = function(expected: any)
			assert(deepEqual(value, expected), "Expected values to be equal", expected, value)
		end,

		exist = function()
			assert(value ~= nil, "Expected value to exist (not be nil)", "non-nil", "nil")
		end,

		beNil = function()
			assert(value == nil, "Expected value to be nil", "nil", value)
		end,

		beNaN = function()
			assert(isNaN(value), "Expected value to be NaN", "NaN", value)
		end,

		throw = function(expectedMessage: string?)
			assert(
				type(value) == "function",
				"Expected value to be a function to test for throwing",
				"function",
				type(value)
			)

			local success, err = pcall(value)

			if inverted then
				if not success then
					error("Expected function not to throw, but it threw: " .. tostring(err), 2)
				end
			else
				if success then
					error("Expected function to throw an error, but it did not", 2)
				end

				if expectedMessage and not string.find(tostring(err), expectedMessage, 1, true) then
					error(`Expected error message to contain "{expectedMessage}"\nGot: {tostring(err)}`, 2)
				end
			end
		end,

		contain = function(expected: any)
			if type(value) == "table" then
				local found = false
				for _, v in pairs(value) do
					if deepEqual(v, expected) then
						found = true
						break
					end
				end
				assert(found, "Expected table to contain value", expected, value)
			elseif type(value) == "string" then
				assert(
					string.find(value, expected, 1, true) ~= nil,
					"Expected string to contain substring",
					expected,
					value
				)
			else
				error("contain() can only be used with tables or strings", 2)
			end
		end,

		match = function(pattern: string)
			assert(type(value) == "string", "match() can only be used with strings", "string", type(value))
			assert(string.find(value, pattern) ~= nil, "Expected string to match pattern", pattern, value)
		end,
	}

	-- Create "be" chain
	local be: Be = {
		ok = function()
			assert(value ~= nil and value ~= false, "Expected value to be ok (truthy)", "truthy", value)
		end,

		a = function(typeName: string)
			typeCheck(typeName)
		end,

		an = function(typeName: string)
			typeCheck(typeName)
		end,

		number = function()
			typeCheck "number"
		end,

		string = function()
			typeCheck "string"
		end,

		boolean = function()
			typeCheck "boolean"
		end,

		table = function()
			typeCheck "table"
		end,

		["function"] = function()
			typeCheck "function"
		end,

		thread = function()
			typeCheck "thread"
		end,

		userdata = function()
			typeCheck "userdata"
		end,

		truthy = function()
			assert(value ~= nil and value ~= false, "Expected value to be truthy", "truthy", value)
		end,

		falsy = function()
			assert(value == nil or value == false, "Expected value to be falsy", "falsy", value)
		end,

		equal = function(expected: any)
			assert(deepEqual(value, expected), "Expected values to be equal", expected, value)
		end,

		near = function(expected: number, epsilon: number?)
			assert(type(value) == "number", "near() requires a number", "number", type(value))
			assert(type(expected) == "number", "near() requires expected to be a number")

			local eps = epsilon or 0.001
			local diff = math.abs(value - expected)

			assert(diff <= eps, `Expected {value} to be near {expected} (within {eps})`, expected, value)
		end,

		greaterThan = function(expected: number)
			assert(type(value) == "number", "greaterThan() requires a number", "number", type(value))
			assert(value > expected, `Expected {value} to be greater than {expected}`, `> {expected}`, value)
		end,

		lessThan = function(expected: number)
			assert(type(value) == "number", "lessThan() requires a number", "number", type(value))
			assert(value < expected, `Expected {value} to be less than {expected}`, `< {expected}`, value)
		end,

		greaterThanOrEqual = function(expected: number)
			assert(type(value) == "number", "greaterThanOrEqual() requires a number", "number", type(value))
			assert(value >= expected, `Expected {value} to be greater than or equal to {expected}`, `>= {expected}`, value)
		end,

		lessThanOrEqual = function(expected: number)
			assert(type(value) == "number", "lessThanOrEqual() requires a number", "number", type(value))
			assert(value <= expected, `Expected {value} to be less than or equal to {expected}`, `<= {expected}`, value)
		end,
	}

	to.be = be
	expectation.to = to

	return expectation
end

-- Main expect function
local function expect(value: any): Expectation
	return createExpectation(value, false)
end

return expect
