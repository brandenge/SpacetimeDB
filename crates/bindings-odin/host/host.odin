package host

import "base:runtime"
import "core:reflect"

Status :: distinct u16
Table_Id :: distinct u32
Index_Id :: distinct u32
Column_Id :: distinct u16
Index_Type :: distinct u8
Log_Level :: distinct u8
Bytes_Sink :: distinct u32
Bytes_Source :: distinct u32
Row_Iterator :: distinct u32
Console_Timer_Id :: distinct u32

INVALID_TABLE_ID :: Table_Id(0)
INVALID_INDEX_ID :: Index_Id(0)
INVALID_ROW_ITERATOR :: Row_Iterator(0)
INVALID_BYTES_SOURCE :: Bytes_Source(0)
INVALID_BYTES_SINK :: Bytes_Sink(0)
INVALID_CONSOLE_TIMER_ID :: Console_Timer_Id(0)

@(export)
foreign import spacetime_10_0 "spacetime_10.0"

@(default_calling_convention = "c")
foreign spacetime_10_0 {
	table_id_from_name :: proc(name_ptr: [^]u8, name_len: uint, out: ^Table_Id) -> Status ---
	index_id_from_name :: proc(name_ptr: [^]u8, name_len: uint, out: ^Index_Id) -> Status ---
	datastore_table_row_count :: proc(table_id: Table_Id, out: ^u64) -> Status ---
	datastore_table_scan_bsatn :: proc(table_id: Table_Id, out: ^Row_Iterator) -> Status ---
	datastore_index_scan_range_bsatn :: proc(
		index_id: Index_Id,
		prefix_ptr: [^]u8,
		prefix_len: uint,
		prefix_elems: Column_Id,
		rstart_ptr: [^]u8,
		rstart_len: uint,
		rend_ptr: [^]u8,
		rend_len: uint,
		out: ^Row_Iterator,
	) -> Status ---
	datastore_btree_scan_bsatn :: proc(
		index_id: Index_Id,
		prefix_ptr: [^]u8,
		prefix_len: uint,
		prefix_elems: Column_Id,
		rstart_ptr: [^]u8,
		rstart_len: uint,
		rend_ptr: [^]u8,
		rend_len: uint,
		out: ^Row_Iterator,
	) -> Status ---
	row_iter_bsatn_advance :: proc(iter: Row_Iterator, buffer_ptr: [^]u8, buffer_len_ptr: ^uint) -> i16 ---
	row_iter_bsatn_close :: proc(iter: Row_Iterator) -> Status ---
	datastore_insert_bsatn :: proc(table_id: Table_Id, row_ptr: [^]u8, row_len_ptr: ^uint) -> Status ---
	datastore_update_bsatn :: proc(
		table_id: Table_Id,
		index_id: Index_Id,
		row_ptr: [^]u8,
		row_len_ptr: ^uint,
	) -> Status ---
	datastore_delete_by_index_scan_range_bsatn :: proc(
		index_id: Index_Id,
		prefix_ptr: [^]u8,
		prefix_len: uint,
		prefix_elems: Column_Id,
		rstart_ptr: [^]u8,
		rstart_len: uint,
		rend_ptr: [^]u8,
		rend_len: uint,
		out: ^u32,
	) -> Status ---
	datastore_delete_by_btree_scan_bsatn :: proc(
		index_id: Index_Id,
		prefix_ptr: [^]u8,
		prefix_len: uint,
		prefix_elems: Column_Id,
		rstart_ptr: [^]u8,
		rstart_len: uint,
		rend_ptr: [^]u8,
		rend_len: uint,
		out: ^u32,
	) -> Status ---
	datastore_delete_all_by_eq_bsatn :: proc(
		table_id: Table_Id,
		rel_ptr: [^]u8,
		rel_len: uint,
		out: ^u32,
	) -> Status ---
	bytes_source_read :: proc(source: Bytes_Source, buffer_ptr: [^]u8, buffer_len_ptr: ^uint) -> i16 ---
	bytes_sink_write :: proc(sink: Bytes_Sink, buffer_ptr: [^]u8, buffer_len_ptr: ^uint) -> Status ---
	console_log :: proc(
		level: Log_Level,
		target_ptr: [^]u8,
		target_len: uint,
		filename_ptr: [^]u8,
		filename_len: uint,
		line_number: u32,
		message_ptr: [^]u8,
		message_len: uint,
	) ---
	console_timer_start :: proc(name_ptr: [^]u8, name_len: uint) -> Console_Timer_Id ---
	console_timer_end :: proc(timer_id: Console_Timer_Id) -> Status ---
	identity :: proc(id_ptr: [^]u8) ---
}

@(export)
foreign import spacetime_10_1 "spacetime_10.1"

@(default_calling_convention = "c")
foreign spacetime_10_1 {
	bytes_source_remaining_length :: proc(source: Bytes_Source, out: ^u32) -> i16 ---
}

@(export)
foreign import spacetime_10_2 "spacetime_10.2"

@(default_calling_convention = "c")
foreign spacetime_10_2 {
	get_jwt :: proc(connection_id_ptr: [^]u8, out: ^Bytes_Source) -> Status ---
}

@(export)
foreign import spacetime_10_3 "spacetime_10.3"

@(default_calling_convention = "c")
foreign spacetime_10_3 {
	procedure_sleep_until :: proc(wake_at_micros_since_unix_epoch: i64) -> i64 ---
	procedure_start_mut_tx :: proc(out: ^i64) -> Status ---
	procedure_commit_mut_tx :: proc() -> Status ---
	procedure_abort_mut_tx :: proc() -> Status ---
	procedure_http_request :: proc(
		request_ptr: [^]u8,
		request_len: uint,
		body_ptr: [^]u8,
		body_len: uint,
		out: [^]Bytes_Source,
	) -> Status ---
}

@(export)
foreign import spacetime_10_4 "spacetime_10.4"

