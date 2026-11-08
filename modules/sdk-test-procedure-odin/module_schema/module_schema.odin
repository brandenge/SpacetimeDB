package module_schema

import "base:runtime"
import "stdb:host"

Add_Args :: struct {
	left: u32,
	right: u32,
}

No_Args :: struct {}

Schema_Args :: struct {
	uri: string,
}

Point_Args :: struct {
	x: u32,
	y: u32,
}

Return_Point :: struct {
	x: u32,
	y: u32,
}

Procedure_Row :: struct {
	id: u64,
}

Scheduled_Row :: struct {
	scheduled_id: u64,
	scheduled_at: host.Schedule_At,
	reducer_ts: host.Timestamp,
	x: u8,
	y: u8,
}

Scheduled_Result :: struct {
	id: u64,
	reducer_ts: host.Timestamp,
	procedure_ts: host.Timestamp,
	x: u8,
	y: u8,
}

Procedure_Concurrency_Row :: struct {
	insertion_order: u32,
	insertion_context: string,
}

Insert_Concurrency_Args :: struct {
	insertion_context: string,
}

Scheduled_Concurrency_Row :: struct {
	scheduled_id: u64,
	scheduled_at: host.Schedule_At,
	insertion_context: string,
}

Scheduled_Procedure_Concurrency_Row :: struct {
	scheduled_id: u64,
	scheduled_at: host.Schedule_At,
	run: u8,
}

