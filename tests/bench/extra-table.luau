--!strict

--[[
	Extended Table Library
	---------------------------------------------
	Author: @akari_yn
	Date: 2025-07-08 (Last Updated)
	Version: 1.1.0

	Description:
	A comprehensive Luau utility library designed to supercharge the standard 'table' object.
	It provides a rich set of functions for advanced data manipulation, memory inspection,
	functional programming, and complex transformations, extending beyond the capabilities
	of the built-in table API.

	Features:
	- **Memory & Size Utilities**: Inspect the allocated size and memory usage of tables (e.g., `getAllocatedArraySize`, `getTableMemorySize`).
	- **Advanced Table Transformations**: Perform complex operations like deep merging, accumulation, diffing, and syncing tables.
	- **Comprehensive Array Manipulation**: A full suite of tools for array operations including flattening, compacting, shuffling, sampling, and efficient removal.
	- **Functional Programming**: High-order functions like `map`, `filter`, `reduce`, `every`, and `some` for expressive data processing.
	- **Deep Operations**: Recursively copy, compare (`deepEqual`), and freeze tables to ensure data integrity and immutability.
	- **Inspection & Conversion**: Easily get keys/values, check for array types (`isContiguousArray`), and convert tables to different formats (`prettyPrint`, `tableToPairs`).

	Important Notes:
	- This library is designed for the Luau environment and may use Luau-specific functions.
	- While partially optimized, be mindful of performance implications when using deep/recursive functions on very large tables.
	- Providing malformed inputs on non-strict mode (`STRICT_MODE` on line 865) may result in errors or undefined behavior.
]]

--// Types \\--

type table<K = any, V = any> = { [K]: V }
type array<V = any> = { V }

