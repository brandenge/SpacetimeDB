package client

import "core:strings"
import "stdb:host"
import "base:runtime"

// Rows are keyed by their BSATN bytes; the count tracks duplicates delivered by overlapping queries.
Row_Counts :: map[string]u32
Set_Tables :: map[string]Row_Counts
Cache_Index_Extractor :: proc(row: []u8, user: rawptr) -> ([]u8, host.Codec_Error)
Cache_Index_Less :: proc(left, right: []u8, user: rawptr) -> (bool, host.Codec_Error)
Cache_Index_Prefix_Match :: proc(key, prefix: []u8, user: rawptr) -> (bool, host.Codec_Error)

Cache_Index_Bound_Mode :: enum u8 {
	Unbounded,
	Inclusive,
	Exclusive,
}

Cache_Index :: struct {
	table: string,
	extractor: Cache_Index_Extractor,
	less: Cache_Index_Less,
	prefix_matches: Cache_Index_Prefix_Match,
	user: rawptr,
	valid: bool,
	rows: map[string]map[string]struct{},
	ordered_keys: [dynamic]string,
}

// Mirrors subscribed rows per query set so unsubscribing or a subscription error drops exactly that set's rows.
Cache :: struct {
	sets: map[u32]Set_Tables,
	indexes: map[string]Cache_Index,
}

cache_destroy :: proc(cache: ^Cache) {
	when ODIN_OS == .JS do context = runtime.default_context()
	for _, &tables in cache.sets do set_tables_destroy(&tables)
	delete(cache.sets)
	cache.sets = nil
	cache_index_destroy_all(cache)
}

@(private)
cache_index_destroy_all :: proc(cache: ^Cache) {
	for name, &index in cache.indexes {
		for key, &rows in index.rows {
			for row in rows do delete(row)
			delete(rows)
			delete(key)
		}
		delete(index.rows)
		for key in index.ordered_keys do delete(key)
		delete(index.ordered_keys)
		delete(index.table)
		delete(name)
	}
	delete(cache.indexes)
	cache.indexes = nil
}

@(private)
set_tables_destroy :: proc(tables: ^Set_Tables) {
	for name, &rows in tables^ {
		for key in rows do delete(key)
		delete(rows)
		delete(name)
	}
	delete(tables^)
}

@(private)
set_add_row :: proc(tables: ^Set_Tables, table: string, row: []u8) -> (newly_added: bool) {
	rows := &tables[table]
	if rows == nil {
		tables[strings.clone(table)] = Row_Counts{}
		rows = &tables[table]
	}
	if count := &rows[string(row)]; count != nil {
		count^ += 1
		return false
	}
	rows[strings.clone_from_bytes(row)] = 1
	return true
}

@(private)
set_remove_row :: proc(tables: ^Set_Tables, table: string, row: []u8) -> (removed: bool) {
	rows := &tables[table]
	if rows == nil do return false
	count := &rows[string(row)]
	if count == nil do return false
	if count^ > 1 {
		count^ -= 1
		return false
	}
	key, _ := delete_key(rows, string(row))
	delete(key)
	return true
}

@(private)
row_in_other_sets :: proc(cache: ^Cache, set_id: u32, table: string, row: []u8) -> bool {
	for id, &tables in cache.sets {
		if id == set_id do continue
		if rows := &tables[table]; rows != nil && string(row) in rows^ do return true
	}
	return false
}

@(private)
set_apply_list :: proc(
	cache: ^Cache,
	set_id: u32,
	table: string,
	list: Row_List,
	insert: bool,
	changes: ^[dynamic]Row_Change,
) {
	tables := cache_set(cache, set_id)
	for index in 0 ..< row_list_len(list) {
		row, ok := row_list_row(list, index)
		if !ok do continue
		changed := set_add_row(tables, table, row) if insert else set_remove_row(tables, table, row)
		if changed && !row_in_other_sets(cache, set_id, table, row) {
			cache_update_indexes(cache, table, row, insert)
			if changes != nil do append(changes, Row_Change{table = table, kind = .Insert if insert else .Delete, row = row})
		}
	}
}

