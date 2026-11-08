package module_schema

import "base:runtime"
import "stdb:host"

Counters :: struct {
	id: u64,
	value: u64,
}

Increment_Args :: struct {
	id: u64,
}

Set_Value_Args :: struct {
	id: u64,
	value: u64,
}

Delete_Value_Args :: struct {
	id: u64,
	value: u64,
}

Test_Values :: struct {
	uuid: u128,
	id: u64,
	score: u64,
	identity: host.Identity,
	connection_id: host.Connection_Id,
	timestamp: host.Timestamp,
}

Test_User :: struct {
	identity: host.Identity,
	name: string,
}

Insert_Test_User_Args :: struct {
	name: string,
	identity: host.Identity,
}

Join_R :: struct {
	id: u64,
	data: i32,
}

Join_S :: struct {
	r_id: u64,
	score: i32,
}

Join_T :: struct {
	r_id: u64,
}

Insert_Join_R_Args :: struct {
	id: u64,
	data: i32,
}

Insert_Join_S_Args :: struct {
	r_id: u64,
	score: i32,
}

Insert_Join_T_Args :: struct {
	r_id: u64,
}

Update_Join_R_Args :: struct {
	id: u64,
	data: i32,
}

Record_Values_Args :: struct {
	uuid: u128,
	id: u64,
	score: u64,
}

Update_Values_Args :: struct {
	id: u64,
	score: u64,
}

Delete_Values_Args :: struct {
	id: u64,
}

Update_Uuid_Args :: struct {
	uuid: u128,
	id: u64,
}

Delete_Uuid_Args :: struct {
	id: u64,
}

Record_Generated_Uuid_Args :: struct {
	id: u64,
}

Record_Generated_Uuid_V7_Args :: struct {
	id: u64,
}

Test_Vector :: struct {
	id: u64,
	values: []i32,
}

Record_Vector_Args :: struct {
	id: u64,
	values: []i32,
}

Test_Option :: struct {
	id: u64,
	value: runtime.Maybe(i32),
}

Record_Option_Args :: struct {
	id: u64,
	value: runtime.Maybe(i32),
}

Test_Color :: enum u8 {
	Red,
	Green,
	Blue,
}

Test_Enum :: struct {
	color: Test_Color,
	data: u64,
}

Record_Enum_Args :: struct {
	color: Test_Color,
	data: u64,
}

Update_Enum_Args :: struct {
	color: Test_Color,
	data: u64,
}

Test_String :: struct {
	id: u64,
	text: string,
}

Record_String_Args :: struct {
	id: u64,
	text: string,
}

Test_Choice_Number :: struct {
	value: i32,
}

Test_Choice_Text :: struct {
	value: string,
}

Test_Choice :: union #no_nil {Test_Choice_Number, Test_Choice_Text}

Test_Sum :: struct {
	id: u64,
	choice: Test_Choice,
}

Record_Sum_Args :: struct {
	id: u64,
	choice: Test_Choice,
}

Fail_Args :: struct {
	id: u64,
}

