package module_schema

import "core:strings"
import "stdb:host"

@(export, link_name = "__describe_module__")
describe_module :: proc "c" (description: host.Bytes_Sink) {
	context = host.scratch_context()
	_, _ = write_module_definition(description)
}

@(export, link_name = "__call_reducer__")
call_reducer :: proc "c" (
	id: uint,
	sender_0, sender_1, sender_2, sender_3: u64,
	conn_id_0, conn_id_1: u64,
	timestamp: u64,
	args: host.Bytes_Source,
	error: host.Bytes_Sink,
) -> i16 {
	context = host.scratch_context()
	caller := host.reducer_context(sender_0, sender_1, sender_2, sender_3, conn_id_0, conn_id_1, timestamp)
	if id == 2 do return handle_disconnect_player_reducer(caller, error)
	args_length: u32
	if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
	buffer := make([]u8, int(args_length))
	defer delete(buffer)
	if id == 0 {
		decoded, decode_err := host.read_reducer_args(Insert_Player_Args, args, buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_insert_player_reducer(caller, decoded, error)
	}
	if id == 1 {
		decoded, decode_err := host.read_reducer_args(Update_Player_Args, args, buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_update_player_reducer(caller, decoded, error)
	}
	if id == 3 {
		decoded, decode_err := host.read_reducer_args(Delete_Player_Args, args, buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_delete_player_reducer(caller, decoded, error)
	}
	return host.reducer_fail(error, "unknown reducer id")
}

@(export, link_name = "__call_view_anon__")
call_view_anon :: proc "c" (
	id: uint,
	args: host.Bytes_Source,
	sink: host.Bytes_Sink,
) -> i16 {
	context = host.scratch_context()
	_ = args
	if id != 0 do return -1
	status, complete := host.write_view_query(sink, "SELECT * FROM players")
	if status != host.Status(0) || !complete do return -1
	return host.VIEW_ABI_RESULT
}

@(export, link_name = "__call_view__")
call_view :: proc "c" (
	id: uint,
	sender_0, sender_1, sender_2, sender_3: u64,
	args: host.Bytes_Source,
	sink: host.Bytes_Sink,
) -> i16 {
	context = host.scratch_context()
	_ = args
	caller := host.reducer_context(sender_0, sender_1, sender_2, sender_3, 0, 0, 0).sender
	table, table_err := host.typed_table(Player, "players", "players_id_idx_btree")
	if table_err != .None do return -1
	batch: [2048]u8
	scan, scan_status := host.typed_scan_open(Player, table, batch[:])
	if scan_status != host.Status(0) do return -1
	rows: [dynamic]Player
	defer for row in rows do delete(row.name)
	for {
		row, has_row, status, scan_err := host.typed_scan_next(Player, &scan)
		if scan_err != .None || (status != 0 && status != -1) {
			_ = host.typed_scan_close(Player, &scan)
			return -1
		}
		if !has_row do break
		if row.owner != caller do continue
		name, clone_err := strings.clone(row.name)
		if clone_err != nil {
			_ = host.typed_scan_close(Player, &scan)
			return -1
		}
		append(&rows, Player{id = row.id, owner = row.owner, name = name, score = row.score})
	}
	_ = host.typed_scan_close(Player, &scan)
	if id == 1 {
		summary_rows: [dynamic]Player_Summary
		for row in rows {
			if row.owner == caller do append(&summary_rows, Player_Summary{id = row.id, owner = row.owner, score = row.score})
		}
		encoded: [4096]u8
		if host.write_view_rows(Player_Summary, sink, summary_rows[:], encoded[:]) != .None do return -1
		return host.VIEW_ABI_RESULT
	}
	if id != 0 do return -1
	encoded: [4096]u8
	if host.write_view_rows(Player, sink, rows[:], encoded[:]) != .None do return -1
	return host.VIEW_ABI_RESULT
}
