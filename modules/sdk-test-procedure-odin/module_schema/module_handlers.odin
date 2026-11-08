package module_schema

import "core:strings"
import "stdb:host"

handle_return_primitive_procedure :: proc(ctx: host.Procedure_Context, args: Add_Args) -> u32 {
	_ = ctx
	return args.left + args.right
}

handle_return_struct_procedure :: proc(ctx: host.Procedure_Context, args: Point_Args) -> Return_Point {
	_ = ctx
	return Return_Point{x = args.x, y = args.y}
}


procedure_row_count :: proc() -> (u64, bool) {
	_, start_status := host.procedure_start_tx()
	if start_status != host.Status(0) do return 0, false
	table, table_err := host.typed_table(Procedure_Row, "procedure_rows", "procedure_rows_id_idx_btree")
	if table_err != .None {
		_ = host.procedure_abort_tx()
		return 0, false
	}
	count, status := host.typed_count(Procedure_Row, table)
	if status != host.Status(0) {
		_ = host.procedure_abort_tx()
		return 0, false
	}
	if host.procedure_commit_tx() != host.Status(0) do return 0, false
	return count, true
}

insert_procedure_row :: proc() -> bool {
	_, start_status := host.procedure_start_tx()
	if start_status != host.Status(0) do return false
	table, table_err := host.typed_table(Procedure_Row, "procedure_rows", "procedure_rows_id_idx_btree")
	if table_err != .None {
		_ = host.procedure_abort_tx()
		return false
	}
	buffer: [64]u8
	status, insert_err := host.typed_insert(Procedure_Row, table, Procedure_Row{id = 1}, buffer[:])
	if insert_err != .None || status != host.Status(0) {
		_ = host.procedure_abort_tx()
		return false
	}
	return true
}

handle_insert_with_tx_commit_procedure :: proc(ctx: host.Procedure_Context, args: No_Args) -> (u64, bool) {
	_ = args
	_ = ctx
	if !insert_procedure_row() do return 0, false
	if host.procedure_commit_tx() != host.Status(0) do return 0, false
	return procedure_row_count()
}

handle_insert_with_tx_rollback_procedure :: proc(ctx: host.Procedure_Context, args: No_Args) -> (u64, bool) {
	_ = args
	_ = ctx
	if !insert_procedure_row() do return 0, false
	if host.procedure_abort_tx() != host.Status(0) do return 0, false
	return procedure_row_count()
}

handle_read_my_schema_procedure :: proc(ctx: host.Procedure_Context, args: Schema_Args) -> (string, bool) {
	_ = ctx
	response, _, request_err := host.http_request(host.Http_Request{method = .Get, uri = args.uri})
	if request_err != .None do return "", false
	defer host.delete_http_response(&response)
	value, clone_err := strings.clone(transmute(string)response.body)
	if clone_err != nil do return "", false
	return value, true
}

handle_invalid_request_procedure :: proc(ctx: host.Procedure_Context, args: No_Args) -> string {
	_ = ctx
	_ = args
	_, _, request_err := host.http_request(host.Http_Request{method = .Get, uri = "http://foo.invalid/"})
	if request_err == .None do return "unexpected response from http://foo.invalid/"
	return "error requesting http://foo.invalid/"
}

handle_schedule_proc_reducer :: proc(ctx: host.Reducer_Context, error: host.Bytes_Sink) -> i16 {
	table, table_err := host.typed_table(Scheduled_Row, "scheduled_rows", "scheduled_rows_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid scheduled rows table")
	row := Scheduled_Row{
		scheduled_at = host.schedule_at_time(host.Timestamp(i64(ctx.timestamp) + 1_000_000)),
		reducer_ts = ctx.timestamp,
		x = 42,
		y = 24,
	}
	buffer: [128]u8
	status, insert_err := host.typed_insert(Scheduled_Row, table, row, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "scheduled row insert failed")
	return 0
}

