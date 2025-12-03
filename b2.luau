--!optimize 2
--!native
--[[
- U53:
	Represents a positive integer with a number (a.k.a., double, or F64) value. 2^53 is the maximum unsigned integer a
number in luau can accurately represent. Used primarily for entity Ids.
- U32:
	Represents a positive integer, and implies it can or should be used with bit32 or other 32-bit operations.
- U26:
	Represents a positive integer up to 2^26, which is the maximum size for an array in luau. Because of this, it's used
to signify a table indexer which is a "dense array".
- U24:
	Represents the maximum positive integer a float (F32) can accurately represent, but it is more relevant in this
library as the "low" portion of an entity ID.
- Ptr:
	Represents a position in a buffer.
- Set<Key, Value>:
	Specifically represents sparse mappings of keys and values. If no value is provided, it defaults to true.
- Sorted<Values>:
	Denotes an object will always have sorted values no matter what.
]]
type U53 = number
type U32 = number
type U26 = number
type U24 = number
type Ptr = number
type Set<Key, Value = true> = { [Key]: Value }
type Sorted<Tbl> = Tbl

-- A set of bits.
type Bitset = U32
-- List of entity IDs. Components are entities as well.
type IdList = { U53 }
-- Observable event ID
type ObservableEventId = U53

type ArchLocation = U26
type ArchHash = string
type Row = U26
type PageRecord = Bitset
type Column = { [Row]: any }
type Arch = {
	-- Location of the archetype in the dense list of archetypes.
	location: ArchLocation,
	-- ORDERED_HASH of the archetype's sorted Id list
	hash: ArchHash,

	--[[B2 Archetypes use of Bitsets
	A bitset is a list of single-bit flags. Archetypes in B2 are queried for components via bitsets, where every
	component maps to a specific bit. One way to check if a bitset contains another set of bits (I.e., the "filter") is
	to call bit32.band on the set along with the filter, and check if it is equal to the filter. This works because
	bitwise AND gets the shared bits between two sets - and if the set does not share all of the filter bits, it is
	invalid. Luau only has built-in bitmasking operations for 32-bit numbers, so, single set of bits would limit
	component count to 32. To get around this, we split the bitset into smaller pages which can be tested. Another
	bitset, a "page record" is also stored - which keeps record of which pages are nonzero. Since the record is a U32 as
	well, the paged bitset is limited to 32*32 bits, i.e., 1024 components. Component columns outside of this range are
	not stored as any part of this bitset.
	]]
	pages_record: Bitset,
	bitset_pages: buffer,

	ids: Sorted<IdList>,

	-- list of rows which are 'empty', - I.e., their value is false, they have been removed, and are waiting to be
	-- removed completely.
	empty_rows: { Row },
	-- entities
	ents: { [Row]: U53 | false },
	columns_dense: { [U26]: Column },
	-- map of component IDs to columns
	columns_map: Set<U53, Column>,
}

--[[Archetype Graph
The archetype graph maps one node to another by adding or removing an ID. Indexing with an ID that is present in this
node attempts to traverse removal, and indexing with an ID that is not present in this node attempts to traverse adding.
- ids:
	A sorted, exact-size buffer holding F64 IDs in this node.
- arch:
	An optional arch. This means a graph node can exist without having an archetype associated with it. Archetype hash is
generated from ids, so any archetype that exists is guaranteed to have a node, but not the other way around.
]]
type ArchGraphNode = {
	[U53]: ArchGraphNode,
	ids: buffer,
	arch: Arch?,
}

--[[
For performance purposes, the keys here are actually numbers. Hooks["_*"] in the type maps to Hooks[internal.hks_*].
]]
type Hooks = {
	_on_add: InternalOnAddHook?,
	_on_change: InternalOnChangeHook?,
	_on_remove: InternalOnRemoveHook?,
}
local hks_add: "_on_add" = 1 :: any
local hks_change: "_on_change" = 2 :: any
local hks_remove: "_on_remove" = 3 :: any

type EntRecord = {
	arch: Arch,
	-- A lack of row signifies the entity is currently 'empty' - i.e., newly created with no data.
	row: Row?,
	dense: U26,
	hooks: Hooks?,
	-- data can still be read from the entity, but the entity is in the process of being deleted.
	deleting: true?,
}

--[[ IdRecord
Stores all of the critical information relating to a component and archetypes it is a part of. For performance
purposes, the keys here are actually numbers. IdRecord["_*"] in the type maps to IdRecord[internal.idr_*].
]]
type IdRecord = {
	-- Bitflags describing various pieces of metadata about a component
	_flags: Bitset,

	-- hooks table for this entity, taken from an EntRecord
	_hooks: Hooks,

	--[[
	- arch_sparse:
	A sparse mapping from an archetype object to a dense index.
	- arch_count:
		The number of dense indices. Each dense index represents an archetype.
	- dense_cached:
		Dense list of archetypes for easy use in iteration.
	]]
	_arch_sparse: Set<Arch, U26>,
	_arch_count: number,
	_dense_cached: { [U26]: Arch },
	-- location of the column for this Id based on dense archetype location
	_dense_column: { [U26]: number },
	-- Used to describe how "many" of this component exist in each archetype. This is only important for relationships
	-- (a.k.a. pairs.) More info @ https://ajmmertens.medium.com/a-roadmap-to-entity-relationships-5b1d11ebb4eb
	_dense_counts: { [U26]: number },
	-- Row monitors for this Id.
	_monitors: { Monitor }?,
}
local idr_flags: "_flags" = 1 :: any
local idr_hooks: "_hooks" = 2 :: any
local idr_arch_sparse: "_arch_sparse" = 3 :: any
local idr_arch_count: "_arch_count" = 4 :: any
local idr_dense_cached: "_dense_cached" = 5 :: any
local idr_dense_column: "_dense_column" = 6 :: any
local idr_dense_counts: "_dense_counts" = 7 :: any
local idr_monitors: "_monitors" = 8 :: any

type InternalOnAddHook = (entity: U53, id: U53, data: any?) -> ()
type InternalOnChangeHook = (entity: U53, id: U53, data: any) -> ()
type InternalOnRemoveHook = (entity: U53, id: U53) -> ()

-- Queries assemble up to 5 filters:
-- - One bitset to check that the archetype's pages_record contains all of the **included** bitset pages of the query.
-- - One map of page Ptrs to included filter bitsets
-- - One list of "slow" components - i.e., components which do not fit into the paged bitset range, such as pairs or tags.
-- - A "without filter" counterpart to the previous two.
-- These are assembled into a "QueryMatcher" function, which checks archetypes against the filters in in the following
-- order:
-- - record filter, then:
-- - included pages, then:
-- - excluded pages, then:
-- - included (slow), then:
-- - excluded (slow).
-- This matcher function is cached in the query object, and is also cached globally based on an ordered hash of the
-- filter components, and, furthermore, if the query is exclusively "fast" - i.e., only checks bitset pages, it will be
-- cached based on the bitset of included and excluded values as a binary string.
type QueryMatcher = (Arch) -> boolean
type QueryInner = () -> (U53, ...any)
type QueryOuter = (QueryMatcher) -> ({ Arch }, { number })

type Observer<Parameters... = ...any> = {
	callback: (Parameters...) -> (),
	match: QueryMatcher,
}

type Monitor = Observer<U53, Arch, Row>

local function INDEX<Indexable, Index>(indexable: Indexable, index: Index): index<Indexable, Index>
	return (indexable :: any)[index]
end

local function NOOP(): ...any end
local NULL_ARRAY: { any } = table.freeze(table.create(0))
local NULLPTR = buffer.create(0)
local F64_BYTES = 8

--stylua: ignore start
local IDFLAG_TAG                       = 0b10 ^ 0
local IDFLAG_DELETE_ONCLEAR            = 0b10 ^ 1
local IDFLAG_DELETE_ONDELETE           = 0b10 ^ 2
local IDFLAG_DELETE_ONCLEARTARGET      = 0b10 ^ 3
local IDFLAG_DELETE_ONDELETETARGET     = 0b10 ^ 4
local IDFLAG_DELETE_ONCLEARASRELATION  = 0b10 ^ 5
local IDFLAG_DELETE_ONDELETEASRELATION = 0b10 ^ 6
local IDFLAG_EXCLUSIVE                 = 0b10 ^ 7
local IDFLAG_HOOK_ONADD                = 0b10 ^ 8
local IDFLAG_HOOK_ONCHANGE             = 0b10 ^ 9
local IDFLAG_HOOK_ONREM                = 0b10 ^ 10

local EMASK_LO = 0b10 ^ 24
local EMASK_GENERATION = 0b10^16
local EPAIR_OFFSET = 0b10 ^ 48
local COMPONENT_PAGE_SIZE = 32
local COMPONENT_PAGE_RECORD_SIZE = 32
local MAX_PAGED_COMPONENT = COMPONENT_PAGE_SIZE * COMPONENT_PAGE_RECORD_SIZE
local MAX_COMPONENT = MAX_PAGED_COMPONENT - 64
--[[ecs builtins]]
local B2Component             = MAX_COMPONENT + 1
local B2Name                  = MAX_COMPONENT + 2
local B2Exclusive             = MAX_COMPONENT + 3
local B2Wildcard              = MAX_COMPONENT + 4
local B2ChildOf               = MAX_COMPONENT + 5
--[[cleanup conditons]]
local B2OnClear               = MAX_COMPONENT + 6
local B2OnDelete              = MAX_COMPONENT + 7
local B2OnClearTarget         = MAX_COMPONENT + 8
local B2OnDeleteTarget        = MAX_COMPONENT + 9
local B2OnClearAsRelation     = MAX_COMPONENT + 10
local B2OnDeleteAsRelation    = MAX_COMPONENT + 11
--[[cleanup actions]]
local B2CleanupDelete         = MAX_COMPONENT + 12
--[[hooks]]
local B2OnAdd                 = MAX_COMPONENT + 13
local B2OnRemove              = MAX_COMPONENT + 14
local B2OnChange              = MAX_COMPONENT + 15
--stylua: ignore end

local function ASSERT<Condition>(condition: Condition, msg: string?): typeof(assert(... :: Condition))
	if condition then
		return condition
	end
	error(msg, 2)
end

local function ORDERED_HASH(tbl: { any })
	local hashed = table.concat(tbl, "|")
	return hashed
end

local function ENT_LO(entity: U53): U24
	return entity % EMASK_LO
end

-- unused for now, left as a user-facing internal API
local function ENT_HI(entity: U53): number
	return entity // EMASK_LO
end

local function ENT_PAIR(hi: U53, lo: U53): U53
	hi %= EMASK_LO
	hi *= EMASK_LO
	lo %= EMASK_LO
	return hi + lo + EPAIR_OFFSET
end

local function ENT_PAIR_EH(ent: U53): boolean
	return ent > EPAIR_OFFSET
end

local function ENT_PAIR_HI(pair: U53): U24
	return (pair - EPAIR_OFFSET) // EMASK_LO
end

local function ENT_PAIR_LO(pair: U53): U24
	return (pair - EPAIR_OFFSET) % EMASK_LO
end

local function ARCH_APPEND(entity: U53, arch: Arch): number
	local ents = arch.ents
	local ents_top = #ents + 1
	ents[ents_top] = entity
	return ents_top
end

local function ENT_INCREMENT_GENERATION(entity: U53): U53
	if entity > EMASK_LO then
		local id = entity % EMASK_LO
		local generation = entity // EMASK_LO

		local next_gen = generation + 1
		if next_gen >= EMASK_GENERATION then
			return id
		end

		return entity + next_gen * EMASK_LO
	end
	return entity + EMASK_LO
end

local function RECORD_ENSURE_ROW(record: EntRecord, record_arch: Arch, entity: U53): Row
	local row = record.row
	if row then
		return row
	end
	row = ARCH_APPEND(entity, record_arch)
	record.row = row
	return row
end

