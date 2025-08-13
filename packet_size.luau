local module

if game then
	module = require "./roblox_packages/packet_size"
else
	module = {
		GetDataByteSize = function(_: any): number
			return 0
		end,
	}
end

return module
