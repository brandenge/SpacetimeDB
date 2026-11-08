package module_schema

import "core:strings"
import "stdb:host"

handle_insert_player_reducer :: proc(ctx: host.Reducer_Context, args: Insert_Player_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Player, "players", "players_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid players table")
	name, clone_err := strings.clone(args.name)
	if clone_err != nil do return host.reducer_fail(error, "player name allocation failed")
	defer delete(name)
	buffer: [128]u8
	status, insert_err := host.typed_insert(Player, table, Player{id = args.id, owner = ctx.sender, name = name, score = args.score}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "player insert failed")
	return 0
}

handle_update_player_reducer :: proc(ctx: host.Reducer_Context, args: Update_Player_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Player, "players", "players_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid players table")
	key_buffer: [32]u8
	scan_buffer: [256]u8
	scan, scan_status, scan_err := host.typed_scan_index_point(Player, "players_id_idx_btree", args.id, key_buffer[:], scan_buffer[:])
	if scan_err != .None || scan_status != host.Status(0) do return host.reducer_fail(error, "player lookup failed")
	row, found, next_status, next_err := host.typed_scan_next(Player, &scan)
	_ = host.typed_scan_close(Player, &scan)
	if next_err != .None || (next_status != 0 && next_status != -1) || !found do return host.reducer_fail(error, "player row not found")
	row.score = args.score
	buffer: [128]u8
	status, update_err := host.typed_update(Player, table, row, buffer[:])
	if update_err != .None || status != host.Status(0) do return host.reducer_fail(error, "player update failed")
	return 0
}

handle_delete_player_reducer :: proc(ctx: host.Reducer_Context, args: Delete_Player_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Player, "players", "players_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid players table")
	key_buffer: [32]u8
	scan_buffer: [256]u8
	scan, scan_status, scan_err := host.typed_scan_index_point(Player, "players_id_idx_btree", args.id, key_buffer[:], scan_buffer[:])
	if scan_err != .None || scan_status != host.Status(0) do return host.reducer_fail(error, "player lookup failed")
	row, found, next_status, next_err := host.typed_scan_next(Player, &scan)
	_ = host.typed_scan_close(Player, &scan)
	if next_err != .None || (next_status != 0 && next_status != -1) || !found do return host.reducer_fail(error, "player row not found")
	buffer: [128]u8
	_, status, delete_err := host.typed_delete(Player, table, row, buffer[:])
	if delete_err != .None || status != host.Status(0) do return host.reducer_fail(error, "player delete failed")
	return 0
}

handle_disconnect_player_reducer :: proc(ctx: host.Reducer_Context, error: host.Bytes_Sink) -> i16 {
	table, table_err := host.typed_table(Player, "players", "players_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid players table")
	batch: [512]u8
	scan, scan_status := host.typed_scan_open(Player, table, batch[:])
	if scan_status != host.Status(0) do return host.reducer_fail(error, "players scan failed")
	rows: [dynamic]Player
	for {
		row, has_row, status, scan_err := host.typed_scan_next(Player, &scan)
		if scan_err != .None || (status != 0 && status != -1) {
			_ = host.typed_scan_close(Player, &scan)
			return host.reducer_fail(error, "players scan failed")
		}
		if !has_row do break
		if row.owner == ctx.sender do append(&rows, row)
	}
	_ = host.typed_scan_close(Player, &scan)
	buffer: [128]u8
	for row in rows {
		_, status, delete_err := host.typed_delete(Player, table, row, buffer[:])
		if delete_err != .None || status != host.Status(0) do return host.reducer_fail(error, "disconnected player delete failed")
	}
	return 0
}