handle_scheduled_proc :: proc(ctx: host.Procedure_Context, args: Scheduled_Row) -> bool {
	_, start_status := host.procedure_start_tx()
	if start_status != host.Status(0) do return false
	table, table_err := host.typed_table(Scheduled_Result, "scheduled_results", "scheduled_results_id_idx_btree")
	if table_err != .None {
		_ = host.procedure_abort_tx()
		return false
	}
	row := Scheduled_Result{id = 1, reducer_ts = args.reducer_ts, procedure_ts = ctx.timestamp, x = args.x, y = args.y}
	buffer: [128]u8
	status, insert_err := host.typed_insert(Scheduled_Result, table, row, buffer[:])
	if insert_err != .None || status != host.Status(0) {
		_ = host.procedure_abort_tx()
		return false
	}
	return host.procedure_commit_tx() == host.Status(0)
}

handle_insert_concurrency_row_reducer :: proc(ctx: host.Reducer_Context, args: Insert_Concurrency_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Procedure_Concurrency_Row, "procedure_concurrency_rows", "")
	if table_err != .None do return host.reducer_fail(error, "invalid concurrency rows table")
	buffer: [256]u8
	status, insert_err := host.typed_insert(Procedure_Concurrency_Row, table, Procedure_Concurrency_Row{insertion_context = args.insertion_context}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "concurrency reducer insert failed")
	return 0
}

handle_insert_scheduled_concurrency_row_reducer :: proc(ctx: host.Reducer_Context, args: Scheduled_Concurrency_Row, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Procedure_Concurrency_Row, "procedure_concurrency_rows", "")
	if table_err != .None do return host.reducer_fail(error, "invalid concurrency rows table")
	buffer: [256]u8
	status, insert_err := host.typed_insert(Procedure_Concurrency_Row, table, Procedure_Concurrency_Row{insertion_context = args.insertion_context}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "scheduled concurrency reducer insert failed")
	return 0
}

handle_schedule_procedure_then_reducer :: proc(ctx: host.Reducer_Context, error: host.Bytes_Sink) -> i16 {
	procedure_table, procedure_table_err := host.typed_table(Scheduled_Procedure_Concurrency_Row, "scheduled_procedure_concurrency_rows", "scheduled_procedure_concurrency_id_idx_btree")
	if procedure_table_err != .None do return host.reducer_fail(error, "invalid scheduled procedure table")
	reducer_table, reducer_table_err := host.typed_table(Scheduled_Concurrency_Row, "scheduled_concurrency_rows", "scheduled_concurrency_id_idx_btree")
	if reducer_table_err != .None do return host.reducer_fail(error, "invalid scheduled reducer table")
	procedure_buffer: [128]u8
	reducer_buffer: [256]u8
	procedure_status, procedure_insert_err := host.typed_insert(Scheduled_Procedure_Concurrency_Row, procedure_table, Scheduled_Procedure_Concurrency_Row{scheduled_at = host.schedule_at_time(ctx.timestamp), run = 0}, procedure_buffer[:])
	if procedure_insert_err != .None || procedure_status != host.Status(0) do return host.reducer_fail(error, "scheduled procedure insert failed")
	first_status, first_err := host.typed_insert(Scheduled_Concurrency_Row, reducer_table, Scheduled_Concurrency_Row{scheduled_at = host.schedule_at_time(host.Timestamp(i64(ctx.timestamp) + 1_000_000)), insertion_context = "scheduled_reducer_1"}, reducer_buffer[:])
	if first_err != .None || first_status != host.Status(0) do return host.reducer_fail(error, "first scheduled reducer insert failed")
	second_status, second_err := host.typed_insert(Scheduled_Concurrency_Row, reducer_table, Scheduled_Concurrency_Row{scheduled_at = host.schedule_at_time(host.Timestamp(i64(ctx.timestamp) + 2_000_000)), insertion_context = "scheduled_reducer_2"}, reducer_buffer[:])
	if second_err != .None || second_status != host.Status(0) do return host.reducer_fail(error, "second scheduled reducer insert failed")
	return 0
}