write_module_definition :: proc(description: host.Bytes_Sink) -> (host.Status, bool) {
	context = host.scratch_context()
	reducers: [dynamic]host.Reducer_Definition
	schedule_reducer, schedule_reducer_err := host.typed_reducer_definition(No_Args, "schedule_proc", .None, private = false)
	if schedule_reducer_err != .None do return host.Status(0), false
	append(&reducers, schedule_reducer)
	insert_concurrency_row, insert_concurrency_row_err := host.typed_reducer_definition(Insert_Concurrency_Args, "insert_reducer_row", .None, private = false)
	if insert_concurrency_row_err != .None do return host.Status(0), false
	append(&reducers, insert_concurrency_row)
	scheduled_concurrency_args := make([]host.Reducer_Argument, 1)
	scheduled_concurrency_args[0] = host.Reducer_Argument{name = "arg", table_ref = "scheduled_concurrency_rows"}
	append(&reducers, host.Reducer_Definition{name = "insert_scheduled_concurrency_row", args = scheduled_concurrency_args, private = true, row_table = "scheduled_concurrency_rows"})
	schedule_procedure_reducer, schedule_procedure_reducer_err := host.typed_reducer_definition(No_Args, "schedule_procedure_then_reducer", .None, private = false)
	if schedule_procedure_reducer_err != .None do return host.Status(0), false
	append(&reducers, schedule_procedure_reducer)
	schedule_update_reducer, schedule_update_reducer_err := host.typed_reducer_definition(No_Args, "schedule_procedure_update_while_inflight", .None, private = false)
	if schedule_update_reducer_err != .None do return host.Status(0), false
	append(&reducers, schedule_update_reducer)
	procedures: [dynamic]host.Procedure_Definition
	defer for procedure in procedures do delete(procedure.args)
	procedure, procedure_err := host.typed_procedure_definition(Add_Args, "return_primitive", type_info_of(u32))
	if procedure_err != .None do return host.Status(0), false
	append(&procedures, procedure)
	point, point_err := host.typed_procedure_definition(Point_Args, "return_struct", type_info_of(Return_Point))
	if point_err != .None do return host.Status(0), false
	append(&procedures, point)
	panic_procedure, panic_err := host.typed_procedure_definition(No_Args, "will_panic")
	if panic_err != .None do return host.Status(0), false
	append(&procedures, panic_procedure)
	commit_procedure, commit_err := host.typed_procedure_definition(No_Args, "insert_with_tx_commit", type_info_of(u64))
	if commit_err != .None do return host.Status(0), false
	append(&procedures, commit_procedure)
	rollback_procedure, rollback_err := host.typed_procedure_definition(No_Args, "insert_with_tx_rollback", type_info_of(u64))
	if rollback_err != .None do return host.Status(0), false
	append(&procedures, rollback_procedure)
	schema_procedure, schema_err := host.typed_procedure_definition(Schema_Args, "read_my_schema", type_info_of(string))
	if schema_err != .None do return host.Status(0), false
	append(&procedures, schema_procedure)
	invalid_request, invalid_request_err := host.typed_procedure_definition(No_Args, "invalid_request", type_info_of(string))
	if invalid_request_err != .None do return host.Status(0), false
	append(&procedures, invalid_request)
	scheduled_procedure_args := make([]host.Reducer_Argument, 1)
	scheduled_procedure_args[0] = host.Reducer_Argument{name = "arg", table_ref = "scheduled_rows"}
	append(&procedures, host.Procedure_Definition{name = "scheduled_proc", args = scheduled_procedure_args, private = true})
	interleaving_procedure, interleaving_procedure_err := host.typed_procedure_definition(No_Args, "procedure_sleep_between_inserts")
	if interleaving_procedure_err != .None do return host.Status(0), false
	append(&procedures, interleaving_procedure)
	scheduled_interleaving_procedure, scheduled_interleaving_procedure_err := host.typed_procedure_definition(No_Args, "procedure_schedule_reducer_between_inserts")
	if scheduled_interleaving_procedure_err != .None do return host.Status(0), false
	append(&procedures, scheduled_interleaving_procedure)
	scheduled_procedure_concurrency_args := make([]host.Reducer_Argument, 1)
	scheduled_procedure_concurrency_args[0] = host.Reducer_Argument{name = "arg", table_ref = "scheduled_procedure_concurrency_rows"}
	append(&procedures, host.Procedure_Definition{name = "scheduled_procedure_concurrency", args = scheduled_procedure_concurrency_args, private = true})
	tables: [dynamic]host.Table_Definition
	defer for table in tables do host.delete_table_definition(table)
	columns := [?]u16{0}
	index := host.Table_Index{source_name = "procedure_rows_id_idx_btree", accessor_name = "by_id", algorithm = .BTree, columns = columns[:]}
	indexes := [?]host.Table_Index{index}
	unique := host.Unique_Constraint{columns = columns[:]}
	unique_constraints := [?]host.Unique_Constraint{unique}
	table, table_err := host.typed_table_definition(Procedure_Row, "procedure_rows", .Public, columns[:], indexes[:], unique_constraints[:])
	if table_err != .None do return host.Status(0), false
	append(&tables, table)
	scheduled_key_columns := [?]u16{0}
	scheduled_key_index := host.Table_Index{source_name = "scheduled_rows_id_idx_btree", accessor_name = "by_id", algorithm = .BTree, columns = scheduled_key_columns[:]}
	scheduled_key_indexes := [?]host.Table_Index{scheduled_key_index}
	scheduled_key_unique := host.Unique_Constraint{columns = scheduled_key_columns[:]}
	scheduled_key_constraints := [?]host.Unique_Constraint{scheduled_key_unique}
	scheduled_table, scheduled_table_err := host.typed_table_definition(Scheduled_Row, "scheduled_rows", .Private, scheduled_key_columns[:], scheduled_key_indexes[:], scheduled_key_constraints[:])
	if scheduled_table_err != .None do return host.Status(0), false
	scheduled_table.auto_increment_columns = scheduled_key_columns[:]
	scheduled_table.scheduled_function = "scheduled_proc"
	scheduled_table.schedule_at_column = 1
	append(&tables, scheduled_table)
	result_key_columns := [?]u16{0}
	result_key_index := host.Table_Index{source_name = "scheduled_results_id_idx_btree", accessor_name = "by_id", algorithm = .BTree, columns = result_key_columns[:]}
	result_indexes := [?]host.Table_Index{result_key_index}
	result_unique := host.Unique_Constraint{columns = result_key_columns[:]}
	result_constraints := [?]host.Unique_Constraint{result_unique}
	result_table, result_table_err := host.typed_table_definition(Scheduled_Result, "scheduled_results", .Public, result_key_columns[:], result_indexes[:], result_constraints[:])
	if result_table_err != .None do return host.Status(0), false
	append(&tables, result_table)
	concurrency_auto_columns := [?]u16{0}
	concurrency_table, concurrency_table_err := host.typed_table_definition(Procedure_Concurrency_Row, "procedure_concurrency_rows", .Public, nil, nil, nil)
	if concurrency_table_err != .None do return host.Status(0), false
	concurrency_table.auto_increment_columns = concurrency_auto_columns[:]
	append(&tables, concurrency_table)
	scheduled_concurrency_key_columns := [?]u16{0}
	scheduled_concurrency_index := host.Table_Index{source_name = "scheduled_concurrency_id_idx_btree", accessor_name = "by_id", algorithm = .BTree, columns = scheduled_concurrency_key_columns[:]}
	scheduled_concurrency_indexes := [?]host.Table_Index{scheduled_concurrency_index}
	scheduled_concurrency_unique := host.Unique_Constraint{columns = scheduled_concurrency_key_columns[:]}
	scheduled_concurrency_unique_constraints := [?]host.Unique_Constraint{scheduled_concurrency_unique}
	scheduled_concurrency_table, scheduled_concurrency_table_err := host.typed_table_definition(Scheduled_Concurrency_Row, "scheduled_concurrency_rows", .Private, scheduled_concurrency_key_columns[:], scheduled_concurrency_indexes[:], scheduled_concurrency_unique_constraints[:])
	if scheduled_concurrency_table_err != .None do return host.Status(0), false
	scheduled_concurrency_table.auto_increment_columns = scheduled_concurrency_key_columns[:]
	scheduled_concurrency_table.scheduled_function = "insert_scheduled_concurrency_row"
	scheduled_concurrency_table.schedule_at_column = 1
	append(&tables, scheduled_concurrency_table)
	scheduled_procedure_key_columns := [?]u16{0}
	scheduled_procedure_index := host.Table_Index{source_name = "scheduled_procedure_concurrency_id_idx_btree", accessor_name = "by_id", algorithm = .BTree, columns = scheduled_procedure_key_columns[:]}
	scheduled_procedure_indexes := [?]host.Table_Index{scheduled_procedure_index}
	scheduled_procedure_unique := host.Unique_Constraint{columns = scheduled_procedure_key_columns[:]}
	scheduled_procedure_constraints := [?]host.Unique_Constraint{scheduled_procedure_unique}
	scheduled_procedure_table, scheduled_procedure_table_err := host.typed_table_definition(Scheduled_Procedure_Concurrency_Row, "scheduled_procedure_concurrency_rows", .Private, scheduled_procedure_key_columns[:], scheduled_procedure_indexes[:], scheduled_procedure_constraints[:])
	if scheduled_procedure_table_err != .None do return host.Status(0), false
	scheduled_procedure_table.auto_increment_columns = scheduled_procedure_key_columns[:]
	scheduled_procedure_table.scheduled_function = "scheduled_procedure_concurrency"
	scheduled_procedure_table.schedule_at_column = 1
	append(&tables, scheduled_procedure_table)
	views: [dynamic]host.View_Definition
	defer for view in views do delete(view.args)
	handlers: []string = nil
	routes: [dynamic]host.Http_Route
	environment: [dynamic]host.Environment_Definition
	return host.write_module_def_all(description, reducers[:], tables[:], views[:], procedures[:], handlers[:], routes[:], environment[:])
}
