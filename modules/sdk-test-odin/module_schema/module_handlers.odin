package module_schema

import "core:strings"
import "stdb:host"

handle_increment_reducer :: proc(ctx: host.Reducer_Context, args: Increment_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Counters, "counters", "counters_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid counters table")

	key_buffer: [32]u8
	scan_buffer: [128]u8
	scan, scan_status, scan_err := host.typed_scan_index_point(Counters, "counters_id_idx_btree", args.id, key_buffer[:], scan_buffer[:])
	if scan_err != .None || scan_status != host.Status(0) do return host.reducer_fail(error, "counter lookup failed")
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

handle_set_value_reducer :: proc(ctx: host.Reducer_Context, args: Set_Value_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Counters, "counters", "counters_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid counters table")
	row_buffer: [128]u8
	status, update_err := host.typed_update(Counters, table, Counters{id = args.id, value = args.value}, row_buffer[:])
		if update_err != .None || status != host.Status(0) do return host.reducer_fail(error, "counter update failed")
	return 0
}

handle_delete_value_reducer :: proc(ctx: host.Reducer_Context, args: Delete_Value_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Counters, "counters", "counters_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid counters table")
	row_buffer: [128]u8
	_, status, delete_err := host.typed_delete(Counters, table, Counters{id = args.id, value = args.value}, row_buffer[:])
	if delete_err != .None || status != host.Status(0) do return host.reducer_fail(error, "counter delete failed")
	return 0
}

handle_record_values_reducer :: proc(ctx: host.Reducer_Context, args: Record_Values_Args, error: host.Bytes_Sink) -> i16 {
	if args.uuid != 0 && args.uuid != 0x00112233445566778899aabbccddeeff do return host.reducer_fail(error, "UUID reducer argument changed")
	table, table_err := host.typed_table(Test_Values, "test_values", "")
	if table_err != .None do return host.reducer_fail(error, "invalid test values table")
	buffer: [256]u8
	row := Test_Values{
		uuid = args.uuid,
		id = args.id,
		score = 0,
		identity = ctx.sender,
		connection_id = ctx.connection_id,
		timestamp = ctx.timestamp,
	}
	status, insert_err := host.typed_insert(Test_Values, table, row, buffer[:])
	if insert_err != .None {
		#partial switch insert_err {
		case .Buffer_Too_Small:
			return host.reducer_fail(error, "test values codec insert: buffer too small")
		case .Unsupported_Type:
			return host.reducer_fail(error, "test values codec insert: unsupported type")
		case .Unsupported_Endianness:
			return host.reducer_fail(error, "test values codec insert: unsupported endianness")
		case .Invalid_Boolean:
			return host.reducer_fail(error, "test values codec insert: invalid boolean")
		case .Invalid_Utf8:
			return host.reducer_fail(error, "test values codec insert: invalid UTF-8")
		case:
			return host.reducer_fail(error, "test values codec insert: other codec error")
		}
	}
	if status != host.Status(0) do return host.reducer_fail(error, "test values datastore insert failed")
	return 0
}

handle_record_generated_uuid_reducer :: proc(ctx: host.Reducer_Context, args: Record_Generated_Uuid_Args, error: host.Bytes_Sink) -> i16 {
	table, table_err := host.typed_table(Test_Values, "test_values", "")
	if table_err != .None do return host.reducer_fail(error, "invalid test values table")
	mutable_ctx := ctx
	buffer: [256]u8
	row := Test_Values{
		uuid = host.context_new_uuid_v4(&mutable_ctx),
		id = args.id,
		score = 0,
		identity = ctx.sender,
		connection_id = ctx.connection_id,
		timestamp = ctx.timestamp,
	}
	status, insert_err := host.typed_insert(Test_Values, table, row, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "generated UUID insert failed")
	return 0
}

handle_record_generated_uuid_v7_reducer :: proc(ctx: host.Reducer_Context, args: Record_Generated_Uuid_V7_Args, error: host.Bytes_Sink) -> i16 {
	table, table_err := host.typed_table(Test_Values, "test_values", "")
	if table_err != .None do return host.reducer_fail(error, "invalid test values table")
	mutable_ctx := ctx
	uuid, uuid_err := host.context_new_uuid_v7(&mutable_ctx)
	if uuid_err != .None do return host.reducer_fail(error, "UUIDv7 generation failed")
	buffer: [256]u8
	row := Test_Values{
		uuid = uuid,
		id = args.id,
		score = 0,
		identity = ctx.sender,
		connection_id = ctx.connection_id,
		timestamp = ctx.timestamp,
	}
	status, insert_err := host.typed_insert(Test_Values, table, row, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "generated UUIDv7 insert failed")
	return 0
}