handle_schedule_procedure_update_while_inflight :: proc(ctx: host.Reducer_Context, error: host.Bytes_Sink) -> i16 {
	procedure_table, procedure_table_err := host.typed_table(Scheduled_Procedure_Concurrency_Row, "scheduled_procedure_concurrency_rows", "scheduled_procedure_concurrency_id_idx_btree")
	if procedure_table_err != .None do return host.reducer_fail(error, "invalid scheduled procedure table")
	reducer_table, reducer_table_err := host.typed_table(Scheduled_Concurrency_Row, "scheduled_concurrency_rows", "scheduled_concurrency_id_idx_btree")
	if reducer_table_err != .None do return host.reducer_fail(error, "invalid scheduled reducer table")
	procedure_buffer: [128]u8
	reducer_buffer: [256]u8
	procedure_status, procedure_insert_err := host.typed_insert(Scheduled_Procedure_Concurrency_Row, procedure_table, Scheduled_Procedure_Concurrency_Row{scheduled_at = host.schedule_at_time(host.Timestamp(i64(ctx.timestamp) + 1_000_000)), run = 1}, procedure_buffer[:])
	if procedure_insert_err != .None || procedure_status != host.Status(0) do return host.reducer_fail(error, "inflight scheduled procedure insert failed")
	verifier_status, verifier_err := host.typed_insert(Scheduled_Concurrency_Row, reducer_table, Scheduled_Concurrency_Row{scheduled_at = host.schedule_at_time(host.Timestamp(i64(ctx.timestamp) + 4_000_000)), insertion_context = "scheduled_procedure_update_verifier"}, reducer_buffer[:])
	if verifier_err != .None || verifier_status != host.Status(0) do return host.reducer_fail(error, "scheduled procedure verifier insert failed")
	return 0
}

insert_procedure_concurrency_row :: proc(value: string) -> bool {
	_, start_status := host.procedure_start_tx()
	if start_status != host.Status(0) do return false
	table, table_err := host.typed_table(Procedure_Concurrency_Row, "procedure_concurrency_rows", "")
	if table_err != .None {
		_ = host.procedure_abort_tx()
		return false
	}
	buffer: [256]u8
	status, insert_err := host.typed_insert(Procedure_Concurrency_Row, table, Procedure_Concurrency_Row{insertion_context = value}, buffer[:])
	if insert_err != .None || status != host.Status(0) {
		_ = host.procedure_abort_tx()
		return false
	}
	return host.procedure_commit_tx() == host.Status(0)
}

procedure_has_concurrency_row :: proc(insertion_context: string) -> (found: bool, ok: bool) {
	_, start_status := host.procedure_start_tx()
	if start_status != host.Status(0) do return false, false
	table, table_err := host.typed_table(Procedure_Concurrency_Row, "procedure_concurrency_rows", "")
	if table_err != .None {
		_ = host.procedure_abort_tx()
		return false, false
	}
	batch: [512]u8
	scan, scan_status := host.typed_scan_open(Procedure_Concurrency_Row, table, batch[:])
	if scan_status != host.Status(0) {
		_ = host.procedure_abort_tx()
		return false, false
	}
	for {
		row, has_row, status, scan_err := host.typed_scan_next(Procedure_Concurrency_Row, &scan)
		if scan_err != .None || (status != 0 && status != -1) {
			_ = host.typed_scan_close(Procedure_Concurrency_Row, &scan)
			_ = host.procedure_abort_tx()
			return false, false
		}
		if !has_row do break
		if row.insertion_context == insertion_context {
			found = true
			break
		}
	}
	_ = host.typed_scan_close(Procedure_Concurrency_Row, &scan)
	if host.procedure_commit_tx() != host.Status(0) do return false, false
	return found, true
}

handle_procedure_sleep_between_inserts :: proc(ctx: ^host.Procedure_Context) -> bool {
	if !insert_procedure_concurrency_row("procedure_before") do return false
	deadline := i64(ctx.timestamp) + 10_000_000
	for i64(ctx.timestamp) < deadline {
		found, ok := procedure_has_concurrency_row("reducer")
		if !ok do return false
		if found do return insert_procedure_concurrency_row("procedure_after")
		host.context_procedure_sleep_until(ctx, host.Timestamp(i64(ctx.timestamp) + 100_000))
	}
	return false
}

