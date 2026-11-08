package client

import "base:runtime"
import "stdb:host"

Row_List :: struct {
	fixed_size: u16, // 0 when rows are delimited by offsets
	offsets: []u64,
	data: []u8,
}

Table_Rows :: struct {
	table: string,
	rows: Row_List,
}

Query_Rows :: struct {
	tables: []Table_Rows,
}

// The server may send several groups for one table; persistent groups carry inserts/deletes, event groups carry events.
Update_Group :: struct {
	is_event: bool,
	inserts: Row_List,
	deletes: Row_List,
	events: Row_List,
}

Table_Update :: struct {
	table: string,
	groups: []Update_Group,
}

Query_Set_Update :: struct {
	query_set_id: u32,
	tables: []Table_Update,
}

Transaction_Update :: struct {
	query_sets: []Query_Set_Update,
}

Initial_Connection :: struct {
	identity: [32]u8,
	connection_id: [16]u8,
	token: string,
}

Subscribe_Applied :: struct {
	request_id: u32,
	query_set_id: u32,
	rows: Query_Rows,
}

Unsubscribe_Applied :: struct {
	request_id: u32,
	query_set_id: u32,
	has_rows: bool,
	rows: Query_Rows,
}

Subscribe_Set_Applied :: struct {
	rows: Query_Rows,
}

Subscribe_Set_Error :: struct {
	error: string,
}

Subscribe_Set_Outcome :: union {
	Subscribe_Set_Applied,
	Subscribe_Set_Error,
}

Subscribe_Set_Result :: struct {
	query_set_id: u32,
	outcome: Subscribe_Set_Outcome,
}

Subscribe_Batch_Applied :: struct {
	request_id: u32,
	results: []Subscribe_Set_Result,
}

Subscription_Error :: struct {
	has_request_id: bool,
	request_id: u32,
	query_set_id: u32,
	error: string,
}

One_Off_Query_Result :: struct {
	request_id: u32,
	failed: bool,
	rows: Query_Rows,
	error: string,
}

Reducer_Outcome :: enum u8 {
	Ok,
	Ok_Empty,
	Err,
	Internal_Error,
}

Reducer_Result :: struct {
	request_id: u32,
	timestamp_nanos: i64,
	outcome: Reducer_Outcome,
	return_value: []u8, // Ok: return value; Err: BSATN-encoded error value
	message: string, // Internal_Error: diagnostic text
	update: Transaction_Update, // Ok only
}

Procedure_Result :: struct {
	request_id: u32,
	timestamp_nanos: i64,
	returned: bool,
	return_value: []u8,
	message: string,
}

Server_Message :: union {
	Initial_Connection,
	Subscribe_Applied,
	Unsubscribe_Applied,
	Subscribe_Batch_Applied,
	Subscription_Error,
	Transaction_Update,
	One_Off_Query_Result,
	Reducer_Result,
	Procedure_Result,
}

// body borrows strings and byte slices from payload; message_destroy releases both.
Message :: struct {
	payload: []u8,
	body: Server_Message,
}

Client_Subscribe_Set :: struct {
	query_set_id: u32,
	queries: []string,
}

Reader :: host.Byte_Reader

reader_remaining :: proc(reader: ^Reader) -> int {
	return len(reader.buffer) - reader.offset
}

read_exact :: proc(reader: ^Reader, count: int) -> ([]u8, bool) {
	bytes, err := host.read_codec_bytes(reader, count)
	return bytes, err == .None
}

read_u8 :: proc(reader: ^Reader) -> (u8, bool) {
	bytes, ok := read_exact(reader, 1)
	if !ok do return 0, false
	return bytes[0], true
}

read_u16 :: proc(reader: ^Reader) -> (u16, bool) {
	bytes, ok := read_exact(reader, 2)
	if !ok do return 0, false
	return u16(bytes[0]) | u16(bytes[1]) << 8, true
}

read_u32 :: proc(reader: ^Reader) -> (u32, bool) {
	value, err := host.read_codec_u32(reader)
	return value, err == .None
}

read_u64 :: proc(reader: ^Reader) -> (u64, bool) {
	bytes, ok := read_exact(reader, 8)
	if !ok do return 0, false
	value: u64
	for index in 0 ..< 8 do value |= u64(bytes[index]) << u64(index * 8)
	return value, true
}

read_bytes :: proc(reader: ^Reader) -> ([]u8, bool) {
	length, ok := read_u32(reader)
	if !ok do return nil, false
	return read_exact(reader, int(length))
}

read_string :: proc(reader: ^Reader) -> (string, bool) {
	bytes, ok := read_bytes(reader)
	if !ok || !host.validate_codec_utf8(bytes) do return "", false
	return string(bytes), true
}