@(private)
cache_set :: proc(cache: ^Cache, query_set_id: u32) -> ^Set_Tables {
	if query_set_id not_in cache.sets do cache.sets[query_set_id] = Set_Tables{}
	return &cache.sets[query_set_id]
}

@(private)
cache_drop_set :: proc(cache: ^Cache, set_id: u32, changes: ^[dynamic]Row_Change) {
	tables := &cache.sets[set_id]
	if tables == nil do return
	// The dropped storage is freed below, so callback changes own temp-allocated copies.
	for name, &rows in tables^ {
		for key in rows {
			row := transmute([]u8)key
			if row_in_other_sets(cache, set_id, name, row) do continue
			cache_update_indexes(cache, name, row, false)
			if changes != nil {
				append(changes, Row_Change{
					table = strings.clone(name, context.temp_allocator),
					kind = .Delete,
					row = transmute([]u8)strings.clone(key, context.temp_allocator),
				})
			}
		}
	}
	set_tables_destroy(tables)
	delete_key(&cache.sets, set_id)
}

// Registers an index by name and builds it from rows already present in the cache.
cache_index_register :: proc(
	cache: ^Cache,
	index_name, table: string,
	extractor: Cache_Index_Extractor,
	user: rawptr = nil,
	less: Cache_Index_Less = nil,
	prefix_matches: Cache_Index_Prefix_Match = nil,
) -> host.Codec_Error {
	when ODIN_OS == .JS do context = runtime.default_context()
	if extractor == nil || len(index_name) == 0 || len(table) == 0 do return .Malformed_Data
	if index := &cache.indexes[index_name]; index != nil {
		if index.table != table do return .Malformed_Data
		if !index.valid do return .Malformed_Data
		if less != nil && index.less == nil {
			index.less = less
			for key, _ in index.rows {
				if !cache_index_add_ordered_key(index, key) {
					index.valid = false
					return .Malformed_Data
				}
			}
		}
		if prefix_matches != nil && index.prefix_matches == nil do index.prefix_matches = prefix_matches
		return .None
	}
	if cache.indexes == nil do cache.indexes = make(map[string]Cache_Index)
	owned_name := strings.clone(index_name)
	cache.indexes[owned_name] = Cache_Index{
		table = strings.clone(table),
		extractor = extractor,
		less = less,
		prefix_matches = prefix_matches,
		user = user,
		valid = true,
		rows = make(map[string]map[string]struct{}),
	}
	index := &cache.indexes[index_name]
	for row in cache_table_rows(cache, table, context.temp_allocator) do cache_index_update_one(index, row, true)
	if !index.valid do return .Malformed_Data
	return .None
}

// Lookup an encoded composite-key prefix. Prefix interpretation is supplied by the registered index.
cache_index_prefix_lookup :: proc(
	cache: ^Cache,
	index_name: string,
	prefix: []u8,
	allocator := context.temp_allocator,
) -> (rows: [][]u8, indexed: bool) {
	when ODIN_OS == .JS do context = runtime.default_context()
	index := &cache.indexes[index_name]
	if index == nil || !index.valid || index.prefix_matches == nil do return nil, false
	result := make([dynamic][]u8, allocator = allocator)
	for key, matching_rows in index.rows {
		matches, err := index.prefix_matches(transmute([]u8)key, prefix, index.user)
		if err != .None {
			delete(result)
			index.valid = false
			return nil, false
		}
		if !matches do continue
		for row in matching_rows do append(&result, transmute([]u8)row)
	}
	return result[:], true
}

