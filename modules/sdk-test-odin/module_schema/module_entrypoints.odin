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
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Increment_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_increment_reducer(caller, decoded, error)
	}
	if id == 1 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Set_Value_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_set_value_reducer(caller, decoded, error)
	}
	if id == 2 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Delete_Value_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_delete_value_reducer(caller, decoded, error)
	}
	if id == 3 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Record_Values_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_record_values_reducer(caller, decoded, error)
	}
	if id == 4 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Record_Vector_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_record_vector_reducer(caller, decoded, error)
	}
	if id == 5 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Record_Option_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_record_option_reducer(caller, decoded, error)
	}
	if id == 6 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Fail_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_fail_operation_reducer(caller, decoded, error)
	}
	if id == 7 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Record_Enum_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_record_enum_reducer(caller, decoded, error)
	}
	if id == 8 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Record_String_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_record_string_reducer(caller, decoded, error)
	}
	if id == 9 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Record_Sum_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_record_sum_reducer(caller, decoded, error)
	}
	if id == 10 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Record_Generated_Uuid_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_record_generated_uuid_reducer(caller, decoded, error)
	}
	if id == 11 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Record_Generated_Uuid_V7_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_record_generated_uuid_v7_reducer(caller, decoded, error)
	}
	if id == 12 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Update_Values_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_update_values_reducer(caller, decoded, error)
	}
	if id == 13 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Delete_Values_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_delete_values_reducer(caller, decoded, error)
	}
	if id == 14 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Update_Uuid_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_update_uuid_reducer(caller, decoded, error)
	}
	if id == 15 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Delete_Uuid_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_delete_uuid_reducer(caller, decoded, error)
	}
	if id == 16 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Insert_Test_User_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_insert_test_user_reducer(caller, decoded, error)
	}
	if id == 17 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Update_Enum_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_update_enum_reducer(caller, decoded, error)
	}
	if id == 18 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Insert_Join_R_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_insert_join_r_reducer(caller, decoded, error)
	}
	if id == 19 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Insert_Join_S_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_insert_join_s_reducer(caller, decoded, error)
	}
	if id == 20 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Update_Join_R_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_update_join_r_reducer(caller, decoded, error)
	}
	if id == 21 {
		args_length: u32
		if host.bytes_source_remaining_length(args, &args_length) != 0 do return host.reducer_fail(error, "failed to read reducer arguments")
		arg_buffer := make([]u8, int(args_length))
		defer delete(arg_buffer)
		decoded, decode_err := host.read_reducer_args(Insert_Join_T_Args, args, arg_buffer)
		if decode_err != .None do return host.reducer_fail(error, "invalid reducer arguments")
		return handle_insert_join_t_reducer(caller, decoded, error)
	}
	return host.reducer_fail(error, "unknown reducer id")
}
