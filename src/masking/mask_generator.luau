--!native
--!optimize 2

local utils = require(script.Parent.Parent.utils)

type ComputeCallback = (generator: MaskGenerator) -> utils.Bitmask
type SubscribeCallback = (generator: MaskGenerator) -> ()

export type MaskGenerator = {
	compute_callback: ComputeCallback?,
	subscribed: SubscribeCallback?,
	bitmask: utils.Bitmask,

	tracking: { GeneratorInternal },
	tracked_by: { GeneratorInternal },
	tracked_indexes: { [GeneratorInternal]: number },

	compute: (self: MaskGenerator) -> (),
	run_subscribed: (self: MaskGenerator) -> (),
	track: (self: MaskGenerator, tracking: MaskGenerator) -> (),
	destroy: (self: MaskGenerator) -> (),
}

local mask_generator = {}
mask_generator.__index = mask_generator

type GeneratorInternal = MaskGenerator & typeof(mask_generator)

function mask_generator.track(generator: GeneratorInternal, tracking: GeneratorInternal)
	table.insert(generator.tracking, tracking)
	tracking:mark_as_tracked(generator)
end

function mask_generator.mark_as_tracked(generator: GeneratorInternal, tracked_by: GeneratorInternal)
	table.insert(generator.tracked_by, tracked_by)
	generator.tracked_indexes[tracked_by] = #generator.tracked_by
end

function mask_generator.unmark_tracked(generator: GeneratorInternal, to_untrack: GeneratorInternal)
	local index = generator.tracked_indexes[to_untrack]
	if index then
		local last = table.remove(generator.tracked_by)

		if last and last ~= to_untrack then
			generator.tracked_by[index] = last
			generator.tracked_indexes[last :: GeneratorInternal] = index
		end

		generator.tracked_indexes[to_untrack] = nil
	end
end

function mask_generator.run_subscribed(generator: GeneratorInternal)
	if generator.subscribed then
		generator.subscribed(generator :: GeneratorInternal)
	end
end

function mask_generator.compute(generator: GeneratorInternal)
	if generator.compute_callback then
		local result = generator.compute_callback(generator :: GeneratorInternal)
		generator.bitmask = result
	end
	if generator.subscribed then
		generator.subscribed(generator :: GeneratorInternal)
	end

	for _, tracking in generator.tracked_by do
		tracking:compute()
	end
end

function mask_generator.destroy(generator: GeneratorInternal)
	for _, tracking in generator.tracking do
		tracking:unmark_tracked(generator :: GeneratorInternal)
	end
end

function create(bitmask: utils.Bitmask?, compute: ComputeCallback?): MaskGenerator
	local self = {} :: MaskGenerator

	self.bitmask = bitmask or (compute :: ComputeCallback)(self)
	self.compute_callback = compute
	self.subscribed = nil
	self.tracking = {}
	self.tracked_by = {}
	self.tracked_indexes = {}

	return setmetatable(self, mask_generator) :: any
end

function follow(leading: MaskGenerator): MaskGenerator
	local created = create(nil, function()
		return leading.bitmask
	end)
	created:track(leading)
	return created
end

return { create = create, follow = follow }