// Lookup rows by encoded key; returned row bytes borrow the index and remain valid until cache_apply.
cache_index_lookup :: proc(
	cache: ^Cache,
	index_name: string,
	key: []u8,
	allocator := context.temp_allocator,
) -> (rows: [][]u8, indexed: bool) {
	when ODIN_OS == .JS do context = runtime.default_context()
	index := &cache.indexes[index_name]
	if index == nil || !index.valid do return nil, false
	matching := &index.rows[string(key)]
	if matching == nil do return nil, true
	result := make([dynamic][]u8, allocator = allocator)
	for row in matching^ do append(&result, transmute([]u8)row)
	return result[:], true
}

// Lookup an ordered key range. The key-slice bounds are ignored when their modes are .Unbounded.
cache_index_range_lookup :: proc(
	cache: ^Cache,
	index_name: string,
	lower_key: []u8,
	lower_mode: Cache_Index_Bound_Mode,
	upper_key: []u8,
	upper_mode: Cache_Index_Bound_Mode,
	allocator := context.temp_allocator,
) -> (rows: [][]u8, indexed: bool) {
	when ODIN_OS == .JS do context = runtime.default_context()
	index := &cache.indexes[index_name]
	if index == nil || !index.valid || index.less == nil do return nil, false
	start := 0
	end := len(index.ordered_keys)
	if lower_mode != .Unbounded {
		lower_position, lower_ok := cache_index_bound_position(index, lower_key, lower_mode == .Inclusive, true)
		if !lower_ok do return nil, false
		start = lower_position
	}
	if upper_mode != .Unbounded {
		upper_position, upper_ok := cache_index_bound_position(index, upper_key, upper_mode == .Inclusive, false)
		if !upper_ok do return nil, false
		end = upper_position
	}
	result := make([dynamic][]u8, allocator = allocator)
	if start >= end do return result[:], true
	for key in index.ordered_keys[start:end] {
		if matching := &index.rows[key]; matching != nil {
			for row in matching^ do append(&result, transmute([]u8)row)
		}
	}
	return result[:], true
}

// Decodes an index hit set into owned rows; release successful results with delete_rows.
cache_index_decode_rows :: proc(cache: ^Cache, index_name: string, key: []u8, $Row: typeid) -> ([]Row, host.Codec_Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	encoded_rows, indexed := cache_index_lookup(cache, index_name, key, context.temp_allocator)
	if !indexed do return nil, .Malformed_Data
	rows := make([]Row, len(encoded_rows))
	for encoded_row, index in encoded_rows {
		row, consumed, err := host.decode_row_from(Row, encoded_row)
		if err == .None && consumed != len(encoded_row) do err = .Trailing_Bytes
		if err != .None {
			delete_rows(rows[:index])
			return nil, err
		}
		rows[index] = row
	}
	return rows, .None
}

cache_index_decode_range_rows :: proc(
	cache: ^Cache,
	index_name: string,
	lower_key: []u8,
	lower_mode: Cache_Index_Bound_Mode,
	upper_key: []u8,
	upper_mode: Cache_Index_Bound_Mode,
	$Row: typeid,
) -> ([]Row, host.Codec_Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	encoded_rows, indexed := cache_index_range_lookup(
		cache,
		index_name,
		lower_key,
		lower_mode,
		upper_key,
		upper_mode,
		context.temp_allocator,
	)
	if !indexed do return nil, .Malformed_Data
	rows := make([]Row, len(encoded_rows))
	for encoded_row, index in encoded_rows {
		row, consumed, err := host.decode_row_from(Row, encoded_row)
		if err == .None && consumed != len(encoded_row) do err = .Trailing_Bytes
		if err != .None {
			delete_rows(rows[:index])
			return nil, err
		}
		rows[index] = row
	}
	return rows, .None
}

cache_index_decode_prefix_rows :: proc(
	cache: ^Cache,
	index_name: string,
	prefix: []u8,
	$Row: typeid,
) -> ([]Row, host.Codec_Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	encoded_rows, indexed := cache_index_prefix_lookup(cache, index_name, prefix, context.temp_allocator)
	if !indexed do return nil, .Malformed_Data
	rows := make([]Row, len(encoded_rows))
	for encoded_row, index in encoded_rows {
		row, consumed, err := host.decode_row_from(Row, encoded_row)
		if err == .None && consumed != len(encoded_row) do err = .Trailing_Bytes
		if err != .None {
			delete_rows(rows[:index])
			return nil, err
		}
		rows[index] = row
	}
	return rows, .None
}

