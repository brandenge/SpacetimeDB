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
	if id == 1 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		buffer := make([]u8, int(args_length))
		defer delete(buffer)
		decoded, decode_err := host.read_reducer_args(Insert_Concurrency_Args, args, buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_insert_concurrency_row_reducer(caller, decoded, error)
	}
	if id == 2 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read scheduled reducer arguments")
		buffer := make([]u8, int(args_length))
		defer delete(buffer)
		decoded, decode_err := host.read_reducer_args(Scheduled_Concurrency_Row, args, buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid scheduled reducer arguments")
		return handle_insert_scheduled_concurrency_row_reducer(caller, decoded, error)
	}
	if id == 3 {
		args_length: u32
		if args != host.INVALID_BYTES_SOURCE && host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		if args_length != 0 do return host.reducer_fail(error, "unexpected reducer arguments")
		return handle_schedule_procedure_then_reducer(caller, error)
	}
	if id == 4 {
		args_length: u32
		if args != host.INVALID_BYTES_SOURCE && host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		if args_length != 0 do return host.reducer_fail(error, "unexpected reducer arguments")
		return handle_schedule_procedure_update_while_inflight(caller, error)
	}
	if id != 0 do return host.reducer_fail(error, "unknown reducer id")
	args_length: u32
	if args != host.INVALID_BYTES_SOURCE && host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
	if args_length != 0 do return host.reducer_fail(error, "unexpected reducer arguments")
	return handle_schedule_proc_reducer(caller, error)
}

@(export, link_name = "__call_procedure__")
call_procedure :: proc "c" (
	id: uint,
	sender_0, sender_1, sender_2, sender_3: u64,
	conn_id_0, conn_id_1: u64,
	timestamp: u64,
	args: host.Bytes_Source,
	result: host.Bytes_Sink,
) -> i16 {
	context = host.scratch_context()
	caller := host.procedure_context(sender_0, sender_1, sender_2, sender_3, conn_id_0, conn_id_1, timestamp)
	if id == 0 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return -1
		buffer := make([]u8, int(args_length))
		defer delete(buffer)
		decoded, decode_err := host.read_reducer_args(Add_Args, args, buffer)
		if decode_err != .None do return -1
		value := handle_return_primitive_procedure(caller, decoded)
		result_buffer: [16]u8
		if host.write_procedure_result(u32, result, value, result_buffer[:]) != .None do return -1
		return 0
	}
	if id == 1 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return -1
		buffer := make([]u8, int(args_length))
		defer delete(buffer)
		decoded, decode_err := host.read_reducer_args(Point_Args, args, buffer)
		if decode_err != .None do return -1
		value := handle_return_struct_procedure(caller, decoded)
		result_buffer: [32]u8
		if host.write_procedure_result(Return_Point, result, value, result_buffer[:]) != .None do return -1
		return 0
	}
	if id == 2 do return -1
	if id == 3 {
		args_length: u32
		if args != host.INVALID_BYTES_SOURCE && host.bytes_source_remaining_length(args, &args_length) != 0 do return -1
		if args_length != 0 do return -1
		decoded: No_Args
		value, ok := handle_insert_with_tx_commit_procedure(caller, decoded)
		if !ok do return -1
		result_buffer: [16]u8
		if host.write_procedure_result(u64, result, value, result_buffer[:]) != .None do return -1
		return 0
	}
	if id == 4 {
		args_length: u32
		if args != host.INVALID_BYTES_SOURCE && host.bytes_source_remaining_length(args, &args_length) != 0 do return -1
		if args_length != 0 do return -1
		decoded: No_Args
		value, ok := handle_insert_with_tx_rollback_procedure(caller, decoded)
		if !ok do return -1
		result_buffer: [16]u8
		if host.write_procedure_result(u64, result, value, result_buffer[:]) != .None do return -1
		return 0
	}
	if id == 5 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return -1
		buffer := make([]u8, int(args_length))
		defer delete(buffer)
		decoded, decode_err := host.read_reducer_args(Schema_Args, args, buffer)
		if decode_err != .None do return -1
		value, ok := handle_read_my_schema_procedure(caller, decoded)
		if !ok do return -1
		result_buffer: [65_536]u8
		if host.write_procedure_result(string, result, value, result_buffer[:]) != .None do return -1
		return 0
	}
	if id == 6 {
		args_length: u32
		if args != host.INVALID_BYTES_SOURCE && host.bytes_source_remaining_length(args, &args_length) != 0 do return -1
		if args_length != 0 do return -1
		value := handle_invalid_request_procedure(caller, No_Args{})
		result_buffer: [128]u8
		if host.write_procedure_result(string, result, value, result_buffer[:]) != .None do return -1
		return 0
	}
	if id == 7 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return -1
		buffer := make([]u8, int(args_length))
		defer delete(buffer)
		decoded, decode_err := host.read_reducer_args(Scheduled_Row, args, buffer)
		if decode_err != .None do return -1
		if !handle_scheduled_proc(caller, decoded) do return -1
		return 0
	}
	if id == 8 {
		args_length: u32
		if args != host.INVALID_BYTES_SOURCE && host.bytes_source_remaining_length(args, &args_length) != 0 do return -1
		if args_length != 0 do return -1
		if !handle_procedure_sleep_between_inserts(&caller) do return -1
		return 0
	}
	if id == 9 {
		args_length: u32
		if args != host.INVALID_BYTES_SOURCE && host.bytes_source_remaining_length(args, &args_length) != 0 do return -1
		if args_length != 0 do return -1
		if !handle_procedure_schedule_reducer_between_inserts(&caller) do return -1
		return 0
	}
	if id == 10 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return -1
		buffer := make([]u8, int(args_length))
		defer delete(buffer)
		decoded, decode_err := host.read_reducer_args(Scheduled_Procedure_Concurrency_Row, args, buffer)
		if decode_err != .None do return -1
		if !handle_scheduled_procedure_concurrency(&caller, decoded) do return -1
		return 0
	}
	return -1
}