// Bounds counts by the remaining input so hostile lengths cannot force huge allocations.
read_count :: proc(reader: ^Reader) -> (int, bool) {
	count, ok := read_u32(reader)
	if !ok || int(count) > reader_remaining(reader) do return 0, false
	return int(count), true
}

// Option and Result tags: 0 is some/ok, 1 is none/err.
read_tag :: proc(reader: ^Reader, max: u8) -> (u8, bool) {
	tag, ok := read_u8(reader)
	if !ok || tag > max do return 0, false
	return tag, true
}

read_row_list :: proc(reader: ^Reader) -> (list: Row_List, ok: bool) {
	tag := read_tag(reader, 1) or_return
	if tag == 0 {
		list.fixed_size = read_u16(reader) or_return
		if list.fixed_size == 0 do return list, false
	} else {
		count := read_u32(reader) or_return
		if u64(count) * 8 > u64(reader_remaining(reader)) do return list, false
		list.offsets = make([]u64, int(count))
		for index in 0 ..< int(count) {
			value, value_ok := read_u64(reader)
			if !value_ok {
				row_list_destroy(&list)
				return list, false
			}
			list.offsets[index] = value
		}
	}
	data, data_ok := read_bytes(reader)
	if !data_ok {
		row_list_destroy(&list)
		return list, false
	}
	list.data = data
	return list, true
}

row_list_len :: proc(list: Row_List) -> int {
	if list.fixed_size != 0 do return len(list.data) / int(list.fixed_size)
	return len(list.offsets)
}

row_list_row :: proc(list: Row_List, index: int) -> ([]u8, bool) {
	if index < 0 || index >= row_list_len(list) do return nil, false
	if list.fixed_size != 0 {
		size := int(list.fixed_size)
		return list.data[index * size:(index + 1) * size], true
	}
	start := list.offsets[index]
	end := u64(len(list.data))
	if index + 1 < len(list.offsets) do end = list.offsets[index + 1]
	if start > end || end > u64(len(list.data)) do return nil, false
	return list.data[start:end], true
}

row_list_destroy :: proc(list: ^Row_List) {
	delete(list.offsets)
	list.offsets = nil
}

read_query_rows :: proc(reader: ^Reader) -> (rows: Query_Rows, ok: bool) {
	count := read_count(reader) or_return
	rows.tables = make([]Table_Rows, count)
	for index in 0 ..< count {
		table := &rows.tables[index]
		table_name, name_ok := read_string(reader)
		if !name_ok {
			query_rows_destroy(&rows)
			return rows, false
		}
		table.table = table_name
		list, list_ok := read_row_list(reader)
		if !list_ok {
			query_rows_destroy(&rows)
			return rows, false
		}
		table.rows = list
	}
	return rows, true
}

query_rows_destroy :: proc(rows: ^Query_Rows) {
	for &table in rows.tables do row_list_destroy(&table.rows)
	delete(rows.tables)
	rows.tables = nil
}

read_update_group :: proc(reader: ^Reader, group: ^Update_Group) -> (ok: bool) {
	tag := read_tag(reader, 1) or_return
	if tag == 0 {
		group.inserts = read_row_list(reader) or_return
		group.deletes = read_row_list(reader) or_return
	} else {
		group.is_event = true
		group.events = read_row_list(reader) or_return
	}
	return true
}

read_table_update :: proc(reader: ^Reader, table: ^Table_Update) -> (ok: bool) {
	table.table = read_string(reader) or_return
	count := read_count(reader) or_return
	table.groups = make([]Update_Group, count)
	for index in 0 ..< count do read_update_group(reader, &table.groups[index]) or_return
	return true
}

read_query_set_update :: proc(reader: ^Reader, set: ^Query_Set_Update) -> (ok: bool) {
	set.query_set_id = read_u32(reader) or_return
	count := read_count(reader) or_return
	set.tables = make([]Table_Update, count)
	for index in 0 ..< count do read_table_update(reader, &set.tables[index]) or_return
	return true
}

// Allocates before reading so a failed read can be cleaned up by transaction_update_destroy.
read_transaction_update :: proc(reader: ^Reader) -> (update: Transaction_Update, ok: bool) {
	count := read_count(reader) or_return
	update.query_sets = make([]Query_Set_Update, count)
	for index in 0 ..< count {
		if !read_query_set_update(reader, &update.query_sets[index]) {
			transaction_update_destroy(&update)
			return update, false
		}
	}
	return update, true
}

transaction_update_destroy :: proc(update: ^Transaction_Update) {
	for &set in update.query_sets {
		for &table in set.tables {
			for &group in table.groups {
				row_list_destroy(&group.inserts)
				row_list_destroy(&group.deletes)
				row_list_destroy(&group.events)
			}
			delete(table.groups)
		}
		delete(set.tables)
	}
	delete(update.query_sets)
	update.query_sets = nil
}