@(private)
cache_update_indexes :: proc(cache: ^Cache, table: string, row: []u8, insert: bool) {
	for _, &index in cache.indexes {
		if index.table == table do cache_index_update_one(&index, row, insert)
	}
}

@(private)
cache_index_update_one :: proc(index: ^Cache_Index, row: []u8, insert: bool) {
	if !index.valid do return
	key_bytes, err := index.extractor(row, index.user)
	if err != .None {
		index.valid = false
		return
	}
	defer delete(key_bytes)
	if insert {
		rows := &index.rows[string(key_bytes)]
		if rows == nil {
			if index.less != nil && !cache_index_add_ordered_key(index, string(key_bytes)) {
				index.valid = false
				return
			}
			owned_key := strings.clone_from_bytes(key_bytes)
			index.rows[owned_key] = make(map[string]struct{})
			rows = &index.rows[string(key_bytes)]
		}
		if string(row) not_in rows^ do rows^[strings.clone_from_bytes(row)] = {}
		return
	}
	rows := &index.rows[string(key_bytes)]
	if rows == nil do return
	owned_row, _ := delete_key(rows, string(row))
	delete(owned_row)
	if len(rows^) == 0 {
		delete(rows^)
		owned_key, _ := delete_key(&index.rows, string(key_bytes))
		delete(owned_key)
		cache_index_remove_ordered_key(index, string(key_bytes))
	}
}

@(private)
cache_index_add_ordered_key :: proc(index: ^Cache_Index, key: string) -> bool {
	low := 0
	high := len(index.ordered_keys)
	for low < high {
		middle := (low + high) / 2
		existing := index.ordered_keys[middle]
	key_is_less, key_err := index.less(transmute([]u8)key, transmute([]u8)existing, index.user)
		existing_is_less, existing_err := index.less(transmute([]u8)existing, transmute([]u8)key, index.user)
		if key_err != .None || existing_err != .None do return false
		if !key_is_less && !existing_is_less do return true
		if key_is_less {
			high = middle
		} else {
			low = middle + 1
		}
	}
	append(&index.ordered_keys, "")
	for position := len(index.ordered_keys) - 1; position > low; position -= 1 {
		index.ordered_keys[position] = index.ordered_keys[position - 1]
	}
	index.ordered_keys[low] = strings.clone(key)
	return true
}

@(private)
cache_index_remove_ordered_key :: proc(index: ^Cache_Index, key: string) {
	for existing, position in index.ordered_keys {
		if existing != key do continue
		delete(existing)
		for next in position ..< len(index.ordered_keys) - 1 do index.ordered_keys[next] = index.ordered_keys[next + 1]
		pop(&index.ordered_keys)
		return
	}
}

