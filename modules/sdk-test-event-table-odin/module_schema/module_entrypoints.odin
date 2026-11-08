package module_schema

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
	if id == 0 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		buffer := make([]u8, int(args_length))
		defer delete(buffer)
		decoded, decode_err := host.read_reducer_args(Emit_Event_Args, args, buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_emit_test_event_reducer(caller, decoded, error)
	}
	if id == 1 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		buffer := make([]u8, int(args_length))
		defer delete(buffer)
		decoded, decode_err := host.read_reducer_args(Emit_Multiple_Args, args, buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_emit_multiple_test_events_reducer(caller, decoded, error)
	}
	if id == 2 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		buffer := make([]u8, int(args_length))
		defer delete(buffer)
		decoded, decode_err := host.read_reducer_args(Noop_Args, args, buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_noop_reducer(caller, decoded, error)
	}
	return host.reducer_fail(error, "unknown reducer id")
}