type ExtendedTableLibrary = {

	--[=[
	==============================
	 1. Memory & Size Utilities
	==============================
	]=]

	--[=[
		GetAllocatedArraySize

		Determines the allocated size of a Luau table's array part, not
		just the number of items currently in the table (which `#t` would give).

		@param tbl The table whose allocated size is to be determined.
		@return The allocated size of the table's array part.
	]=]
	getAllocatedArraySize: <K, V>(tbl: table<K, V>) -> number,

	--[=[
		GetAllocatedHashSize

		Determines the allocated size of a Luau table's hash part.

		@param tbl The table to inspect.
		@return The allocated size of the table's hash part.
	]=]
	getAllocatedHashSize: <K, V>(tbl: table<K, V>) -> number,

	--[=[
		GetTableMemorySize

		Returns the total memory used by a table structure, including its internal
		allocation and structural overhead (e.g., array/hash parts).

		- If `includeContents` is true, it also includes the memory size of the contents of the table.
			Note that memory usage of function, thread, and userdata values is not included.

		@param tbl The table to measure.
		@param includeContents? If true, includes the memory size of the contents of the table.
		@return An estimated memory size in bytes.
	]=]
	getTableMemorySize: <K, V>(tbl: table<K, V>, includeContents: boolean?) -> number,

	--[=[
		GetTableSize

		Counts the number of elements in a table. It can be optimized for
		contiguous arrays.

		@param tbl The table to count.
		@param isContiguous? If true (default), assumes the table's array is contiguous.
				If false, iterates over all key-value pairs.
		@return The total number of elements in the table.
	]=]
	getTableSize: <K, V>(tbl: table<K, V>, isContiguous: boolean?) -> number,

	--[=[
	==============================
	 2. Table Transformation
	==============================
	]=]

	--[=[
		MergeTables

		Recursively merging tables, combining their keys and values.
		If a key exists in more than one tables:
			- If both values are tables, they are merged recursively.
			- Otherwise, the first value is kept.

		- If `depth` is -1, it merges all nested tables without depth limit.
		- If `inPlace` is true, the first table is modified in place and returned. Otherwise, a new table is returned.

		@param inPlace? Whether to modify and return the first table instead of creating a new table (default is false).
		@param depth? The depth to merge nested tables (default is -1).
		@param ... Two or more tables to merge.
		@return A new table or modified first table with all inputs merged.
	]=]
	mergeTables: <K, V>(inPlace: boolean?, depth: number?, ...table<K, V>) -> table<K, V>,

	--[=[
		MergeTablesWith

		Recursively merges multiple tables, allowing a custom resolver function to handle conflicts.
		If a key exists in more than one table:
			- If both values are tables, they are merged recursively.
			- Otherwise, the resolver function is applied to combine the values.

		- If `depth` is -1, it merges all nested tables without depth limit.
		- If `inPlace` is true, the first table is modified in place and returned. Otherwise, a new table is returned.

		@param inPlace? Whether to modify and return the first table instead of creating a new table (default is false).
		@param depth? The depth to merge nested tables (default is -1).
		@param resolver A function that resolves conflicts between two values.
				It receives the key and two values and returns the resolved value.
		@param ... Two or more tables to merge.
		@return A new table or modified first table with all inputs merged.
	]=]
	mergeTablesWith: <K, V>(
		inPlace: boolean?,
		depth: number?,
		resolver: (K, V, V) -> any,
		...table<K, V>
	) -> table<K, V>,

	--[=[
		AccumulateTables

		Recursively combines multiple tables by summing matching numeric values and merging nested tables.

		- If a key exists in multiple tables:
			- If all values are numbers, they are added together.
			- If all values are tables, they are merged recursively.
			- If value types conflict (e.g., number vs string), an error is thrown.
		- If a key exists in only one table, that value is used.
		- Supports optional in-place modification of the first table.

		@param inPlace? If true, modifies and returns the first table.
		@param ... Two or more tables to accumulate.
		@return A new table or modified first table with all inputs accumulated.
	]=]
	accumulateTables: <K, V>(inPlace: boolean?, ...table<K, V>) -> table<K, V>,

	--[=[
		DiffTables

		Compares two tables (`old` and `new`) and returns a breakdown of differences between them.
		Useful for detecting what has changed, been added, or removed when comparing data sets.

		@param old The original table.
		@param new The updated table to compare against the original.
		@return table A table containing:
			- `added`: table<kB, vB> — entries present in `new` but not in `old`.
			- `removed`: table<kA, vA> — entries present in `old` but not in `new`.
			- `changed`: table<kA, vA> — entries that exist in both but have different values.
	]=]
	diffTables: <kA, vA, kB, vB>(
		old: table<kA, vA>,
		new: table<kB, vB>
	) -> {
		added: table<kA | kB, vA | vB>,
		removed: table<kA | kB, vA | vB>,
		changed: table<kA | kB, vA | vB>,
	},

	--[=[
		SyncTable

		Synchronizes the keys and values of a source table with a target table.
		If a key exists in the source but not in the target, it is added to the target.
		If a key exists in the target but not in the source, it is removed from the target.

		@param src The source table to sync from.
		@param target The target table to sync to.
		@return The updated target table after synchronization.
	]=]
	syncTable: <kS, vS, kT, vT>(src: table<kS, vS>, target: table<kT, vT>) -> table<kT, vT>,

	--[=[
		MapTable

		Creates a new table by applying a callback function to each key-value pair in the original table.

		@param tbl The table to map.
		@param callback The function to apply to each key-value pair. It receives the key and value.
		@return A new table with the results of the callback function.
	]=]
	mapTable: <K, V, U>(tbl: table<K, V>, callback: (K, V) -> U) -> table<K, U>,

	--[=[
		FilterTable

		Creates a new table containing only the key-value pairs that satisfy the given predicate function.

		@param tbl The table to filter.
		@param predicate The function to test each key-value pair. It receives the key and value.
		@param preAllocate? If true, pre-allocates the result table with the same size as the input table (default is true).

		@return A new table with only the key-value pairs that match the predicate.
	]=]
	filterTable: <K, V, U>(
		tbl: table<K | U, V>,
		predicate: (K | U, V) -> boolean,
		preAllocate: boolean?
	) -> table<U, V>,

	--[=[
		ReduceTable

		Reduces a table to a single value by applying a reducer function to each key-value pair.

		@param tbl The table to reduce.
		@param reducer The function that combines the accumulated value with each key-value pair.
			It receives the accumulated value, key, and value.
		@param initial The initial value for the reduction.
		@return The final reduced value.
	]=]
	reduceTable: <K, V, U>(tbl: table<K, V>, reducer: (U, K, V) -> U, initial: U) -> U,

	--[=[
		GroupTableBy

		Groups the elements of a table by a specified key or property.
		The callback function receives each key-value pair and returns the grouping key.

		@param tbl The table to group.
		@param callback The function that determines the grouping key for each key-value pair.
		@return A new table where keys are the grouping keys and values are arrays of grouped items.
	]=]
	groupTableBy: <K, V, G>(tbl: table<K, V>, callback: (K, V) -> G) -> table<G, array<V>>,

	--[=[
		TableToPairs

		Converts a table into an array of key-value pairs, where each pair is represented as an array.

		@param tbl The table to convert.
		@return An array of key-value pairs, where each pair is an array of the form {key, value}.
	]=]
	tableToPairs: <K, V>(tbl: table<K, V>) -> array<{ K | V }>,

	--[=[
		InvertTable

		Inverts a table, swapping its keys and values.
		If multiple keys map to the same value, only one key will be kept.

		@param tbl The table to invert.
		@return A new table with keys and values swapped.
	]=]
	invertTable: <K, V>(tbl: table<K, V>) -> table<V, K>,

	--[=[
		TableIntersection

		Finds the intersection of two tables, returning a new table containing only the keys and values
		that are present in both tables. The value from the first table is used in the result.

		@param tbl1 The first table.
		@param tbl2 The second table.
		@param matchValue? If true, checks both keys and values for intersection (default is false).
		@return A new table containing only the key-value pairs that exist in both input tables.
	]=]
	tableIntersection: <K, V>(tbl1: table<K, V>, tbl2: table<K, V>, matchValue: boolean?) -> table<K, V>,

	--[=[
		TableDifference

		Finds the difference between two tables, returning a new table containing only the keys and values
		that are present in the first table but not in the second table. 
		
		If `matchValue` is true, it only checks differences for keys that exist in both tables, and the return result is only for keys that have different values.
		If `symmetric` is true, returns the symmetric difference (keys present in either table but not both).
		
		Note: `matchValue` and `symmetric` options are incompatible and cannot both be true.

		@param tbl1 The first table.
		@param tbl2 The second table.
		@param matchValue? If true, only checks differences for keys that exist in both tables, returning keys with different values (default is false).
		@param symmetric? If true, returns the symmetric difference (keys in either table but not both) (default is false).
		@return A new table containing only the key-value pairs that exist in `tbl1` but not in `tbl2`.
	]=]
	tableDifference: <K, V>(
		tbl1: table<K, V>,
		tbl2: table<K, V>,
		matchValue: boolean?,
		symmetric: boolean?
	) -> table<K, V>,

	--[=[
		RemoveAll

		Removes all occurrences of a specified value from a table.
		If the value is an array, it removes all elements that match any of the values in the array.

		@param tbl The table to modify.
		@param value The value or array of values to remove from the table.
	]=]
	removeAll: <K, V, T>(tbl: table<K, V>, value: T | array<T>) -> (),

	--[=[
	==============================
	 3. Array Manipulation
	==============================
	]=]

	--[=[
		ExtendArraySize

		Extends an array by a given size.

		@param tbl The array to extend.
		@param expandSize The number of elements to add.
	]=]
	extendArraySize: <K, V>(tbl: table<K, V>, expandSize: number) -> (),

	--[=[
		SetArraySize

		Sets the length of an array to a new size. This function can only be
		used to expand an array by nil-padding it. It cannot be used to
		truncate an array.

		@param tbl The array to resize.
		@param newSize The desired new size of the array, must be >= sizearray.
	]=]
	setArraySize: <K, V>(tbl: table<K, V>, newSize: number) -> (),

	--[=[
		TruncateArray

		Truncates an array to a specified size, removing any elements beyond that size.

		@param array The array to truncate.
		@param newSize The new size of the array. If this is less than the current size, elements will be removed.

		@return A new array with the specified size, containing the first `newSize` elements of the original array.
	]=]
	truncateArray: <T>(array: array<T>, newSize: number) -> array<T>,

	--[=[
		ConcatArrays

		Concatenates multiple arrays into a single array.

		@param inPlace? If true, modifies the first array in place and returns it.
		@param ...array The arrays to concatenate.
		@return A new array containing all elements from the input arrays, in order.
	]=]
	concatArrays: <T>(inPlace: boolean?, ...array<T>) -> array<T>,

	--[=[
		UnionArrays

		Creates a new array that contains all unique elements from the input arrays.

		@param ...array The arrays to union.
		@return A new array containing all unique elements from the input arrays.
	]=]
	unionArrays: <T>(...array<T>) -> array<T>,

	--[=[
		FlattenArray

		Recursively flattens a nested array up to a given depth.

		@param src An array containing other arrays.
		@param depth The number of levels to flatten (default: -1 for full flatten).
		@return A new, flattened array up to the specified depth.
	]=]
	flattenArray: <T, U>(src: array<T>, depth: number?) -> array<U>,

	--[=[
		CompactArray

		Compacts a sparse array into a contiguous array, removing any gaps in indices.
		
		A sparse array is an array with missing indices (e.g., {[1] = "a", [3] = "c", [5] = "e"}).
		This function creates a new array where all elements are moved to consecutive indices 
		starting from 1 (e.g., {[1] = "a", [2] = "c", [3] = "e"}).

		@param array The sparse array to compact. Can have missing indices between elements.
		@param allocateExactSize? If true, creates a new array with size equal to the number of elements.
				If false or nil, uses the same size as the original table for better performance.
		@param isArray? If true, uses optimized array iteration that leverages Luau's guaranteed 
				in-order traversal for arrays (indices stored in array portion, not hash portion).
				If false, treats input as a general table. Default is false.
		@return A compacted array with consecutive indices starting from 1. May return the 
				original array if it's already compact.
	]=]
	compactArray: <T>(array: array<T>, allocateExactSize: boolean?, isArray: boolean?) -> array<T>,

	--[=[
		FillWithValue

		Fills an array with a specified value from a start index to an end index.
		Optimized for filling with the same value repeatedly.

		@param array The array to fill.
		@param value The value to fill the array with.
		@param startIndex? The index to start filling from (default is 1).
		@param endIndex? The index to stop filling at (default is the length of the array).
		@param sourceArray? An optional pre-allocated array containing the fill value, used for performance optimization
			when filling large ranges. Should contain only the same value as the `value` parameter.
			If not provided, one may be created internally for large fills.
	]=]
	fillWithValue: <T>(array: array<T>, value: T, startIndex: number?, endIndex: number?, sourceArray: array<T>?) -> (),

	--[=[
		FillWithPattern

		Fills an array with values from a source array, repeating the source array pattern as needed.
		This is useful for filling with repeating patterns or sequences.

		@param array The array to fill.
		@param pattern The array containing the pattern/values to fill with. Cannot be empty.
		@param startIndex? The index to start filling from (default is 1).
		@param endIndex? The index to stop filling at (default is the length of the array).
	]=]
	fillWithPattern: <T>(array: array<T>, pattern: array<T>, startIndex: number?, endIndex: number?) -> (),

	--[=[
		ReverseArray

		Reverses the order of elements in an array in place.

		@param array The array to reverse.
	]=]
	reverseArray: <T>(array: array<T>) -> (),

	--[=[
		RotateArray

		Rotates the elements of an array by a specified number of positions.
		A positive shift rotates to the right, while a negative shift rotates to the left.

		@param array The array to rotate.
		@param shift The number of positions to rotate. Positive values rotate right, negative values rotate left.
	]=]
	rotateArray: <T>(array: array<T>, shift: number) -> (),

	--[=[
		SliceArray

		Creates a new array containing a portion of the original array from startIndex to endIndex.
		If startIndex or endIndex are not provided, they default to 1 and the length of the array, respectively.

		@param array The array to slice.
		@param startIndex? The index to start slicing from (default is 1).
		@param endIndex? The index to stop slicing at (default is the length of the array).
		@return A new array containing the sliced portion.
	]=]
	sliceArray: <T>(array: array<T>, startIndex: number?, endIndex: number?) -> array<T>,

	--[=[
		ShuffleArray

		Randomly shuffles the elements of an array in place.

		@param array The array to shuffle.
	]=]
	shuffleArray: <T>(array: array<T>) -> (),

	--[=[
		SampleArray

		Randomly selects a specified number of elements from an array, optionally allowing duplicates.
		If `allowDuplicates` is false, each element can only be selected once.

		@param array The array to sample from.
		@param sampleSize The number of elements to sample.
		@param allowDuplicates? If true, allows the same element to be selected multiple times (default is false).
		@return A new array containing the sampled elements.
	]=]
	sampleArray: <T>(array: array<T>, sampleSize: number, allowDuplicates: boolean?) -> array<T>,

	--[=[
		SampleValue

		Randomly selects a single value from an array, optionally within a specified range of indices.

		@param array The array to sample from.
		@param startIndex? The index to start sampling from (default is 1).
		@param endIndex? The index to stop sampling at (default is the length of the array).
		@return A randomly selected value from the specified range in the array.
	]=]
	sampleValue: <T>(array: array<T>, startIndex: number?, endIndex: number?) -> T,

	--[=[
		RemoveDuplicate

		Removes duplicate values from an array, preserving the order of the first occurrence.
		An optional `by` function can be provided to determine uniqueness based on a transformed value.

		@param array The array to process.
		@param by? An optional function that takes an element and returns a value to be used for uniqueness checks.
		@return A new array with duplicates removed.
	]=]
	removeDuplicate: <T, K>(array: array<T>, by: ((value: T) -> K)?) -> array<T>,

	--[=[
		SwapRemove

		Removes an element from an array at a specified index and replaces it with the last element.
		This is more efficient than removing an element by shifting all subsequent elements.

		@param array The array to modify.
		@param index The index of the element to remove.
	]=]
	swapRemove: <T>(array: array<T>, index: number) -> (),

	--[=[
		GetAndRemove

		Retrieves and removes an element from an array at a specified index.

		@param array The array to modify.
		@param index The index of the element to retrieve and remove.
		@param swap? If true, uses the swap-remove method for efficiency (default is false).
		@return The element at the specified index, or nil if the index is out of bounds.
	]=]
	getAndRemove: <T>(array: array<T>, index: number, swap: boolean?) -> T?,

	--[=[
		FindAndRemove

		Finds the first occurrence of a value in an array and removes it.
		If the value is found, it returns true; otherwise, it returns false.

		@param array The array to search.
		@param value The value to find and remove.
		@param swap? If true, uses the swap-remove method for efficiency (default is false).
		@return True if the value was found and removed, otherwise false.
	]=]
	findAndRemove: <T>(array: array<T>, value: T, swap: boolean?) -> boolean,

	--[=[
		ZipArray

		Combines multiple arrays into a single array of tuples (arrays), where each tuple contains
		the elements from the input arrays at the same index.

		For example, zipArray({1, 2, 3}, {"a", "b", "c"}) returns {{1, "a"}, {2, "b"}, {3, "c"}}.

		The resulting array has a length equal to the shortest of the input arrays.

		@param ...array A variable number of arrays to zip together.
		@return A new array where each element is an array containing the ith elements of the input arrays.
	]=]
	zipArray: (...array) -> array<array>,

	--[=[
		UnzipArray

		Reverses the operation of `zipArray`. Takes an array of tuples (arrays) and separates them back
		into individual arrays, one for each position in the tuples.

		For example, unzipArray({{1, "a"}, {2, "b"}, {3, "c"}}) returns {{1, 2, 3}, {"a", "b", "c"}}.

		All subarrays in the input must be of equal length.

		@param zippedArray An array of arrays (tuples) to unzip.
		@return An array of arrays, where each array contains the ith elements from the tuples in the input.
	]=]
	unzipArray: (zippedArray: array<array>) -> array<array>,

	--[=[
		PartitionArray

		Splits an array into smaller arrays of a specified size.

		@param array The array to partition.
		@param size The size of each partition.
		@return An array of arrays, where each sub-array has at most `size` elements.
	]=]
	partitionArray: <T>(array: array<T>, size: number) -> array<array<T>>,

	--[=[
		PartitionArrayBy

		Splits an array into two arrays based on a predicate function.
		The first array contains elements that satisfy the predicate, and the second contains those that do not.

		@param array The array to partition.
		@param predicate A function that takes an element and returns true or false.
			If true, the element goes into the first array; if false, it goes into the second.
		@return A tuple containing two arrays: the first with elements that satisfy the predicate,
			and the second with elements that do not.
	]=]
	partitionArrayBy: <T, A, B>(array: array<T>, predicate: (T) -> boolean) -> (array<A>, array<B>),

	--[=[
		BinarySearch

		Performs a binary search on a sorted array to find the index of a specified value.
		If the value is not found, it returns nil.

		@param array The sorted array to search.
		@param value The value to search for.
		@param comparator? An optional comparator function that takes two values and returns:
			- A negative number if the first value is less than the second,
			- Zero if they are equal,
			- A positive number if the first value is greater than the second.
			If not provided, uses the default equality check.
		@return The index of the found value, or nil if not found.
	]=]
	binarySearch: <K, V>(array: array<K>, value: K, comparator: ((K, K) -> number)?) -> number?,

	--[=[
	==============================
	 4. Inspection & Metadata
	==============================
	]=]

	--[=[
		GetKeys

		Retrieves the keys of a table as an array.

		@param tbl The table to get keys from.
		@return An array containing all the keys of the table.
	]=]
	getKeys: <K, V>(tbl: table<K, V>) -> array<K>,

	--[=[
		GetValues

		Retrieves the values of a table as an array.

		@param tbl The table to get values from.
		@return An array containing all the values of the table.
	]=]
	getValues: <K, V>(tbl: table<K, V>) -> array<V>,

	--[=[
		IsContiguousArray

		Checks if a table is an array, and if it is contiguous (i.e., has no `nil` holes from index 1 to #array).

		@param array The array to check.
		@return True if the array is contiguous, otherwise false.
	]=]
	isContiguousArray: <K, V>(tbl: table<K, V>) -> boolean,

	--[=[
		IsSparseArray

		Checks if all the keys in the table are positive integer,
		and if it is sparse (i.e., has `nil` holes in the array part).

		@param array The array to check.
		@return True if the array is sparse, otherwise false.
	]=]
	isSparseArray: <K, V>(tbl: table<K, V>) -> boolean,

	--[=[
		IsArray

		Checks if a table is an array, which means it has only positive integer keys.

		@param tbl The table to check.
		@return True if the table is an array, otherwise false.
	]=]
	isArray: <K, V>(tbl: table<K, V>) -> boolean,

	--[=[                
		IsEmpty

		Checks if a table is empty, meaning it has no keys or values.

		@param tbl The table to check.
		@return True if the table is empty, otherwise false.
	]=]
	isEmpty: <K, V>(tbl: table<K, V>) -> boolean,

	--[=[
		HasKey

		Checks if a table contains a specific key.

		@param tbl The table to check.
		@param key The key to look for.
		@return True if the table has the specified key, otherwise false.
	]=]
	hasKey: <K, V>(tbl: table<K, V>, key: K) -> boolean,

	--[=[
		HasValue

		Checks if a table contains a specific value.

		@param tbl The table to check.
		@param value The value to look for.
		@return True if the table has the specified value, otherwise false.
	]=]
	hasValue: <K, V>(tbl: table<K, V>, value: V) -> boolean,

	--[=[
		CountOccurences

		Counts the number of occurrences of a specific value in a table.
		This is useful for determining how many times a value appears in the table.

		@param tbl The table to inspect.
		@param value The value to count occurrences of.
		@return The number of times the specified value appears in the table.
	]=]
	countOccurences: <K, V>(tbl: table<K, V>, value: V) -> number,

	--[=[
		CountKeysByType

		Counts the number of keys in a table that match a specific type.
		This is useful for filtering keys based on their type.

		@param tbl The table to inspect.
		@param keyType The type of keys to count (e.g., "string", "number").
		@return The number of keys in the table that match the specified type.
	]=]
	countKeysByType: <K, V>(tbl: table<K, V>, keyType: string) -> number,

	--[=[
		CountValuesByType

		Counts the number of values in a table that match a specific type.
		This is useful for filtering values based on their type.

		@param tbl The table to inspect.
		@param valueType The type of values to count (e.g., "string", "number").
		@return The number of values in the table that match the specified type.
	]=]
	countValuesByType: <K, V>(tbl: table<K, V>, value: V) -> number,

	--[=[
		KeysOfValue

		Retrieves all keys in a table that map to a specific value.
		This is useful for finding all keys associated with a particular value.

		@param tbl The table to search.
		@param targetValue The value to find keys for.
		@return An array of keys that map to the specified value.
	]=]
	keysOfValue: <K, V>(tbl: table<K, V>, targetValue: V) -> array<K>,

	--[=[
	==============================
	 5. Functional Utilities
	==============================
	]=]

	--[=[
		DeepCopy

		Creates a recursive, deep copy of a table.

		@param tbl The table to copy.
		@return A new table with all nested tables also copied.
	]=]
	deepCopy: <K, V>(tbl: table<K, V>) -> table<K, V>,

	--[=[
		DeepEqual

		Recursively compares two values for equality, handling nested tables.
		Only values are compared deepy, keys are compared by identity.

		@param a The first value.
		@param b The second value.
		@return True if the values are deeply equal, otherwise false.
	]=]
	deepEqual: <A, B>(a: A, b: B) -> boolean,

	--[=[
		DeepFreeze

		Recursively freezes a table and its nested tables, making them read-only.

		@param tbl The table to freeze.
		@param layers? The number of layers to freeze. If -1, freezes all layers (default is -1).
	]=]
	deepFreeze: <K, V>(tbl: table<K, V>, layers: number?) -> table<K, V>,

	--[=[
		FindMatch

		Finds the first key in a table that satisfies the given filter function.

		@param tbl The table to search.
		@param filter The function to test each key-value pair. It receives the key and value.
		@return The first key that matches the filter, or nil if no match is found.
	]=]
	findMatch: <K, V>(tbl: table<K, V>, filter: (K, V) -> boolean) -> K,

	--[=[
		Every

		Checks if every key-value pair in a table satisfies the given filter function.

		@param tbl The table to check.
		@param filter The function to test each key-value pair. It receives the key and value.
		@return True if every key-value pair satisfies the filter, otherwise false.
	]=]
	every: <K, V>(tbl: table<K, V>, filter: (K, V) -> boolean) -> boolean,

	--[=[
		Some

		Checks if at least one key-value pair in a table satisfies the given filter function.

		@param tbl The table to check.
		@param filter The function to test each key-value pair. It receives the key and value.
		@return True if at least one key-value pair satisfies the filter, otherwise false.
	]=]
	some: <K, V>(tbl: table<K, V>, filter: (K, V) -> boolean) -> boolean,

	--[=[
		ToSet

		Converts a table into a set, where each key is the original key and the value is always true.
		This is useful for quickly checking membership in a set.

		@param tbl The table to convert.
		@return A new table where each key from the original table maps to true.
	]=]
	toSet: <K, V>(tbl: table<K, V>) -> table<K, boolean>,

	--[=[
	==============================
	 6. Conversion & Formatting
	==============================
	]=]

	--[=[
		PrettyPrint

		Converts a table into a human-readable string format, with optional indentation.

		@param tbl The table to print.
		@param indent? The number of spaces to use for indentation (default is 2).
		@return A string representation of the table.
	]=]
	prettyPrint: <K, V>(tbl: table<K, V>, indent: number?) -> string,

	--[=[
		ToCSV

		Converts a 2D array (array of arrays) into a CSV string format.
		Each inner array represents a row, and elements are separated by a specified delimiter.

		@param rows The 2D array to convert to CSV.
		@param delimiter? The character used to separate values in the CSV (default is ",").
		@return A string representing the CSV format of the input array.
	]=]
	toCSV: <T>(rows: array<array<T>>, delimiter: string?) -> string,
} & typeof(table) -- Extend the table type with the ExtendedTableLibrary methods.

--// Constants \\--

local MOVE_TEMPLATE = { nil, true }
local ARRAY_REHASH_THRESHOLD = 2 ^ 12
local MAX_TABLE_SIZE = 2 ^ 26 -- Maximum size of a table in Luau

local DEFAULT_FILL_ARRAY_SIZE = 2 ^ 13 -- Size of the array used for filling operations.
local FILL_THRESHOLD = 2 ^ 11 -- Threshold for creating a fill array.
local MOVE_THRESHOLD = 2 ^ 2 + 1 -- Threshold for using `table.move` instead of a simple loop for filling arrays.

local STRICT_MODE = true -- If true, will throw an error if a table is not a valid array when required.

-- If true, will check the buffer's value for comparisons instead of buffer's identity.
local CHECK_BUFFER_VALUE = false

local SPECIAL_CHARACTERS = {
	["\a"] = "\\a",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
	["\v"] = "\\v",
	["\0"] = "\\0",
}
local LUAU_KEYWORDS = {
	["and"] = true,
	["break"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["until"] = true,
	["while"] = true,
	["continue"] = true,
}

--// Functions \\--

local function checkArgs(argName: string, argType: string, argValue: any, optional: boolean?)
	if (argValue == nil and optional) or (type(argValue) == argType) then
		return
	end
	error(`Expected argument '{argName}' to be of type '{argType}', got '{type(argValue)}'`, 3)
end

local deepCopy

--[=[
==============================
 1. Memory & Size Utilities
==============================
]=]

local function getAllocatedArraySize<K, V>(tbl: table<K, V>): number
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end

	-- Create a probe table that preserves the original table's allocation size.
	local probeTable = table.clone(tbl)
	table.clear(probeTable) -- `table.clear` empties the table but keeps the allocated capacity.

	local ZERO_CONST = 0
	ZERO_CONST = ZERO_CONST -- Prevent folding.

	local TWO_CONST = 2
	TWO_CONST = TWO_CONST -- Prevent folding.

	-- Check if size is 0 or 1 by probing index 2.
	probeTable[2] = ZERO_CONST

	if #probeTable == ZERO_CONST then -- Size is confirmed to be either 0 or 1.
		probeTable = table.clone(tbl)
		table.move(MOVE_TEMPLATE, TWO_CONST, TWO_CONST, TWO_CONST, probeTable) -- Force expansion if size is 1.

		if #probeTable == ZERO_CONST then
			return ZERO_CONST -- The allocated size was 0.
		else
			return 1 -- The allocated size was 1.
		end
	end

	local NIL_CONST = nil
	NIL_CONST = NIL_CONST -- Prevent folding.

	-- Check if size is 2.
	probeTable[3] = ZERO_CONST
	if #probeTable == ZERO_CONST then
		return TWO_CONST
	end

	probeTable[2] = NIL_CONST

	-- Size is at least 3, begin binary search-like probing.
	local probeIndex = 3

	while true do
		-- If the probe index is large, use table.move to force array expansion, avoiding rehash's performance costs.
		if probeIndex > ARRAY_REHASH_THRESHOLD then
			table.move(probeTable, TWO_CONST, TWO_CONST, probeIndex + 1)
		else
			probeTable[probeIndex + 1] = NIL_CONST
		end
		if #probeTable == ZERO_CONST then
			return probeIndex
		end

		probeTable[probeIndex] = NIL_CONST
		probeIndex = (probeIndex - 1) * 2
		probeTable[probeIndex] = ZERO_CONST

		if #probeTable == probeIndex then
			continue
		end

		probeTable[probeIndex] = NIL_CONST
		probeIndex = probeIndex + 1
		probeTable[probeIndex] = ZERO_CONST

		if #probeTable == probeIndex then
			continue
		end

		probeTable[probeIndex] = NIL_CONST
		probeIndex = probeIndex + 1
		probeTable[probeIndex] = ZERO_CONST
	end
end

local function getAllocatedHashSize<K, V>(tbl: table<K, V>): number
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end

	-- Clone the table to measure its hash capacity without modifying the original.
	local probeTable = table.clone(tbl)
	table.clear(probeTable) -- `table.clear` empties the table but keeps the allocated capacity.

	local ZERO_CONST = 0
	ZERO_CONST = ZERO_CONST -- Prevent folding.

	local ONE_CONST = 1
	ONE_CONST = ONE_CONST -- Prevent folding.

	local TWO_CONST = 2
	TWO_CONST = TWO_CONST -- Prevent folding.

	-- This move forces the table to have an array part, standardizing the starting state.
	table.move(MOVE_TEMPLATE, ONE_CONST, TWO_CONST, ONE_CONST, probeTable)

	-- Iterate with negative indices to probe the hash part directly.
	for i = -MAX_TABLE_SIZE, -1 do
		probeTable[i] = ONE_CONST
		if #probeTable == ZERO_CONST then
			return i + MAX_TABLE_SIZE
		end -- The size is found.
	end

	return MAX_TABLE_SIZE
end

local function getMemorySize(v: any, cache: table?): number
	if cache and cache[v] then
		return 0
	end
	local valueType = type(v)
	-- If value type isn't table, cache is guaranteed to exist.

	if valueType == "table" then
		local arraySize = getAllocatedArraySize(v)
		local hashSize = getAllocatedHashSize(v)

		-- Luau memory calculation based on known struct sizes.
		-- TValue (value part): 16 bytes
		-- LuaNode (TKey-TValue pair in hash): 32 bytes
		-- Table object overhead: 48 bytes (Table struct)
		local tblSize = 48 + arraySize * 16 + hashSize * 32

		if cache then
			tblSize = tblSize + getMemorySize(getmetatable(v), cache)
			cache[v] = true -- Mark this table as processed to avoid infinite recursion.

			if arraySize ~= 0 then
				local nextIndex = 1
				for k, subValue in next, v do
					if k ~= nextIndex then
						break
					end
					tblSize = tblSize + getMemorySize(subValue, cache)
					nextIndex = nextIndex + 1
				end

				if hashSize == 0 then
					return tblSize
				end

				for k, subValue in next, v, arraySize do
					tblSize = tblSize + getMemorySize(k, cache) -- Recursively add size of nested keys.
					tblSize = tblSize + getMemorySize(subValue, cache) -- Recursively add size of nested values.
				end
			else
				if hashSize == 0 then
					return tblSize
				end

				for k, subValue in next, v do
					tblSize = tblSize + getMemorySize(k, cache) -- Recursively add size of nested keys.
					tblSize = tblSize + getMemorySize(subValue, cache) -- Recursively add size of nested values.
				end
			end
		end

		return tblSize
	elseif valueType == "buffer" then
		(cache :: table)[v] = true -- Mark this buffer as processed.
		return math.ceil(buffer.len(v) / 8) * 8 -- Return the size of the buffer.
	elseif valueType == "string" then
		(cache :: table)[v] = true -- Mark this string as processed.
		local stringLength = #v
		if stringLength <= 8 then
			return 32
		end
		return 24 + math.ceil(stringLength / 8) * 8 -- TString struct + size of the string.
	elseif valueType == "userdata" then
		(cache :: table)[v] = true -- Mark this userdata as processed.
		return 24 + getMemorySize(getmetatable(v), cache) -- Udata struct + size of the userdata's metatable.
	elseif valueType == "function" then
		(cache :: table)[v] = true -- Mark this function as processed.
		return 48 + 16 -- Closure struct + 1 UpVal minimum.
	elseif valueType == "thread" then
		(cache :: table)[v] = true -- Mark this thread as processed.
		return 128 -- lua_State struct
	else -- For other types (nil, boolean, number), they fit into a single TValue.
		return 0
	end
end

local function getTableMemorySize<K, V>(tbl: table<K, V>, includeContents: boolean?): number
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("includeContents", "boolean", includeContents, true)
	end

	if includeContents then
		-- If includeContents is true, we need to recursively calculate the size of the table's contents.
		return 16 + getMemorySize(tbl, {})
	else
		return 16 + getMemorySize(tbl)
	end
end

local function getTableSize<K, V>(tbl: table<K, V>, isContiguous: boolean?): number
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("isContiguous", "boolean", isContiguous, true)
	end

	if isContiguous ~= false then
		-- Start with the length operator for the contiguous array part.
		local size = #tbl

		-- Iterate through the hash part to count any remaining elements.
		if size == 0 then
			for _ in next, tbl do
				size = size + 1
			end
		else
			for _ in next, tbl, size do
				size = size + 1
			end
		end
		return size
	end

	-- If not contiguous, iterate through every element, which is slower but always accurate.
	local size = 0
	for _ in tbl do
		size = size + 1
	end
	return size
end

--[=[
==============================
 2. Table Transformation
==============================
]=]

local function mergeInPlace(
	valueMap: table,
	depth: number,
	resolver: ((any, any, any) -> any)?,
	result: table,
	...: table
): table
	local resultCache = valueMap[result]
	if not resultCache then
		resultCache = {}
		valueMap[result] = resultCache
	end

	for i = 1, select("#", ...) do
		local tbl = select(i, ...)
		-- If this table has already been merged, skip it to avoid infinite recursion.
		if resultCache[tbl] then
			continue
		end
		resultCache[tbl] = true

		for k, v in tbl do
			local existingValue = result[k]
			local valueType = type(v)

			if existingValue == nil then
				-- If the key does not exist in the result, simply add it.
				if valueType == "table" or CHECK_BUFFER_VALUE and valueType == "buffer" then
					result[k] = deepCopy(v)
				else
					result[k] = v
				end
				continue
			end

			local existingType = type(existingValue)
			if existingType ~= "table" then
				if resolver then
					result[k] = resolver(k, existingValue, v)
				end
				continue
			end

			if valueType ~= "table" then
				if resolver then
					result[k] = resolver(k, existingValue, v)
				end
				continue
			end

			if depth > 0 then
				result[k] = mergeInPlace(valueMap, depth - 1, resolver, existingValue :: any, v)
			end
		end
	end

	return result
end

local function mergeTables<K, V>(inPlace: boolean?, depth: number?, src: table<K, V>, ...: table<K, V>): table<K, V>
	if STRICT_MODE then
		checkArgs("inPlace", "boolean", inPlace, true)
		checkArgs("depth", "number", depth, true)
		checkArgs("src", "table", src)
	end

	depth = depth or -1 -- Default depth is -1, meaning no limit on recursion depth.
	if depth == -1 then
		depth = math.huge
	end -- Convert -1 to a very large number for practical purposes.

	local result: table = inPlace and src or deepCopy(src)
	return mergeInPlace({}, depth, nil, result, ...)
end

local function mergeTablesWith<K, V>(
	inPlace: boolean?,
	depth: number?,
	resolver: (K, V, V) -> any,
	src: table<K, V>,
	...: table<K, V>
): table<K, V>
	if STRICT_MODE then
		checkArgs("inPlace", "boolean", inPlace, true)
		checkArgs("depth", "number", depth, true)
		checkArgs("resolver", "function", resolver)
		checkArgs("src", "table", src)
	end

	depth = depth or -1 -- Default depth is -1, meaning no limit on recursion depth.
	if depth == -1 then
		depth = math.huge
	end -- Convert -1 to a very large number for practical purposes.

	local result: table = inPlace and src or deepCopy(src)
	return mergeInPlace({}, depth, resolver, result, ...)
end

local function accumulateInPlace(valueMap: table, result: table, ...: table): table
	for i = 1, select("#", ...) do
		local tbl = select(i, ...)
		-- If this table has already been accumulated, skip it to avoid infinite recursion.
		if valueMap[tbl] then
			continue
		end
		valueMap[tbl] = true

		for k, v in tbl do
			local existingValue = result[k]
			local valueType = type(v)
			if existingValue == nil then
				-- If the key does not exist in the result, simply add it.
				if valueType == "table" or CHECK_BUFFER_VALUE and valueType == "buffer" then
					result[k] = deepCopy(v)
				else
					result[k] = v
				end
				continue
			end

			local existingType = type(existingValue)

			if existingType ~= valueType then
				-- If types are different, throw an error.
				error(
					string.format(
						"Cannot accumulate key '%s': conflicting types (%s vs %s)",
						tostring(k),
						existingType,
						valueType
					)
				)
			end

			if existingType == "number" then
				-- If both values are numbers, sum them.
				result[k] = existingValue + v
			elseif existingType == "table" then
				result[k] = accumulateInPlace(valueMap, existingValue :: any, v)
			end
		end
	end

	return result
end

local function accumulateTables<K, V>(inPlace: boolean?, src: table, ...: table<K, V>): table<K, V>
	if STRICT_MODE then
		checkArgs("inPlace", "boolean", inPlace, true)
		checkArgs("src", "table", src)
	end

	local result: table = inPlace and src or deepCopy(src)
	return accumulateInPlace({}, result, ...)
end

local function diffTables<kA, vA, kB, vB>(old: table<kA, vA>, new: table<kB, vB>)
	if STRICT_MODE then
		checkArgs("old", "table", old)
		checkArgs("new", "table", new)
	end

	local added: table<kB, vB> = {}
	local removed: table<kA, vA> = {}
	local changed: table<kA, vA> = {}

	-- Find added and changed keys.
	for k, v in new :: table do
		local oldValue = old[k]
		if oldValue == nil then
			added[k] = v
		elseif oldValue ~= v then
			changed[k] = v
		end
	end

	-- Find removed keys.
	for k in old do
		if new[k] == nil then
			removed[k] = old[k]
		end
	end

	return { added = added, removed = removed, changed = changed }
end

local function syncTable<kS, vS, kT, vT>(src: table<kS, vS>, target: table<kT, vT>): table<kT, vT>
	if STRICT_MODE then
		checkArgs("src", "table", src)
		checkArgs("target", "table", target)
	end

	for k, v in src do
		local valueType = type(v)
		local targetValue: any = target[k]

		-- If the key exists in the source but not in the target, add it.
		if targetValue == nil then
			if valueType == "table" or CHECK_BUFFER_VALUE and valueType == "buffer" then
				-- If the source value is a table, recursively copy it.
				target[k] = deepCopy(v)
			else
				-- If the source value is not a table, copy it directly.
				target[k] = v
			end
			continue
		end

		if valueType ~= "table" then
			continue
		end
		local targetType = type(targetValue)

		if targetType ~= "table" then
			-- If the target value is not a table, replace it with the source value.
			target[k] = deepCopy(v)
			continue
		end

		-- If both values are tables, recursively sync them.
		target[k] = syncTable(v :: table<kS, vS>, targetValue :: table<kT, vT>)
	end

	for k in target do
		-- If the key exists in the target but not in the source, remove it.
		if src[k] == nil then
			target[k] = nil
		end
	end

	return target
end

local function mapTable<K, V, U>(tbl: table<K, V>, callback: (K, V) -> U): table<K, U>
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("callback", "function", callback)
	end

	local result: table<K, U> = table.clone(tbl) -- Create a shallow copy of the original table to pre-allocate.

	-- Iterate through each key-value pair in the original table.
	for k, v in tbl do
		-- Apply the callback function to each key-value pair and store the result.
		result[k] = callback(k, v)
	end

	return result
end

local function filterTable<K, V, U>(tbl: table<K | U, V>, predicate: (K | U, V) -> boolean, preAllocate: boolean?): table<U, V>
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("predicate", "function", predicate)
		checkArgs("preAllocate", "boolean", preAllocate, true)
	end

	if preAllocate ~= false then
		-- Create a shallow copy of the original table to pre-allocate.
		local result: table<U, V> = table.clone(tbl)

		-- Iterate through each key-value pair in the original table.
		for k, v in tbl do
			-- If the predicate returns true for this key-value pair, add it to the result.
			if not (predicate(k, v) :: boolean) then
				result[k] = nil
			end
		end

		return result
	else
		local result = {}
		-- Iterate through each key-value pair in the original table.
		for k, v in tbl do
			-- If the predicate returns true for this key-value pair, add it to the result.
			if predicate(k, v) then
				result[k] = v
			end
		end

		return result
	end
end

local function reduceTable<K, V, U>(tbl: table<K, V>, reducer: (U, K, V) -> U, initial: U): U
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("reducer", "function", reducer)
		-- checkArgs("initial", "any", initial)
	end

	local accumulator = initial
	-- Iterate through each key-value pair in the table.
	for k, v in tbl do
		-- Apply the reducer function to the current accumulated value, key, and value.
		accumulator = reducer(accumulator, k, v)
	end

	return accumulator
end

local function groupTableBy<K, V, G>(tbl: table<K, V>, callback: (K, V) -> G): table<G, array<V>>
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("callback", "function", callback)
	end

	local result: table<G, array<V>> = {}

	-- Iterate through each key-value pair in the table.
	for k, v in tbl :: table do
		-- Get the grouping key using the callback function.
		local groupKey = callback(k, v)
		if groupKey == nil then
			error("Group key cannot be nil", 2)
		end

		local groupTable = result[groupKey :: G]

		-- If the group does not exist yet, create it.
		if not groupTable then
			groupTable = {}
			result[groupKey] = groupTable
		end

		-- Add the value to the corresponding group.
		table.insert(groupTable, v)
	end

	return result
end

local function tableToPairs<K, V>(tbl: table<K, V>): array<{ K | V }>
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end

	local result: array<{ K | V }> = {}

	-- Iterate through each key-value pair in the table.
	for k, v in tbl do
		table.insert(result, { k, v })
	end

	return result
end

local function invertTable<K, V>(tbl: table<K, V>): table<V, K>
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end

	local result: table<V, K> = {}

	-- Iterate through each key-value pair in the table.
	for k, v in tbl do
		result[v] = k -- Set the value as the key and the key as the value.
	end

	return result
end

local function tableIntersection<K, V>(tbl1: table<K, V>, tbl2: table<K, V>, matchValue: boolean?): table<K, V>
	if STRICT_MODE then
		checkArgs("tbl1", "table", tbl1)
		checkArgs("tbl2", "table", tbl2)
	end

	local result: table<K, V> = {}

	-- Iterate through each key-value pair in the first table.
	if matchValue then
		for k, v in tbl1 :: table do
			if tbl2[k] == v then
				result[k] = v -- If the key exists in both tables, add it to the result.
			end
		end
	else
		for k, v in tbl1 do
			if tbl2[k] ~= nil then
				result[k] = v -- If the key exists in both tables, add it to the result.
			end
		end
	end

	return result
end

local function tableDifference<K, V>(
	tbl1: table<K, V>,
	tbl2: table<K, V>,
	matchValue: boolean?,
	symmetric: boolean?
): table<K, V>
	if STRICT_MODE then
		checkArgs("tbl1", "table", tbl1)
		checkArgs("tbl2", "table", tbl2)
		checkArgs("matchValue", "boolean", matchValue, true)
		checkArgs("symmetric", "boolean", symmetric, true)

		if matchValue and symmetric then
			error("Cannot use both 'matchValue' and 'symmetric' options together", 2)
		end
	end

	local result: table<K, V> = {}
	if matchValue then
		for k, v in tbl1 :: table do
			if tbl2[k] ~= nil and tbl2[k] ~= v then
				result[k] = v -- If the key exists in both tables but values differ, add it to the result.
			end
		end
	elseif symmetric then
		for k, v in tbl1 do
			if tbl2[k] == nil then
				result[k] = v -- If the key does not exist in the second table, add it to the result.
			end
		end
		for k, v in tbl2 do
			if tbl1[k] == nil then
				result[k] = v -- If the key does not exist in the first table, add it to the result.
			end
		end
	else
		for k, v in tbl1 do
			if tbl2[k] == nil then
				result[k] = v -- If the key does not exist in the second table, add it to the result.
			end
		end
	end

	return result
end

local function removeAll<K, V, T>(tbl: table<K, V>, value: T | array<T>): ()
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		-- checkArgs("value", "any", value)
	end

	-- If 'value' is a table, convert it to a set for faster lookups.
	if type(value) == "table" then
		local valueSet: table<T, boolean> = {}
		for _, v in value do
			valueSet[v] = true
		end

		for k, v in tbl do
			if valueSet[v] then
				tbl[k] = nil -- If the value is in the set, remove it from the table.
			end
		end
	else
		for k, v in tbl :: table do
			if v == value then
				tbl[k] = nil -- If the value matches, remove it from the table.
			end
		end
	end
end

--[=[
==============================
 3. Array Manipulation
==============================
]=]

local function extendArraySize<K, V>(tbl: table<K, V>, expandSize: number)
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("expandSize", "number", expandSize)
	end

	-- `table.move` with the same source and destination effectively extending the array length.
	local size = getAllocatedArraySize(tbl)
	table.move(tbl, size, size + expandSize, size)
end

local function setArraySize<K, V>(tbl: table<K, V>, newSize: number)
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("newSize", "number", newSize)
	end

	-- `table.move` with the same source and destination effectively extending the array length.
	table.move(tbl, 1, newSize, 1)
end

local function truncateArray<T>(array: array<T>, newSize: number): array<T>
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("newSize", "number", newSize)
	end

	local length = #array
	if newSize >= length then
		return table.clone(array)
	end

	local result: array<T> = table.create(newSize)
	table.move(array, 1, newSize, 1, result)

	return result
end

local function concatArrays<T>(inPlace: boolean?, ...: array<T>): array<T>
	if STRICT_MODE then
		checkArgs("inPlace", "boolean", inPlace, true)
	end

	local argCount = select("#", ...)
	if argCount == 0 then
		return {}
	end
	local totalSize = 0

	-- First, calculate the total size of the resulting array.
	for i = 1, argCount do
		local subArray = select(i, ...)
		if STRICT_MODE then
			checkArgs("arg" .. i, "table", subArray)
		end
		totalSize = totalSize + #subArray -- Add the size of each sub-array.
	end

	local firstArray = (...)

	-- Create the result array with the exact size needed.
	local result: array<T> = inPlace and firstArray or table.create(totalSize)
	local insertIndex = #firstArray + 1

	if inPlace then
		setArraySize(result, totalSize) -- Resize the in-place array to the new size.
	else
		table.move(firstArray, 1, insertIndex - 1, 1, result) -- Copy the first array into the result.
	end

	for i = 2, argCount do
		local subArray = select(i, ...)
		local subSize = #subArray
		if subSize == 0 then
			continue
		end -- Skip empty sub-arrays.

		-- Move the contents of the sub-array into the result array.
		table.move(subArray, 1, subSize, insertIndex, result)
		insertIndex = insertIndex + subSize -- Update the insertion index for the next block.
	end

	return result
end

local function unionArrays<T>(...: array<T>): array<T>
	if STRICT_MODE then
		for i = 1, select("#", ...) do
			checkArgs("arg" .. i, "table", select(i, ...))
		end
	end

	local result: array<T> = {}
	local seen: table<T, boolean> = {}

	for i = 1, select("#", ...) do
		local subArray = select(i, ...)
		for _, value in subArray do
			if not seen[value] then
				seen[value] = true -- Mark this value as seen.
				table.insert(result, value) -- Add it to the result array.
			end
		end
	end

	return result
end

local function flattenArray<T, U>(src: array<T>, depth: number?)
	if STRICT_MODE then
		checkArgs("src", "table", src)
		checkArgs("depth", "number", depth, true)
	end

	depth = depth or -1 -- Default depth is -1, meaning no limit on recursion depth.

	if depth == 1 then
		local totalSize = 0
		for _, subArray in src do
			totalSize = totalSize + (type(subArray) == "table" and #(subArray :: array) or 1)
		end

		local result: array<U> = table.create(totalSize)
		local insertIndex = 1

		for _, subArray in src do
			if type(subArray) == "table" then
				local subSize = #(subArray :: array)
				if subSize == 0 then
					continue
				end -- Skip empty sub-arrays.
				table.move(subArray, 1, subSize, insertIndex, result)
				insertIndex = insertIndex + subSize
			else
				result[insertIndex] = subArray
				insertIndex = insertIndex + 1
			end
		end

		return result
	else
		local result: array<U> = src

		if depth == -1 then
			-- If depth is -1, flatten the array completely.
			depth = math.huge
		end

		for i = 1, depth do
			src, result = result, {}

			local hasSubArrays = false
			local insertIndex = 1

			for _, subArray in src do
				if type(subArray) == "table" then
					local subSize = #(subArray :: array)
					if subSize == 0 then
						continue
					end -- Skip empty sub-arrays.
					table.move(subArray, 1, subSize, insertIndex, result)
					insertIndex = insertIndex + subSize
					hasSubArrays = true
				else
					result[insertIndex] = subArray
					insertIndex = insertIndex + 1
				end
			end
			if not hasSubArrays then
				break
			end
		end

		return result
	end
end

local function compactArray<T>(array: array<T>, allocateExactSize: boolean?, isArray: boolean?)
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("allocateExactSize", "boolean", allocateExactSize, true)
		checkArgs("isArray", "boolean", isArray, true)
	end

	-- Find the last numerical index in the contiguous part of the array starting from 1.
	local lastIndex: number
	for i, _ in ipairs(array) do
		lastIndex = i
	end

	-- Check if array is already compact (no extra entries past the contiguous block).
	local startIndex = next(array, lastIndex)
	if not startIndex then -- The array is already compact.
		if allocateExactSize then
			-- Return a newly sized array with only the contiguous elements.
			if lastIndex then
				local newArray = table.create(lastIndex)
				table.move(array, 1, lastIndex, 1, newArray)
				return newArray
			else
				-- The array was empty.
				return {}
			end
		else
			-- Return original array (already compact).
			return array
		end
	end

	local result: array<T>
	if allocateExactSize then
		-- Count all elements to allocate a properly sized array
		local size = lastIndex or 0
		for _ in next, array, lastIndex do
			size += 1
		end
		result = table.create(size)
	else
		-- Clone and clear the array to avoid counting elements.
		result = table.clone(array)
		table.clear(result)
	end

	-- Copy initial contiguous values.
	if lastIndex then
		table.move(array, 1, lastIndex, 1, result)
	end

	local resultIndex = (lastIndex or 0) + 1
	if isArray then
		local nextIndex = startIndex + 1
		-- Iterate through the rest of the elements in the sparse part of the array.
		-- `next` guarantees traversal in index order for the array part.
		for i, v in next, array, startIndex do
			if i ~= nextIndex then
				-- A gap in indices is found. Move the previous block of elements.
				table.move(array, startIndex, nextIndex - 1, resultIndex, result)
				resultIndex += (nextIndex - startIndex)
				startIndex = i
			end
			-- The next expected index in the current block.
			nextIndex = i + 1
		end

		-- Move the final block of elements.
		table.move(array, startIndex, nextIndex - 1, resultIndex, result)
	else
		local chunks: { [number]: number } = {} -- Maps an index to the other end of its chunk.

		-- 1. Find and merge chunks in a single pass.
		for i in next, array, lastIndex do
			local connectsToPrev = chunks[i - 1]
			local connectsToNext = chunks[i + 1]

			if connectsToPrev then
				-- This index bridges two existing chunks. Merge them.
				if connectsToNext then
					local start = connectsToPrev
					local end_ = connectsToNext
					chunks[start] = end_
					chunks[end_] = start
					if start ~= i - 1 then
						chunks[i - 1] = nil
					end
					if end_ ~= i + 1 then
						chunks[i + 1] = i
					end
				else -- Extend the previous chunk forward.
					local start = connectsToPrev
					chunks[start] = i
					if start ~= i - 1 then
						chunks[i - 1] = nil
					end
					chunks[i] = start
				end
			elseif connectsToNext then
				-- Extend the next chunk backward.
				local end_ = connectsToNext
				chunks[end_] = i
				if end_ ~= i + 1 then
					chunks[i + 1] = nil
				end
				chunks[i] = end_
			else
				-- This is a new, standalone chunk of size 1.
				chunks[i] = i
			end
		end

		-- 2. Collect the start points of each chunk for ordered copying.
		local startPoints = {}
		for start, end_ in next, chunks do
			-- To avoid duplication, only add the actual start point of each chunk.
			if start <= end_ then
				table.insert(startPoints, start)
			end
		end
		table.sort(startPoints) -- This sort is on a much smaller list (just the chunks).

		-- 3. Use table.move to efficiently copy the data from the identified chunks.
		for _, startIdx in startPoints do
			local endIdx = chunks[startIdx]
			local chunkSize = endIdx - startIdx + 1
			table.move(array, startIdx, endIdx, resultIndex, result)
			resultIndex = resultIndex + chunkSize
		end
	end

	return result
end

local function fillWithValue<T>(array: array<T>, value: T, startIndex: number?, endIndex: number?, sourceArray: array<T>?)
	if STRICT_MODE then
		checkArgs("array", "table", array)
		-- checkArgs("value", "any", value)
		checkArgs("startIndex", "number", startIndex, true)
		checkArgs("endIndex", "number", endIndex, true)
		checkArgs("sourceArray", "table", sourceArray, true)
	end

	local from = startIndex or 1
	local to = endIndex or #array
	local fillSize = to - from + 1

	if fillSize <= 0 then
		return
	end -- No need to fill if the range is invalid.

	if fillSize < MOVE_THRESHOLD then
		-- If the fill size is small, fill with the specified value.
		for i = from, to do
			array[i] = value
		end
	else
		if fillSize > FILL_THRESHOLD then
			sourceArray = sourceArray or table.create(math.min(fillSize, DEFAULT_FILL_ARRAY_SIZE), value)
		end

		if sourceArray then
			-- Fill from the source array, repeating it if necessary.
			local fillArraySize = #sourceArray

			if fillSize <= fillArraySize then
				table.move(sourceArray, 1, fillSize, from, array)
			else
				local lastIndex = fillSize // fillArraySize - 1

				for i = 0, lastIndex do
					table.move(sourceArray, 1, fillArraySize, from + i * fillArraySize, array)
				end

				table.move(sourceArray, 1, fillSize % fillArraySize, from + (lastIndex + 1) * fillArraySize, array)
			end
		else
			-- If the fill size is small, fill with the specified value.
			for i = from, to do
				array[i] = value
			end
		end
	end
end

local function fillWithPattern<T>(array: array<T>, pattern: array<T>, startIndex: number?, endIndex: number?)
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("pattern", "table", pattern)
		checkArgs("startIndex", "number", startIndex, true)
		checkArgs("endIndex", "number", endIndex, true)
	end

	local patternSize = #pattern
	if patternSize == 0 then
		error("Pattern array cannot be empty", 2)
	end

	local from = startIndex or 1
	local to = endIndex or #array
	local fillSize = to - from + 1
	if fillSize <= 0 then
		return
	end -- No need to fill if the range is invalid.

	if fillSize <= patternSize then
		table.move(pattern, 1, fillSize, from, array)
	else
		local lastIndex = fillSize // patternSize - 1

		for i = 0, lastIndex do
			table.move(pattern, 1, patternSize, from + i * patternSize, array)
		end

		table.move(pattern, 1, fillSize % patternSize, from + (lastIndex + 1) * patternSize, array)
	end
end

local function reverseArray<T>(array: array<T>)
	if STRICT_MODE then
		checkArgs("array", "table", array)
	end

	local size = #array
	if size <= 1 then
		return
	end -- No need to reverse if the array is empty or has one element.

	-- Use a loop to swap elements from both ends towards the center.
	for i = 1, size // 2 do
		local j = size - i + 1
		array[i], array[j] = array[j], array[i]
	end
end

local function rotateArray<T>(array: array<T>, shift: number)
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("shift", "number", shift)
	end

	local size = #array
	if size <= 1 or shift == 0 then
		return
	end -- No need to rotate if the array is empty, has one element, or no shift.

	shift = shift % size -- Normalize the shift to be within the bounds of the array size.
	if shift < 0 then
		shift = size + shift -- Convert negative shifts to positive equivalent.
	end

	-- Use table.move to perform the rotation efficiently.
	local temp = table.create(shift)
	table.move(array, size - shift + 1, size, 1, temp) -- Store the last 'shift' elements in a temporary array.
	table.move(array, 1, size - shift, shift + 1, array) -- Move the first elements to the right.
	table.move(temp, 1, shift, 1, array) -- Move the temporary elements to the beginning of the array.
end

local function sliceArray<T>(array: array<T>, startIndex: number?, endIndex: number?): array<T>
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("startIndex", "number", startIndex, true)
		checkArgs("endIndex", "number", endIndex, true)
	end

	local from = startIndex or 1
	local to = endIndex or #array

	local len = #array
	if len == 0 then
		return {}
	end

	-- Handle negative indices by wrapping them around from the end of the array.
	if from < 0 then
		from = len + from + 1
	end
	if to < 0 then
		to = len + to + 1
	end

	if from > to then
		return {}
	end -- If the range is invalid, return an empty array.

	-- Create a new array and copy the specified range.
	local result: array<T> = table.create(to - from + 1)
	table.move(array, from, to, 1, result)

	return result
end

local function shuffleArray<T>(array: array<T>)
	if STRICT_MODE then
		checkArgs("array", "table", array)
	end

	local size = #array
	if size <= 1 then
		return
	end -- No need to shuffle if the array is empty or has one element.

	-- Use the Fisher-Yates shuffle algorithm to randomly swap elements.
	for i = size, 2, -1 do
		local j = math.random(1, i) -- Get a random index from 1 to i.
		array[i], array[j] = array[j], array[i] -- Swap elements at indices i and j.
	end
end

local function sampleArray<T>(array: array<T>, sampleSize: number, allowDuplicates: boolean?): array<T>
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("sampleSize", "number", sampleSize)
		checkArgs("allowDuplicates", "boolean", allowDuplicates, true)
	end

	local size = #array
	if size == 0 or sampleSize <= 0 then
		return {}
	end -- Return empty if the array is empty or sample size is invalid.

	local result: array<T> = table.create(sampleSize)

	if allowDuplicates then
		-- If duplicates are allowed, randomly select elements from the array.
		for i = 1, sampleSize do
			local index = math.random(1, size) -- Get a random index from 1 to size.
			result[i] = array[index] -- Add the randomly selected element to the result.
		end
	else
		sampleSize = math.min(sampleSize, size)

		-- Use a hash map to avoid mutating the original array
		local map = {}

		-- Partial Fisher–Yates Shuffle
		for i = 1, sampleSize do
			-- Generate a random index from i to size
			local j = math.random(i, size)
			local valJ = map[j] or (array :: array)[j]
			local valI = map[i] or (array :: array)[i]

			map[i], map[j] = valJ, valI
			result[i] = map[i]
		end
	end

	return result
end

local function sampleValue<T>(array: array<T>, startIndex: number?, endIndex: number?): T?
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("startIndex", "number", startIndex, true)
		checkArgs("endIndex", "number", endIndex, true)
	end

	local size = #array
	if size == 0 then
		return nil
	end -- Return nil if the array is empty.

	local from = startIndex or 1
	local to = endIndex or size

	-- Handle negative indices by wrapping them around from the end of the array.
	if from < 0 then
		from = size + from + 1
	end
	if to < 0 then
		to = size + to + 1
	end

	if from > to or from < 1 or to > size then
		return nil
	end -- If the range is invalid, return nil.

	-- Randomly select an index within the specified range.
	local index = math.random(from, to)
	return array[index] -- Return the value at the randomly selected index.
end

local function removeDuplicate<T, K>(array: array<T>, by: ((value: T) -> K)?): array<T>
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("by", "function", by, true)
	end

	local seen: table<T | K, boolean> = {}
	local result: array<T> = {}

	-- Iterate through the array and collect unique values.
	for _, value in array do
		local key = if by then by(value) else value
		if seen[key] then
			continue
		end -- Skip if the value has already been seen.
		seen[key] = true
		table.insert(result, value)
	end

	return result
end

local function swapRemove<T>(array: array<T>, index: number)
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("index", "number", index)
	end

	local lastIndex = #array
	if index ~= lastIndex then
		array[index] = array[lastIndex]
	end
	array[lastIndex] = nil
end

local function getAndRemove<T>(array: array<T>, index: number, swap: boolean?): T?
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("index", "number", index)
		checkArgs("swap", "boolean", swap, true)
	end

	local value = array[index]
	if value == nil then
		return nil
	end

	if swap then
		local lastIndex = #array
		array[index] = array[lastIndex] -- Swap the element with the last one.
		array[lastIndex] = nil -- Remove the last element.
	else
		table.remove(array, index) -- Remove the element at the specified index.
	end

	return value -- Return the removed value.
end

local function findAndRemove<T>(array: array<T>, value: T, swap: boolean?): boolean
	if STRICT_MODE then
		checkArgs("array", "table", array)
		-- checkArgs("value", "any", value)
		checkArgs("swap", "boolean", swap, true)
	end

	local size = #array
	if size == 0 then
		return false
	end -- Return false if the array is empty.

	-- Iterate through the array to find the value.
	for i, v in array :: array do
		if v ~= value :: any then
			continue
		end
		if swap then
			array[i] = array[size]
			array[size] = nil
		else
			table.remove(array, i)
		end
		return true -- Return true if the value was found and removed.
	end

	return false -- Return false if the value was not found in the array.
end

local function zipArray(...)
	local nArrays = select("#", ...)
	if nArrays == 0 then
		return {}
	end

	local maxLength = math.huge
	for i = 1, nArrays do
		local arr = select(i, ...)
		if STRICT_MODE then
			checkArgs("arg" .. i, "table", arr)
		end
		maxLength = math.min(maxLength, #arr)
	end

	-- Create a new array to hold the zipped result.
	local result = table.create(maxLength) :: array<array>

	-- Fill the result array with sub-arrays.
	for i = 1, maxLength do
		local subArray: array = table.create(nArrays)
		for j = 1, nArrays do
			local arr = select(j, ...)
			subArray[j] = arr[i]
		end
		result[i] = subArray
	end

	return result
end

local function unzipArray(zippedArray: array<array>)
	if STRICT_MODE then
		checkArgs("zippedArray", "table", zippedArray)
	end

	local size = #zippedArray
	if size == 0 then
		return {}
	end

	local nArrays = #zippedArray[1]
	local result = table.create(nArrays) :: array<array>

	-- Fill each sub-array with the corresponding elements from the zipped array.
	for i = 1, nArrays do
		local array = table.create(size) :: array
		for j, subArray in zippedArray do
			if STRICT_MODE then
				checkArgs("subArray" .. j, "table", subArray)
			end

			array[j] = subArray[i]
		end
		result[i] = array
	end

	return result
end

local function partitionArray<T>(array: array<T>, size: number): array<array<T>>
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("size", "number", size)
	end

	if size <= 0 then
		error("Partition size must be greater than 0", 2)
	end

	local arraySize = #array
	if arraySize == 0 then
		return {}
	end -- Return empty if the array is empty.

	local resultSize = math.ceil(arraySize / size)
	local result: array<array<T>> = table.create(resultSize) :: array<array<T>>
	for i = 1, arraySize - size, size do
		local partition: array<T> = table.create(size)
		table.move(array, i, i + size - 1, 1, partition)
		result[math.ceil(i / size)] = partition
	end

	do
		local remainingSize = (arraySize - 1) % size + 1
		local partition: array<T> = table.create(remainingSize)
		table.move(array, arraySize - remainingSize + 1, arraySize, 1, partition)
		result[resultSize] = partition -- Add the last partition with remaining elements.
	end

	return result
end

local function partitionArrayBy<T, A, B>(array: array<T>, predicate: (T) -> boolean): (array<A>, array<B>)
	if STRICT_MODE then
		checkArgs("array", "table", array)
		checkArgs("predicate", "function", predicate)
	end

	local truePartition: array<A> = {}
	local falsePartition: array<B> = {}

	-- Iterate through the array and partition elements based on the predicate.
	for _, value in array do
		if predicate(value) then
			table.insert(truePartition, value :: A) -- Add to true partition.
		else
			table.insert(falsePartition, value :: B) -- Add to false partition.
		end
	end

	return truePartition, falsePartition
end

local function binarySearch<K>(array: array<K>, value: K, comparator: ((K, K) -> number)?): number?
	if STRICT_MODE then
		checkArgs("array", "table", array)
		-- checkArgs("value", "any", value)
		checkArgs("comparator", "function", comparator, true)
	end

	local low = 1
	local high = #array

	while low <= high do
		local mid = (low + high) // 2
		local midValue: any = array[mid]

		local cmpResult: number
		if comparator then
			cmpResult = comparator(midValue, value)
		else
			cmpResult = (midValue == (value :: any)) and 0 or (midValue < (value :: any) and -1 or 1)
		end

		if cmpResult == 0 then
			return mid -- Value found at index mid.
		elseif cmpResult < 0 then
			low = mid + 1 -- Search in the right half.
		else
			high = mid - 1 -- Search in the left half.
		end
	end

	return nil -- Value not found.
end

--[=[
==============================
 4. Inspection & Metadata
==============================
]=]

local function getKeys<K, V>(tbl: table<K, V>): array<K>
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end
	-- Pre-allocate for the array portion of the table. Will still be resized if hash part is present.
	local keys: array<K> = table.create(#tbl)

	-- Iterate through each key-value pair in the table.
	for k in tbl do
		table.insert(keys, k) -- Add each key to the keys array.
	end

	return keys
end

local function getValues<K, V>(tbl: table<K, V>): array<V>
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end

	-- Pre-allocate for the array portion of the table. Will still be resized if hash part is present.
	local values: array<V> = table.create(#tbl)

	-- Iterate through each key-value pair in the table.
	for _, v in tbl do
		table.insert(values, v) -- Add each value to the values array.
	end

	return values
end

local function isContiguousArray<K, V>(tbl: table<K, V>): boolean
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end

	local length = #tbl

	-- An empty array is contiguous only if it has no non-numeric keys.
	if length == 0 then
		return next(tbl) == nil
	end
	-- If there's an element right after the '#' length, it's not contiguous.
	if next(tbl, length) ~= nil then
		return false
	end

	local lastIndex: number

	-- `ipairs` stops at the first nil value.
	for i, _ in ipairs(tbl) do
		lastIndex = i + 0
	end

	-- If the last index found by ipairs matches the length, the array is contiguous.
	return lastIndex == length
end

local function isSparseArray<K, V>(tbl: table<K, V>): boolean
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end

	local nextIndex, exitIndex = 1, nil

	for i, _ in next, tbl :: table do
		if i ~= nextIndex then
			exitIndex = i
			break
		end
		nextIndex = i + 1
	end

	if type(exitIndex) ~= "number" then
		return false
	end
	if exitIndex // 1 ~= exitIndex or exitIndex < 1 then
		return false -- Not an array
	end

	for i, _ in next, tbl :: table, exitIndex do
		if type(i) ~= "number" or i // 1 ~= i or i < 1 then
			return false -- Not an array
		end
	end

	return true
end

local function isArray<K, V>(tbl: table<K, V>): boolean
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end

	for i: number in tbl do
		if type(i) ~= "number" or (i :: number) // 1 ~= (i :: number) or (i :: number) < 1 then
			return false -- Not an array
		end
	end

	return true
end

local function isEmpty<K, V>(tbl: table<K, V>): boolean
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end

	-- Check if the table is empty by checking if it has any keys.
	return next(tbl) == nil
end

local function hasKey<K, V>(tbl: table<K, V>, key: K): boolean
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		-- checkArgs("key", "any", key)
	end

	-- Check if the key exists in the table.
	return tbl[key] ~= nil
end

local function hasValue<K, V>(tbl: table<K, V>, value: V): boolean
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		-- checkArgs("value", "any", value)
	end

	-- Iterate through the table to check if the value exists.
	for _, v: any in tbl do
		if v :: any == value :: any then
			return true -- Return true if the value is found.
		end
	end

	return false -- Return false if the value is not found.
end

local function countOccurences<K, V>(tbl: table<K, V>, value: V): number
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		-- checkArgs("value", "any", value)
	end

	local count = 0

	-- Iterate through the table to count occurrences of the value.
	for _, v in tbl do
		if v :: any == value :: any then
			count += 1 -- Increment the count if the value matches.
		end
	end

	return count -- Return the total count of occurrences.
end

local function countKeysByType<K, V>(tbl: table<K, V>, keyType: string): number
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("keyType", "string", keyType)
	end

	local count = 0
	for k in tbl do
		if typeof(k) == keyType then
			count = count + 1
		end
	end
	return count
end

local function countValuesByType<K, V>(tbl: table<K, V>, valueType: string): number
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("valueType", "string", valueType)
	end

	local count = 0
	for _, v in tbl do
		if typeof(v) == valueType then
			count = count + 1
		end
	end
	return count
end

local function keysOfValue<K, V>(tbl: table<K, V>, value: V): array<K>
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		-- checkArgs("value", "any", value)
	end

	local keys: array<K> = {}

	-- Iterate through the table to find keys with the specified value.
	for k, v in tbl do
		if v :: any == value :: any then
			table.insert(keys, k) -- Add the key to the keys array if the value matches.
		end
	end

	return keys -- Return the array of keys with the specified value.
end

--[=[
==============================
 5. Functional Utilities
==============================
]=]

function deepCopy<K, V>(tbl: table<K, V>, valueMap: table?): table<K, V>
	if type(tbl) == "buffer" then
		local bufferLen = buffer.len(tbl)
		local newBuffer = buffer.create(bufferLen)
		buffer.copy(tbl, 0, newBuffer)

		if valueMap then
			valueMap[tbl] = newBuffer
		end
		return newBuffer :: any
	end

	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end

	-- Create a shallow copy first, which pre-allocate and copies top-level keys and values.
	local copy: table = table.clone(tbl)
	if valueMap then
		valueMap[tbl] = copy
	else
		valueMap = { [tbl] = copy }
	end

	assert(valueMap) -- Type Reinforcement.

	-- Use a constant to avoid loading a string in every iteration.
	local TABLE_TYPE = "table"
	TABLE_TYPE = TABLE_TYPE -- Prevent folding.

	local BUFFER_TYPE = CHECK_BUFFER_VALUE and "buffer"
	BUFFER_TYPE = BUFFER_TYPE -- Prevent folding.

	-- Iterate through the table to handle nested tables.
	for k, v in tbl :: table do
		local keyType = type(k)
		local valueType = type(v)

		local shouldCloneKey = keyType == TABLE_TYPE or (CHECK_BUFFER_VALUE and keyType == BUFFER_TYPE)
		local shouldCloneValue = valueType == TABLE_TYPE or (CHECK_BUFFER_VALUE and valueType == BUFFER_TYPE)

		if shouldCloneKey then
			copy[k] = nil
			k = valueMap[k] or deepCopy(k :: K, valueMap :: table)
			copy[k] = if shouldCloneValue then valueMap[v] or deepCopy(v, valueMap :: table) else v
		elseif shouldCloneValue then
			copy[k] = valueMap[v] or deepCopy(v, valueMap :: table)
		end
	end

	return copy :: table<K, V>
end

local function deepEqual<A, B>(a: any, b: any, visited: table?): boolean
	if STRICT_MODE then
		-- checkArgs("a", "any", a)
		-- checkArgs("b", "any", b)
	end

	-- If they are physically the same or simple equal primitives, they are equal.
	if a == b then
		return true
	end

	local typeA = type(a)
	local typeB = type(b)

	-- If types are different, they can't be equal.
	if typeA ~= typeB then
		return false
	end

	if CHECK_BUFFER_VALUE and typeA == "buffer" then
		-- For buffers, compare their lengths first.
		local lenA, lenB = buffer.len(a), buffer.len(b)
		if lenA ~= lenB then
			return false
		end

		if visited then
			local visitedA = visited[a] :: table

			if visitedA then
				if visitedA[b] then
					-- If both buffers were already compared, they are equal.
					return true
				end
				visitedA[b] = true
			else
				visitedA = {
					[b] = true,
				}
				visited[a] = visitedA
			end
		end

		-- Compare the buffer contents as strings.
		-- Partial substring comparsion can be used if buffer are unlikely to be equal.
		return buffer.readstring(a, 0, lenA) == buffer.readstring(b, 0, lenB)
	end

	if typeA == "number" and a ~= a then
		-- Special case for NaN, which is not equal to itself.
		return b ~= b
	end

	-- If types are not 'table' and they failed the initial 'a == b' check, they are not equal.
	if typeA ~= "table" then
		return false
	end

	-- Check for previously compared pair to handle cycles
	if visited then
		local visitedA = visited[a] :: table
		if visitedA and visitedA[b] then
			return true
		end
	end

	-- Check if all keys in 'a' also exist in 'b'.
	for k in a do
		if b[k] == nil then
			return false
		end
	end

	visited = visited or {}
	local visitedA = visited[a]
	if visitedA then
		(visitedA :: table)[b] = true
	else
		visitedA = {
			[b] = true,
		}
		visited[a] = visitedA
	end

	-- Recursively check if values for all keys in 'b' are deeply equal to those in 'a'.
	for k, v in b do
		if not deepEqual(v, a[k], visited) then
			return false
		end
	end

	-- If all checks pass, the tables are deeply equal.
	return true
end

local function deepFreeze<K, V>(tbl: table<K, V>, layers: number?, visited: table?): table<K, V>
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("layers", "number", layers, true)
	end

	if visited and visited[tbl] then
		return tbl
	end

	if layers and layers ~= -1 then
		if layers <= 0 then
			return table.freeze(tbl)
		end
		layers = layers - 1
	else
		layers = math.huge -- If no layers specified, freeze all layers.
	end

	visited = visited or {}
	visited[tbl] = true -- Mark this table as visited to handle cycles.

	local TABLE_TYPE = "table"
	TABLE_TYPE = TABLE_TYPE -- Prevent folding.

	-- Recursively freeze all nested tables first.
	for k, v in tbl do
		if type(k) == TABLE_TYPE then
			deepFreeze(k :: K, layers, visited)
		end
		if type(v) == TABLE_TYPE then
			deepFreeze(v, layers, visited)
		end
	end

	-- Freeze the top-level table after all its contents are frozen.
	return table.freeze(tbl)
end

local function findMatch<K, V>(tbl: table<K, V>, filter: (K, V) -> boolean): K?
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("filter", "function", filter)
	end

	-- Iterate through each key-value pair in the table.
	for k, v in tbl do
		-- If the filter returns true for this key-value pair, return the key.
		if filter(k, v) then
			return k
		end
	end

	return nil -- Return nil if no matching key is found.
end

local function every<K, V>(tbl: table<K, V>, filter: (K, V) -> boolean): boolean
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("filter", "function", filter)
	end

	-- Iterate through each key-value pair in the table.
	for k, v in tbl do
		-- If the filter returns false for any key-value pair, return false.
		if not (filter(k, v) :: boolean) then
			return false
		end
	end

	return true -- Return true if all key-value pairs satisfy the filter.
end

local function some<K, V>(tbl: table<K, V>, filter: (K, V) -> boolean): boolean
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("filter", "function", filter)
	end

	-- Iterate through each key-value pair in the table.
	for k, v in tbl do
		-- If the filter returns true for any key-value pair, return true.
		if filter(k, v) then
			return true
		end
	end

	return false -- Return false if no key-value pair satisfies the filter.
end

local function toSet<K, V>(tbl: table<K, V>): table<K, boolean>
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
	end

	local set: table<K, boolean> = {}

	-- Iterate through each key-value pair in the table.
	for k in tbl do
		set[k] = true -- Add each key to the set with a value of true.
	end

	return set -- Return the resulting set.
end

--[=[
==============================
 6. Conversion & Formatting
==============================
]=]

local function serializeType(value: any, valueType: string): string
	if valueType == "string" then
		return '"' .. string.gsub(value, "[%c%z]", SPECIAL_CHARACTERS) .. '"'
	elseif valueType == "Instance" then
		return ((value :: any):GetFullName())
	else
		return tostring(value)
	end
end

local function prettyPrint<K, V>(tbl: table<K, V>, indent: number?): string
	if STRICT_MODE then
		checkArgs("tbl", "table", tbl)
		checkArgs("indent", "number", indent, true)
	end

	local tab = string.rep(" ", indent or 2) -- Default indentation is 2 spaces.
	local ignoreTable = {}

	local function printTable(tbl: table, depthData: table, path: string): string
		local concatTbl: { string } = {}
		local cyclicData: table = ignoreTable[tbl]
		if cyclicData then
			if cyclicData[1] == depthData[1] - 1 then
				table.insert(concatTbl, "'[Cyclic Parent ")
			else
				table.insert(concatTbl, "'[Cyclic ")
			end

			table.insert(concatTbl, tostring(tbl))
			table.insert(concatTbl, ", path: ")
			table.insert(concatTbl, depthData[2])
			table.insert(concatTbl, "]'")
			return table.concat(concatTbl)
		end

		local depth = depthData[1] + 1
		depthData[1] = depth -- Increment the depth for this table.
		depthData[2] = path

		ignoreTable[tbl] = depthData

		if next(tbl) == nil then
			-- table.insert(concatTbl, "{}")
			return "{}"
		end

		local padding = string.rep(tab, depth)
		local trailing = string.rep(tab, depth - 1)
		local lineTab = "\n" .. padding
		local isOrdered = true
		local nextIndex = 1

		for key, value in next, tbl do
			if isOrdered then
				if key == nextIndex then
					nextIndex += 1
				else
					isOrdered = false
				end
			end

			if isOrdered then
				local valueType = typeof(value)
				if valueType == "table" then
					value = printTable(value, table.clone(depthData), path .. "[" .. key .. "]")
				else
					value = serializeType(value, valueType)
				end
			else
				local keyType = typeof(key)
				local hasBrackets = false

				if keyType == "string" then
					key = string.gsub(key :: any, "[%c%z]", SPECIAL_CHARACTERS)
					if LUAU_KEYWORDS[key] or not string.match(key, "^[_%a][_%w]*$") then
						hasBrackets = true
						key = string.format('["%s"]', key)
					end
				else
					hasBrackets = true
					if keyType == "table" then
						key = "["
							.. string.gsub(printTable(key :: any, table.clone(depthData)), "^%s*(.-)%s*$", "%1")
							.. "]"
					else
						key = "[" .. serializeType(key, keyType) .. "]"
					end
				end

				local valueType = typeof(value)
				if valueType == "table" then
					value = printTable(value, table.clone(depthData), path .. (hasBrackets and "" or ".") .. key)
				else
					value = serializeType(value, valueType)
				end
			end

			table.insert(concatTbl, lineTab)
			if isOrdered then
				table.insert(concatTbl, value)
			else
				table.insert(concatTbl, key :: any)
				table.insert(concatTbl, " = ")
				table.insert(concatTbl, value)
			end
			table.insert(concatTbl, ",")
		end

		table.remove(concatTbl)
		table.insert(concatTbl, "\n")
		table.insert(concatTbl, trailing)
		table.insert(concatTbl, "}")

		return table.concat(concatTbl)
	end

	return printTable(tbl, { 0, "ROOT" } :: any, "ROOT")
end

local function toCSV<T>(rows: array<array<T>>, delimiter: string?): string
	if STRICT_MODE then
		checkArgs("rows", "table", rows)
		checkArgs("delimiter", "string", delimiter, true)
	end

	delimiter = delimiter or ","
	local csvLines = table.create(#rows) :: { string }

	for _, row in rows do
		local csvRow: { string } = {}
		for _, value in row do
			local valueType = typeof(value)
			if valueType == "string" then
				value = '"' .. string.gsub(value, '"', '""') .. '"'
			elseif valueType == "number" or valueType == "boolean" then
				value = tostring(value)
			else
				value = '"' .. tostring(value) .. '"'
			end
			table.insert(csvRow, value)
		end
		table.insert(csvLines, table.concat(csvRow, delimiter))
	end

	return table.concat(csvLines, "\n")
end

--// Return \\--

local Library = {

	--[=[
	==============================
	 1. Memory & Size Utilities
	==============================
	]=]

	getAllocatedArraySize = getAllocatedArraySize,
	getAllocatedHashSize = getAllocatedHashSize,
	getTableMemorySize = getTableMemorySize,
	getTableSize = getTableSize,

	--[=[
	==============================
	 2. Table Transformation
	==============================
	]=]

	mergeTables = mergeTables,
	mergeTablesWith = mergeTablesWith,
	accumulateTables = accumulateTables,
	diffTables = diffTables,
	syncTable = syncTable,
	mapTable = mapTable,
	filterTable = filterTable,
	reduceTable = reduceTable,
	groupTableBy = groupTableBy,
	tableToPairs = tableToPairs,
	invertTable = invertTable,
	tableIntersection = tableIntersection,
	tableDifference = tableDifference,
	removeAll = removeAll,

	--[=[
	==============================
	 3. Array Manipulation
	==============================
	]=]

	extendArraySize = extendArraySize,
	setArraySize = setArraySize,
	truncateArray = truncateArray,
	concatArrays = concatArrays,
	unionArrays = unionArrays,
	flattenArray = flattenArray,
	compactArray = compactArray,
	fillWithValue = fillWithValue,
	fillWithPattern = fillWithPattern,
	reverseArray = reverseArray,
	rotateArray = rotateArray,
	sliceArray = sliceArray,
	shuffleArray = shuffleArray,
	sampleArray = sampleArray,
	sampleValue = sampleValue,
	removeDuplicate = removeDuplicate,
	swapRemove = swapRemove,
	getAndRemove = getAndRemove,
	findAndRemove = findAndRemove,
	zipArray = zipArray,
	unzipArray = unzipArray,
	partitionArray = partitionArray,
	partitionArrayBy = partitionArrayBy,
	binarySearch = binarySearch,

	--[=[
	==============================
	 4. Inspection & Metadata
	==============================
	]=]

	getKeys = getKeys,
	getValues = getValues,
	isContiguousArray = isContiguousArray,
	isSparseArray = isSparseArray,
	isArray = isArray,
	isEmpty = isEmpty,
	hasKey = hasKey,
	hasValue = hasValue,
	countOccurences = countOccurences,
	countKeysByType = countKeysByType,
	countValuesByType = countValuesByType,
	keysOfValue = keysOfValue,

	--[=[
	==============================
	 5. Functional Utilities
	==============================
	]=]

	deepCopy = deepCopy,
	deepEqual = deepEqual,
	deepFreeze = deepFreeze,
	findMatch = findMatch,
	every = every,
	some = some,
	toSet = toSet,

	--[=[
	==============================
	 6. Conversion & Formatting
	==============================
	]=]

	prettyPrint = prettyPrint,
	toCSV = toCSV,
}

for key, value in table :: table do
	Library[key] = value
end

return table.freeze(Library) :: ExtendedTableLibrary
