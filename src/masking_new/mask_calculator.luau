type Bitmask = any

type CachedFilterDelta = {
	added: Bitmask,
	removed: Bitmask,
	redirect: Bitmask,
}

local cached_filters = {}
local cached_filter_deltas: { [string]: CachedFilterDelta } = {}

function set_entity() end