local function ecs_new(_: any, disable_auto_ensure_dense: boolean?)
	local ROOT_ARCHETYPE: Arch
	local agraph_root: ArchGraphNode = { ids = NULLPTR }
	local agraph: Set<ArchHash, ArchGraphNode> = { [""] = agraph_root }
	local arch_has_empty_rows: { [Arch]: true } = {}
	local arch_scheduled_for_deletion: { [Arch]: true } = {}
	local archetypes: { [ArchLocation]: Arch } = {}
	local archetypes_count = 0
	local observe_arch_added: Set<U53, { Observer<Arch> }> = {}
	local observe_arch_removed: Set<U53, { Observer<Arch> }> = {}

	local cindex: Set<U53, IdRecord> = {}

	local eindex_dense: Set<U26, U53> = {}
	local eindex_sparse: Set<U24, EntRecord> = {}
	local eindex_alive_count: number = 0
	local eindex_id_top: number = 0

	local user_components_count: number = 0

	--[=[
	Gets a record for an entity if one exists. Runs no safety checks, so, it may retrieve a record from a dead entity or
	from an entirely different generation.
	]=]
	local function eindex_try_any_record(entity: U53): EntRecord?
		return eindex_sparse[ENT_LO(entity)]
	end

	--[[
	Retrieves record for an entity if that entity matches the recorded entity. This guarantees the generation matches,
	but, will not check if the entity is alive. If a generation is incremented manually or a rogue number happens to
	match the entity low portion and full ID including generation.
	]]
	local function eindex_try_matching_record(entity: U53): EntRecord?
		local record = eindex_try_any_record(entity)
		if record and eindex_dense[record.dense] ~= entity then
			return nil
		end
		return record
	end

	-- --[[
	-- Retrieves record for an entity if that entity is alive and matches the recorded entity. This guarantees generation
	-- matches and that the id given is alive.
	-- ]]
	-- local function eindex_try_alive_record(entity: U53): EntRecord?
	-- 	local record = eindex_try_any_record(entity)
	-- 	if record then
	-- 		local record_dense = record.dense
	-- 		local dead_eh = record_dense > eindex_alive_count
	-- 		if dead_eh or (eindex_dense[record_dense] ~= entity) then return nil end
	-- 	end
	-- 	return record
	-- end

	local function eindex_alive_eh(entity: U53): boolean
		local record = eindex_try_any_record(entity)
		if record then
			local record_dense = record.dense
			return (record_dense <= eindex_alive_count) and (eindex_dense[record_dense] == entity)
		end
		return false
	end

	local function ecs_existed(entity: U53): boolean
		return eindex_try_any_record(entity) ~= nil
	end

	local function ecs_contains(entity: U53): boolean
		return eindex_alive_eh(entity)
	end

	--[=[
	Gets the latest alive generation of an entity if one exists.
	]=]
	local function ent_try_latest_alive(entity: U53): U53?
		local record = eindex_try_any_record(entity)
		if record then
			return eindex_dense[record.dense] --
		end
		return nil
	end

	-- local function ent_try_latest_alive_safe(entity: U53): U53?
	-- 	local record = eindex_try_any_record(entity)
	-- 	if record then
	-- 		local record_dense = record.dense
	-- 		if (record_dense <= eindex_alive_count) and (eindex_dense[record_dense] == entity) then return entity end
	--
	-- 		if entity > EMASK_LO then return nil end
	--
	-- 		return eindex_dense[record.dense]
	-- 	end
	--
	-- 	return nil
	-- end

	local function eindex_new_id_alive(): U53
		if eindex_alive_count < eindex_id_top then
			eindex_alive_count += 1
			return eindex_dense[eindex_alive_count]
		end

		eindex_id_top += 1
		local id = eindex_id_top

		eindex_alive_count += 1
		eindex_dense[eindex_alive_count] = id
		eindex_sparse[id] = {
			dense = eindex_alive_count,
			arch = ROOT_ARCHETYPE,
		}

		return id
	end

	local function ecs_entity(): U53
		return (eindex_new_id_alive())
	end

	local function ecs_in_use(entity: U53): boolean
		local record = eindex_try_matching_record(entity)
		if record then
			return not not record.hooks
		end
		return false
	end

	local function arch_ensure_dense(arch: Arch): ()
		local empty_rows = arch.empty_rows
		local empty_rows_count = #empty_rows
		if empty_rows_count == 0 then
			return
		end
		local entities = arch.ents
		local columns = arch.columns_dense
		local columns_count = #columns
		local last_row = #entities
		if empty_rows_count == last_row then
			table.clear(entities)
			for col_index = 1, columns_count do
				local column = columns[col_index]
				if column == NULL_ARRAY then
					continue
				end
				table.clear(column)
			end
			arch.empty_rows = {}
			return
		end
		table.sort(empty_rows)
		-- reverse iter so that we're filling the furthest rows last
		for empty_row_index = empty_rows_count, 1, -1 do
			local empty_row = empty_rows[empty_row_index]
			empty_rows[empty_row_index] = nil

			local occupied_entity = entities[last_row]

			if occupied_entity then
				entities[empty_row], entities[last_row] = occupied_entity, nil

				for col_index = 1, columns_count do
					local column = columns[col_index]
					if column == NULL_ARRAY then
						continue
					end
					column[empty_row], column[last_row] = column[last_row], nil
				end

				local record = eindex_sparse[ENT_LO(occupied_entity)]
				record.row = empty_row
			else
				--[[
				iterating unoccupied rows from high to low means any empty entity at the end should be **this** entity
				]]
				entities[last_row] = nil
				for col_index = 1, columns_count do
					local column = columns[col_index]
					if column == NULL_ARRAY then
						continue
					end
					column[last_row] = nil
				end
			end
			last_row -= 1
		end
	end

	--[=[
	src_row should always be an occupied row in the src archetype
	]=]
	local function arch_move(src: Arch, src_entity: U53, src_row: Row, dst: Arch, dst_row: Row): ()
		local src_columns = src.columns_dense
		local src_entities = src.ents
		local src_ids = src.ids
		local src_empty_rows = src.empty_rows
		local dst_entities = dst.ents
		local dst_columns_map = dst.columns_map

		local src_columns_count = #src_columns
		src_entities[src_row], dst_entities[dst_row] = false, src_entity

		table.insert(src_empty_rows, src_row)
		arch_has_empty_rows[src] = true

		for columns_index = 1, src_columns_count do
			local src_column = src_columns[columns_index]

			-- tags are given a null array column
			if src_column == NULL_ARRAY then
				continue
			end

			local dst_column = dst_columns_map[src_ids[columns_index]]

			-- dst archetype might not have this column
			if dst_column then
				dst_column[dst_row] = src_column[src_row]
			end

			-- since this row is unused until made dense, set the src column value to false so the column does not hold a
			-- hard reference to its previous value.
			src_column[src_row] = false
		end

		-- src entity should always be occupied when moved
		local moved_record = eindex_sparse[ENT_LO(src_entity :: U53)]
		moved_record.row = dst_row
		moved_record.arch = dst
	end

	local function ent_move(entity: U53, record: EntRecord, src: Arch, dst: Arch): Row
		local src_row = RECORD_ENSURE_ROW(record, src, entity)
		local dst_row = ARCH_APPEND(entity, dst)
		arch_move(src, entity, src_row, dst, dst_row)
		return dst_row
	end

	local function fetch_at_row(columns_map: index<Arch, "columns_map">, id: U53, row: Row): any?
		local column = columns_map[id]
		if column then
			return column[row]
		end
		return column
	end

	local function ecs_get(entity: U53, A: U53, B: U53?, C: U53?, D: U53?, ...: U53): ...any
		local record = eindex_try_matching_record(entity)
		if not record then
			return
		end

		local record_arch = record.arch
		local row = RECORD_ENSURE_ROW(record, record_arch, entity)

		local column_map = record_arch.columns_map

		local a = fetch_at_row(column_map, A, row)
		if B then
			local b = fetch_at_row(column_map, B, row)
			if C then
				local c = fetch_at_row(column_map, C, row)
				if D then
					local d = fetch_at_row(column_map, D, row)
					local E = ...
					if E then
						local rest: { any } = { ... }
						for index = 1, #rest do
							rest[index] = fetch_at_row(column_map, rest[index], row)
						end
						return a, b, c, d, table.unpack(rest)
					else
						return a, b, c, d
					end
				else
					return a, b, c
				end
			else
				return a, b
			end
		else
			return a
		end
	end

	local function ecs_bulk_get(entity: U53, ids: { U53 }): { any }?
		local record = eindex_try_matching_record(entity)
		if not record then
			return nil
		end

		local record_arch = record.arch
		local row = RECORD_ENSURE_ROW(record, record_arch, entity)

		local column_map = record_arch.columns_map

		local ids_count = #ids
		local data = table.create(ids_count) :: { any }
		for ids_index = 1, ids_count do
			local id = ids[ids_index]
			data[ids_index] = fetch_at_row(column_map, id, row)
		end
		return data
	end

	local function ecs_has(entity: U53, A: U53, B: U53?, C: U53?, D: U53?, ...: U53): boolean
		local record = eindex_try_matching_record(entity)
		if not record then
			return false
		end

		local column_map = record.arch.columns_map

		local has_all = column_map[A]
		if has_all then
			if B then
				has_all = column_map[B]
				if has_all then
					if C then
						has_all = column_map[C]
						if has_all then
							if D then
								has_all = column_map[D]
								if has_all then
									local E = ...
									if E then
										local rest: { any } = { ... }
										local rest_count = #rest
										for rest_index = 1, rest_count do
											if column_map[rest_index] then
												continue
											end
											has_all = false
											break
										end
										return not not has_all
									else
										return true
									end
								else
									return false
								end
							else
								return true
							end
						else
							return false
						end
					else
						return true
					end
				else
					return false
				end
			else
				return true
			end
		else
			return false
		end
	end

	local function ent_has_inline(entity: U53, id: U53): boolean
		local record = eindex_try_matching_record(entity)
		if not record then
			return false
		end

		if record.arch.columns_map[id] then
			return true
		else
			return false
		end
	end

	local function ecs_target(entity: U53, relation: U24, index: number?): U24?
		local record = eindex_try_matching_record(entity)
		if not record then
			return nil
		end

		local wildcard_relation = ENT_PAIR(relation, B2Wildcard)
		local id_record = cindex[wildcard_relation]

		if not id_record then
			return nil
		end
		local arch = record.arch

		local dense_location = INDEX(id_record, idr_arch_sparse)[arch]
		local count = INDEX(id_record, idr_dense_counts)[dense_location]

		if not count then
			return nil
		end

		local column_start = INDEX(id_record, idr_dense_column)[dense_location]

		local id_target_index = column_start
		if index then
			if index >= count then
				return nil
			else
				id_target_index += index
			end
		end

		local id_target = arch.ids[id_target_index]

		if not id_target then
			return nil
		end

		local alive = ent_try_latest_alive(ENT_PAIR_LO(id_target))

		return alive
	end

	local function ecs_parent(entity: U53): U24?
		local record = eindex_try_matching_record(entity)
		if not record then
			return nil
		end

		local wildcard_relation = ENT_PAIR(B2ChildOf, B2Wildcard)
		local id_record = cindex[wildcard_relation]

		if not id_record then
			return nil
		end
		local arch = record.arch

		local dense_location = INDEX(id_record, idr_arch_sparse)[arch]

		local column_start = INDEX(id_record, idr_dense_column)[dense_location]

		local id_target_index = column_start

		local id_target = arch.ids[id_target_index]

		if not id_target then
			return nil
		end

		local alive = ent_try_latest_alive(ENT_PAIR_LO(id_target))

		return alive
	end

	local function id_record_new(id: U53): IdRecord
		local flags = 0

		local relation = id
		local component_eh: boolean?
		if ENT_PAIR_EH(id) then
			-- Luau
			relation = ent_try_latest_alive(ENT_PAIR_HI(id)) :: U53
			local target = ent_try_latest_alive(ENT_PAIR_LO(id))
			ASSERT(relation and target, "Internal Error")

			component_eh = ent_has_inline(target :: typeof(assert(target)), B2Component)

			if ent_has_inline(relation, B2Exclusive) then
				flags += IDFLAG_EXCLUSIVE
			end

			if ecs_target(relation, B2OnClearTarget) == B2CleanupDelete then
				flags += IDFLAG_DELETE_ONCLEARTARGET
				flags += IDFLAG_DELETE_ONDELETETARGET
			elseif ecs_target(relation, B2OnDeleteTarget) == B2CleanupDelete then
				flags += IDFLAG_DELETE_ONDELETETARGET
			end
			if ecs_target(relation, B2OnClearAsRelation) == B2CleanupDelete then
				flags += IDFLAG_DELETE_ONCLEARASRELATION
				flags += IDFLAG_DELETE_ONDELETEASRELATION
			elseif ecs_target(relation, B2OnDeleteAsRelation) == B2CleanupDelete then
				flags += IDFLAG_DELETE_ONDELETEASRELATION
			end
		else
			if ecs_target(relation, B2OnClear) == B2CleanupDelete then
				flags += IDFLAG_DELETE_ONCLEAR
				flags += IDFLAG_DELETE_ONDELETE
			elseif ecs_target(relation, B2OnDelete) == B2CleanupDelete then
				flags += IDFLAG_DELETE_ONDELETE
			end
		end

		component_eh = component_eh or ent_has_inline(relation, B2Component)

		if not component_eh then
			flags += IDFLAG_TAG
		end

		local record = eindex_try_any_record(relation) :: EntRecord
		local hooks: Hooks = record.hooks :: Hooks
		local on_add: InternalOnAddHook?, on_change: InternalOnChangeHook?, on_remove: InternalOnRemoveHook?
		if not hooks then
			on_add, on_change, on_remove = ecs_get(relation, B2OnAdd, B2OnChange, B2OnRemove)
			if on_add or on_change or on_remove then
				hooks = table.freeze {
					[hks_add] = on_add,
					[hks_change] = on_change,
					[hks_remove] = on_remove,
					-- Luau
				} :: any
			else
				hooks = NULL_ARRAY :: Hooks
			end
			record.hooks = hooks
		else
			on_add, on_change, on_remove = INDEX(hooks, hks_add), INDEX(hooks, hks_change), INDEX(hooks, hks_remove)
		end

		if on_add then
			flags += IDFLAG_HOOK_ONADD
		end
		if on_change then
			flags += IDFLAG_HOOK_ONCHANGE
		end
		if on_remove then
			flags += IDFLAG_HOOK_ONREM
		end

		local id_record = {
			[idr_flags] = flags,

			[idr_hooks] = hooks,
			[idr_arch_sparse] = {},
			[idr_arch_count] = 0,
			[idr_dense_cached] = {},
			[idr_dense_column] = {},
			[idr_dense_counts] = {},
		} :: IdRecord

		cindex[id] = id_record

		return id_record
	end

	local function id_record_ensure(id: U53): IdRecord
		do
			local id_record = cindex[id]
			if id_record then
				return id_record
			end
		end

		return (id_record_new(id))
	end

	local function id_record_arch_append(id_record: IdRecord, id: U53, arch: Arch, count: number): ()
		local id_record_arch_sparse = INDEX(id_record, idr_arch_sparse)
		local id_record_dense_counts = INDEX(id_record, idr_dense_counts)

		local dense_location = id_record_arch_sparse[arch]
		-- id record already contains arch, increment count
		if dense_location then
			local id_record_dense_count = id_record_dense_counts[dense_location] + 1
			id_record_dense_counts[dense_location] = id_record_dense_count
		else
			local id_record_arch_count = INDEX(id_record, idr_arch_count) + 1
			id_record_arch_sparse[arch] = id_record_arch_count;
			(id_record :: { [typeof(idr_arch_count)]: index<IdRecord, typeof(idr_arch_count)> })[idr_arch_count] =
				id_record_arch_count

			INDEX(id_record, idr_dense_cached)[id_record_arch_count] = arch
			INDEX(id_record, idr_dense_column)[id_record_arch_count] = count
			id_record_dense_counts[id_record_arch_count] = 1
		end
	end

	local function ids_page_mapping(ids: Sorted<IdList>): (IdList, Sorted<{ Ptr }>, { Bitset }, number)
		local unpaged: { U53 } = {}
		local unpaged_count = 0
		local pages_record = 0
		local pages_ptrs: { Ptr } = {}
		local pages: { Bitset } = {}
		local pages_count = 0

		local ids_count = #ids
		for ids_index = 1, ids_count do
			local id = ids[ids_index]
			if id > COMPONENT_PAGE_SIZE then
				unpaged_count += 1
				unpaged[unpaged_count] = id
				continue
			end

			local id_page = id // COMPONENT_PAGE_RECORD_SIZE
			local id_page_position = id % COMPONENT_PAGE_SIZE
			local id_page_ptr = id_page * COMPONENT_PAGE_SIZE

			pages_record = bit32.bor(pages_record, 2 ^ id_page)

			local inserted: true?
			local bitflag = 2 ^ id_page_position
			for pages_index = 1, pages_count do
				local page_ptr = pages_ptrs[pages_index]
				if page_ptr >= id_page_ptr then
					inserted = true
					if page_ptr == id_page_ptr then
						pages[pages_index] = bit32.bor(pages[pages_index], bitflag)
					else
						table.insert(pages_ptrs, pages_index, id_page_ptr)
						table.insert(pages, pages_index, bitflag)
					end
					break
				end
			end
			if not inserted then
				pages_count += 1
				pages_ptrs[pages_count] = id_page_ptr
				pages[pages_count] = bitflag
			end
		end
		return unpaged, pages_ptrs, pages, pages_record
	end

	local function pagebuff_from_mapping(pages_ptrs: Sorted<{ Ptr }>, pages_bitsets: { Bitset }): buffer
		local buff = buffer.create(MAX_PAGED_COMPONENT)
		for pages_index = 1, #pages_ptrs do
			local page_ptr = pages_ptrs[pages_index]
			local page_bitset = pages_bitsets[pages_index]
			buffer.writeu32(buff, page_ptr, page_bitset)
		end
		return buff
	end

	local function list_from_buff(id_buffer: buffer): { U53 }
		local buff_len = buffer.len(id_buffer)
		local list = table.create(buff_len / F64_BYTES) :: { U53 }
		local list_count = 0
		for ptr = 0, buffer.len(id_buffer) - F64_BYTES, F64_BYTES do
			list_count += 1
			list[list_count] = buffer.readf64(id_buffer, ptr)
		end
		return list
	end

	local function arch_new(agraph_node: ArchGraphNode): Arch
		local ids = agraph_node.ids
		local hash = buffer.tostring(ids)
		local ids_list = list_from_buff(ids)
		local _, pages_ptrs, pages_bitsets, pages_record = ids_page_mapping(ids_list)
		local pages_buff = pagebuff_from_mapping(pages_ptrs, pages_bitsets)

		local arch_location = archetypes_count + 1
		archetypes_count = arch_location

		local id_count = #ids_list
		local arch_columns_dense = table.create(id_count) :: { Column }
		local arch_columns_map = {} :: Set<U53, Column>

		local arch: Arch = {
			location = arch_location,
			hash = hash,

			pages_record = pages_record,
			bitset_pages = pages_buff,

			ids = ids_list,

			empty_rows = {},

			columns_map = arch_columns_map,
			columns_dense = arch_columns_dense,
			ents = {},
		}
		archetypes[archetypes_count] = arch
		agraph_node.arch = arch

		for ids_index = 1, id_count do
			local id = ids_list[ids_index]
			local id_record = id_record_ensure(id)
			local column = if bit32.btest(INDEX(id_record, idr_flags), IDFLAG_TAG) then NULL_ARRAY else {}
			arch_columns_dense[ids_index] = column
			arch_columns_map[id] = column
			if ENT_PAIR_EH(id) then
				local relation = ENT_PAIR_HI(id)
				local object = ENT_PAIR_LO(id)
				local relation_wildcard = ENT_PAIR(relation, B2Wildcard)
				local relation_wildcard_id_record = id_record_ensure(relation_wildcard)
				id_record_arch_append(relation_wildcard_id_record, relation_wildcard, arch, ids_index)
				arch_columns_map[relation_wildcard] = column

				local wildcard_object = ENT_PAIR(B2Wildcard, object)
				local wildcard_object_id_record = id_record_ensure(wildcard_object)
				id_record_arch_append(wildcard_object_id_record, wildcard_object, arch, ids_index)
				arch_columns_map[wildcard_object] = column
			end
			id_record_arch_append(id_record, id, arch, ids_index)
		end
		for id in arch_columns_map do
			local observer_cache = observe_arch_added[id]
			if observer_cache then
				local observer_cache_count = #observer_cache
				for observer_cache_index = 1, observer_cache_count do
					local observer = observer_cache[observer_cache_index]
					if observer.match(arch) then
						observer.callback(arch)
					end
				end
			end
		end

		return arch
	end

	-- unused for now, left as a user-facing internal API
	local function agraph_ensure(ids: buffer): ArchGraphNode
		local hash = buffer.tostring(ids)
		do
			local cached = agraph[hash]
			if cached then
				return cached
			end
		end

		local node: ArchGraphNode = {
			ids = ids,
		}
		agraph[hash] = node

		return node
	end

	local function agraph_ensure_arch(node: ArchGraphNode): Arch
		do
			local arch = node.arch
			if arch then
				return arch
			end
		end

		local arch = arch_new(node)

		return arch
	end

	local function binary_search(buff: buffer, find: number): number?
		local lower = 0
		local upper = (buffer.len(buff) - 8) / 8
		local middle: number
		while lower <= upper do
			middle = lower + ((upper - lower) // 2)
			local ptr = middle * 8
			local id = buffer.readf64(buff, ptr)

			if id < find then
				lower = middle + 1
			elseif id > find then
				upper = middle - 1
			else
				return ptr
			end
		end
		return nil
	end

	local function binary_insert(buff: buffer, search: number): number
		local len = buffer.len(buff)
		local lower = 0
		local upper = (len - 8) / 8
		local ptr = 0
		while lower <= upper do
			if upper <= lower then
				ptr = lower * 8
				if search > buffer.readf64(buff, ptr) then
					ptr += 8
				end
				break
			end

			local middle = lower + ((upper - lower) // 2)
			ptr = middle * 8
			local id = buffer.readf64(buff, ptr)

			if id < search then
				lower = middle + 1
			elseif id > search then
				upper = middle - 1
			else
				return ptr
			end
		end
		return ptr
	end

	local function agraph_traverse_add(src: ArchGraphNode, id: U53): ArchGraphNode
		local src_ids = src.ids
		local src_ids_len = buffer.len(src_ids)

		local traversed_ids_len = src_ids_len + F64_BYTES
		local traversed_ids = buffer.create(traversed_ids_len)
		local insert_ptr = binary_insert(src_ids, id)

		if insert_ptr == src_ids_len then
			buffer.copy(traversed_ids, 0, src_ids)
			buffer.writef64(traversed_ids, insert_ptr, id)
		else
			buffer.copy(traversed_ids, 0, src_ids, 0, insert_ptr)
			buffer.writef64(traversed_ids, insert_ptr, id)
			local second_copy_begin = insert_ptr + F64_BYTES
			if second_copy_begin <= src_ids_len then
				buffer.copy(traversed_ids, second_copy_begin, src_ids, insert_ptr)
			end
		end

		local hash = buffer.tostring(traversed_ids)
		do
			local traversed = agraph[hash]
			if traversed then
				traversed[id] = src
				src[id] = traversed
				return traversed
			end
		end

		local traversed: ArchGraphNode = {
			ids = traversed_ids,
			[id] = src,
		}
		src[id] = traversed
		agraph[hash] = traversed

		return traversed
	end

	local function agraph_traverse_add_ensure(src: ArchGraphNode, id: U53): ArchGraphNode
		do
			local traversed = src[id]
			if traversed then
				return traversed
			end
		end

		return (agraph_traverse_add(src, id))
	end

	local function agraph_traverse_rem(src: ArchGraphNode, id: U53): ArchGraphNode
		local src_ids = src.ids
		local src_ids_len = buffer.len(src_ids)
		local src_ids_top: Ptr = src_ids_len - F64_BYTES

		local traversed_ids_len = src_ids_len - F64_BYTES
		local traversed_ids = buffer.create(traversed_ids_len)
		local remove_ptr = binary_search(src_ids, id) :: number

		if remove_ptr == src_ids_top then
			buffer.copy(traversed_ids, 0, src_ids, 0, traversed_ids_len)
		else
			buffer.copy(traversed_ids, 0, src_ids, 0, remove_ptr) --
			buffer.copy(traversed_ids, remove_ptr, src_ids, remove_ptr + F64_BYTES) --
		end

		local hash = buffer.tostring(traversed_ids)
		do
			local traversed = agraph[hash]
			if traversed then
				traversed[id] = src
				src[id] = traversed
				return traversed
			end
		end

		local traversed: ArchGraphNode = {
			ids = traversed_ids,
			[id] = src,
		}
		src[id] = traversed
		agraph[hash] = traversed

		return traversed
	end

	local function agraph_traverse_rem_ensure(src: ArchGraphNode, id: U53): ArchGraphNode
		do
			local traversed = src[id]
			if traversed then
				return traversed
			end
		end

		return (agraph_traverse_rem(src, id))
	end

	local function ecs_add(entity: U53, id: U53): ()
		local record = eindex_try_matching_record(entity)
		if not record then
			return
		end

		local record_arch = record.arch
		local didnt_move = record_arch.columns_map[id]
		if didnt_move then
			return
		end
		local start_arch = record_arch

		local id_record = id_record_ensure(id)
		local flags = INDEX(id_record, idr_flags)
		local monitors = INDEX(id_record, idr_monitors)
		local relation = id
		local dst_node: ArchGraphNode
		if ENT_PAIR_EH(id) and bit32.btest(flags, IDFLAG_EXCLUSIVE) then
			relation = ENT_PAIR_HI(id)
			local target = ecs_target(entity, relation)
			if target then
				local pair = ENT_PAIR(relation, target)

				if bit32.btest(flags, IDFLAG_HOOK_ONREM) then
					local hooks = INDEX(id_record, idr_hooks)
					local on_rem = INDEX(hooks, hks_remove);
					(on_rem :: typeof(assert(on_rem)))(entity, pair)
					local new_arch = record.arch
					if new_arch ~= record_arch then
						record_arch = new_arch
					end
				end
				dst_node = agraph[record_arch.hash]
				dst_node = agraph_traverse_rem_ensure(dst_node, pair) --
			else
				dst_node = agraph[record_arch.hash]
			end
		else
			dst_node = agraph[record_arch.hash]
		end

		if bit32.btest(flags, IDFLAG_HOOK_ONADD) then
			local hooks = INDEX(id_record, idr_hooks)
			local on_add = INDEX(hooks, hks_add);
			(on_add :: typeof(assert(on_add)))(entity, id)
			local new_arch = record.arch
			if new_arch ~= record_arch then
				record_arch = new_arch
				dst_node = agraph[record_arch.hash]
			end
		end

		dst_node = agraph_traverse_add_ensure(dst_node, id)

		local dst_arch = agraph_ensure_arch(dst_node)
		local dst_row = ent_move(entity, record, record_arch, dst_arch)
		if monitors then
			for monitors_index = 1, #monitors do
				local monitor = monitors[monitors_index]
				local match = monitor.match
				if (not match(start_arch)) and match(dst_arch) then
					monitor.callback(entity, dst_arch, dst_row) --
				end
			end
		end
	end

	local function ecs_bulk_add(entity: U53, add_ids: { U53 }): ()
		local record = eindex_try_matching_record(entity)
		if not record then
			return
		end

		local record_arch = record.arch
		local start_arch = record_arch
		local record_column_map = record_arch.columns_map
		local dst_node = agraph[record_arch.hash]

		local check_monitors: Set<Monitor> = {}
		for add_ids_index = 1, #add_ids do
			local id = add_ids[add_ids_index]

			if record_column_map[id] then
				continue
			end

			local id_record = id_record_ensure(id)
			local flags = INDEX(id_record, idr_flags)
			local monitors = INDEX(id_record, idr_monitors)
			if monitors then
				for monitors_index = 1, #monitors do
					check_monitors[monitors[monitors_index]] = true
				end
			end
			local relation = id
			if ENT_PAIR_EH(id) and bit32.btest(flags, IDFLAG_EXCLUSIVE) then
				relation = ENT_PAIR_HI(id)
				local target = ecs_target(entity, relation)
				if target then
					local pair = ENT_PAIR(relation, target)

					if bit32.btest(flags, IDFLAG_HOOK_ONREM) then
						local hooks = INDEX(id_record, idr_hooks)
						local on_rem = INDEX(hooks, hks_remove);
						(on_rem :: typeof(assert(on_rem)))(entity, pair)
						local new_arch = record.arch
						if new_arch ~= record_arch then
							record_arch = new_arch
							record_column_map = record_arch.columns_map
							dst_node = agraph[record_arch.hash]
						end
					end
					dst_node = agraph_traverse_rem_ensure(dst_node, pair) --
				end
			end

			if bit32.btest(flags, IDFLAG_HOOK_ONADD) then
				local hooks = INDEX(id_record, idr_hooks)
				local on_add = INDEX(hooks, hks_add);
				(on_add :: typeof(assert(on_add)))(entity, id)
				local new_arch = record.arch
				if new_arch ~= record_arch then
					record_arch = new_arch
					record_column_map = record_arch.columns_map
					dst_node = agraph[record_arch.hash]
				end
			end
			dst_node = agraph_traverse_add_ensure(dst_node, id)
		end

		local dst_arch = agraph_ensure_arch(dst_node)
		local dst_row = ent_move(entity, record, record_arch, dst_arch)

		for monitor in check_monitors do
			local match = monitor.match
			if (not match(start_arch)) and match(dst_arch) then
				monitor.callback(entity, dst_arch, dst_row) --
			end
		end
	end

	local function ecs_component(): U53
		local id = user_components_count + 1
		if id > MAX_COMPONENT then
			error(`Cannot create component above {MAX_COMPONENT}`, 2)
		end
		user_components_count = id
		ecs_add(id, B2Component)

		return id
	end

	local function ecs_set(entity: U53, id: U53, data: any): ()
		local record = eindex_try_matching_record(entity)
		if not record then
			return
		end

		local record_arch = record.arch
		local column = record_arch.columns_map[id]
		if column then
			local id_record = cindex[id]
			local hooks = INDEX(id_record, idr_hooks)
			local on_change = INDEX(hooks, hks_change)
			if on_change then
				(on_change :: typeof(assert(on_change)))(entity, id, data)
				local new_arch = record.arch
				if new_arch ~= record_arch then
					record_arch = new_arch
					column = record_arch.columns_map[id]
				end
			end
			local record_row = RECORD_ENSURE_ROW(record, record_arch, entity)
			column[record_row] = data
		else
			local start_arch = record_arch
			local id_record = id_record_ensure(id)
			local flags = INDEX(id_record, idr_flags)
			local monitors = INDEX(id_record, idr_monitors)
			local relation = id
			local dst_node: ArchGraphNode
			if ENT_PAIR_EH(id) and bit32.btest(flags, IDFLAG_EXCLUSIVE) then
				relation = ENT_PAIR_HI(id)
				local target = ecs_target(entity, relation)
				if target then
					local pair = ENT_PAIR(relation, target)

					if bit32.btest(flags, IDFLAG_HOOK_ONREM) then
						local hooks = INDEX(id_record, idr_hooks)
						local on_rem = INDEX(hooks, hks_remove);
						(on_rem :: typeof(assert(on_rem)))(entity, pair)
						local new_arch = record.arch
						if new_arch ~= record_arch then
							record_arch = new_arch
						end
					end
					dst_node = agraph[record_arch.hash]
					dst_node = agraph_traverse_rem_ensure(dst_node, pair) --
				else
					dst_node = agraph[record_arch.hash]
				end
			else
				dst_node = agraph[record_arch.hash]
			end

			if bit32.btest(flags, IDFLAG_HOOK_ONADD) then
				local hooks = INDEX(id_record, idr_hooks)
				local on_add = INDEX(hooks, hks_add);
				(on_add :: typeof(assert(on_add)))(entity, id, data)
				local new_arch = record.arch
				if new_arch ~= record_arch then
					record_arch = new_arch
					dst_node = agraph[record_arch.hash]
				end
			end
			dst_node = agraph_traverse_add_ensure(dst_node, id)

			local dst_arch = agraph_ensure_arch(dst_node)
			column = dst_arch.columns_map[id]
			local dst_row = ent_move(entity, record, record_arch, dst_arch)
			column[dst_row] = data
			if monitors then
				for monitors_index = 1, #monitors do
					local monitor = monitors[monitors_index]
					local match = monitor.match
					if (not match(start_arch)) and match(dst_arch) then
						monitor.callback(entity, dst_arch, dst_row) --
					end
				end
			end
		end
	end

	local function ecs_bulk_set(entity: U53, set_ids: { U53 }, data: { any }): ()
		local record = eindex_try_matching_record(entity)
		if not record then
			return
		end

		local record_arch = record.arch
		local start_arch = record_arch
		local record_arch_column_map = record_arch.columns_map

		local set_ids_count = #set_ids

		local monitor_lists: { { Monitor } }?
		local monitor_lists_count: number
		local dst_node = agraph[record_arch.hash]
		for set_ids_index = 1, set_ids_count do
			local id = set_ids[set_ids_index]
			local column: Column = record_arch_column_map[id]
			local setting_data = data[set_ids_index]
			if column then
				local id_record = cindex[id]
				local flags = INDEX(id_record, idr_flags)
				local monitors = INDEX(id_record, idr_monitors)
				if monitors then
					if monitor_lists then
						monitor_lists_count += 1
						monitor_lists[monitor_lists_count] = monitors
					else
						monitor_lists_count = 1
						monitor_lists = { monitors }
					end
				end
				if bit32.btest(flags, IDFLAG_HOOK_ONCHANGE) then
					local hooks = INDEX(id_record, idr_hooks)
					local hks_change = INDEX(hooks, hks_change);
					--
					(hks_change :: typeof(assert(hks_change)))(entity, id, setting_data)
					local new_arch = record.arch
					if new_arch ~= record_arch then
						record_arch = new_arch
						record_arch_column_map = record_arch.columns_map
						column = record_arch_column_map[id]
					end
				end
			else
				local id_record = id_record_ensure(id)
				local flags = INDEX(id_record, idr_flags)
				local relation = id
				if ENT_PAIR_EH(id) and bit32.btest(flags, IDFLAG_EXCLUSIVE) then
					relation = ENT_PAIR_HI(id)
					local target = ecs_target(entity, relation)
					if target then
						local pair = ENT_PAIR(relation, target)

						if bit32.btest(flags, IDFLAG_HOOK_ONREM) then
							local hooks = INDEX(id_record, idr_hooks)
							local on_rem = INDEX(hooks, hks_remove);
							(on_rem :: typeof(assert(on_rem)))(entity, pair)
							local new_arch = record.arch
							if new_arch ~= record_arch then
								record_arch = new_arch
								dst_node = agraph[record_arch.hash]
							end
						end
						dst_node = agraph_traverse_rem_ensure(dst_node, pair) --
					end
				end

				if bit32.btest(flags, IDFLAG_HOOK_ONADD) then
					local hooks = INDEX(id_record, idr_hooks)
					local on_add = INDEX(hooks, hks_add);
					(on_add :: typeof(assert(on_add)))(entity, id, setting_data)
					local new_arch = record.arch
					if new_arch ~= record_arch then
						record_arch = new_arch
						dst_node = agraph[record_arch.hash]
					end
				end
				dst_node = agraph_traverse_add_ensure(dst_node, id)
			end
		end

		local dst_arch = agraph_ensure_arch(dst_node)
		local dst_row = ent_move(entity, record, record_arch, dst_arch)
		local dst_column_map = dst_arch.columns_map

		for ids_index = 1, set_ids_count do
			local id = set_ids[ids_index]
			local column = dst_column_map[id]
			if column == NULL_ARRAY then
				continue
			end
			if not column then
				continue
			end

			local id_data = data[ids_index]
			column[dst_row] = id_data
		end
		if monitor_lists then
			for monitor_lists_index = 1, monitor_lists_count do
				local monitors = monitor_lists[monitor_lists_index]
				for monitors_index = 1, #monitors do
					local monitor = monitors[monitors_index]
					local match = monitor.match
					if (not match(start_arch)) and match(dst_arch) then
						monitor.callback(entity, dst_arch, dst_row) --
					end
				end
			end
		end
	end

	local function ecs_remove(entity: U53, id: U53): ()
		local record = eindex_try_matching_record(entity)
		if not record then
			return
		end

		local record_arch = record.arch
		local record_column_map = record_arch.columns_map
		local column = record_column_map[id]
		if not column then
			return
		end
		local start_arch = record_arch

		local id_record = id_record_ensure(id)
		local flags = INDEX(id_record, idr_flags)
		local monitors = INDEX(id_record, idr_monitors)
		local dst_node: ArchGraphNode
		if bit32.btest(flags, IDFLAG_HOOK_ONREM) then
			local hooks = INDEX(id_record, idr_hooks)
			local on_rem = INDEX(hooks, hks_remove);
			(on_rem :: typeof(assert(on_rem)))(entity, id)
			local new_arch = record.arch
			if new_arch ~= record_arch then
				record_arch = new_arch
			end
		end

		dst_node = agraph[record_arch.hash]
		dst_node = agraph_traverse_rem_ensure(dst_node, id)
		local dst_arch = agraph_ensure_arch(dst_node)
		local dst_row = ent_move(entity, record, record_arch, dst_arch)
		if monitors then
			for monitors_index = 1, #monitors do
				local monitor = monitors[monitors_index]
				local match = monitor.match
				if (not match(start_arch)) and match(dst_arch) then
					monitor.callback(entity, dst_arch, dst_row) --
				end
			end
		end
	end

	local function ecs_bulk_remove(entity: U53, remove_ids: { U53 }): ()
		local record = eindex_try_matching_record(entity)
		if not record then
			return
		end

		local record_arch = record.arch
		local start_arch = record_arch
		local record_column_map = record_arch.columns_map

		local monitor_lists: { { Monitor } }?
		local monitor_lists_count: number
		local dst_node = agraph[record_arch.hash]
		for remove_ids_index = 1, #remove_ids do
			local id = remove_ids[remove_ids_index]

			if not record_column_map[id] then
				continue
			end
			local id_record = id_record_ensure(id)
			local monitors = INDEX(id_record, idr_monitors)
			if monitors then
				if monitor_lists then
					monitor_lists_count += 1
					monitor_lists[monitor_lists_count] = monitors
				else
					monitor_lists_count = 1
					monitor_lists = { monitors }
				end
			end
			local flags = INDEX(id_record, idr_flags)
			if bit32.btest(flags, IDFLAG_HOOK_ONREM) then
				local hooks = INDEX(id_record, idr_hooks)
				local on_rem = INDEX(hooks, hks_remove);
				(on_rem :: typeof(assert(on_rem)))(entity, id)
				local new_arch = record.arch
				if new_arch ~= record_arch then
					record_arch = new_arch
					dst_node = agraph[record_arch.hash]
				end
			end
			dst_node = agraph_traverse_rem_ensure(dst_node, id)
		end

		local dst_arch = agraph_ensure_arch(dst_node)
		local dst_row: number?
		dst_row = ent_move(entity, record, record_arch, dst_arch)
		if monitor_lists then
			dst_row = dst_row or 0
			for monitor_lists_index = 1, monitor_lists_count do
				local monitors = monitor_lists[monitor_lists_index]
				for monitors_index = 1, #monitors do
					local monitor = monitors[monitors_index]
					local match = monitor.match
					if (not match(start_arch)) and match(dst_arch) then
						monitor.callback(entity, dst_arch, dst_row) --
					end
				end
			end
		end
	end

	--[[
	THE BELOW COMMENT IS OUTDATED
	TODO: REIMPLEMENT OPTIMIZATION
	ecs_remove logic is inlined in this function, because we can make a lot of good assumptions:
	- Every entity is alive, and has an Entity Record, because we're iterating archetypes' entity lists.
	- We know the archetype for every entity without looking it up, because the entity is pulled from an
	archetype known to us.
	- We can compute the destination archetype only once for each archetype, avoiding a graph traversal on every
	entity.
	- We can put checks for on_remove hooks and/or monitor lists outside of inner loops
	]]
	local function ecs_clear(input_entity: U53, delete: boolean?): ()
		local record = eindex_try_matching_record(input_entity)
		if not record then
			return
		end
		if record.deleting then
			return
		end

		local relation_wildcard = ENT_PAIR(input_entity, B2Wildcard)
		local wildcard_object = ENT_PAIR(B2Wildcard, input_entity)

		local delete_test_not_as_relation = IDFLAG_DELETE_ONCLEAR + IDFLAG_DELETE_ONCLEARTARGET
		local delete_test_any = delete_test_not_as_relation + IDFLAG_DELETE_ONCLEARASRELATION
		if delete then
			record.deleting = true
			delete_test_not_as_relation += IDFLAG_DELETE_ONDELETE + IDFLAG_DELETE_ONDELETETARGET
			delete_test_any += IDFLAG_DELETE_ONDELETE + IDFLAG_DELETE_ONDELETETARGET + IDFLAG_DELETE_ONDELETEASRELATION
		end

		local id_record = cindex[input_entity]
		if id_record then
			local flags = INDEX(id_record, idr_flags)
			local dense_cached = INDEX(id_record, idr_dense_cached)
			local arch_count = INDEX(id_record, idr_arch_count)
			if bit32.btest(flags, delete_test_any) then
				for dense_index = 1, arch_count do
					local cached_arch = dense_cached[dense_index]

					local entities = cached_arch.ents
					for entities_index = 1, #entities do
						local deleting_entity = entities[entities_index]
						if not deleting_entity then
							continue
						end
						ecs_clear(deleting_entity, true)
					end
					arch_scheduled_for_deletion[cached_arch] = true
				end
			else
				for dense_index = 1, arch_count do
					local cached_arch = dense_cached[dense_index]

					local entities = cached_arch.ents
					for entities_index = 1, #entities do
						local entity = entities[entities_index]
						if not entity then
							continue
						end
						ecs_remove(entity, input_entity)
					end
					arch_scheduled_for_deletion[cached_arch] = true
				end
			end
		end

		local wildcard_object_id_record = cindex[wildcard_object]
		if wildcard_object_id_record then
			local removal_archs: { Arch } = {}
			local removal_lists: { IdList } = {}
			local entity_counts: { number } = {}
			local removal_count = 0

			local removal_list: { U53 } = {}
			local removal_list_count = 0

			local dense_cached = INDEX(wildcard_object_id_record, idr_dense_cached)
			for dense_index = 1, #dense_cached do
				local cached_arch = dense_cached[dense_index]

				local cached_arch_ids = cached_arch.ids
				for arch_ids_index = 1, #cached_arch_ids do
					local rem_id = cached_arch_ids[arch_ids_index]
					if not ENT_PAIR_EH(rem_id) then
						continue
					end
					if ent_try_latest_alive(ENT_PAIR_LO(rem_id)) ~= input_entity then
						continue
					end
					local rem_id_record = cindex[rem_id]
					local rem_id_flags = INDEX(rem_id_record, idr_flags)
					if
						bit32.btest(
							rem_id_flags,
							if ent_try_latest_alive(ENT_PAIR_HI(rem_id)) == input_entity
								then delete_test_any
								else delete_test_not_as_relation
						)
					then
						local entities = cached_arch.ents
						for entities_index = 1, #entities do
							local entity = entities[entities_index]
							if not entity then
								continue
							end
							ecs_clear(entity, true)
						end

						if removal_list_count ~= 0 then
							removal_list_count = 0
							removal_list = {}
						end
						break
					else
						removal_list_count += 1
						removal_list[removal_list_count] = rem_id
					end
				end

				if removal_list_count == 0 then
					continue
				end

				removal_count += 1
				removal_archs[removal_count] = cached_arch
				removal_lists[removal_count] = removal_list
				entity_counts[removal_count] = #cached_arch.ents
				removal_list = {}
				removal_list_count = 0
			end

			for removal_index = 1, removal_count do
				removal_list = removal_lists[removal_index]
				local arch = removal_archs[removal_index]
				local entity_count = entity_counts[removal_index]
				local entities = arch.ents

				for entities_index = 1, entity_count do
					local removing_from = entities[entities_index]
					if not removing_from then
						continue
					end
					ecs_bulk_remove(removing_from, removal_list)
				end
				arch_scheduled_for_deletion[arch] = true
			end
		end

		local relation_wildcard_id_record = cindex[relation_wildcard]
		-- TODO: Optimize this path to iterate via wildcard record counts
		if relation_wildcard_id_record then
			local dense_cached = INDEX(relation_wildcard_id_record, idr_dense_cached)

			local flags = INDEX(relation_wildcard_id_record, idr_flags)

			if bit32.btest(flags, delete_test_any) then
				for dense_index = 1, #dense_cached do
					local cached_arch = dense_cached[dense_index]

					local cached_arch_ids = cached_arch.ids
					for arch_ids_index = 1, #cached_arch_ids do
						local rem_id = cached_arch_ids[arch_ids_index]
						if not ENT_PAIR_EH(rem_id) then
							continue
						end
						if ent_try_latest_alive(ENT_PAIR_HI(rem_id)) ~= input_entity then
							continue
						end

						local entities = cached_arch.ents
						for entities_index = 1, #entities do
							local entity = entities[entities_index]
							if not entity then
								continue
							end
							ecs_clear(entity, true)
						end
					end
				end
			else
				local removal_archs: { Arch } = {}
				local removal_lists: { IdList } = {}
				local entity_counts: { number } = {}
				local removal_count = 0

				local removal_list: { U53 } = {}
				local removal_list_count = 0

				for dense_index = 1, #dense_cached do
					local cached_arch = dense_cached[dense_index]

					local cached_arch_ids = cached_arch.ids
					for arch_ids_index = 1, #cached_arch_ids do
						local rem_id = cached_arch_ids[arch_ids_index]
						if not ENT_PAIR_EH(rem_id) then
							continue
						end
						if ent_try_latest_alive(ENT_PAIR_HI(rem_id)) ~= input_entity then
							continue
						end
						local rem_id_record = cindex[rem_id]
						local rem_id_flags = INDEX(rem_id_record, idr_flags)
						if bit32.btest(rem_id_flags, delete_test_any) then
							local entities = cached_arch.ents
							for entities_index = 1, #entities do
								local entity = entities[entities_index]
								if not entity then
									continue
								end
								ecs_clear(entity, true)
							end

							if removal_list_count ~= 0 then
								removal_list_count = 0
								removal_list = {}
							end
							break
						else
							removal_list_count += 1
							removal_list[removal_list_count] = rem_id
						end
					end

					if removal_list_count == 0 then
						continue
					end

					removal_count += 1
					removal_archs[removal_count] = cached_arch
					removal_lists[removal_count] = removal_list
					entity_counts[removal_count] = #cached_arch.ents
					removal_list = {}
					removal_list_count = 0
				end

				for removal_index = 1, removal_count do
					removal_list = removal_lists[removal_index]
					local arch = removal_archs[removal_index]
					local entity_count = entity_counts[removal_index]
					local entities = arch.ents

					for entities_index = 1, entity_count do
						local removing_from = entities[entities_index]
						if not removing_from then
							continue
						end
						ecs_bulk_remove(removing_from, removal_list)
					end
					arch_scheduled_for_deletion[arch] = true
				end
			end
		end

		if not delete then
			return
		end

		local record_arch = record.arch
		-- remove hooks could add components, this loop ensures the entity reaches the root archetype before being deleted
		while record_arch ~= ROOT_ARCHETYPE do
			ecs_bulk_remove(input_entity, record_arch.ids)
			record_arch = record.arch
		end

		record.deleting = nil

		local dense = record.dense
		local swap_index = eindex_alive_count
		eindex_alive_count = swap_index - 1

		local swap_entity = eindex_dense[swap_index]
		local swap_record = eindex_try_any_record(swap_entity) :: EntRecord

		swap_record.dense = dense
		record.dense = swap_index
		record.arch = ROOT_ARCHETYPE
		if record.row then
			record.row = nil
		end
		if record.hooks then
			record.hooks = nil
		end

		input_entity = ENT_INCREMENT_GENERATION(input_entity)

		eindex_dense[dense] = swap_entity
		eindex_dense[swap_index] = input_entity
	end

	local function arch_delete(arch: Arch): ()
		if arch == ROOT_ARCHETYPE then
			return
		end

		local ids = arch.ids
		local ids_count = #ids

		for id in arch.columns_map do
			local observer_cache = observe_arch_removed[id]
			if observer_cache then
				local observer_cache_count = #observer_cache
				for observer_cache_index = 1, observer_cache_count do
					local observer = observer_cache[observer_cache_index]
					if observer.match(arch) then
						observer.callback(arch)
					end
				end
			end
		end

		local hash = arch.hash
		local graph_node = agraph[hash]
		for id, node in graph_node do
			if type(id) ~= "number" then
				continue
			end
			node[id] = nil
		end
		agraph[hash] = nil

		local arch_location = arch.location
		arch.location = 0
		local swap_location = archetypes_count
		archetypes_count = swap_location - 1

		if arch_location ~= swap_location then
			archetypes[arch_location] = archetypes[swap_location] --
		end

		archetypes[swap_location] = nil

		for ids_index = 1, ids_count do
			local id = ids[ids_index]
			local id_record = cindex[id]

			local arch_count = INDEX(id_record, idr_arch_count)
			local new_arch_count = arch_count - 1
			if new_arch_count == 0 then
				cindex[id] = nil
				continue
			end
			(id_record :: { [typeof(idr_arch_count)]: index<IdRecord, typeof(idr_arch_count)> })[idr_arch_count] =
				new_arch_count

			local arch_sparse = INDEX(id_record, idr_arch_sparse)
			local arch_dense = arch_sparse[arch]
			local dense_cached, dense_column, dense_counts =
				INDEX(id_record, idr_dense_cached),
				INDEX(id_record, idr_dense_column),
				INDEX(id_record, idr_dense_counts)

			if arch_dense ~= arch_count then
				local cached = dense_cached[arch_count]
				dense_cached[arch_dense] = cached
				dense_column[arch_dense] = dense_column[arch_count]
				dense_counts[arch_dense] = dense_counts[arch_count]
				arch_sparse[cached] = arch_dense
			end
			dense_cached[arch_count] = nil
			dense_column[arch_count] = nil
			dense_counts[arch_count] = nil
			arch_sparse[arch] = nil
		end
	end

	local function ecs_cleanup(): ()
		for archetypes_index = archetypes_count, 1, -1 do
			local arch = archetypes[archetypes_index]
			arch_ensure_dense(arch)
			if arch.ents[1] then
				continue
			end
			arch_delete(arch)
		end
		if next(arch_has_empty_rows) then
			arch_has_empty_rows = {} --
		end
		if next(arch_scheduled_for_deletion) then
			arch_scheduled_for_deletion = {} --
		end
	end

	local function ecs_ensure_dense_archetypes(): ()
		for arch in arch_has_empty_rows do
			arch_ensure_dense(arch)
		end
		for arch in arch_scheduled_for_deletion do
			if arch.ents[1] then
				continue
			end
			arch_delete(arch)
		end
		if next(arch_has_empty_rows) then
			arch_has_empty_rows = {} --
		end
		if next(arch_scheduled_for_deletion) then
			arch_scheduled_for_deletion = {} --
		end
	end

	local query_matcher_cache: { [string]: QueryMatcher } = setmetatable({}, { __mode = "v" })
	local function query_matcher_hash(query_with: IdList, query_without: IdList): string
		local with_hash = ORDERED_HASH(query_with)
		local without_hash = ORDERED_HASH(query_without)
		local hashed = `{with_hash}\1{without_hash}`
		return hashed
	end
	local function query_matcher_new(hashed_fast: string, query_with: IdList, query_without: IdList): QueryMatcher
		local query_with_slow, query_with_ptrs, query_with_bitsets, with_pages_record = ids_page_mapping(query_with)
		local query_without_slow, query_without_ptrs, query_without_bitsets = ids_page_mapping(query_without)
		local with_pages_count = #query_with_ptrs
		local without_pages_count = #query_without_ptrs
		local query_with_slow_count = #query_with_slow
		local query_without_slow_count = #query_without_slow

		--[[
		has_wisl = has with_slow
		has_wosl = has without_slow
		has_wipg = has with_pages
		has_wopg = has without_pages
		]]
		local has_wisl = query_with_slow_count ~= 0
		local has_wosl = query_without_slow_count ~= 0
		local has_wipg = with_pages_count ~= 0
		local has_wopg = without_pages_count ~= 0

		local hashed_bitsets: string?

		if not (has_wisl or has_wosl) then
			local wigtset = if has_wipg then pagebuff_from_mapping(query_with_ptrs, query_with_bitsets) else NULLPTR
			local wogtset = if has_wopg
				then pagebuff_from_mapping(query_without_ptrs, query_without_bitsets)
				else NULLPTR
			-- using \2\1 as a separator since both are lo2hi sorted arrays
			hashed_bitsets = `{buffer.tostring(wigtset)}\2\1{buffer.tostring(wogtset)}`
			local cached = query_matcher_cache[hashed_bitsets]
			if cached then
				return cached
			end
		end

		local query_match
		if has_wipg then
			if has_wopg then
				if has_wisl then
					if has_wosl then
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for with_index = 1, with_pages_count do
								local page_ptr = query_with_ptrs[with_index]
								local page_test = query_with_bitsets[with_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local match_eh = bit32.band(arch_type, page_test) == page_test

								if not match_eh then
									return false
								end
							end

							for without_index = 1, without_pages_count do
								local page_ptr = query_without_ptrs[without_index]
								local page_test = query_without_bitsets[without_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local arch_contains_excluded_fast = bit32.btest(arch_type, page_test)

								if arch_contains_excluded_fast then
									return false
								end
							end

							local columns_sparse = arch.columns_map

							for slow_index = 1, query_with_slow_count do
								local with = query_with_slow[slow_index]
								if not columns_sparse[with] then
									return false
								end
							end

							for slow_index = 1, query_without_slow_count do
								local without = query_without_slow[slow_index]
								if columns_sparse[without] then
									return false
								end
							end

							return true
						end
					else
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for with_index = 1, with_pages_count do
								local page_ptr = query_with_ptrs[with_index]
								local page_test = query_with_bitsets[with_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local match_eh = bit32.band(arch_type, page_test) == page_test

								if not match_eh then
									return false
								end
							end

							for without_index = 1, without_pages_count do
								local page_ptr = query_without_ptrs[without_index]
								local page_test = query_without_bitsets[without_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local arch_contains_excluded_fast = bit32.btest(arch_type, page_test)

								if arch_contains_excluded_fast then
									return false
								end
							end

							local columns_sparse = arch.columns_map

							for slow_index = 1, query_with_slow_count do
								local with = query_with_slow[slow_index]
								if not columns_sparse[with] then
									return false
								end
							end

							return true
						end
					end
				else
					if has_wosl then
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for with_index = 1, with_pages_count do
								local page_ptr = query_with_ptrs[with_index]
								local page_test = query_with_bitsets[with_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local match_eh = bit32.band(arch_type, page_test) == page_test

								if not match_eh then
									return false
								end
							end

							for without_index = 1, without_pages_count do
								local page_ptr = query_without_ptrs[without_index]
								local page_test = query_without_bitsets[without_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local arch_contains_excluded_fast = bit32.btest(arch_type, page_test)

								if arch_contains_excluded_fast then
									return false
								end
							end

							local columns_sparse = arch.columns_map

							for slow_index = 1, query_without_slow_count do
								local without = query_without_slow[slow_index]
								if columns_sparse[without] then
									return false
								end
							end

							return true
						end
					else
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for with_index = 1, with_pages_count do
								local page_ptr = query_with_ptrs[with_index]
								local page_test = query_with_bitsets[with_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local match_eh = bit32.band(arch_type, page_test) == page_test

								if not match_eh then
									return false
								end
							end

							for without_index = 1, without_pages_count do
								local page_ptr = query_without_ptrs[without_index]
								local page_test = query_without_bitsets[without_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local arch_contains_excluded_fast = bit32.btest(arch_type, page_test)

								if arch_contains_excluded_fast then
									return false
								end
							end

							return true
						end
					end
				end
			else
				if has_wisl then
					if has_wosl then
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for with_index = 1, with_pages_count do
								local page_ptr = query_with_ptrs[with_index]
								local page_test = query_with_bitsets[with_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local match_eh = bit32.band(arch_type, page_test) == page_test

								if not match_eh then
									return false
								end
							end

							local columns_sparse = arch.columns_map

							for slow_index = 1, query_with_slow_count do
								local with = query_with_slow[slow_index]
								if not columns_sparse[with] then
									return false
								end
							end

							for slow_index = 1, query_without_slow_count do
								local without = query_without_slow[slow_index]
								if columns_sparse[without] then
									return false
								end
							end

							return true
						end
					else
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for with_index = 1, with_pages_count do
								local page_ptr = query_with_ptrs[with_index]
								local page_test = query_with_bitsets[with_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local match_eh = bit32.band(arch_type, page_test) == page_test

								if not match_eh then
									return false
								end
							end

							local columns_sparse = arch.columns_map

							for slow_index = 1, query_with_slow_count do
								local with = query_with_slow[slow_index]
								if not columns_sparse[with] then
									return false
								end
							end

							return true
						end
					end
				else
					if has_wosl then
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for with_index = 1, with_pages_count do
								local page_ptr = query_with_ptrs[with_index]
								local page_test = query_with_bitsets[with_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local match_eh = bit32.band(arch_type, page_test) == page_test

								if not match_eh then
									return false
								end
							end

							local columns_sparse = arch.columns_map

							for slow_index = 1, query_without_slow_count do
								local without = query_without_slow[slow_index]
								if columns_sparse[without] then
									return false
								end
							end

							return true
						end
					else
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for with_index = 1, with_pages_count do
								local page_ptr = query_with_ptrs[with_index]
								local page_test = query_with_bitsets[with_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local match_eh = bit32.band(arch_type, page_test) == page_test

								if not match_eh then
									return false
								end
							end

							return true
						end
					end
				end
			end
		else
			if has_wopg then
				if has_wisl then
					if has_wosl then
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for without_index = 1, without_pages_count do
								local page_ptr = query_without_ptrs[without_index]
								local page_test = query_without_bitsets[without_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local arch_contains_excluded_fast = bit32.btest(arch_type, page_test)

								if arch_contains_excluded_fast then
									return false
								end
							end

							local columns_sparse = arch.columns_map

							for slow_index = 1, query_with_slow_count do
								local with = query_with_slow[slow_index]
								if not columns_sparse[with] then
									return false
								end
							end

							for slow_index = 1, query_without_slow_count do
								local without = query_without_slow[slow_index]
								if columns_sparse[without] then
									return false
								end
							end

							return true
						end
					else
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for without_index = 1, without_pages_count do
								local page_ptr = query_without_ptrs[without_index]
								local page_test = query_without_bitsets[without_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local arch_contains_excluded_fast = bit32.btest(arch_type, page_test)

								if arch_contains_excluded_fast then
									return false
								end
							end

							local columns_sparse = arch.columns_map

							for slow_index = 1, query_with_slow_count do
								local with = query_with_slow[slow_index]
								if not columns_sparse[with] then
									return false
								end
							end

							return true
						end
					end
				else
					if has_wosl then
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for without_index = 1, without_pages_count do
								local page_ptr = query_without_ptrs[without_index]
								local page_test = query_without_bitsets[without_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local arch_contains_excluded_fast = bit32.btest(arch_type, page_test)

								if arch_contains_excluded_fast then
									return false
								end
							end

							local columns_sparse = arch.columns_map

							for slow_index = 1, query_without_slow_count do
								local without = query_without_slow[slow_index]
								if columns_sparse[without] then
									return false
								end
							end

							return true
						end
					else
						function query_match(arch: Arch): boolean
							do
								local match_fast = bit32.band(arch.pages_record, with_pages_record) == with_pages_record
								if not match_fast then
									return false
								end
							end

							local arch_bitset = arch.bitset_pages

							for without_index = 1, without_pages_count do
								local page_ptr = query_without_ptrs[without_index]
								local page_test = query_without_bitsets[without_index]
								local arch_type = buffer.readu32(arch_bitset, page_ptr)

								local arch_contains_excluded_fast = bit32.btest(arch_type, page_test)

								if arch_contains_excluded_fast then
									return false
								end
							end

							return true
						end
					end
				end
			else
				if has_wisl then
					if has_wosl then
						function query_match(arch: Arch): boolean
							local columns_sparse = arch.columns_map

							for slow_index = 1, query_with_slow_count do
								local with = query_with_slow[slow_index]
								if not columns_sparse[with] then
									return false
								end
							end

							for slow_index = 1, query_without_slow_count do
								local without = query_without_slow[slow_index]
								if columns_sparse[without] then
									return false
								end
							end

							return true
						end
					else
						function query_match(arch: Arch): boolean
							local columns_sparse = arch.columns_map

							for slow_index = 1, query_with_slow_count do
								local with = query_with_slow[slow_index]
								if not columns_sparse[with] then
									return false
								end
							end

							return true
						end
					end
				else
					if has_wosl then
						function query_match(arch: Arch): boolean
							local columns_sparse = arch.columns_map

							for slow_index = 1, query_without_slow_count do
								local without = query_without_slow[slow_index]
								if columns_sparse[without] then
									return false
								end
							end

							return true
						end
					else
						function query_match(arch: Arch): boolean
							return true
						end
					end
				end
			end
		end

		query_matcher_cache[hashed_fast] = query_match
		if hashed_bitsets then
			query_matcher_cache[hashed_bitsets] = query_match
		end

		return query_match
	end
	local function query_matcher_ensure(query_with: IdList, query_without: IdList): QueryMatcher
		local hashed_fast = query_matcher_hash(query_with, query_without)
		do
			local cached = query_matcher_cache[hashed_fast]
			if cached then
				return cached
			end
		end

		return (query_matcher_new(hashed_fast, query_with, query_without))
	end

	local function ecs_each(id: U53): () -> U53?
		local id_record = cindex[id]
		if not id_record then
			return NOOP :: () -> U53?
		end

		local arch_count = INDEX(id_record, idr_arch_count)
		if arch_count == 0 then
			return NOOP :: () -> U53?
		end
		local dense_cached = INDEX(id_record, idr_dense_cached)
		local dense_ent_count = table.create(arch_count) :: { number }
		for dense_index = 1, arch_count do
			dense_ent_count[dense_index] = #dense_cached[dense_index].ents
		end

		local arch = dense_cached[arch_count]
		local row = dense_ent_count[arch_count]
		local entities = arch.ents

		local function b2_each_iterator(): U53?
			local entity = entities[row]
			while not entity do
				row -= 1
				if row <= 0 then
					arch_count -= 1

					if arch_count == 0 then
						return nil
					end

					arch = dense_cached[arch_count]
					entities = arch.ents
					row = dense_ent_count[arch_count]
				end
				entity = entities[row]
			end
			row -= 1
			-- while loop condition should have handled this typestate
			return entity :: typeof(assert(entity))
		end

		return b2_each_iterator
	end

	local queryobj = {}
	local queryobj_metatable = { __index = queryobj }
	type QueryIdentityInternal = setmetatable<{
		_reads: { U53 },
		_sparse: { [U53]: number },
		_with_dense: { U53 },
		_without_dense: { U53 },
		_observed_archs: { Arch }?,
		_matcher: QueryMatcher?,
	}, typeof(queryobj_metatable)>
	local function ecs_query(...: U53): QueryIdentityInternal
		local sparse = {}
		local with_dense = { ... }
		for dense, id in with_dense do
			sparse[id] = dense
		end
		local self = setmetatable({
			_reads = table.clone(with_dense),
			_sparse = sparse,
			_with_dense = with_dense,
			_without_dense = {},
			_matcher = nil :: QueryMatcher?,
			_observed_archs = nil :: { Arch }?,
		}, queryobj_metatable)
		return self
	end

	function queryobj.with(self: QueryIdentityInternal, ...: U53): QueryIdentityInternal
		local dense = self._with_dense
		local dense_count = #dense
		local sparse = self._sparse
		local add_with = { ... }
		local add_with_count = #add_with
		for add_with_index = 1, add_with_count do
			local add = add_with[add_with_index]
			if sparse[add] then
				error(`query already contains id {add}`, 2)
			end
			dense_count += 1
			dense[dense_count] = add
			sparse[add] = dense_count
		end
		return self
	end

	function queryobj.without(self: QueryIdentityInternal, ...: U53): QueryIdentityInternal
		local dense = self._without_dense
		local dense_count = #dense
		local sparse = self._sparse
		local add_without = { ... }
		local add_without_count = #add_without
		for add_without_index = 1, add_without_count do
			local add = add_without[add_without_index]
			if sparse[add] then
				error(`query already contains id {add}`, 2)
			end
			dense_count += 1
			dense[dense_count] = add
			sparse[add] = dense_count
		end
		return self
	end

	function queryobj.match(self: QueryIdentityInternal): QueryMatcher
		local matcher = self._matcher :: typeof(assert(self._matcher))
		if not matcher then
			matcher = query_matcher_ensure(self._with_dense, self._without_dense)
			self._matcher = matcher
		end
		return matcher
	end

	function queryobj.archetypes(self: QueryIdentityInternal): { Arch }
		local with_dense = self._with_dense
		local without_dense = self._without_dense
		local matcher = self._matcher :: typeof(assert(self._matcher))
		if not matcher then
			matcher = query_matcher_ensure(with_dense, without_dense)
			self._matcher = matcher
		end

		--[[
		IdRecord stores a cache of which archetypes an Id is a part of. Go through each Ids record, and select the one
		with the smallest number of cached archetypes. It's important to check the most exclusive set, because one cache
		(E.g., the cache for 'b2.Name') may pertain to way more archetypes than other components in the query.
		]]
		local cached_archs = archetypes
		local cached_count = archetypes_count
		local maximally_exclusive_id_record: IdRecord?
		for with_dense_index = 1, #with_dense do
			local id = with_dense[with_dense_index]
			local id_record = cindex[id]

			if not id_record then
				continue
			end

			local arch_count = INDEX(id_record, idr_arch_count)

			if arch_count > cached_count then
				continue
			end

			maximally_exclusive_id_record = id_record
			cached_count = arch_count
		end
		if maximally_exclusive_id_record then
			cached_archs = INDEX(maximally_exclusive_id_record, idr_dense_cached)
		end

		local compatible = {}
		local compatible_count = 0
		for cached_archs_index = 1, cached_count do
			local cached_arch = cached_archs[cached_archs_index]
			if matcher(cached_arch) then
				compatible_count += 1
				compatible[compatible_count] = cached_arch
			end
		end

		return compatible
	end

	function queryobj.entities(self: QueryIdentityInternal): () -> (U53?, ...any)
		if not disable_auto_ensure_dense then
			ecs_ensure_dense_archetypes()
		end
		local compatible_archs = self:archetypes()
		local compatible_count = #compatible_archs

		if compatible_count == 0 then
			return NOOP :: () -> U53?
		end

		local reads = self._reads
		local reads_count = #reads

		local compatible_ent_counts: { U26 } = {}
		for compatible_index = 1, compatible_count do
			local compatible_arch = compatible_archs[compatible_index]
			compatible_ent_counts[compatible_index] = #compatible_arch.ents
		end

		local arch = compatible_archs[compatible_count]
		local entities = arch.ents
		local columns_map_init = arch.columns_map
		local row = compatible_ent_counts[compatible_count]

		local query_iter: () -> (U53?, ...any)
		if reads_count == 1 then
			local A = reads[1]
			local col1 = columns_map_init[A]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53, col1[read_row]
			end
		elseif reads_count == 2 then
			local A = reads[1]
			local B = reads[2]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53, col1[read_row], col2[read_row]
			end
		elseif reads_count == 3 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53, col1[read_row], col2[read_row], col3[read_row]
			end
		elseif reads_count == 4 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53, col1[read_row], col2[read_row], col3[read_row], col4[read_row]
			end
		elseif reads_count == 5 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			local col5 = columns_map_init[E]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
						col5 = columns_map[E]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53, col1[read_row], col2[read_row], col3[read_row], col4[read_row], col5[read_row]
			end
		elseif reads_count == 6 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			local col5 = columns_map_init[E]
			local col6 = columns_map_init[F]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
						col5 = columns_map[E]
						col6 = columns_map[F]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53,
					col1[read_row],
					col2[read_row],
					col3[read_row],
					col4[read_row],
					col5[read_row],
					col6[read_row]
			end
		elseif reads_count == 7 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			local G = reads[7]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			local col5 = columns_map_init[E]
			local col6 = columns_map_init[F]
			local col7 = columns_map_init[G]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
						col5 = columns_map[E]
						col6 = columns_map[F]
						col7 = columns_map[G]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53,
					col1[read_row],
					col2[read_row],
					col3[read_row],
					col4[read_row],
					col5[read_row],
					col6[read_row],
					col7[read_row]
			end
		elseif reads_count == 8 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			local G = reads[7]
			local H = reads[8]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			local col5 = columns_map_init[E]
			local col6 = columns_map_init[F]
			local col7 = columns_map_init[G]
			local col8 = columns_map_init[H]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
						col5 = columns_map[E]
						col6 = columns_map[F]
						col7 = columns_map[G]
						col8 = columns_map[H]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53,
					col1[read_row],
					col2[read_row],
					col3[read_row],
					col4[read_row],
					col5[read_row],
					col6[read_row],
					col7[read_row],
					col8[read_row]
			end
		elseif reads_count == 0 then
			error("needs to read at least 1 component", 2)
		else
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			local G = reads[7]
			local H = reads[8]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			local col5 = columns_map_init[E]
			local col6 = columns_map_init[F]
			local col7 = columns_map_init[G]
			local col8 = columns_map_init[H]
			local colrest_count = reads_count - 8
			local colrest = table.create(colrest_count) :: { Column }
			for colrest_index = 1, colrest_count do
				local Id = reads[8 + colrest_index]
				colrest[colrest_index] = columns_map_init[Id]
			end
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
						col5 = columns_map[E]
						col6 = columns_map[F]
						col7 = columns_map[G]
						col8 = columns_map[H]
						colrest = table.create(colrest_count) :: { Column }
						for colrest_index = 1, colrest_count do
							local Id = reads[8 + colrest_index]
							colrest[colrest_index] = columns_map[Id]
						end
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				local read_rest = table.create(colrest_count)
				for colrest_index = 1, colrest_count do
					read_rest[colrest_index] = colrest[colrest_index][read_row]
				end
				return ent :: U53,
					col1[read_row],
					col2[read_row],
					col3[read_row],
					col4[read_row],
					col5[read_row],
					col6[read_row],
					col7[read_row],
					col8[read_row],
					table.unpack(read_rest)
			end
		end

		return query_iter
	end

	function queryobj.observe_added(self: QueryIdentityInternal, callback: (Arch) -> ()): ()
		local with_dense = self._with_dense
		local First = ASSERT(with_dense[1], "Internal Error")

		local added_cached: index<typeof(observe_arch_added), U53>
		for with_index = 1, #with_dense do
			local cache = observe_arch_added[with_dense[with_index]]
			if cache then
				added_cached = cache
				break
			end
		end
		local observer: Observer<(Arch)> = {
			match = self:match(),
			callback = callback,
		}
		if not added_cached then
			added_cached = { observer } :: index<typeof(observe_arch_added), U53>
			observe_arch_added[First] = added_cached
		else
			table.insert(added_cached, observer)
		end
	end

	function queryobj.observe_removed(self: QueryIdentityInternal, callback: (Arch) -> ()): ()
		local with_dense = self._with_dense
		local First = ASSERT(with_dense[1], "Internal Error")

		local removed_cached: index<typeof(observe_arch_removed), U53>
		for with_index = 1, #with_dense do
			local cache = observe_arch_removed[with_dense[with_index]]
			if cache then
				removed_cached = cache
				break
			end
		end
		local observer: Observer<(Arch)> = {
			match = self:match(),
			callback = callback,
		}
		if not removed_cached then
			removed_cached = { observer } :: index<typeof(observe_arch_removed), U53>
			observe_arch_removed[First] = removed_cached
		else
			table.insert(removed_cached, observer)
		end
	end

	function queryobj.monitor_added_row(self: QueryIdentityInternal, callback: (U53, Arch, Row) -> ()): () -> ()
		local match = self:match()

		local with_observer: Monitor = {
			match = match,
			callback = callback,
		}

		local with_dense = self._with_dense
		local without_dense = self._without_dense
		local with_dense_count = #with_dense
		local without_dense_count = #without_dense

		for with_index = 1, with_dense_count do
			local id = with_dense[with_index]
			local id_record = id_record_ensure(id)
			local monitors = INDEX(id_record, idr_monitors)
			if not monitors then
				monitors = { with_observer }
				-- Luau
				(id_record :: any)[idr_monitors] = monitors
			else
				table.insert(monitors, with_observer)
			end
		end
		for without_index = 1, without_dense_count do
			local id = without_dense[without_index]
			local id_record = id_record_ensure(id)
			local monitors = INDEX(id_record, idr_monitors)
			if not monitors then
				monitors = { with_observer }
				(id_record :: any)[idr_monitors] = monitors
			else
				table.insert(monitors, with_observer)
			end
		end

		local function monitor_destroy(): ()
			for with_index = 1, with_dense_count do
				local id = with_dense[with_index]
				local id_record = cindex[id]
				if not id_record then
					continue
				end
				local monitors = INDEX(id_record, idr_monitors)
				if not monitors then
					continue
				end
				local found = table.find(monitors, with_observer)
				if not found then
					continue
				end
				table.remove(monitors, found)
			end
			for without_index = 1, with_dense_count do
				local id = without_dense[without_index]
				local id_record = cindex[id]
				if not id_record then
					continue
				end
				local monitors = INDEX(id_record, idr_monitors)
				if not monitors then
					continue
				end
				local found = table.find(monitors, with_observer)
				if not found then
					continue
				end
				table.remove(monitors, found)
			end
		end

		return monitor_destroy
	end

	function queryobj.monitor_removed_row(self: QueryIdentityInternal, callback: (U53, Arch, Row) -> ()): () -> ()
		local match = self:match()
		local function antimatch(arch: Arch): boolean
			return not match(arch)
		end

		local without_observer: Monitor = {
			match = antimatch,
			callback = callback,
		}

		local with_dense = self._with_dense
		local without_dense = self._without_dense
		local with_dense_count = #with_dense
		local without_dense_count = #without_dense

		for with_index = 1, with_dense_count do
			local id = with_dense[with_index]
			local id_record = id_record_ensure(id)
			local monitors = INDEX(id_record, idr_monitors)
			if not monitors then
				monitors = { without_observer }
				-- Luau
				(id_record :: any)[idr_monitors] = monitors
			else
				table.insert(monitors, without_observer)
			end
		end
		for without_index = 1, without_dense_count do
			local id = without_dense[without_index]
			local id_record = id_record_ensure(id)
			local monitors = INDEX(id_record, idr_monitors)
			if not monitors then
				monitors = { without_observer }
				(id_record :: any)[idr_monitors] = monitors
			else
				table.insert(monitors, without_observer)
			end
		end

		local function monitor_destroy(): ()
			for with_index = 1, with_dense_count do
				local id = with_dense[with_index]
				local id_record = cindex[id]
				if not id_record then
					continue
				end
				local monitors = INDEX(id_record, idr_monitors)
				if not monitors then
					continue
				end
				local found = table.find(monitors, without_observer)
				if not found then
					continue
				end
				table.remove(monitors, found)
			end
			for without_index = 1, with_dense_count do
				local id = without_dense[without_index]
				local id_record = cindex[id]
				if not id_record then
					continue
				end
				local monitors = INDEX(id_record, idr_monitors)
				if not monitors then
					continue
				end
				local found = table.find(monitors, without_observer)
				if not found then
					continue
				end
				table.remove(monitors, found)
			end
		end

		return monitor_destroy
	end

	function queryobj.monitor_added(self: QueryIdentityInternal, callback: (U53, ...any) -> ()): () -> ()
		local reads = self._reads
		local reads_count = #reads

		local wrapper_callback: (U53, Arch, Row) -> ()
		if reads_count == 1 then
			local A = reads[1]
			function wrapper_callback(entity: U53, arch: Arch, row: Row)
				local columns_map = arch.columns_map
				callback(entity, columns_map[A], row)
			end
		elseif reads_count == 2 then
			local A = reads[1]
			local B = reads[2]
			function wrapper_callback(entity: U53, arch: Arch, row: Row)
				local columns_map = arch.columns_map
				callback(entity, columns_map[A][row], columns_map[B][row])
			end
		elseif reads_count == 3 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			function wrapper_callback(entity: U53, arch: Arch, row: Row)
				local columns_map = arch.columns_map
				callback(entity, columns_map[A][row], columns_map[B][row], columns_map[C][row])
			end
		elseif reads_count == 4 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			function wrapper_callback(entity: U53, arch: Arch, row: Row)
				local columns_map = arch.columns_map
				callback(entity, columns_map[A][row], columns_map[B][row], columns_map[C][row], columns_map[D][row])
			end
		elseif reads_count == 5 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			function wrapper_callback(entity: U53, arch: Arch, row: Row)
				local columns_map = arch.columns_map
				callback(
					entity,
					columns_map[A][row],
					columns_map[B][row],
					columns_map[C][row],
					columns_map[D][row],
					columns_map[E][row]
				)
			end
		elseif reads_count == 6 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			function wrapper_callback(entity: U53, arch: Arch, row: Row)
				local columns_map = arch.columns_map
				callback(
					entity,
					columns_map[A][row],
					columns_map[B][row],
					columns_map[C][row],
					columns_map[D][row],
					columns_map[E][row],
					columns_map[F][row]
				)
			end
		elseif reads_count == 7 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			local G = reads[7]
			function wrapper_callback(entity: U53, arch: Arch, row: Row)
				local columns_map = arch.columns_map
				callback(
					entity,
					columns_map[A][row],
					columns_map[B][row],
					columns_map[C][row],
					columns_map[D][row],
					columns_map[E][row],
					columns_map[F][row],
					columns_map[G][row]
				)
			end
		elseif reads_count == 8 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			local G = reads[7]
			local H = reads[8]
			function wrapper_callback(entity: U53, arch: Arch, row: Row)
				local columns_map = arch.columns_map
				callback(
					entity,
					columns_map[A][row],
					columns_map[B][row],
					columns_map[C][row],
					columns_map[D][row],
					columns_map[E][row],
					columns_map[F][row],
					columns_map[G][row],
					columns_map[H][row]
				)
			end
		elseif reads_count == 0 then
			error("Internal Error", 2)
		else
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			local G = reads[7]
			local H = reads[8]
			local rest_size = reads_count - 8
			function wrapper_callback(entity: U53, arch: Arch, row: Row)
				local columns_map = arch.columns_map
				local rest = table.create(rest_size)
				local rest_count = 0
				for rest_index = 9, reads_count do
					rest_count += 1
					rest[rest_count] = columns_map[reads[rest_index]][row]
				end
				callback(
					entity,
					columns_map[A][row],
					columns_map[B][row],
					columns_map[C][row],
					columns_map[D][row],
					columns_map[E][row],
					columns_map[F][row],
					columns_map[G][row],
					columns_map[H][row],
					table.unpack(rest)
				)
			end
		end

		-- Entity has been added, so it is guaranteed to have a row.
		return (self:monitor_added_row(wrapper_callback :: (U53, Arch, Row) -> ()))
	end

	function queryobj.monitor_removed(self: QueryIdentityInternal, callback: (U53) -> ()): () -> ()
		local function wrapper_callback(entity: U53)
			callback(entity)
		end

		return (self:monitor_removed_row(wrapper_callback))
	end

	function queryobj.archetypes_cached(self: QueryIdentityInternal): { Arch }
		do
			local cached = self._observed_archs
			if cached then
				return cached
			end
		end
		local with_dense = self._with_dense
		local First = with_dense[1]
		if not First then
			error "cannot get archetype cache from blank query"
		end

		local added_cached: index<typeof(observe_arch_added), U53>
		for with_index = 1, #with_dense do
			local cache = observe_arch_added[with_dense[with_index]]
			if cache then
				added_cached = cache
				break
			end
		end
		if not added_cached then
			added_cached = {} :: index<typeof(observe_arch_added), U53>
			observe_arch_added[First] = added_cached
		end

		local removed_cached: index<typeof(observe_arch_removed), U53>
		for with_index = 1, #with_dense do
			local cache = observe_arch_removed[with_dense[with_index]]
			if cache then
				removed_cached = cache
				break
			end
		end
		if not removed_cached then
			removed_cached = {} :: index<typeof(observe_arch_removed), U53>
			observe_arch_removed[First] = removed_cached
		end

		local arch_cache_dense: { [U26]: Arch } = self:archetypes()
		local arch_cache_dense_count = #arch_cache_dense
		local arch_cache_sparse: Set<Arch, U26> = {}
		for dense_index = 1, arch_cache_dense_count do
			local arch = arch_cache_dense[dense_index]
			arch_cache_sparse[arch] = dense_index
		end

		local function observing_added(arch: Arch): ()
			local dense_location = arch_cache_dense_count + 1
			arch_cache_dense_count = dense_location
			arch_cache_dense[arch_cache_dense_count] = arch
		end

		local function observing_removed(arch: Arch): ()
			local dense_location = arch_cache_sparse[arch]
			local dense_swap = arch_cache_dense_count
			arch_cache_dense_count = dense_swap - 1
			arch_cache_sparse[arch] = nil
			if dense_location == dense_swap then
				arch_cache_dense[dense_location] = nil
			else
				local swap_arch = arch_cache_dense[dense_swap]
				arch_cache_dense[dense_swap] = nil

				arch_cache_sparse[swap_arch] = dense_location
				arch_cache_dense[dense_location] = swap_arch
			end
		end

		self:observe_added(observing_added)
		self:observe_removed(observing_removed)

		return arch_cache_dense
	end

	function queryobj.entities_cached(self: QueryIdentityInternal): () -> (U53?, ...any)
		if not disable_auto_ensure_dense then
			ecs_ensure_dense_archetypes()
		end
		local compatible_archs = self:archetypes_cached()
		local compatible_count = #compatible_archs

		if compatible_count == 0 then
			return NOOP :: () -> U53?
		end

		local reads = self._reads
		local reads_count = #reads

		local compatible_ent_counts: { U26 } = {}
		local compatible_reads: { { Column } } = {}
		for compatible_index = 1, compatible_count do
			local compatible_arch = compatible_archs[compatible_index]
			local columns_map = compatible_arch.columns_map
			compatible_ent_counts[compatible_index] = #compatible_arch.ents

			local reads_list = table.create(reads_count) :: { Column }
			for reads_index = 1, reads_count do
				local read_id = reads[reads_index]
				reads_list[read_id] = columns_map[read_id]
			end
			compatible_reads[compatible_index] = reads_list
		end

		local arch = compatible_archs[compatible_count]
		local entities = arch.ents
		local columns_map_init = arch.columns_map
		local row = compatible_ent_counts[compatible_count]

		local query_iter: () -> (U53?, ...any)
		if reads_count == 1 then
			local A = reads[1]
			local col1 = columns_map_init[A]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53, col1[read_row]
			end
		elseif reads_count == 2 then
			local A = reads[1]
			local B = reads[2]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53, col1[read_row], col2[read_row]
			end
		elseif reads_count == 3 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53, col1[read_row], col2[read_row], col3[read_row]
			end
		elseif reads_count == 4 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53, col1[read_row], col2[read_row], col3[read_row], col4[read_row]
			end
		elseif reads_count == 5 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			local col5 = columns_map_init[E]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
						col5 = columns_map[E]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53, col1[read_row], col2[read_row], col3[read_row], col4[read_row], col5[read_row]
			end
		elseif reads_count == 6 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			local col5 = columns_map_init[E]
			local col6 = columns_map_init[F]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
						col5 = columns_map[E]
						col6 = columns_map[F]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53,
					col1[read_row],
					col2[read_row],
					col3[read_row],
					col4[read_row],
					col5[read_row],
					col6[read_row]
			end
		elseif reads_count == 7 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			local G = reads[7]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			local col5 = columns_map_init[E]
			local col6 = columns_map_init[F]
			local col7 = columns_map_init[G]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
						col5 = columns_map[E]
						col6 = columns_map[F]
						col7 = columns_map[G]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53,
					col1[read_row],
					col2[read_row],
					col3[read_row],
					col4[read_row],
					col5[read_row],
					col6[read_row],
					col7[read_row]
			end
		elseif reads_count == 8 then
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			local G = reads[7]
			local H = reads[8]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			local col5 = columns_map_init[E]
			local col6 = columns_map_init[F]
			local col7 = columns_map_init[G]
			local col8 = columns_map_init[H]
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
						col5 = columns_map[E]
						col6 = columns_map[F]
						col7 = columns_map[G]
						col8 = columns_map[H]
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				return ent :: U53,
					col1[read_row],
					col2[read_row],
					col3[read_row],
					col4[read_row],
					col5[read_row],
					col6[read_row],
					col7[read_row],
					col8[read_row]
			end
		elseif reads_count == 0 then
			error("needs to read at least 1 component", 2)
		else
			local A = reads[1]
			local B = reads[2]
			local C = reads[3]
			local D = reads[4]
			local E = reads[5]
			local F = reads[6]
			local G = reads[7]
			local H = reads[8]
			local col1 = columns_map_init[A]
			local col2 = columns_map_init[B]
			local col3 = columns_map_init[C]
			local col4 = columns_map_init[D]
			local col5 = columns_map_init[E]
			local col6 = columns_map_init[F]
			local col7 = columns_map_init[G]
			local col8 = columns_map_init[H]
			local colrest_count = reads_count - 8
			local colrest = table.create(colrest_count) :: { Column }
			for colrest_index = 1, colrest_count do
				local Id = reads[8 + colrest_index]
				colrest[colrest_index] = columns_map_init[Id]
			end
			function query_iter(): (U53?, ...any)
				local read_row = row
				local ent = entities[read_row]
				while not ent do
					read_row -= 1
					if read_row <= 0 then
						compatible_count -= 1
						if compatible_count == 0 then
							return nil
						end

						arch = compatible_archs[compatible_count]
						entities = arch.ents
						local columns_map = arch.columns_map
						read_row = compatible_ent_counts[compatible_count]
						col1 = columns_map[A]
						col2 = columns_map[B]
						col3 = columns_map[C]
						col4 = columns_map[D]
						col5 = columns_map[E]
						col6 = columns_map[F]
						col7 = columns_map[G]
						col8 = columns_map[H]
						colrest = table.create(colrest_count) :: { Column }
						for colrest_index = 1, colrest_count do
							local Id = reads[8 + colrest_index]
							colrest[colrest_index] = columns_map[Id]
						end
					end
					ent = entities[read_row]
				end
				row = read_row - 1
				local read_rest = table.create(colrest_count)
				for colrest_index = 1, colrest_count do
					read_rest[colrest_index] = colrest[colrest_index][read_row]
				end
				return ent :: U53,
					col1[read_row],
					col2[read_row],
					col3[read_row],
					col4[read_row],
					col5[read_row],
					col6[read_row],
					col7[read_row],
					col8[read_row],
					table.unpack(read_rest)
			end
		end

		return query_iter
	end

	ROOT_ARCHETYPE = agraph_ensure_arch(agraph_root)

	for _ = 1, MAX_PAGED_COMPONENT do
		eindex_new_id_alive()
	end

	ecs_add(B2Name, B2Component)
	ecs_set(B2Component, B2Name, "B2Component")
	ecs_set(B2Name, B2Name, "B2Name")
	ecs_set(B2Wildcard, B2Name, "B2Wildcard")
	ecs_set(B2ChildOf, B2Name, "B2ChildOf")
	ecs_set(B2OnClear, B2Name, "B2CleanupOnClear")
	ecs_set(B2OnClearTarget, B2Name, "B2CleanupOnClearTarget")
	ecs_set(B2CleanupDelete, B2Name, "B2CleanupDelete")
	ecs_set(B2OnAdd, B2Name, "B2OnAdd")
	ecs_set(B2OnChange, B2Name, "B2OnChange")
	ecs_set(B2OnRemove, B2Name, "B2OnRemove")
	ecs_add(B2OnChange, B2Component)
	ecs_add(B2OnAdd, B2Component)
	ecs_add(B2OnRemove, B2Component)
	ecs_add(B2ChildOf, ENT_PAIR(B2OnClearTarget, B2CleanupDelete))
	ecs_add(B2ChildOf, B2Exclusive)

	--stylua: ignore
	return {
		existed = ecs_existed,
		contains = ecs_contains,
		entity = ecs_entity,
		in_use = ecs_in_use,
		get = ecs_get,
		bulk_get = ecs_bulk_get,
		has = ecs_has,
		target = ecs_target,
		parent = ecs_parent,
		add = ecs_add,
		bulk_add = ecs_bulk_add,
		component = ecs_component,
		set = ecs_set,
		bulk_set = ecs_bulk_set,
		remove = ecs_remove,
		bulk_remove = ecs_bulk_remove,
		clear = ecs_clear,
		cleanup = ecs_cleanup,
		ensure_dense_archetypes = ecs_ensure_dense_archetypes,
		each = ecs_each,
		query = ecs_query,

		internal = {
			ROOT_ARCHETYPE = ROOT_ARCHETYPE,
			agraph_root = agraph_root,
			agraph = agraph,
			arch_has_empty_rows = arch_has_empty_rows,
			arch_scheduled_for_deletion = arch_scheduled_for_deletion,
			archetypes = archetypes,
			archetypes_count = function() return archetypes_count end,
			observe_arch_added = observe_arch_added,
			observe_arch_removed = observe_arch_removed,
			cindex = cindex,
			eindex_dense = eindex_dense,
			eindex_sparse = eindex_sparse,
			eindex_alive_count = function() return eindex_alive_count end,
			eindex_id_top = function() return eindex_id_top end,
			user_components_count = function() return user_components_count end,
			eindex_try_any_record = eindex_try_any_record,
			eindex_try_matching_record = eindex_try_matching_record,
			eindex_alive_eh = eindex_alive_eh,
			ecs_existed = ecs_existed,
			ecs_contains = ecs_contains,
			ent_try_latest_alive = ent_try_latest_alive,
			eindex_new_id_alive = eindex_new_id_alive,
			ecs_entity = ecs_entity,
			ecs_in_use = ecs_in_use,
			arch_ensure_dense = arch_ensure_dense,
			arch_move = arch_move,
			ent_move = ent_move,
			fetch_at_row = fetch_at_row,
			ecs_get = ecs_get,
			ecs_bulk_get = ecs_bulk_get,
			ecs_has = ecs_has,
			ent_has_inline = ent_has_inline,
			ecs_target = ecs_target,
			ecs_parent = ecs_parent,
			id_record_new = id_record_new,
			id_record_ensure = id_record_ensure,
			id_record_arch_append = id_record_arch_append,
			ids_page_mapping = ids_page_mapping,
			pagebuff_from_mapping = pagebuff_from_mapping,
			list_from_buff = list_from_buff,
			arch_new = arch_new,
			agraph_ensure = agraph_ensure,
			agraph_ensure_arch = agraph_ensure_arch,
			binary_search = binary_search,
			binary_insert = binary_insert,
			agraph_traverse_add = agraph_traverse_add,
			agraph_traverse_add_ensure = agraph_traverse_add_ensure,
			agraph_traverse_rem = agraph_traverse_rem,
			agraph_traverse_rem_ensure = agraph_traverse_rem_ensure,
			ecs_add = ecs_add,
			ecs_bulk_add = ecs_bulk_add,
			ecs_component = ecs_component,
			ecs_set = ecs_set,
			ecs_bulk_set = ecs_bulk_set,
			ecs_remove = ecs_remove,
			ecs_bulk_remove = ecs_bulk_remove,
			ecs_clear = ecs_clear,
			arch_delete = arch_delete,
			ecs_cleanup = ecs_cleanup,
			ecs_ensure_dense_archetypes = ecs_ensure_dense_archetypes,
			query_matcher_cache = query_matcher_cache,
			query_matcher_hash = query_matcher_hash,
			query_matcher_new = query_matcher_new,
			query_matcher_ensure = query_matcher_ensure,
			ecs_each = ecs_each,
			queryobj = queryobj,
			queryobj_metatable = queryobj_metatable,
			ecs_query = ecs_query,
		},
	}
end

local b2264644_3d77_4ab9_8a00_5e9ffb0ff964 = {
	ecs = ecs_new,
	pair = ENT_PAIR :: (hi: Ent, lo: Ent) -> Ent,
	Component = B2Component :: any,
	Name = B2Name :: any,
	Wildcard = B2Wildcard :: any,
	ChildOf = B2ChildOf :: any,
	DeleteOnClear = ENT_PAIR(B2OnClear, B2CleanupDelete),
	DeleteOnDelete = ENT_PAIR(B2OnDelete, B2CleanupDelete),
	DeleteOnClearTarget = ENT_PAIR(B2OnClearTarget, B2CleanupDelete),
	DeleteOnDeleteTarget = ENT_PAIR(B2OnDeleteTarget, B2CleanupDelete),
	DeleteOnClearAsRelation = ENT_PAIR(B2OnClearAsRelation, B2CleanupDelete),
	DeleteOnDeleteAsRelation = ENT_PAIR(B2OnDeleteAsRelation, B2CleanupDelete),
	OnClear = B2OnClear :: any,
	OnDelete = B2OnDelete :: any,
	OnClearTarget = B2OnClearTarget :: any,
	OnDeleteTarget = B2OnDeleteTarget :: any,
	CleanupDelete = B2CleanupDelete :: any,
	OnAdd = B2OnAdd :: any,
	OnChange = B2OnChange :: any,
	OnRemove = B2OnRemove :: any,
	Exclusive = B2Exclusive :: any,

	internal = {
		hks_add = hks_add,
		hks_change = hks_change,
		hks_remove = hks_remove,
		idr_flags = idr_flags,
		idr_hooks = idr_hooks,
		idr_arch_sparse = idr_arch_sparse,
		idr_arch_count = idr_arch_count,
		idr_dense_cached = idr_dense_cached,
		idr_dense_column = idr_dense_column,
		idr_dense_counts = idr_dense_counts,
		idr_monitors = idr_monitors,

		INDEX = INDEX,
		NULL_ARRAY = NULL_ARRAY,
		NULLPTR = NULLPTR,
		F64_BYTES = F64_BYTES,
		IDFLAG_TAG = IDFLAG_TAG,
		IDFLAG_DELETE_ONCLEAR = IDFLAG_DELETE_ONCLEAR,
		IDFLAG_DELETE_ONDELETE = IDFLAG_DELETE_ONDELETE,
		IDFLAG_DELETE_ONCLEARTARGET = IDFLAG_DELETE_ONCLEARTARGET,
		IDFLAG_DELETE_ONDELETETARGET = IDFLAG_DELETE_ONDELETETARGET,
		IDFLAG_DELETE_ONCLEARASRELATION = IDFLAG_DELETE_ONCLEARASRELATION,
		IDFLAG_DELETE_ONDELETEASRELATION = IDFLAG_DELETE_ONDELETEASRELATION,
		IDFLAG_EXCLUSIVE = IDFLAG_EXCLUSIVE,
		IDFLAG_HOOK_ONADD = IDFLAG_HOOK_ONADD,
		IDFLAG_HOOK_ONCHANGE = IDFLAG_HOOK_ONCHANGE,
		IDFLAG_HOOK_ONREM = IDFLAG_HOOK_ONREM,
		EMASK_LO = EMASK_LO,
		EMASK_GENERATION = EMASK_GENERATION,
		EPAIR_OFFSET = EPAIR_OFFSET,
		COMPONENT_PAGE_SIZE = COMPONENT_PAGE_SIZE,
		COMPONENT_PAGE_RECORD_SIZE = COMPONENT_PAGE_RECORD_SIZE,
		MAX_PAGED_COMPONENT = MAX_PAGED_COMPONENT,
		MAX_COMPONENT = MAX_COMPONENT,

		B2Component = B2Component,
		B2Name = B2Name,
		B2Exclusive = B2Exclusive,
		B2Wildcard = B2Wildcard,
		B2ChildOf = B2ChildOf,
		B2OnClear = B2OnClear,
		B2OnDelete = B2OnDelete,
		B2OnClearTarget = B2OnClearTarget,
		B2OnDeleteTarget = B2OnDeleteTarget,
		B2OnClearAsRelation = B2OnClearAsRelation,
		B2OnDeleteAsRelation = B2OnDeleteAsRelation,
		B2CleanupDelete = B2CleanupDelete,
		B2OnAdd = B2OnAdd,
		B2OnRemove = B2OnRemove,
		B2OnChange = B2OnChange,

		ASSERT = ASSERT,
		ORDERED_HASH = ORDERED_HASH,
		ENT_LO = ENT_LO,
		ENT_HI = ENT_HI,
		ENT_PAIR = ENT_PAIR,
		ENT_PAIR_EH = ENT_PAIR_EH,
		ENT_PAIR_HI = ENT_PAIR_HI,
		ENT_PAIR_LO = ENT_PAIR_LO,
		ARCH_APPEND = ARCH_APPEND,
		ENT_INCREMENT_GENERATION = ENT_INCREMENT_GENERATION,
		RECORD_ENSURE_ROW = RECORD_ENSURE_ROW,
		ecs_new = ecs_new,
	},
}

export type Ent<T = any> = { _B2: T }
export type Id<T = nil> = Ent<T>

export type Query<Reads...> = {
	with: (self: Query<Reads...>, ...Ent) -> Query<Reads...>,
	without: (self: Query<Reads...>, ...Ent) -> Query<Reads...>,
	match: (self: Query<Reads...>) -> (Arch) -> boolean,
	archetypes: (self: Query<Reads...>) -> { Arch },
	entities: (self: Query<Reads...>) -> () -> (Ent, Reads...),
	archetypes_cached: (self: Query<Reads...>) -> { Arch },
	entities_cached: (self: Query<Reads...>) -> () -> (Ent, Reads...),
	observe_added: (self: Query<Reads...>, callback: (Arch) -> ()) -> (),
	observe_removed: (self: Query<Reads...>, callback: (Arch) -> ()) -> (),
	monitor_added_row: (self: Query<Reads...>, callback: (Ent, Arch, Row) -> ()) -> (),
	monitor_removed_row: (self: Query<Reads...>, callback: (Ent, Arch, Row) -> ()) -> (),
	monitor_added: (self: Query<Reads...>, callback: (Ent, Reads...) -> ()) -> (),
	monitor_removed: (self: Query<Reads...>, callback: (Ent) -> ()) -> (),
}

export type OldSolverECS = {
	-- has an entity with this ID ever existed under any generation?
	existed: (entity: Ent) -> boolean,
	-- does an entity with this ID exist, and is it alive?
	contains: (entity: Ent) -> boolean,
	entity: () -> Ent,
	in_use: (Ent) -> boolean,
	get: (<A>(entity: Ent, component: Ent<A>) -> A?)
		& (<A, B>(entity: Ent, a: Ent<A>, b: Ent<B>) -> (A?, B?))
		& (<A, B, C>(entity: Ent, a: Ent<A>, b: Ent<B>, c: Ent<C>) -> (A?, B?, C?))
		& (<A, B, C, D>(entity: Ent, a: Ent<A>, b: Ent<B>, c: Ent<C>, d: Ent<D>) -> (A?, B?, C?, D?)),
	bulk_get: (entity: Ent, components: { Ent }) -> { any },
	has: (entity: Ent, A: Ent, ...Ent) -> boolean,
	target: (entity: Ent, rel: Ent, idx: number?) -> Ent?,
	parent: (entity: Ent) -> Ent?,
	add: (entity: Ent, A: Ent) -> (),
	bulk_add: (entity: Ent, components: { Ent }) -> (),
	component: <Data>() -> Ent<Data>,
	set: <Data>(entity: Ent, component: Ent<Data>, data: Data) -> (),
	bulk_set: (entity: Ent, components: { Ent }, values: { any }) -> (),
	remove: (entity: Ent, component: Ent) -> (),
	bulk_remove: (entity: Ent, components: { Ent }) -> (),
	clear: (entity: Ent, delete: boolean?) -> (),
	cleanup: () -> (),
	ensure_dense_archetypes: () -> (),
	each: (id: Ent) -> () -> Ent?,
	query: (() -> Query<>)
		& (<A>(A: Ent<A>) -> Query<A>)
		& (<A, B>(A: Ent<A>, B: Ent<B>) -> Query<A, B>)
		& (<A, B, C>(A: Ent<A>, B: Ent<B>, C: Ent<C>) -> Query<A, B, C>)
		& (<A, B, C, D>(A: Ent<A>, B: Ent<B>, C: Ent<C>, D: Ent<D>) -> Query<A, B, C, D>)
		& (<A, B, C, D, E>(A: Ent<A>, B: Ent<B>, C: Ent<C>, D: Ent<D>, E: Ent<E>) -> Query<A, B, C, D, E>)
		& (<A, B, C, D, E, F>(
			A: Ent<A>,
			B: Ent<B>,
			C: Ent<C>,
			D: Ent<D>,
			E: Ent<E>,
			F: Ent<F>
		) -> Query<A, B, C, D, E, F>)
		& (<A, B, C, D, E, F, G>(
			A: Ent<A>,
			B: Ent<B>,
			C: Ent<C>,
			D: Ent<D>,
			E: Ent<E>,
			F: Ent<F>,
			...Ent<G>
		) -> Query<A, B, C, D, E, F, ...G>),

	internal: typeof(ecs_new().internal),
}

-- export type function greedy(Type: type): type
-- 	return Type
-- end

type function _query(pack: type): type
	local b2_id = types.singleton "_B2"
	local params = pack:parameters()
	local head = params.head
	if head then
		local head_count = #head
		local id_types = table.create(head_count) :: { type }
		for head_index = 1, head_count do
			local id = head[head_index]
			local id_tag = id.tag
			if id_tag ~= "table" then
				id_types[head_index] = types.any
				continue
			end
			local prop = id:readproperty(b2_id)
			if not prop then
				id_types[head_index] = types.any
				continue
			end
			id_types[head_index] = prop
		end
		return (Query(table.unpack(id_types)))
	end
	return Query()
end

export type query<Ids...> = _query<(Ids...) -> ()>

export type NewSolverECS = OldSolverECS

export type OnAddHook = <Data>(entity: Ent, id: Ent<Data>, data: Data) -> ()
export type OnChangeHook = <Data>(entity: Ent, id: Ent<Data>, data: Data) -> ()
export type OnRemoveHook = <Data>(entity: U53, id: Ent<Data>) -> ()

export type B2 = {
	internal: typeof(b2264644_3d77_4ab9_8a00_5e9ffb0ff964.internal),

	ecs: ((new_solver: false, disable_auto_ensure_dense: boolean?) -> OldSolverECS)
		& ((new_solver: true, disable_auto_ensure_dense: boolean?) -> NewSolverECS),
	pair: (hi: Ent, lo: Ent) -> Ent,
	Component: Id,
	Name: Id<string>,
	Wildcard: Id,
	ChildOf: Id,
	DeleteOnClear: Id,
	DeleteOnDelete: Id,
	DeleteOnClearTarget: Id,
	DeleteOnDeleteTarget: Id,
	DeleteOnClearAsRelation: Id,
	DeleteOnDeleteAsRelation: Id,
	OnClear: Id,
	OnDelete: Id,
	OnClearTarget: Id,
	OnDeleteTarget: Id,
	CleanupDelete: Id,
	OnAdd: Id<OnAddHook>,
	OnChange: Id<OnChangeHook>,
	OnRemove: Id<OnRemoveHook>,
	Exclusive: Id,
}

--[[
internal type exports
]]
export type _IdList = IdList
export type _ObservableEventId = ObservableEventId
export type _ArchLocation = ArchLocation
export type _ArchHash = ArchHash
export type _Row = Row
export type _Column = Column
export type _Arch = Arch
export type _ArchGraphNode = ArchGraphNode
export type _Hooks = Hooks
export type _IdRecord = IdRecord
export type _InternalOnAddHook = InternalOnAddHook
export type _InternalOnChangeHook = InternalOnChangeHook
export type _InternalOnRemoveHook = InternalOnRemoveHook
export type _QueryMatcher = QueryMatcher
export type _QueryInner = QueryInner
export type _QueryOuter = QueryOuter
export type _Observer<Parameters... = ...any> = Observer<Parameters...>
export type _EntRecord = EntRecord

return (b2264644_3d77_4ab9_8a00_5e9ffb0ff964 :: any) :: B2
