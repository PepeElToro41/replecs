--!optimize 2

local color = require "../testlib/ansi"

local bench = {}

local NAME_WIDTH = 44
local LABEL_WIDTH = 6

local function format(seconds: number): string
	if seconds < 1e-6 then
		return string.format("%.0f ns", seconds * 1e9)
	elseif seconds < 1e-3 then
		return string.format("%.2f us", seconds * 1e6)
	elseif seconds < 1 then
		return string.format("%.2f ms", seconds * 1e3)
	end
	return string.format("%.2f s", seconds)
end

-- highlighted time with its unit, padded before coloring so columns stay aligned
local function time(seconds: number): string
	return color.yellow(string.format("%10s", format(seconds)))
end

local function padName(name: string): string
	return string.format("%-" .. NAME_WIDTH .. "s", name)
end

-- unit labels ("/op", "total", "/item") padded to the same width so columns line up
local function label(text: string): string
	return string.format("%-" .. LABEL_WIDTH .. "s", text)
end

function bench.title(name: string)
	print()
	print(color.green_highlight(` --- {name} --- `))
end

-- times `fn(i)` over `iterations` calls, reports per-call and total time
function bench.run(name: string, iterations: number, fn: (index: number) -> ()): number
	local start = os.clock()
	for i = 1, iterations do
		fn(i)
	end
	local elapsed = os.clock() - start

	print(
		`  • {padName(name)} {time(elapsed / iterations)}{label "/op"}   {color.gray(
			string.format("(%d ops in %s)", iterations, format(elapsed))
		)}`
	)
	return elapsed
end

-- times a single call of `fn`, reports total and per-item time
function bench.once(name: string, items: number, fn: () -> ()): number
	local start = os.clock()
	fn()
	local elapsed = os.clock() - start

	print(
		`  • {padName(name)} {time(elapsed / items)}{label "/item"}   {time(elapsed)}{label " total"}   {color.gray(
			string.format("(%d items)", items)
		)}`
	)
	return elapsed
end

return bench
