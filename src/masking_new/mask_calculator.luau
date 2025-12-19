type Bitmask = any

type CachedFilterDelta = {
	added: Bitmask,
	removed: Bitmask,
	redirect: Bitmask,
}

local cached_filters = {}
local cached_filter_deltas: { [string]: CachedFilterDelta } = {}

function delete_storage_group() end

function set_entity() end