find_values_row :: proc(id: u64) -> (Test_Values, bool, bool) {
	key_buffer: [32]u8
	scan_buffer: [256]u8
	scan, scan_status, scan_err := host.typed_scan_index_point(Test_Values, "test_values_id_idx_btree", id, key_buffer[:], scan_buffer[:])
	if scan_err != .None || scan_status != host.Status(0) do return Test_Values{}, false, false
	row, found, status, next_err := host.typed_scan_next(Test_Values, &scan)
	_ = host.typed_scan_close(Test_Values, &scan)
	return row, found, next_err == .None && (status == 0 || status == -1)
}

handle_update_values_reducer :: proc(ctx: host.Reducer_Context, args: Update_Values_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_Values, "test_values", "test_values_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid test values table")
	row, found, lookup_ok := find_values_row(args.id)
	if !lookup_ok || !found do return host.reducer_fail(error, "test values row not found")
	row.score = args.score
	buffer: [256]u8
	status, update_err := host.typed_update(Test_Values, table, row, buffer[:])
	if update_err != .None || status != host.Status(0) do return host.reducer_fail(error, "test values update failed")
	return 0
}

handle_delete_values_reducer :: proc(ctx: host.Reducer_Context, args: Delete_Values_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_Values, "test_values", "test_values_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid test values table")
	row, found, lookup_ok := find_values_row(args.id)
	if !lookup_ok || !found do return host.reducer_fail(error, "test values row not found")
	buffer: [256]u8
	_, status, delete_err := host.typed_delete(Test_Values, table, row, buffer[:])
	if delete_err != .None || status != host.Status(0) do return host.reducer_fail(error, "test values delete failed")
	return 0
}

handle_update_uuid_reducer :: proc(ctx: host.Reducer_Context, args: Update_Uuid_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_Values, "test_values", "test_values_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid test values table")
	row, found, lookup_ok := find_values_row(args.id)
	if !lookup_ok || !found do return host.reducer_fail(error, "test values row not found")
	row.uuid = args.uuid
	buffer: [256]u8
	status, update_err := host.typed_update(Test_Values, table, row, buffer[:])
	if update_err != .None || status != host.Status(0) do return host.reducer_fail(error, "UUID update failed")
	return 0
}

handle_delete_uuid_reducer :: proc(ctx: host.Reducer_Context, args: Delete_Uuid_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_Values, "test_values", "test_values_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid test values table")
	row, found, lookup_ok := find_values_row(args.id)
	if !lookup_ok || !found do return host.reducer_fail(error, "test values row not found")
	buffer: [256]u8
	_, status, delete_err := host.typed_delete(Test_Values, table, row, buffer[:])
	if delete_err != .None || status != host.Status(0) do return host.reducer_fail(error, "UUID delete failed")
	return 0
}

handle_insert_test_user_reducer :: proc(ctx: host.Reducer_Context, args: Insert_Test_User_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_User, "test_users", "test_users_identity_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid test users table")
	name, clone_err := strings.clone(args.name)
	if clone_err != nil do return host.reducer_fail(error, "user name allocation failed")
	defer delete(name)
	buffer: [256]u8
	status, insert_err := host.typed_insert(Test_User, table, Test_User{identity = args.identity, name = name}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "test user insert failed")
	return 0
}

handle_insert_join_r_reducer :: proc(ctx: host.Reducer_Context, args: Insert_Join_R_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Join_R, "join_r", "join_r_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid join_r table")
	buffer: [64]u8
	status, insert_err := host.typed_insert(Join_R, table, Join_R{id = args.id, data = args.data}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "join_r insert failed")
	return 0
}

handle_insert_join_s_reducer :: proc(ctx: host.Reducer_Context, args: Insert_Join_S_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Join_S, "join_s", "join_s_r_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid join_s table")
	buffer: [64]u8
	status, insert_err := host.typed_insert(Join_S, table, Join_S{r_id = args.r_id, score = args.score}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "join_s insert failed")
	return 0
}