handle_procedure_schedule_reducer_between_inserts :: proc(ctx: ^host.Procedure_Context) -> bool {
	if !insert_procedure_concurrency_row("procedure_before") do return false
	_, start_status := host.procedure_start_tx()
	if start_status != host.Status(0) do return false
	table, table_err := host.typed_table(Scheduled_Concurrency_Row, "scheduled_concurrency_rows", "scheduled_concurrency_id_idx_btree")
	if table_err != .None {
		_ = host.procedure_abort_tx()
		return false
	}
	row := Scheduled_Concurrency_Row{
		scheduled_at = host.schedule_at_time(ctx.timestamp),
		insertion_context = "scheduled_reducer",
	}
	buffer: [256]u8
	status, insert_err := host.typed_insert(Scheduled_Concurrency_Row, table, row, buffer[:])
	if insert_err != .None || status != host.Status(0) {
		_ = host.procedure_abort_tx()
		return false
	}
	if host.procedure_commit_tx() != host.Status(0) do return false
	deadline := i64(ctx.timestamp) + 10_000_000
	for i64(ctx.timestamp) < deadline {
		found, ok := procedure_has_concurrency_row("scheduled_reducer")
		if !ok do return false
		if found do return insert_procedure_concurrency_row("procedure_after")
		host.context_procedure_sleep_until(ctx, host.Timestamp(i64(ctx.timestamp) + 100_000))
	}
	return false
}

handle_scheduled_procedure_concurrency :: proc(ctx: ^host.Procedure_Context, args: Scheduled_Procedure_Concurrency_Row) -> bool {
	if args.run == 1 || args.run == 2 do return handle_scheduled_procedure_update_inflight(ctx, args)
	if !insert_procedure_concurrency_row("scheduled_procedure_before") do return false
	deadline := i64(ctx.timestamp) + 15_000_000
	for i64(ctx.timestamp) < deadline {
		found, ok := procedure_has_concurrency_row("scheduled_reducer_2")
		if !ok do return false
		if found do return insert_procedure_concurrency_row("scheduled_procedure_after")
		host.context_procedure_sleep_until(ctx, host.Timestamp(i64(ctx.timestamp) + 100_000))
	}
	_ = args
	return false
}

handle_scheduled_procedure_update_inflight :: proc(ctx: ^host.Procedure_Context, args: Scheduled_Procedure_Concurrency_Row) -> bool {
	if args.run == 2 {
		return insert_procedure_concurrency_row("scheduled_procedure_update_second_before") &&
			insert_procedure_concurrency_row("scheduled_procedure_update_second_after")
	}
	if args.run != 1 || !insert_procedure_concurrency_row("scheduled_procedure_update_first_before") do return false
	_, start_status := host.procedure_start_tx()
	if start_status != host.Status(0) do return false
	table, table_err := host.typed_table(Scheduled_Procedure_Concurrency_Row, "scheduled_procedure_concurrency_rows", "scheduled_procedure_concurrency_id_idx_btree")
	if table_err != .None {
		_ = host.procedure_abort_tx()
		return false
	}
	updated_row := args
	updated_row.run = 2
	updated_row.scheduled_at = host.schedule_at_time(host.Timestamp(i64(ctx.timestamp) + 1_000_000))
	buffer: [128]u8
	status, insert_err := host.typed_insert(Scheduled_Procedure_Concurrency_Row, table, updated_row, buffer[:])
	if insert_err != .None || status != host.Status(0) {
		_ = host.procedure_abort_tx()
		return false
	}
	if host.procedure_commit_tx() != host.Status(0) do return false
	host.context_procedure_sleep_until(ctx, host.Timestamp(i64(ctx.timestamp) + 2_000_000))
	return insert_procedure_concurrency_row("scheduled_procedure_update_first_after")
}
