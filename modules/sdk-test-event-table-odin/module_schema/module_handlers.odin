package module_schema

import "core:strings"
import "stdb:host"

insert_event :: proc(table: host.Typed_Table(Test_Event), name: string, value: u64, error: host.Bytes_Sink) -> i16 {
	owned_name, clone_err := strings.clone(name)
	if clone_err != nil do return host.reducer_fail(error, "event name allocation failed")
	defer delete(owned_name)
	buffer: [128]u8
	status, insert_err := host.typed_insert(Test_Event, table, Test_Event{name = owned_name, value = value}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "event insert failed")
	return 0
}

handle_emit_test_event_reducer :: proc(ctx: host.Reducer_Context, args: Emit_Event_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_Event, "test_event", "")
	if table_err != .None do return host.reducer_fail(error, "invalid test event table")
	return insert_event(table, args.name, args.value, error)
}

handle_emit_multiple_test_events_reducer :: proc(ctx: host.Reducer_Context, args: Emit_Multiple_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_Event, "test_event", "")
	if table_err != .None do return host.reducer_fail(error, "invalid test event table")
	names := [?]string{"a", "b", "c"}
	for name, index in names {
		if status := insert_event(table, name, args.seed + u64(index + 1), error); status != 0 do return status
	}
	return 0
}

handle_noop_reducer :: proc(ctx: host.Reducer_Context, args: Noop_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	_ = args
	_ = error
	return 0
}
