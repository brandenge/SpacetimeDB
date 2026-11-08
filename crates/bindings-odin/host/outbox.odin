package host

import "base:runtime"
import "core:reflect"
import "core:slice"

Outbox_Error :: enum u8 {
	None,
	Invalid_Remote_Reducer,
	Invalid_Primary_Key,
	Invalid_Primary_Key_Type,
	Primary_Key_Not_Auto_Increment,
	Target_Column_Not_Found,
	Target_Column_Not_Identity,
	Argument_Buffer_Too_Small,
	Argument_Column_Not_Found,
	Argument_Column_Ambiguous,
	Argument_Type_Mismatch,
}

@(private)
same_type :: proc(left, right: ^reflect.Type_Info) -> bool {
	if left == nil || right == nil do return false
	left_bytes, left_ok := encode_algebraic_type(left)
	if !left_ok do return false
	right_bytes, right_ok := encode_algebraic_type(right)
	if !right_ok {
		delete(left_bytes)
		return false
	}
	equal := slice.equal(left_bytes[:], right_bytes[:])
	delete(left_bytes)
	delete(right_bytes)
	return equal
}

// Matches receiver parameters by name and algebraic type and returns their table column indices
// in receiver argument order. The caller owns arg_column_buffer for as long as the descriptor is used.
make_outbox_definition :: proc (
	table: Table_Definition,
	remote_reducer: string,
	target_column: string,
	remote_args: []Reducer_Argument,
	arg_column_buffer: []u16,
	signature_hash: [32]u8,
	on_result_reducer: runtime.Maybe(string) = nil,
) -> (Outbox_Definition, Outbox_Error) {
	if len(remote_reducer) == 0 do return {}, .Invalid_Remote_Reducer
	if len(table.primary_key_columns) != 1 do return {}, .Invalid_Primary_Key
	primary_key := int(table.primary_key_columns[0])
	if primary_key >= len(table.columns) do return {}, .Invalid_Primary_Key
	if table.columns[primary_key].type != .U64 || table.columns[primary_key].container != .None {
		return {}, .Invalid_Primary_Key_Type
	}
	auto_increment := false
	for column in table.auto_increment_columns do if int(column) == primary_key do auto_increment = true
	if !auto_increment do return {}, .Primary_Key_Not_Auto_Increment

	target_index := -1
	for column, index in table.columns {
		if column.name == target_column {
			target_index = index
			break
		}
	}
	if target_index < 0 do return {}, .Target_Column_Not_Found
	if !same_type(table.columns[target_index].info, type_info_of(Identity)) do return {}, .Target_Column_Not_Identity
	if len(arg_column_buffer) < len(remote_args) do return {}, .Argument_Buffer_Too_Small

	for remote_arg, arg_index in remote_args {
		if len(remote_arg.name) == 0 || remote_arg.info == nil do return {}, .Argument_Column_Not_Found
		matched_column := -1
		name_found := false
		for column, index in table.columns {
			if column.name != remote_arg.name do continue
			name_found = true
			if same_type(column.info, remote_arg.info) {
				if matched_column >= 0 do return {}, .Argument_Column_Ambiguous
				matched_column = index
			}
		}
		if matched_column < 0 do return {}, .Argument_Type_Mismatch if name_found else .Argument_Column_Not_Found
		arg_column_buffer[arg_index] = u16(matched_column)
	}

	return Outbox_Definition{
		remote_reducer = remote_reducer,
		target_column = u16(target_index),
		arg_columns = arg_column_buffer[:len(remote_args)],
		on_result_reducer = on_result_reducer,
		signature_hash = signature_hash,
	}, .None
}

// Argument metadata for an on-result reducer: the source row by table reference and Result<(), String>.
outbox_result_arguments :: proc "contextless" ($Row: typeid, table_name: string) -> [2]Reducer_Argument {
	return [2]Reducer_Argument{
		{name = "row", table_ref = table_name},
		{name = "result", info = type_info_of(Outbox_Result)},
	}
}

// Reads an on-result reducer's (outbox row, delivery result) payload. Decoded strings and slices
// borrow from buffer and must not outlive or survive reuse of that buffer.
read_outbox_result_args :: proc($Row: typeid, source: Bytes_Source, buffer: []u8) -> (Outbox_Result_Args(Row), Codec_Error) {
	return read_reducer_args(Outbox_Result_Args(Row), source, buffer)
}

outbox_result_dispatch :: proc(
	$Row: typeid,
	source: Bytes_Source,
	buffer: []u8,
	handler: proc(args: ^Outbox_Result_Args(Row), user: rawptr) -> Status,
	user: rawptr = nil,
) -> (Status, Codec_Error) {
	if handler == nil do return Status(1), .Unsupported_Type
	args, err := read_outbox_result_args(Row, source, buffer)
	if err != .None do return Status(1), err
	return handler(&args, user), .None
}