handle_update_join_r_reducer :: proc(ctx: host.Reducer_Context, args: Update_Join_R_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Join_R, "join_r", "join_r_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid join_r table")
	key_buffer: [32]u8
	scan_buffer: [128]u8
	scan, scan_status, scan_err := host.typed_scan_index_point(Join_R, "join_r_id_idx_btree", args.id, key_buffer[:], scan_buffer[:])
	if scan_err != .None || scan_status != host.Status(0) do return host.reducer_fail(error, "join_r lookup failed")
	row, found, next_status, next_err := host.typed_scan_next(Join_R, &scan)
	_ = host.typed_scan_close(Join_R, &scan)
	if next_err != .None || (next_status != 0 && next_status != -1) || !found do return host.reducer_fail(error, "join_r row not found")
	row.data = args.data
	buffer: [64]u8
	status, update_err := host.typed_update(Join_R, table, row, buffer[:])
	if update_err != .None || status != host.Status(0) do return host.reducer_fail(error, "join_r update failed")
	return 0
}

handle_insert_join_t_reducer :: proc(ctx: host.Reducer_Context, args: Insert_Join_T_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Join_T, "join_t", "join_t_r_id_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid join_t table")
	buffer: [64]u8
	status, insert_err := host.typed_insert(Join_T, table, Join_T{r_id = args.r_id}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "join_t insert failed")
	return 0
}

handle_record_vector_reducer :: proc(ctx: host.Reducer_Context, args: Record_Vector_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	defer delete(args.values)
	table, table_err := host.typed_table(Test_Vector, "test_vectors", "")
	if table_err != .None do return host.reducer_fail(error, "invalid test vectors table")
	buffer: [65_536]u8
	status, insert_err := host.typed_insert(Test_Vector, table, Test_Vector{id = args.id, values = args.values}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "test vector insert failed")
	return 0
}

handle_record_option_reducer :: proc(ctx: host.Reducer_Context, args: Record_Option_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_Option, "test_options", "")
	if table_err != .None do return host.reducer_fail(error, "invalid test options table")
	buffer: [128]u8
	status, insert_err := host.typed_insert(Test_Option, table, Test_Option{id = args.id, value = args.value}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "test option insert failed")
	return 0
}

handle_fail_operation_reducer :: proc(ctx: host.Reducer_Context, args: Fail_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	_ = args
	return host.reducer_fail(error, "intentional SDK test failure")
}

handle_record_enum_reducer :: proc(ctx: host.Reducer_Context, args: Record_Enum_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_Enum, "test_enums", "")
	if table_err != .None do return host.reducer_fail(error, "invalid test enum table")
	buffer: [64]u8
	status, insert_err := host.typed_insert(Test_Enum, table, Test_Enum{color = args.color, data = args.data}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "test enum insert failed")
	return 0
}

handle_update_enum_reducer :: proc(ctx: host.Reducer_Context, args: Update_Enum_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_Enum, "test_enums", "test_enums_color_idx_btree")
	if table_err != .None do return host.reducer_fail(error, "invalid test enum table")
	buffer: [64]u8
	status, update_err := host.typed_update(Test_Enum, table, Test_Enum{color = args.color, data = args.data}, buffer[:])
	if update_err != .None || status != host.Status(0) do return host.reducer_fail(error, "test enum update failed")
	return 0
}

handle_record_string_reducer :: proc(ctx: host.Reducer_Context, args: Record_String_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_String, "test_strings", "")
	if table_err != .None do return host.reducer_fail(error, "invalid test strings table")
	text, clone_err := strings.clone(args.text)
	if clone_err != nil do return host.reducer_fail(error, "test string allocation failed")
	defer delete(text)
	buffer: [128]u8
	status, insert_err := host.typed_insert(Test_String, table, Test_String{id = args.id, text = text}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "test string insert failed")
	return 0
}

handle_record_sum_reducer :: proc(ctx: host.Reducer_Context, args: Record_Sum_Args, error: host.Bytes_Sink) -> i16 {
	_ = ctx
	table, table_err := host.typed_table(Test_Sum, "test_sums", "")
	if table_err != .None do return host.reducer_fail(error, "invalid test sums table")
	buffer: [256]u8
	status, insert_err := host.typed_insert(Test_Sum, table, Test_Sum{id = args.id, choice = args.choice}, buffer[:])
	if insert_err != .None || status != host.Status(0) do return host.reducer_fail(error, "test sum insert failed")
	return 0
}
