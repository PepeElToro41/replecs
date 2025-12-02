export type MaskingController = {
	storage_edges: any,
}

local masking_controller = {}

local function create(): MaskingController
	local self = {} :: MaskingController

	return setmetatable(self, masking_controller) :: any
end

return { create = create, masking_controller = masking_controller }