@(default_calling_convention = "c")
foreign spacetime_10_4 {
	datastore_index_scan_point_bsatn :: proc(
		index_id: Index_Id,
		point_ptr: [^]u8,
		point_len: uint,
		out: ^Row_Iterator,
	) -> Status ---
	datastore_delete_by_index_scan_point_bsatn :: proc(
		index_id: Index_Id,
		point_ptr: [^]u8,
		point_len: uint,
		out: ^u32,
	) -> Status ---
}

@(export)
foreign import spacetime_10_5 "spacetime_10.5"

@(default_calling_convention = "c")
foreign spacetime_10_5 {
	datastore_clear :: proc(table_id: Table_Id, out: ^u64) -> Status ---
}

@(export)
foreign import spacetime_10_6 "spacetime_10.6"

@(default_calling_convention = "c")
foreign spacetime_10_6 {
	env_get :: proc(key: [^]u8, key_len: u32, out: ^Bytes_Source) -> Status ---
}

Describe_Module_Proc :: proc "c" (description: Bytes_Sink)
Call_Reducer_Proc :: proc "c" (
	id: uint,
	sender_0, sender_1, sender_2, sender_3: u64,
	conn_id_0, conn_id_1: u64,
	timestamp: u64,
	args: Bytes_Source,
	error: Bytes_Sink,
) -> i16

Reducer_Argument_Type :: enum u8 {
	String = 4,
	Bool = 5,
	I8 = 6,
	U8 = 7,
	I16 = 8,
	U16 = 9,
	I32 = 10,
	U32 = 11,
	I64 = 12,
	U64 = 13,
	I128 = 14,
	U128 = 15,
	I256 = 16,
	U256 = 17,
	F32 = 18,
	F64 = 19,
}

Reducer_Argument_Container :: enum u8 {
	None,
	Array,
	Option,
}

I256 :: distinct [32]u8
U256 :: distinct [32]u8

Reducer_Argument :: struct {
	name: string,
	type: Reducer_Argument_Type,
	container: Reducer_Argument_Container,
	info: ^reflect.Type_Info, // when set, overrides type and container
	table_ref: string, // when set, encode the argument as a reference to this table row type
}

// Views return rows of a named struct type; Vec<Row> results are written with write_view_rows.
View_Return_Kind :: enum u8 {
	Array,
	Option,
	Query,
}

View_Definition :: struct {
	name: string,
	args: []Reducer_Argument,
	row_info: ^reflect.Type_Info,
	is_anonymous: bool, // anonymous views cannot see the caller and are exported as __call_view_anon__
	return_kind: View_Return_Kind,
	primary_key: string, // optional row field name that uniquely identifies rows, for client-side updates
	fn_ptr: runtime.Maybe(u32),
}

// Procedures run outside a transaction; wrap datastore access in procedure_start_tx/procedure_commit_tx.
Procedure_Definition :: struct {
	name: string,
	args: []Reducer_Argument,
	return_info: ^reflect.Type_Info, // nil returns the unit type
	private: bool,
}

Lifecycle :: enum u8 {
	None,
	Init,
	On_Connect,
	On_Disconnect,
}

Reducer_Handler :: proc(args: Bytes_Source, error: Bytes_Sink) -> i16

Reducer_Definition :: struct {
	name: string,
	args: []Reducer_Argument,
	lifecycle: Lifecycle, // lifecycle reducers are private and take no arguments
	private: bool, // hides the reducer from clients; required for scheduled reducers
	row_table: string, // scheduled reducers: takes the named table's row as its only parameter, named "arg"
	handler: Reducer_Handler, // optional local dispatch target; excluded from the module definition
}

dispatch_reducer_handler :: proc(
	id: uint,
	reducers: []Reducer_Definition,
	args: Bytes_Source,
	error: Bytes_Sink,
) -> (status: i16, handled: bool) {
	if id >= uint(len(reducers)) do return 0, false
	handler := reducers[int(id)].handler
	if handler == nil do return 0, false
	return handler(args, error), true
}

Table_Access :: enum u8 {
	Public = 0,
	Private = 1,
}

Index_Algorithm :: enum u8 {
	BTree = 0,
	Hash = 1,
	Direct = 2,
}

Table_Index :: struct {
	source_name: string,
	accessor_name: string,
	algorithm: Index_Algorithm,
	columns: []u16,
}

Unique_Constraint :: struct {
	columns: []u16,
}

Column_Default_Value :: struct {
	column: u16,
	bsatn: []u8,
}

Row_Level_Security_Definition :: struct {
	sql: string,
}

Submodule_Definition :: struct {
	namespace: string,
	module_bsatn: []u8,
}

Outbox_Definition :: struct {
	remote_reducer: string,
	target_column: u16,
	arg_columns: []u16,
	on_result_reducer: runtime.Maybe(string),
	signature_hash: [32]u8,
}

Environment_Variable_Type :: enum u8 {
	String,
	String_Literal,
	Union,
}

Environment_Definition :: struct {
	name: string,
	type: Environment_Variable_Type,
	literal: string,
	values: []string,
	optional: bool,
}

Table_Definition :: struct {
	name: string,
	row_info: ^reflect.Type_Info,
	columns: []Reducer_Argument,
	access: Table_Access,
	primary_key_columns: []u16,
	indexes: []Table_Index,
	unique_constraints: []Unique_Constraint,
	default_values: []Column_Default_Value,
	auto_increment_columns: []u16, // integer columns the host fills in when inserted as 0
	scheduled_reducer: string, // legacy alias for scheduled_function
	scheduled_function: string, // reducer or procedure invoked with the scheduled row
	schedule_at_column: u16, // index of the Schedule_At column
	outbox: runtime.Maybe(Outbox_Definition),
	is_event: bool,
}

write_all :: proc "contextless" (sink: Bytes_Sink, bytes: []u8) -> (Status, bool) {
	length := int(len(bytes))
	offset := 0
	for offset < length {
		written := uint(length - offset)
		status := bytes_sink_write(sink, raw_data(bytes[offset:]), &written)
		if status != Status(0) do return status, false
		if written == 0 do return Status(0), false
		offset += int(written)
	}
	return Status(0), true
}

