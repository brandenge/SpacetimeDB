package module_schema

import "stdb:host"

handle_identity_connected_reducer :: proc(ctx: host.Reducer_Context, args: No_Args, error: host.Bytes_Sink) -> i16 {
	_ = args
	table, table_err := host.typed_table(Connected, "connected", "")
	if table_err != .None do return host.reducer_fail(error, "invalid connected table")
	buffer: [64]u8
	status, insert_err := host.typed_insert(Connected, table, Connected{identity = ctx.sender}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "connected row insert failed")
	return 0
}

handle_identity_disconnected_reducer :: proc(ctx: host.Reducer_Context, args: No_Args, error: host.Bytes_Sink) -> i16 {
	_ = args
	table, table_err := host.typed_table(Disconnected, "disconnected", "")
	if table_err != .None do return host.reducer_fail(error, "invalid disconnected table")
	buffer: [64]u8
	status, insert_err := host.typed_insert(Disconnected, table, Disconnected{identity = ctx.sender}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "disconnected row insert failed")
	return 0
}