@(private)
cache_index_bound_position :: proc(
	index: ^Cache_Index,
	bound: []u8,
	inclusive: bool,
	lower_bound: bool,
) -> (position: int, ok: bool) {
	low := 0
	high := len(index.ordered_keys)
	for low < high {
		middle := (low + high) / 2
		key := transmute([]u8)index.ordered_keys[middle]
		key_less, key_err := index.less(key, bound, index.user)
		bound_less, bound_err := index.less(bound, key, index.user)
		if key_err != .None || bound_err != .None {
			index.valid = false
			return 0, false
		}
		equal := !key_less && !bound_less
		advance := key_less || (equal && !inclusive) if lower_bound else key_less || (equal && inclusive)
		if advance {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low, true
}

@(private)
cache_apply_update :: proc(cache: ^Cache, update: Transaction_Update, changes: ^[dynamic]Row_Change) {
	for set in update.query_sets {
		for table in set.tables {
			for group in table.groups {
				if group.is_event {
					if changes == nil do continue
					for index in 0 ..< row_list_len(group.events) {
						row, ok := row_list_row(group.events, index)
						if ok do append(changes, Row_Change{table = table.table, kind = .Insert, row = row})
					}
					continue
				}
				set_apply_list(cache, set.query_set_id, table.table, group.deletes, false, changes)
				set_apply_list(cache, set.query_set_id, table.table, group.inserts, true, changes)
			}
		}
	}
}

// Keeps the cache in sync with a message from poll; call it for every message before message_destroy.
// When changes is set, row inserts and deletes are appended to it; each row is reported once even when
// several query sets contain it. Changes borrow the message payload, so use them before message_destroy.
cache_apply :: proc(cache: ^Cache, message: Message, changes: ^[dynamic]Row_Change = nil) {
	when ODIN_OS == .JS do context = runtime.default_context()
	switch body in message.body {
	case Subscribe_Applied:
		cache_drop_set(cache, body.query_set_id, changes)
		cache_set(cache, body.query_set_id)
		for table in body.rows.tables do set_apply_list(cache, body.query_set_id, table.table, table.rows, true, changes)
	case Unsubscribe_Applied:
		cache_drop_set(cache, body.query_set_id, changes)
	case Subscribe_Batch_Applied:
		for result in body.results do cache_drop_set(cache, result.query_set_id, changes)
		for result in body.results {
			if applied, ok := result.outcome.(Subscribe_Set_Applied); ok {
				cache_set(cache, result.query_set_id)
				for table in applied.rows.tables do set_apply_list(cache, result.query_set_id, table.table, table.rows, true, changes)
			}
		}
	case Subscription_Error:
		cache_drop_set(cache, body.query_set_id, changes)
	case Transaction_Update:
		cache_apply_update(cache, body, changes)
	case Reducer_Result:
		if body.outcome == .Ok do cache_apply_update(cache, body.update, changes)
	case Initial_Connection, One_Off_Query_Result, Procedure_Result:
	}
}

// Distinct rows of a table across all query sets; the slices borrow cache storage until the next apply.
cache_table_rows :: proc(cache: ^Cache, table: string, allocator := context.temp_allocator) -> [][]u8 {
	seen := make(map[string]struct{}, allocator = allocator)
	rows := make([dynamic][]u8, allocator = allocator)
	for _, &tables in cache.sets {
		counts := &tables[table]
		if counts == nil do continue
		for key in counts {
			if key in seen do continue
			seen[key] = {}
			append(&rows, transmute([]u8)key)
		}
	}
	return rows[:]
}

cache_row_count :: proc(cache: ^Cache, table: string) -> int {
	return len(cache_table_rows(cache, table, context.temp_allocator))
}

// Rows own their strings and arrays; release them with delete_rows.
cache_rows :: proc(cache: ^Cache, table: string, $Row: typeid) -> ([]Row, host.Codec_Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	raw := cache_table_rows(cache, table, context.temp_allocator)
	rows := make([]Row, len(raw))
	for bytes, index in raw {
		row, consumed, err := host.decode_row_from(Row, bytes)
		if err == .None && consumed != len(bytes) do err = .Trailing_Bytes
		if err != .None {
			delete_rows(rows[:index])
			return nil, err
		}
		rows[index] = row
	}
	return rows, .None
}

// Returns owned typed rows matching predicate; release the result with delete_rows.
cache_filter_rows :: proc(
	cache: ^Cache,
	table: string,
	$Row: typeid,
	predicate: proc(row: ^Row, user: rawptr) -> bool,
	user: rawptr = nil,
) -> ([]Row, host.Codec_Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	rows, err := cache_rows(cache, table, Row)
	if err != .None do return nil, err
	selected := make([dynamic]Row)
	for &row in rows {
		if predicate(&row, user) {
			append(&selected, row)
		} else {
			host.delete_decoded_row(Row, &row)
		}
	}
	delete(rows)
	return selected[:], .None
}