read_initial_connection :: proc(reader: ^Reader) -> (value: Initial_Connection, ok: bool) {
	identity := read_exact(reader, 32) or_return
	connection_id := read_exact(reader, 16) or_return
	copy(value.identity[:], identity)
	copy(value.connection_id[:], connection_id)
	value.token = read_string(reader) or_return
	return value, true
}

read_reducer_result :: proc(reader: ^Reader) -> (value: Reducer_Result, ok: bool) {
	value.request_id = read_u32(reader) or_return
	timestamp := read_u64(reader) or_return
	value.timestamp_nanos = i64(timestamp)
	tag := read_tag(reader, 3) or_return
	switch tag {
	case 0:
		value.outcome = .Ok
		value.return_value = read_bytes(reader) or_return
		value.update = read_transaction_update(reader) or_return
	case 1:
		value.outcome = .Ok_Empty
	case 2:
		value.outcome = .Err
		value.return_value = read_bytes(reader) or_return
	case 3:
		value.outcome = .Internal_Error
		value.message = read_string(reader) or_return
	}
	return value, true
}

read_procedure_result :: proc(reader: ^Reader) -> (value: Procedure_Result, ok: bool) {
	tag := read_tag(reader, 1) or_return
	if tag == 0 {
		value.returned = true
		value.return_value = read_bytes(reader) or_return
	} else {
		value.message = read_string(reader) or_return
	}
	timestamp := read_u64(reader) or_return
	value.timestamp_nanos = i64(timestamp)
	_ = read_u64(reader) or_return // total_host_execution_duration
	value.request_id = read_u32(reader) or_return
	return value, true
}

read_subscribe_batch_applied :: proc(reader: ^Reader) -> (message: Subscribe_Batch_Applied, ok: bool) {
	var_ok: bool
	message.request_id, var_ok = read_u32(reader)
	if !var_ok do return message, false
	count, count_ok := read_count(reader)
	if !count_ok do return message, false
	message.results = make([]Subscribe_Set_Result, count)
	for index in 0 ..< count {
		result := &message.results[index]
		result.query_set_id, var_ok = read_u32(reader)
		if !var_ok {
			subscribe_batch_applied_destroy(&message)
			return message, false
		}
		tag, tag_ok := read_tag(reader, 1)
		if !tag_ok {
			subscribe_batch_applied_destroy(&message)
			return message, false
		}
		if tag == 0 {
			rows, rows_ok := read_query_rows(reader)
			if !rows_ok {
				subscribe_batch_applied_destroy(&message)
				return message, false
			}
			result.outcome = Subscribe_Set_Applied{rows = rows}
		} else {
			error, error_ok := read_string(reader)
			if !error_ok {
				subscribe_batch_applied_destroy(&message)
				return message, false
			}
			result.outcome = Subscribe_Set_Error{error = error}
		}
	}
	return message, true
}

subscribe_batch_applied_destroy :: proc(message: ^Subscribe_Batch_Applied) {
	for &result in message.results {
		switch &outcome in result.outcome {
		case Subscribe_Set_Applied:
			query_rows_destroy(&outcome.rows)
		case Subscribe_Set_Error:
		}
	}
	delete(message.results)
	message.results = nil
}

// V3 frames concatenate complete BSATN client messages without per-message lengths.
encode_client_messages_v3 :: proc(messages: [][]u8) -> []u8 {
	when ODIN_OS == .JS do context = runtime.default_context()
	total_size := 0
	for message in messages do total_size += len(message)
	frame := make([dynamic]u8, 0, total_size)
	for message in messages do append(&frame, ..message)
	return frame[:]
}

// Parses one uncompressed server frame, including its compression tag.
parse_server_frame :: proc(payload: []u8) -> (body: Server_Message, ok: bool) {
	if len(payload) == 0 || payload[0] != 0 do return nil, false
	parsed_body, consumed, parsed := parse_server_message_prefix(payload[1:])
	if !parsed || consumed != len(payload) - 1 {
		server_message_destroy(&parsed_body)
		return nil, false
	}
	return parsed_body, true
}

