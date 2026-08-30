local types = require "./types"
local common = require "./common"

type Component = common.Component
type Entity = common.Entity
type World = common.World

local handshake = {}

function handshake.generate_handshake(shared: types.Shared): types.HandshakeInfo
	local component_to_name: { [Entity]: string } = {}
	local handshake: types.HandshakeInfo = {
		components = {},
		custom_ids = {},
		serdes = {},
	}

	for component_name, component in shared.components.lookup do
		handshake.components[component_name] = true
		component_to_name[component] = component_name
	end

	for custom_id in shared.custom_ids.lookup do
		handshake.custom_ids[custom_id] = true
	end

	for component, serdes in shared.serdes do
		local name = component_to_name[component]
		if not name then
			continue
		end

		handshake.serdes[name] = {
			includes_variants = serdes.includes_variants,
			bytespan = serdes.bytespan,
		}
	end

	return handshake
end

function handshake.verify_handshake(
	shared: types.Shared,
	handshake: types.HandshakeInfo,
	handshake_side: string,
	verify_side: string
): (boolean, string?)
	local component_to_name: { [Entity]: string } = {}

	for component_name in handshake.components do
		if not shared.components.lookup[component_name] then
			return false, `missing shared component "{component_name}" in {verify_side}`
		end
	end
	for component_name, component in shared.components.lookup do
		if not handshake.components[component_name] then
			return false, `missing shared component "{component_name}" in {handshake_side}`
		end
		component_to_name[component] = component_name
	end

	for custom_id in handshake.custom_ids do
		if not shared.custom_ids.lookup[custom_id] then
			return false, `missing custom id "{custom_id}" in {verify_side}`
		end
	end
	for custom_id in shared.custom_ids.lookup do
		if not handshake.custom_ids[custom_id] then
			return false, `missing custom id "{custom_id}" in {handshake_side}`
		end
	end

	for component_name, serdes_info in handshake.serdes do
		local component = shared.components.lookup[component_name]
		if not component then
			common.log_warn(`{handshake_side} registered a serdes for "{component_name}" that {verify_side} doesn't have`)
			continue
		end

		local serdes = shared.serdes[component]
		if not serdes then
			return false, `missing serdes for component "{component_name}" in {verify_side}`
		end

		if (serdes_info.includes_variants or false) ~= (serdes.includes_variants or false) then
			return false,
				`mismatched includes_variants for component "{component_name}": ({serdes_info.includes_variants} ~= {serdes.includes_variants})`
		end
		if serdes_info.bytespan ~= serdes.bytespan then
			return false,
				`mismatched bytespan for component "{component_name}": ({serdes_info.bytespan} ~= {serdes.bytespan})`
		end
	end
	for component in shared.serdes do
		local component_name = component_to_name[component]
		if not component_name then
			continue
		end

		if not handshake.serdes[component_name] then
			common.log_warn(`{verify_side} registered a serdes for "{component_name}" that {handshake_side} doesn't have`)
		end
	end

	return true, nil
end

return handshake