write_u32 :: proc "contextless" (sink: Bytes_Sink, value: u32) -> (Status, bool) {
	bytes := [4]u8{
		u8(value),
		u8(value >> 8),
		u8(value >> 16),
		u8(value >> 24),
	}
	return write_all(sink, bytes[:])
}

write_u16 :: proc "contextless" (sink: Bytes_Sink, value: u16) -> (Status, bool) {
	bytes := [2]u8{u8(value), u8(value >> 8)}
	return write_all(sink, bytes[:])
}

write_col_list :: proc "contextless" (sink: Bytes_Sink, columns: []u16) -> (Status, bool) {
	status, complete := write_u32(sink, u32(len(columns)))
	if status != Status(0) || !complete do return status, false
	for column in columns {
		status, complete = write_u16(sink, column)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

read_u32_argument :: proc "contextless" (source: Bytes_Source) -> (u32, bool) {
	remaining: u32
	status := bytes_source_remaining_length(source, &remaining)
	if status != 0 || remaining != 4 do return 0, false

	bytes: [4]u8
	length := uint(len(bytes))
	read_status := bytes_source_read(source, raw_data(bytes[:]), &length)
	if read_status != 0 || length != 4 do return 0, false

	value := u32(bytes[0]) | u32(bytes[1]) << 8 | u32(bytes[2]) << 16 | u32(bytes[3]) << 24
	return value, true
}

write_string :: proc "contextless" (sink: Bytes_Sink, value: string) -> (Status, bool) {
	status, complete := write_u32(sink, u32(len(value)))
	if status != Status(0) || !complete do return status, false
	return write_all(sink, transmute([]u8)value)
}

write_argument_type :: proc (sink: Bytes_Sink, argument: Reducer_Argument) -> (Status, bool) {
	if len(argument.table_ref) > 0 {
		table_index := -1
		for table, index in schema_tables do if table.name == argument.table_ref do table_index = index
		if table_index < 0 do return Status(0), false
		status, complete := write_all(sink, []u8{0})
		if status != Status(0) || !complete do return status, false
		return write_u32(sink, schema_table_type_refs[table_index])
	}
	if argument.info != nil do return write_type_info(sink, argument.info)
	status, complete := Status(0), true
	switch argument.container {
	case .None:
		return write_all(sink, []u8{u8(argument.type)})
	case .Array:
		status, complete = write_all(sink, []u8{3})
		if status != Status(0) || !complete do return status, false
		return write_all(sink, []u8{u8(argument.type)})
	case .Option:
		status, complete = write_all(sink, []u8{1})
		if status != Status(0) || !complete do return status, false
		status, complete = write_u32(sink, 2)
		if status != Status(0) || !complete do return status, false
		status, complete = write_all(sink, []u8{0})
		if status != Status(0) || !complete do return status, false
		status, complete = write_string(sink, "some")
		if status != Status(0) || !complete do return status, false
		status, complete = write_all(sink, []u8{u8(argument.type)})
		if status != Status(0) || !complete do return status, false
		status, complete = write_all(sink, []u8{0})
		if status != Status(0) || !complete do return status, false
		status, complete = write_string(sink, "none")
		if status != Status(0) || !complete do return status, false
		status, complete = write_all(sink, []u8{2})
		if status != Status(0) || !complete do return status, false
		return write_u32(sink, 0)
	}
	unreachable()
}

write_reducer_definition :: proc (
	sink: Bytes_Sink,
	reducer: Reducer_Definition,
) -> (Status, bool) {
	if len(reducer.name) == 0 do return Status(0), false
	status, complete := write_string(sink, reducer.name)
	if status != Status(0) || !complete do return status, false

	if len(reducer.row_table) > 0 {
		table_index := -1
		for table, index in schema_tables do if table.name == reducer.row_table do table_index = index
		if table_index < 0 do return Status(0), false
		status, complete = write_u32(sink, 1)
		if status != Status(0) || !complete do return status, false
		status, complete = write_all(sink, []u8{0, 3, 0, 0, 0, 'a', 'r', 'g', 0}) // name: Some("arg"), type: Ref
		if status != Status(0) || !complete do return status, false
		status, complete = write_u32(sink, schema_table_type_refs[table_index])
		if status != Status(0) || !complete do return status, false
	} else {
		status, complete = write_u32(sink, u32(len(reducer.args)))
		if status != Status(0) || !complete do return status, false
	}

	if len(reducer.row_table) == 0 {
		for arg in reducer.args {
			if len(arg.name) == 0 do return Status(0), false
			status, complete = write_all(sink, []u8{0})
			if status != Status(0) || !complete do return status, false
			status, complete = write_string(sink, arg.name)
			if status != Status(0) || !complete do return status, false
			status, complete = write_argument_type(sink, arg)
			if status != Status(0) || !complete do return status, false
		}
	}

	visibility: u8 = 1 // client callable
	if reducer.lifecycle != .None || reducer.private do visibility = 0
	return write_all(sink, []u8{visibility, 2, 0, 0, 0, 0, 4})
}

scheduled_function_name :: proc "contextless" (table: Table_Definition) -> string {
	return table.scheduled_function if len(table.scheduled_function) > 0 else table.scheduled_reducer
}

write_schedule_section :: proc "contextless" (sink: Bytes_Sink, tables: []Table_Definition) -> (Status, bool) {
	count := 0
	for table in tables do if len(scheduled_function_name(table)) > 0 do count += 1
	status, complete := write_all(sink, []u8{6})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(count))
	if status != Status(0) || !complete do return status, false
	for table in tables {
		function_name := scheduled_function_name(table)
		if len(function_name) == 0 do continue
		status, complete = write_all(sink, []u8{1}) // source_name: None
		if status != Status(0) || !complete do return status, false
		status, complete = write_string(sink, table.name)
		if status != Status(0) || !complete do return status, false
		status, complete = write_u16(sink, table.schedule_at_column)
		if status != Status(0) || !complete do return status, false
		status, complete = write_string(sink, function_name)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

write_row_level_security_section :: proc "contextless" (
	sink: Bytes_Sink,
	policies: []Row_Level_Security_Definition,
) -> (Status, bool) {
	status, complete := write_all(sink, []u8{8})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(len(policies)))
	if status != Status(0) || !complete do return status, false
	for policy in policies {
		status, complete = write_string(sink, policy.sql)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

write_submodule_section :: proc "contextless" (
	sink: Bytes_Sink,
	submodules: []Submodule_Definition,
) -> (Status, bool) {
	status, complete := write_all(sink, []u8{14})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(len(submodules)))
	if status != Status(0) || !complete do return status, false
	for submodule in submodules {
		status, complete = write_string(sink, submodule.namespace)
		if status != Status(0) || !complete do return status, false
		status, complete = write_all(sink, submodule.module_bsatn)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

write_bytes :: proc "contextless" (sink: Bytes_Sink, bytes: []u8) -> (Status, bool) {
	if u64(len(bytes)) > u64(0xffff_ffff) do return Status(0), false
	status, complete := write_u32(sink, u32(len(bytes)))
	if status != Status(0) || !complete do return status, false
	return write_all(sink, bytes)
}

write_procedure_section :: proc (sink: Bytes_Sink, procedures: []Procedure_Definition) -> (Status, bool) {
	status, complete := write_all(sink, []u8{4})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(len(procedures)))
	if status != Status(0) || !complete do return status, false
	for procedure in procedures {
		if len(procedure.name) == 0 do return Status(0), false
		status, complete = write_string(sink, procedure.name)
		if status != Status(0) || !complete do return status, false
		status, complete = write_u32(sink, u32(len(procedure.args)))
		if status != Status(0) || !complete do return status, false
		for arg in procedure.args {
			if len(arg.name) == 0 do return Status(0), false
			status, complete = write_all(sink, []u8{0})
			if status != Status(0) || !complete do return status, false
			status, complete = write_string(sink, arg.name)
			if status != Status(0) || !complete do return status, false
			status, complete = write_argument_type(sink, arg)
			if status != Status(0) || !complete do return status, false
		}
		if procedure.return_info == nil {
			status, complete = write_all(sink, []u8{2, 0, 0, 0, 0})
		} else {
			status, complete = write_type_info(sink, procedure.return_info)
		}
		if status != Status(0) || !complete do return status, false
		status, complete = write_all(sink, []u8{0 if procedure.private else 1})
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

write_view_section :: proc (sink: Bytes_Sink, views: []View_Definition) -> (Status, bool) {
	status, complete := write_all(sink, []u8{5})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(len(views)))
	if status != Status(0) || !complete do return status, false
	for view, position in views {
		if len(view.name) == 0 || view.row_info == nil do return Status(0), false
		// Anonymous and caller-aware views are dispatched by id within their own export.
		index := 0
		for earlier in views[:position] do if earlier.is_anonymous == view.is_anonymous do index += 1
		if explicit_index, has_index := view.fn_ptr.(u32); has_index do index = int(explicit_index)
		status, complete = write_string(sink, view.name)
		if status != Status(0) || !complete do return status, false
		status, complete = write_u32(sink, u32(index))
		if status != Status(0) || !complete do return status, false
		status, complete = write_all(sink, []u8{1, 1 if view.is_anonymous else 0}) // is_public, is_anonymous
		if status != Status(0) || !complete do return status, false
		status, complete = write_u32(sink, u32(len(view.args)))
		if status != Status(0) || !complete do return status, false
		for arg in view.args {
			if len(arg.name) == 0 do return Status(0), false
			status, complete = write_all(sink, []u8{0})
			if status != Status(0) || !complete do return status, false
			status, complete = write_string(sink, arg.name)
			if status != Status(0) || !complete do return status, false
			status, complete = write_argument_type(sink, arg)
			if status != Status(0) || !complete do return status, false
		}
		switch view.return_kind {
		case .Array:
			status, complete = write_all(sink, []u8{3})
			if status != Status(0) || !complete do return status, false
			status, complete = write_type_info(sink, view.row_info)
			if status != Status(0) || !complete do return status, false
		case .Option:
			status, complete = write_all(sink, []u8{1, 2, 0, 0, 0, 0})
			if status != Status(0) || !complete do return status, false
			status, complete = write_string(sink, "some")
			if status != Status(0) || !complete do return status, false
			status, complete = write_type_info(sink, view.row_info)
			if status != Status(0) || !complete do return status, false
			status, complete = write_all(sink, []u8{0})
			if status != Status(0) || !complete do return status, false
			status, complete = write_string(sink, "none")
			if status != Status(0) || !complete do return status, false
			status, complete = write_all(sink, []u8{2, 0, 0, 0, 0})
			if status != Status(0) || !complete do return status, false
		case .Query:
			status, complete = write_all(sink, []u8{2, 1, 0, 0, 0, 0})
			if status != Status(0) || !complete do return status, false
			status, complete = write_string(sink, "__query__")
			if status != Status(0) || !complete do return status, false
			status, complete = write_type_info(sink, view.row_info)
			if status != Status(0) || !complete do return status, false
		}
	}
	return Status(0), true
}

write_view_primary_key_section :: proc "contextless" (sink: Bytes_Sink, views: []View_Definition) -> (Status, bool) {
	count := 0
	for view in views do if len(view.primary_key) > 0 do count += 1
	status, complete := write_all(sink, []u8{13})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(count))
	if status != Status(0) || !complete do return status, false
	for view in views {
		if len(view.primary_key) == 0 do continue
		status, complete = write_string(sink, view.name)
		if status != Status(0) || !complete do return status, false
		status, complete = write_u32(sink, 1)
		if status != Status(0) || !complete do return status, false
		status, complete = write_string(sink, view.primary_key)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

write_lifecycle_section :: proc "contextless" (sink: Bytes_Sink, reducers: []Reducer_Definition) -> (Status, bool) {
	count := 0
	for reducer in reducers do if reducer.lifecycle != .None do count += 1
	status, complete := write_all(sink, []u8{7})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(count))
	if status != Status(0) || !complete do return status, false
	for reducer in reducers {
		if reducer.lifecycle == .None do continue
		status, complete = write_all(sink, []u8{u8(reducer.lifecycle) - 1})
		if status != Status(0) || !complete do return status, false
		status, complete = write_string(sink, reducer.name)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

Outbox_Writer :: struct {
	sink: Bytes_Sink,
	capture: []u8,
	capture_offset: int,
	capture_enabled: bool,
	status: Status,
	failed: bool,
}

@(private)
outbox_emit :: proc "contextless" (writer: ^Outbox_Writer, bytes: []u8) {
	if writer.failed do return
	if writer.capture_enabled {
		if len(bytes) > len(writer.capture) - writer.capture_offset {
			writer.failed = true
			return
		}
		copy(writer.capture[writer.capture_offset:], bytes)
		writer.capture_offset += len(bytes)
		return
	}
	when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 {
		status, complete := write_all(writer.sink, bytes)
		writer.status = status
		if !complete do writer.failed = true
	} else {
		writer.failed = true
	}
}

@(private)
outbox_emit_u16 :: proc "contextless" (writer: ^Outbox_Writer, value: u16) {
	outbox_emit(writer, []u8{u8(value), u8(value >> 8)})
}

@(private)
outbox_emit_u32 :: proc "contextless" (writer: ^Outbox_Writer, value: u32) {
	outbox_emit(writer, []u8{u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)})
}

@(private)
outbox_emit_string :: proc "contextless" (writer: ^Outbox_Writer, value: string) {
	outbox_emit_u32(writer, u32(len(value)))
	outbox_emit(writer, transmute([]u8)value)
}

@(private)
write_outbox_section_to :: proc "contextless" (writer: ^Outbox_Writer, tables: []Table_Definition) {
	outbox_count := 0
	for table in tables do if _, has_outbox := table.outbox.(Outbox_Definition); has_outbox do outbox_count += 1
	outbox_emit(writer, []u8{16})
	outbox_emit_u32(writer, u32(outbox_count))
	for table in tables {
		outbox, has_outbox := table.outbox.(Outbox_Definition)
		if !has_outbox do continue
		if len(table.name) == 0 || len(outbox.remote_reducer) == 0 {
			writer.failed = true
			return
		}
		outbox_emit_string(writer, table.name)
		outbox_emit_string(writer, outbox.remote_reducer)
		outbox_emit_u16(writer, outbox.target_column)
		outbox_emit_u32(writer, u32(len(outbox.arg_columns)))
		for column in outbox.arg_columns do outbox_emit_u16(writer, column)
		if on_result_reducer, has_result := outbox.on_result_reducer.(string); has_result {
			outbox_emit(writer, []u8{0})
			outbox_emit_string(writer, on_result_reducer)
		} else {
			outbox_emit(writer, []u8{1})
		}
		signature_hash := outbox.signature_hash
		outbox_emit(writer, signature_hash[:])
	}
}

write_outbox_section :: proc "contextless" (sink: Bytes_Sink, tables: []Table_Definition) -> (Status, bool) {
	writer := Outbox_Writer{sink = sink}
	write_outbox_section_to(&writer, tables)
	return writer.status, !writer.failed
}

encode_outbox_section_into :: proc "contextless" (
	tables: []Table_Definition,
	buffer: []u8,
) -> (encoded_len: int, ok: bool) {
	writer := Outbox_Writer{capture = buffer, capture_enabled = true}
	write_outbox_section_to(&writer, tables)
	return writer.capture_offset, !writer.failed
}

@(private)
write_environment_section_to :: proc "contextless" (
	writer: ^Outbox_Writer,
	environment: []Environment_Definition,
) {
	outbox_emit(writer, []u8{15})
	outbox_emit_u32(writer, u32(len(environment)))
	for declaration in environment {
		if len(declaration.name) == 0 {
			writer.failed = true
			return
		}
		outbox_emit_string(writer, declaration.name)
		switch declaration.type {
		case .String:
			outbox_emit(writer, []u8{0, 1 if declaration.optional else 0})
		case .String_Literal:
			outbox_emit(writer, []u8{1})
			outbox_emit_string(writer, declaration.literal)
			outbox_emit(writer, []u8{1 if declaration.optional else 0})
		case .Union:
			outbox_emit(writer, []u8{2})
			outbox_emit_u32(writer, u32(len(declaration.values)))
			for value in declaration.values do outbox_emit_string(writer, value)
			outbox_emit(writer, []u8{1 if declaration.optional else 0})
		}
	}
}

write_environment_section :: proc "contextless" (
	sink: Bytes_Sink,
	environment: []Environment_Definition,
) -> (Status, bool) {
	writer := Outbox_Writer{sink = sink}
	write_environment_section_to(&writer, environment)
	return writer.status, !writer.failed
}

encode_environment_section_into :: proc "contextless" (
	environment: []Environment_Definition,
	buffer: []u8,
) -> (encoded_len: int, ok: bool) {
	writer := Outbox_Writer{capture = buffer, capture_enabled = true}
	write_environment_section_to(&writer, environment)
	return writer.capture_offset, !writer.failed
}

write_reducer_section :: proc (
	sink: Bytes_Sink,
	reducers: []Reducer_Definition,
) -> (Status, bool) {
	status, complete := write_all(sink, []u8{3})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(len(reducers)))
	if status != Status(0) || !complete do return status, false

	for reducer in reducers {
		status, complete = write_reducer_definition(sink, reducer)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

write_product_type :: proc (sink: Bytes_Sink, columns: []Reducer_Argument) -> (Status, bool) {
	if len(columns) == 0 do return Status(0), false
	status, complete := write_all(sink, []u8{2})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(len(columns)))
	if status != Status(0) || !complete do return status, false
	for column in columns {
		if len(column.name) == 0 do return Status(0), false
		status, complete = write_all(sink, []u8{0})
		if status != Status(0) || !complete do return status, false
		status, complete = write_string(sink, column.name)
		if status != Status(0) || !complete do return status, false
		status, complete = write_argument_type(sink, column)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

write_table_index :: proc "contextless" (sink: Bytes_Sink, index: Table_Index) -> (Status, bool) {
	if len(index.source_name) == 0 || len(index.accessor_name) == 0 do return Status(0), false
	status, complete := write_all(sink, []u8{0})
	if status != Status(0) || !complete do return status, false
	status, complete = write_string(sink, index.source_name)
	if status != Status(0) || !complete do return status, false
	status, complete = write_all(sink, []u8{0})
	if status != Status(0) || !complete do return status, false
	status, complete = write_string(sink, index.accessor_name)
	if status != Status(0) || !complete do return status, false
	status, complete = write_all(sink, []u8{u8(index.algorithm)})
	if status != Status(0) || !complete do return status, false
	switch index.algorithm {
	case .BTree, .Hash:
		return write_col_list(sink, index.columns)
	case .Direct:
		if len(index.columns) != 1 do return Status(0), false
		return write_u16(sink, index.columns[0])
	}
	unreachable()
}

write_unique_constraint :: proc "contextless" (sink: Bytes_Sink, constraint: Unique_Constraint) -> (Status, bool) {
	status, complete := write_all(sink, []u8{1, 0})
	if status != Status(0) || !complete do return status, false
	return write_col_list(sink, constraint.columns)
}

write_type_export :: proc (
	sink: Bytes_Sink,
	info: ^reflect.Type_Info,
	fallback_name: string,
	type_ref: u32,
	exported_types: []Type_Export_Definition,
) -> (Status, bool) {
	definition := Type_Export_Definition{name = fallback_name, custom_ordering = true}
	for candidate in exported_types {
		if info != nil && candidate.info != nil && candidate.info.id == info.id {
			definition = candidate
			break
		}
	}
	status, complete := write_u32(sink, u32(len(definition.scope)))
	if status != Status(0) || !complete do return status, false
	for segment in definition.scope {
		status, complete = write_string(sink, segment)
		if status != Status(0) || !complete do return status, false
	}
	status, complete = write_string(sink, definition.name)
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, type_ref)
	if status != Status(0) || !complete do return status, false
	return write_all(sink, []u8{1 if definition.custom_ordering else 0})
}

write_typespace_sections :: proc (
	sink: Bytes_Sink,
	tables: []Table_Definition,
	registry: ^Type_Registry,
	exported_types: []Type_Export_Definition,
) -> (Status, bool) {
	total := u32(schema_table_type_count + registry.count)
	status, complete := write_all(sink, []u8{0})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, total)
	if status != Status(0) || !complete do return status, false
	emitted_tables := 0
	for table, index in tables {
		if int(schema_table_type_refs[index]) != emitted_tables do continue
		status, complete = write_product_type(sink, table.columns)
		if status != Status(0) || !complete do return status, false
		emitted_tables += 1
	}
	for index in 0 ..< registry.count {
		status, complete = write_type_definition(sink, registry.types[index])
		if status != Status(0) || !complete do return status, false
	}

	status, complete = write_all(sink, []u8{1})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, total)
	if status != Status(0) || !complete do return status, false
	emitted_tables = 0
	for table, index in tables {
		if int(schema_table_type_refs[index]) != emitted_tables do continue
		if len(table.name) == 0 do return Status(0), false
		status, complete = write_type_export(sink, table.row_info, table.name, schema_table_type_refs[index], exported_types)
		if status != Status(0) || !complete do return status, false
		emitted_tables += 1
	}
	for index in 0 ..< registry.count {
		info := registry.types[index]
		status, complete = write_type_export(sink, info, named_type_name(info), registry.ref_base + u32(index), exported_types)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

write_table_sections :: proc (sink: Bytes_Sink, tables: []Table_Definition) -> (Status, bool) {
	status, complete := write_all(sink, []u8{2})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(len(tables)))
	if status != Status(0) || !complete do return status, false
	for table, index in tables {
		status, complete = write_string(sink, table.name)
		if status != Status(0) || !complete do return status, false
		status, complete = write_u32(sink, schema_table_type_refs[index])
		if status != Status(0) || !complete do return status, false
		status, complete = write_col_list(sink, table.primary_key_columns)
		if status != Status(0) || !complete do return status, false
		status, complete = write_u32(sink, u32(len(table.indexes)))
		if status != Status(0) || !complete do return status, false
		for table_index in table.indexes {
			status, complete = write_table_index(sink, table_index)
			if status != Status(0) || !complete do return status, false
		}
		status, complete = write_u32(sink, u32(len(table.unique_constraints)))
		if status != Status(0) || !complete do return status, false
		for constraint in table.unique_constraints {
			status, complete = write_unique_constraint(sink, constraint)
			if status != Status(0) || !complete do return status, false
		}
		status, complete = write_u32(sink, u32(len(table.auto_increment_columns)))
		if status != Status(0) || !complete do return status, false
		for column in table.auto_increment_columns {
			// source_name, start, min and max are None; increment is 1i128.
			status, complete = write_all(sink, []u8{1})
			if status != Status(0) || !complete do return status, false
			status, complete = write_u16(sink, column)
			if status != Status(0) || !complete do return status, false
			status, complete = write_all(sink, []u8{1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0})
			if status != Status(0) || !complete do return status, false
		}
		status, complete = write_all(sink, []u8{1, u8(table.access)})
		if status != Status(0) || !complete do return status, false
		status, complete = write_u32(sink, u32(len(table.default_values)))
		if status != Status(0) || !complete do return status, false
		for default_value in table.default_values {
			status, complete = write_u16(sink, default_value.column)
			if status != Status(0) || !complete do return status, false
			status, complete = write_u32(sink, u32(len(default_value.bsatn)))
			if status != Status(0) || !complete do return status, false
			status, complete = write_all(sink, default_value.bsatn)
			if status != Status(0) || !complete do return status, false
		}
		status, complete = write_all(sink, []u8{1 if table.is_event else 0})
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

write_module_def :: proc (
	sink: Bytes_Sink,
	reducers: []Reducer_Definition,
	tables: []Table_Definition,
) -> (Status, bool) {
	return write_module_def_with_views(sink, reducers, tables, nil)
}

write_module_def_with_views :: proc (
	sink: Bytes_Sink,
	reducers: []Reducer_Definition,
	tables: []Table_Definition,
	views: []View_Definition,
) -> (Status, bool) {
	return write_module_def_full(sink, reducers, tables, views, nil)
}

write_module_def_full :: proc (
	sink: Bytes_Sink,
	reducers: []Reducer_Definition,
	tables: []Table_Definition,
	views: []View_Definition,
	procedures: []Procedure_Definition,
	environment: []Environment_Definition = nil,
	row_level_security: []Row_Level_Security_Definition = nil,
) -> (Status, bool) {
	return write_module_def_all(sink, reducers, tables, views, procedures, nil, nil, environment, row_level_security)
}

// handlers are HTTP handler names; a route's handler must be one of them.
write_module_def_all :: proc (
	sink: Bytes_Sink,
	reducers: []Reducer_Definition,
	tables: []Table_Definition,
	views: []View_Definition,
	procedures: []Procedure_Definition,
	handlers: []string,
	routes: []Http_Route,
	environment: []Environment_Definition = nil,
	row_level_security: []Row_Level_Security_Definition = nil,
	submodules: []Submodule_Definition = nil,
	sum_variants: []Sum_Variant_Definition = nil,
	enum_variants: []Enum_Variant_Definition = nil,
	explicit_names_bsatn: []u8 = nil,
	case_policy_bsatn: []u8 = nil,
	exported_types: []Type_Export_Definition = nil,
	environment_declared := false,
	type_fields: []Type_Field_Definition = nil,
	) -> (Status, bool) {
	table_type_refs := make([]u32, len(tables))
	defer delete(table_type_refs)
	seen_table_types := make(map[typeid]u32)
	defer delete(seen_table_types)
	table_type_count := 0
	for table, index in tables {
		if table.row_info != nil {
			if existing, found := seen_table_types[table.row_info.id]; found {
				table_type_refs[index] = existing
				continue
			}
			seen_table_types[table.row_info.id] = u32(table_type_count)
		}
		table_type_refs[index] = u32(table_type_count)
		table_type_count += 1
	}
	registry := Type_Registry{ref_base = u32(table_type_count)}
	defer delete(registry.types)
	schema_tables = tables
	schema_table_type_refs = table_type_refs
	schema_table_type_count = table_type_count
	schema_sum_variants = sum_variants
	schema_enum_variants = enum_variants
	schema_type_fields = type_fields
	defer {
		schema_registry = nil
		schema_tables = nil
		schema_table_type_refs = nil
		schema_table_type_count = 0
		schema_sum_variants = nil
		schema_enum_variants = nil
		schema_type_fields = nil
	}
	for definition in exported_types do registry_collect(&registry, definition.info)
	for reducer in reducers {
		for argument in reducer.args do registry_collect(&registry, argument.info)
	}
	for table in tables {
		for column in table.columns do registry_collect(&registry, column.info)
	}
	for view in views {
		for argument in view.args do registry_collect(&registry, argument.info)
		registry_collect(&registry, view.row_info)
		if !type_supported(view.row_info) do return Status(0), false
	}
	for procedure in procedures {
		for argument in procedure.args do registry_collect(&registry, argument.info)
		if procedure.return_info != nil {
			registry_collect(&registry, procedure.return_info)
			if !type_supported(procedure.return_info) do return Status(0), false
		}
	}
	schema_registry = &registry

	has_typespace := len(tables) > 0 || registry.count > 0
	section_count := 1
	if has_typespace do section_count += 2
	if len(tables) > 0 do section_count += 1
	has_lifecycle := false
	for reducer in reducers {
		if reducer.lifecycle != .None {
			if len(reducer.args) != 0 do return Status(0), false
			has_lifecycle = true
		}
	}
	if has_lifecycle do section_count += 1
	has_schedule := false
	for table in tables do if len(scheduled_function_name(table)) > 0 do has_schedule = true
	if has_schedule do section_count += 1
	if len(views) > 0 do section_count += 1
	has_view_keys := false
	for view in views do if len(view.primary_key) > 0 do has_view_keys = true
	if has_view_keys do section_count += 1
	if len(procedures) > 0 do section_count += 1
	if len(handlers) > 0 do section_count += 2
	if len(row_level_security) > 0 do section_count += 1
	has_outboxes := false
	for table in tables do if _, has_outbox := table.outbox.(Outbox_Definition); has_outbox do has_outboxes = true
	if has_outboxes do section_count += 1
	if len(environment) > 0 || environment_declared do section_count += 1
	if len(submodules) > 0 do section_count += 1
	if len(explicit_names_bsatn) > 0 do section_count += 1
	if len(case_policy_bsatn) > 0 do section_count += 1
	status, complete := write_all(sink, []u8{2})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(section_count))
	if status != Status(0) || !complete do return status, false
	status, complete = write_reducer_section(sink, reducers)
	if status != Status(0) || !complete do return status, false
	if has_typespace {
		status, complete = write_typespace_sections(sink, tables, &registry, exported_types)
		if status != Status(0) || !complete do return status, false
	}
	if len(tables) > 0 {
		status, complete = write_table_sections(sink, tables)
		if status != Status(0) || !complete do return status, false
	}
	if len(procedures) > 0 {
		status, complete = write_procedure_section(sink, procedures)
		if status != Status(0) || !complete do return status, false
	}
	if len(views) > 0 {
		status, complete = write_view_section(sink, views)
		if status != Status(0) || !complete do return status, false
	}
	if has_view_keys {
		status, complete = write_view_primary_key_section(sink, views)
		if status != Status(0) || !complete do return status, false
	}
	if has_schedule {
		status, complete = write_schedule_section(sink, tables)
		if status != Status(0) || !complete do return status, false
	}
	if has_lifecycle {
		status, complete = write_lifecycle_section(sink, reducers)
		if status != Status(0) || !complete do return status, false
	}
	if len(handlers) > 0 {
		status, complete = write_http_handler_section(sink, handlers)
		if status != Status(0) || !complete do return status, false
		status, complete = write_http_route_section(sink, handlers, routes)
		if status != Status(0) || !complete do return status, false
	}
	if len(row_level_security) > 0 {
		status, complete = write_row_level_security_section(sink, row_level_security)
		if status != Status(0) || !complete do return status, false
	}
	if has_outboxes {
		status, complete = write_outbox_section(sink, tables)
		if status != Status(0) || !complete do return status, false
	}
	if len(environment) > 0 || environment_declared {
		status, complete = write_environment_section(sink, environment)
		if status != Status(0) || !complete do return status, false
	}
	if len(submodules) > 0 {
		status, complete = write_submodule_section(sink, submodules)
		if status != Status(0) || !complete do return status, false
	}
	if len(explicit_names_bsatn) > 0 {
		status, complete = write_all(sink, explicit_names_bsatn)
		if status != Status(0) || !complete do return status, false
	}
	if len(case_policy_bsatn) > 0 {
		status, complete = write_all(sink, case_policy_bsatn)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

write_reducer_module_def :: proc (
	sink: Bytes_Sink,
	reducers: []Reducer_Definition,
) -> (Status, bool) {
	return write_module_def(sink, reducers, nil)
}

write_module_def_with_one_table :: proc (
	sink: Bytes_Sink,
	reducers: []Reducer_Definition,
	table: Table_Definition,
) -> (Status, bool) {
	tables := [1]Table_Definition{table}
	return write_module_def(sink, reducers, tables[:])
}

write_single_noarg_reducer_module_def :: proc (
	sink: Bytes_Sink,
	reducer_name: string,
) -> (Status, bool) {
	if len(reducer_name) == 0 do return Status(0), false
	empty_args: [0]Reducer_Argument
	reducer := Reducer_Definition{name = reducer_name, args = empty_args[:]}
	reducers := [1]Reducer_Definition{reducer}
	return write_reducer_module_def(sink, reducers[:])
}

lookup_table_id :: proc "contextless" (table_name: string) -> (Table_Id, Status) {
	table_id: Table_Id
	status := table_id_from_name(raw_data(table_name), uint(len(table_name)), &table_id)
	return table_id, status
}

lookup_index_id :: proc "contextless" (index_name: string) -> (Index_Id, Status) {
	index_id: Index_Id
	status := index_id_from_name(raw_data(index_name), uint(len(index_name)), &index_id)
	return index_id, status
}

table_row_count :: proc "contextless" (table_name: string) -> (u64, Status) {
	table_id, status := lookup_table_id(table_name)
	if status != Status(0) do return 0, status
	count: u64
	status = datastore_table_row_count(table_id, &count)
	return count, status
}

insert_row_bsatn :: proc "contextless" (table_name: string, row: []u8) -> (Status, uint) {
	table_id, status := lookup_table_id(table_name)
	if status != Status(0) do return status, 0
	row_len := uint(len(row))
	status = datastore_insert_bsatn(table_id, raw_data(row), &row_len)
	return status, row_len
}

update_row_bsatn :: proc "contextless" (
	table_name: string,
	unique_index_name: string,
	row: []u8,
) -> (Status, uint) {
	table_id, status := lookup_table_id(table_name)
	if status != Status(0) do return status, 0
	index_id, index_status := lookup_index_id(unique_index_name)
	if index_status != Status(0) do return index_status, 0
	row_len := uint(len(row))
	status = datastore_update_bsatn(table_id, index_id, raw_data(row), &row_len)
	return status, row_len
}

begin_table_scan :: proc "contextless" (table_name: string) -> (Row_Iterator, Status) {
	table_id, status := lookup_table_id(table_name)
	if status != Status(0) do return INVALID_ROW_ITERATOR, status
	iterator: Row_Iterator
	status = datastore_table_scan_bsatn(table_id, &iterator)
	return iterator, status
}

next_table_rows :: proc "contextless" (iterator: Row_Iterator, buffer: []u8) -> (i16, uint) {
	buffer_len := uint(len(buffer))
	result := row_iter_bsatn_advance(iterator, raw_data(buffer), &buffer_len)
	return result, buffer_len
}

close_table_scan :: proc "contextless" (iterator: Row_Iterator) -> Status {
	return row_iter_bsatn_close(iterator)
}

delete_by_index_point_bsatn :: proc "contextless" (index_name: string, point: []u8) -> (u32, Status) {
	index_id, status := lookup_index_id(index_name)
	if status != Status(0) do return 0, status
	deleted: u32
	status = datastore_delete_by_index_scan_point_bsatn(index_id, raw_data(point), uint(len(point)), &deleted)
	return deleted, status
}

delete_rows_equal_bsatn :: proc "contextless" (table_name: string, relation: []u8) -> (u32, Status) {
	table_id, status := lookup_table_id(table_name)
	if status != Status(0) do return 0, status
	deleted: u32
	status = datastore_delete_all_by_eq_bsatn(table_id, raw_data(relation), uint(len(relation)), &deleted)
	return deleted, status
}

clear_table :: proc "contextless" (table_name: string) -> (u64, Status) {
	table_id, status := lookup_table_id(table_name)
	if status != Status(0) do return 0, status
	deleted: u64
	status = datastore_clear(table_id, &deleted)
	return deleted, status
}