// Parses one BSATN server message and returns the byte length consumed.
parse_server_message_prefix :: proc(payload: []u8) -> (body: Server_Message, consumed: int, ok: bool) {
	reader := Reader{buffer = payload}
	tag := read_tag(&reader, 7 + 1) or_return
	switch tag {
	case 0:
		body = read_initial_connection(&reader) or_return
	case 1:
		message: Subscribe_Applied
		message.request_id = read_u32(&reader) or_return
		message.query_set_id = read_u32(&reader) or_return
		message.rows = read_query_rows(&reader) or_return
		body = message
	case 2:
		message: Unsubscribe_Applied
		message.request_id = read_u32(&reader) or_return
		message.query_set_id = read_u32(&reader) or_return
		present := read_tag(&reader, 1) or_return
		if present == 0 {
			message.has_rows = true
			message.rows = read_query_rows(&reader) or_return
		}
		body = message
	case 3:
		message: Subscription_Error
		present := read_tag(&reader, 1) or_return
		if present == 0 {
			message.has_request_id = true
			message.request_id = read_u32(&reader) or_return
		}
		message.query_set_id = read_u32(&reader) or_return
		message.error = read_string(&reader) or_return
		body = message
	case 4:
		body = read_transaction_update(&reader) or_return
	case 5:
		message: One_Off_Query_Result
		message.request_id = read_u32(&reader) or_return
		result := read_tag(&reader, 1) or_return
		if result == 0 {
			message.rows = read_query_rows(&reader) or_return
		} else {
			message.failed = true
			message.error = read_string(&reader) or_return
		}
		body = message
	case 6:
		body = read_reducer_result(&reader) or_return
	case 7:
		body = read_procedure_result(&reader) or_return
	case 8:
		body = read_subscribe_batch_applied(&reader) or_return
	case:
		return nil, 0, false
	}
	return body, reader.offset, true
}

server_message_destroy :: proc(body: ^Server_Message) {
	switch &value in body {
	case Initial_Connection, Subscription_Error, Procedure_Result:
	case Subscribe_Applied:
		query_rows_destroy(&value.rows)
	case Unsubscribe_Applied:
		query_rows_destroy(&value.rows)
	case Subscribe_Batch_Applied:
		subscribe_batch_applied_destroy(&value)
	case Transaction_Update:
		transaction_update_destroy(&value)
	case One_Off_Query_Result:
		query_rows_destroy(&value.rows)
	case Reducer_Result:
		transaction_update_destroy(&value.update)
	}
	body^ = nil
}

message_destroy :: proc(message: ^Message) {
	when ODIN_OS == .JS do context = runtime.default_context()
	server_message_destroy(&message.body)
	delete(message.payload)
	message.payload = nil
}

// Client messages are BSATN: enum tag, then fields in declaration order.
Builder :: struct {
	bytes: [dynamic]u8,
}

builder_u8 :: proc(builder: ^Builder, value: u8) {
	append(&builder.bytes, value)
}

builder_u32 :: proc(builder: ^Builder, value: u32) {
	append(&builder.bytes, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
}

builder_bytes :: proc(builder: ^Builder, value: []u8) {
	builder_u32(builder, u32(len(value)))
	append(&builder.bytes, ..value)
}

builder_string :: proc(builder: ^Builder, value: string) {
	builder_bytes(builder, transmute([]u8)value)
}

encode_subscribe :: proc(builder: ^Builder, request_id, query_set_id: u32, queries: []string) {
	builder_u8(builder, 0)
	builder_u32(builder, request_id)
	builder_u32(builder, query_set_id)
	builder_u32(builder, u32(len(queries)))
	for query in queries do builder_string(builder, query)
}

encode_subscribe_batch :: proc(builder: ^Builder, request_id: u32, sets: []Client_Subscribe_Set) {
	builder_u8(builder, 5)
	builder_u32(builder, request_id)
	builder_u32(builder, u32(len(sets)))
	for set in sets {
		builder_u32(builder, set.query_set_id)
		builder_u32(builder, u32(len(set.queries)))
		for query in set.queries do builder_string(builder, query)
	}
}

encode_unsubscribe :: proc(builder: ^Builder, request_id, query_set_id: u32, send_dropped_rows: bool) {
	builder_u8(builder, 1)
	builder_u32(builder, request_id)
	builder_u32(builder, query_set_id)
	builder_u8(builder, 1 if send_dropped_rows else 0)
}

encode_one_off_query :: proc(builder: ^Builder, request_id: u32, query: string) {
	builder_u8(builder, 2)
	builder_u32(builder, request_id)
	builder_string(builder, query)
}

encode_call_reducer :: proc(builder: ^Builder, request_id: u32, reducer: string, args: []u8) {
	builder_u8(builder, 3)
	builder_u32(builder, request_id)
	builder_u8(builder, 0)
	builder_string(builder, reducer)
	builder_bytes(builder, args)
}

encode_call_procedure :: proc(builder: ^Builder, request_id: u32, procedure: string, args: []u8) {
	builder_u8(builder, 4)
	builder_u32(builder, request_id)
	builder_u8(builder, 0)
	builder_string(builder, procedure)
	builder_bytes(builder, args)
}
