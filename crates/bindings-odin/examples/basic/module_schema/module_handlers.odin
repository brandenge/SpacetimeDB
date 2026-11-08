// USER-OWNED FILE: edit these handlers; server schema generation preserves this file.

package module_schema

import "stdb:host"

handle_increment_reducer :: proc(ctx: host.Reducer_Context, args: Increment_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Counters, "counters", "counters_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid counters table")

	key_buffer: [32]u8
	scan_buffer: [128]u8
	scan, scan_status, scan_err := host.typed_scan_index_point(
		Counters,
		"counters_id_idx_btree",
		args.id,
		key_buffer[:],
		scan_buffer[:],
	)
	if scan_err != .None || scan_status != host.Status(0) {
		return host.reducer_fail(error, "counter lookup failed")
	}
	current, found, next_status, next_err := host.typed_scan_next(Counters, &scan)
	if next_err != .None || (next_status != 0 && next_status != -1) {
		_ = host.typed_scan_close(Counters, &scan)
		return host.reducer_fail(error, "counter scan failed")
	}
	_ = host.typed_scan_close(Counters, &scan)

	row_buffer: [128]u8
	if found {
		current.value += 1
		status, update_err := host.typed_update(Counters, table, current, row_buffer[:])
		if update_err != .None || status != host.Status(0) do return host.reducer_fail(error, "counter update failed")
	} else {
		status, insert_err := host.typed_insert(Counters, table, Counters{id = args.id, value = 1}, row_buffer[:])
		if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "counter insert failed")
	}
	return 0
}