write_module_definition :: proc(description: host.Bytes_Sink) -> (host.Status, bool) {
	context = host.scratch_context()
	reducers: [dynamic]host.Reducer_Definition
	defer for reducer in reducers do delete(reducer.args)
	reducer_0, reducer_err_0 := host.typed_reducer_definition(Increment_Args, "increment", .None, private = false, row_table = "")
	if reducer_err_0 != .None do return host.Status(0), false
	append(&reducers, reducer_0)
	reducer_1, reducer_err_1 := host.typed_reducer_definition(Set_Value_Args, "set_value", .None, private = false, row_table = "")
	if reducer_err_1 != .None do return host.Status(0), false
	append(&reducers, reducer_1)
	reducer_2, reducer_err_2 := host.typed_reducer_definition(Delete_Value_Args, "delete_value", .None, private = false, row_table = "")
	if reducer_err_2 != .None do return host.Status(0), false
	append(&reducers, reducer_2)
	reducer_3, reducer_err_3 := host.typed_reducer_definition(Record_Values_Args, "record_values", .None, private = false, row_table = "")
	if reducer_err_3 != .None do return host.Status(0), false
	append(&reducers, reducer_3)
	reducer_4, reducer_err_4 := host.typed_reducer_definition(Record_Vector_Args, "record_vector", .None, private = false, row_table = "")
	if reducer_err_4 != .None do return host.Status(0), false
	append(&reducers, reducer_4)
	reducer_5, reducer_err_5 := host.typed_reducer_definition(Record_Option_Args, "record_option", .None, private = false, row_table = "")
	if reducer_err_5 != .None do return host.Status(0), false
	append(&reducers, reducer_5)
	reducer_6, reducer_err_6 := host.typed_reducer_definition(Fail_Args, "fail_operation", .None, private = false, row_table = "")
	if reducer_err_6 != .None do return host.Status(0), false
	append(&reducers, reducer_6)
	reducer_7, reducer_err_7 := host.typed_reducer_definition(Record_Enum_Args, "record_enum", .None, private = false, row_table = "")
	if reducer_err_7 != .None do return host.Status(0), false
	append(&reducers, reducer_7)
	reducer_8, reducer_err_8 := host.typed_reducer_definition(Record_String_Args, "record_string", .None, private = false, row_table = "")
	if reducer_err_8 != .None do return host.Status(0), false
	append(&reducers, reducer_8)
	reducer_9, reducer_err_9 := host.typed_reducer_definition(Record_Sum_Args, "record_sum", .None, private = false, row_table = "")
	if reducer_err_9 != .None do return host.Status(0), false
	append(&reducers, reducer_9)
	reducer_uuid, reducer_uuid_err := host.typed_reducer_definition(Record_Generated_Uuid_Args, "record_generated_uuid", .None, private = false, row_table = "")
	if reducer_uuid_err != .None do return host.Status(0), false
	append(&reducers, reducer_uuid)
	reducer_uuid_v7, reducer_uuid_v7_err := host.typed_reducer_definition(Record_Generated_Uuid_V7_Args, "record_generated_uuid_v7", .None, private = false, row_table = "")
	if reducer_uuid_v7_err != .None do return host.Status(0), false
	append(&reducers, reducer_uuid_v7)
	update_values, update_values_err := host.typed_reducer_definition(Update_Values_Args, "update_values", .None, private = false, row_table = "")
	if update_values_err != .None do return host.Status(0), false
	append(&reducers, update_values)
	delete_values, delete_values_err := host.typed_reducer_definition(Delete_Values_Args, "delete_values", .None, private = false, row_table = "")
	if delete_values_err != .None do return host.Status(0), false
	append(&reducers, delete_values)
	update_uuid, update_uuid_err := host.typed_reducer_definition(Update_Uuid_Args, "update_uuid", .None, private = false, row_table = "")
	if update_uuid_err != .None do return host.Status(0), false
	append(&reducers, update_uuid)
	delete_uuid, delete_uuid_err := host.typed_reducer_definition(Delete_Uuid_Args, "delete_uuid", .None, private = false, row_table = "")
	if delete_uuid_err != .None do return host.Status(0), false
	append(&reducers, delete_uuid)
	insert_test_user, insert_test_user_err := host.typed_reducer_definition(Insert_Test_User_Args, "insert_test_user", .None, private = false, row_table = "")
	if insert_test_user_err != .None do return host.Status(0), false
	append(&reducers, insert_test_user)
	update_enum, update_enum_err := host.typed_reducer_definition(Update_Enum_Args, "update_enum", .None, private = false, row_table = "")
	if update_enum_err != .None do return host.Status(0), false
	append(&reducers, update_enum)
	insert_join_r, insert_join_r_err := host.typed_reducer_definition(Insert_Join_R_Args, "insert_join_r", .None, private = false, row_table = "")
	if insert_join_r_err != .None do return host.Status(0), false
	append(&reducers, insert_join_r)
	insert_join_s, insert_join_s_err := host.typed_reducer_definition(Insert_Join_S_Args, "insert_join_s", .None, private = false, row_table = "")
	if insert_join_s_err != .None do return host.Status(0), false
	append(&reducers, insert_join_s)
	update_join_r, update_join_r_err := host.typed_reducer_definition(Update_Join_R_Args, "update_join_r", .None, private = false, row_table = "")
	if update_join_r_err != .None do return host.Status(0), false
	append(&reducers, update_join_r)
	insert_join_t, insert_join_t_err := host.typed_reducer_definition(Insert_Join_T_Args, "insert_join_t", .None, private = false, row_table = "")
	if insert_join_t_err != .None do return host.Status(0), false
	append(&reducers, insert_join_t)
	tables: [dynamic]host.Table_Definition
	defer for table in tables do host.delete_table_definition(table)
	index_columns := [?]u16{0}
	index := host.Table_Index{source_name = "counters_id_idx_btree", accessor_name = "by_id", algorithm = .BTree, columns = index_columns[: ]}
	indexes := [?]host.Table_Index{index}
	unique_columns := [?]u16{0}
	unique := host.Unique_Constraint{columns = unique_columns[: ]}
	unique_constraints := [?]host.Unique_Constraint{unique}
	table, table_err := host.typed_table_definition(Counters, "counters", .Public, []u16{0}, indexes[:], unique_constraints[:])
	if table_err != .None do return host.Status(0), false
	append(&tables, table)
	values_key_columns := [?]u16{1}
	values_index := host.Table_Index{source_name = "test_values_id_idx_btree", accessor_name = "by_id", algorithm = .BTree, columns = values_key_columns[:]}
	values_indexes := [?]host.Table_Index{values_index}
	values_unique := host.Unique_Constraint{columns = values_key_columns[:]}
	values_unique_constraints := [?]host.Unique_Constraint{values_unique}
	values_table, values_table_err := host.typed_table_definition(Test_Values, "test_values", .Public, values_key_columns[:], values_indexes[:], values_unique_constraints[:])
	if values_table_err != .None do return host.Status(0), false
	append(&tables, values_table)
	user_key_columns := [?]u16{0}
	user_index := host.Table_Index{source_name = "test_users_identity_idx_btree", accessor_name = "by_identity", algorithm = .BTree, columns = user_key_columns[:]}
	user_indexes := [?]host.Table_Index{user_index}
	user_unique := host.Unique_Constraint{columns = user_key_columns[:]}
	user_unique_constraints := [?]host.Unique_Constraint{user_unique}
	user_table, user_table_err := host.typed_table_definition(Test_User, "test_users", .Public, user_key_columns[:], user_indexes[:], user_unique_constraints[:])
	if user_table_err != .None do return host.Status(0), false
	append(&tables, user_table)
	join_r_key_columns := [?]u16{0}
	join_r_index := host.Table_Index{source_name = "join_r_id_idx_btree", accessor_name = "by_id", algorithm = .BTree, columns = join_r_key_columns[:]}
	join_r_indexes := [?]host.Table_Index{join_r_index}
	join_r_unique := host.Unique_Constraint{columns = join_r_key_columns[:]}
	join_r_unique_constraints := [?]host.Unique_Constraint{join_r_unique}
	join_r_table, join_r_table_err := host.typed_table_definition(Join_R, "join_r", .Public, join_r_key_columns[:], join_r_indexes[:], join_r_unique_constraints[:])
	if join_r_table_err != .None do return host.Status(0), false
	append(&tables, join_r_table)
	join_s_key_columns := [?]u16{0}
	join_s_index := host.Table_Index{source_name = "join_s_r_id_idx_btree", accessor_name = "by_r_id", algorithm = .BTree, columns = join_s_key_columns[:]}
	join_s_indexes := [?]host.Table_Index{join_s_index}
	join_s_table, join_s_table_err := host.typed_table_definition(Join_S, "join_s", .Public, nil, join_s_indexes[:], nil)
	if join_s_table_err != .None do return host.Status(0), false
	append(&tables, join_s_table)
	join_t_key_columns := [?]u16{0}
	join_t_index := host.Table_Index{source_name = "join_t_r_id_idx_btree", accessor_name = "by_r_id", algorithm = .BTree, columns = join_t_key_columns[:]}
	join_t_indexes := [?]host.Table_Index{join_t_index}
	join_t_unique := host.Unique_Constraint{columns = join_t_key_columns[:]}
	join_t_unique_constraints := [?]host.Unique_Constraint{join_t_unique}
	join_t_table, join_t_table_err := host.typed_table_definition(Join_T, "join_t", .Public, join_t_key_columns[:], join_t_indexes[:], join_t_unique_constraints[:])
	if join_t_table_err != .None do return host.Status(0), false
	append(&tables, join_t_table)
	vector_table, vector_table_err := host.typed_table_definition(Test_Vector, "test_vectors", .Public, nil, nil, nil)
	if vector_table_err != .None do return host.Status(0), false
	append(&tables, vector_table)
	option_table, option_table_err := host.typed_table_definition(Test_Option, "test_options", .Public, nil, nil, nil)
	if option_table_err != .None do return host.Status(0), false
	append(&tables, option_table)
	enum_index_columns := [?]u16{0}
	enum_index := host.Table_Index{source_name = "test_enums_color_idx_btree", accessor_name = "by_color", algorithm = .BTree, columns = enum_index_columns[:]}
	enum_indexes := [?]host.Table_Index{enum_index}
	enum_unique := host.Unique_Constraint{columns = enum_index_columns[:]}
	enum_unique_constraints := [?]host.Unique_Constraint{enum_unique}
	enum_table, enum_table_err := host.typed_table_definition(Test_Enum, "test_enums", .Public, []u16{0}, enum_indexes[:], enum_unique_constraints[:])
	if enum_table_err != .None do return host.Status(0), false
	append(&tables, enum_table)
	string_table, string_table_err := host.typed_table_definition(Test_String, "test_strings", .Public, nil, nil, nil)
	if string_table_err != .None do return host.Status(0), false
	append(&tables, string_table)
	sum_table, sum_table_err := host.typed_table_definition(Test_Sum, "test_sums", .Public, nil, nil, nil)
	if sum_table_err != .None do return host.Status(0), false
	append(&tables, sum_table)
	procedures: [dynamic]host.Procedure_Definition
	defer for procedure in procedures do delete(procedure.args)
	views: [dynamic]host.View_Definition
	defer for view in views do delete(view.args)
	handlers: []string = nil
	routes: [dynamic]host.Http_Route
	environment: [dynamic]host.Environment_Definition
	rls_policies := [?]host.Row_Level_Security_Definition{{sql = "SELECT * FROM test_users WHERE identity = :sender"}}
	sum_variants := [?]host.Sum_Variant_Definition{
		{info = type_info_of(Test_Choice_Number), name = "Number"},
		{info = type_info_of(Test_Choice_Text), name = "Text"},
	}
	enum_names := [?]string{"Red", "Green", "Blue"}
	enum_variants := [?]host.Enum_Variant_Definition{{info = type_info_of(Test_Color), names = enum_names[:]}}
	return host.write_module_def_all(description, reducers[:], tables[:], views[:], procedures[:], handlers[:], routes[:], environment[:], rls_policies[:], nil, sum_variants[:], enum_variants[:])
}
