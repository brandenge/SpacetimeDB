package main

import "base:runtime"
import "core:reflect"
import "core:strings"
import "stdb:host"

Item :: struct {
	id: u32,
	name: string,
}

Arguments :: Item

Note :: struct {
	id: u64,
	text: string,
}

Text_Args :: struct {
	text: string,
}

Timer :: struct {
	scheduled_id: u64,
	scheduled_at: host.Schedule_At,
}

Limit_Args :: struct {
	limit: u32,
}

Id_Args :: struct {
	id: u32,
}

Probe_Args :: struct {
	url: string,
	method: string, // empty sends GET
	version: u8, // Http_Version: 0 default, 1 HTTP/0.9, 2 HTTP/1.0, 3 HTTP/1.1, 4 HTTP/2, 5 HTTP/3
}

Point :: struct {
	x: i32,
	y: i32,
}

Kind :: enum u8 {
	Small,
	Large,
}

Shape :: struct {
	origin: Point,
	corners: []Point,
	label: Maybe(string),
	kind: Kind,
	weight: host.U256,
	score: f32,
}

Maybe :: runtime.Maybe

Session :: struct {
	identity: host.Identity,
	connected_at: host.Timestamp,
}

Circle :: struct {
	radius: u32,
}

Rect :: struct {
	width: u32,
	height: u32,
}

Label :: struct {
	text: string,
}

Nothing :: struct {}

// Sum types are #no_nil unions whose variants are named types.
Shape_Kind :: union #no_nil {
	Circle,
	Rect,
	Label,
	Nothing,
}

Drawing :: struct {
	kind: Shape_Kind,
	count: u8,
}

Shape_Holder :: struct {
	count: u8,
}

// A sum type whose variant is itself a sum type.
Wrapper :: union #no_nil {
	Shape_Kind,
	Shape_Holder,
}

Nested :: struct {
	list: []Shape_Kind,
	maybe: Maybe(Shape_Kind),
	wrapper: Wrapper,
	fixed: [2]Shape_Kind,
}

Leaf :: union #no_nil {
	Circle,
	Nothing,
}

Mid :: struct {
	leaf: Leaf,
	tag: u8,
}

Branch :: union #no_nil {
	Mid,
	Shape_Holder,
}

Top :: struct {
	branch: Branch,
}

// Sum -> struct payload -> sum -> struct payload -> sum.
Root :: union #no_nil {
	Top,
	Label,
}

Boxed :: struct {
	kind: Shape_Kind,
	note: string,
}

Deep :: struct {
	root: Root,
	boxed: Maybe(Boxed),
	items: []Maybe(Boxed),
}

// Six sums deep, each reached through a struct payload.
S5 :: union #no_nil {
	Circle,
	Nothing,
}

P4 :: struct {
	s: S5,
	n: u8,
}

S4 :: union #no_nil {
	P4,
	Shape_Holder,
}

P3 :: struct {
	s: S4,
}

S3 :: union #no_nil {
	P3,
	Label,
}

P2 :: struct {
	s: S3,
	n: u8,
}

S2 :: union #no_nil {
	P2,
	Shape_Holder,
}

P1 :: struct {
	s: S2,
}

S1 :: union #no_nil {
	P1,
	Label,
}

P0 :: struct {
	s: S1,
	tag: u8,
}

S0 :: union #no_nil {
	P0,
	Nothing,
}

Deeper :: struct {
	chain: S0,
	grid: [2]Maybe(Boxed),
	pair: [2]Maybe(Mid),
}

report_failure :: host.reducer_fail

@(export, link_name="__describe_module__")
describe_module :: proc "c" (description: host.Bytes_Sink) {
	context = host.scratch_context()
	argument_storage: [2]host.Reducer_Argument
	argument_count, argument_error := host.table_columns_into_type(Arguments, argument_storage[:])
	if argument_error != .None do return
	shape_storage: [6]host.Reducer_Argument
	shape_count, shape_error := host.table_columns_into_type(Shape, shape_storage[:])
	if shape_error != .None do return
	shape_weight_column := [1]u16{4}
	shape_score_column := [1]u16{5}
	shape_indexes := [?]host.Table_Index{
		{source_name = "shapes_weight_idx_btree", accessor_name = "weight_idx", algorithm = .BTree, columns = shape_weight_column[:]},
		{source_name = "shapes_score_idx_btree", accessor_name = "score_idx", algorithm = .BTree, columns = shape_score_column[:]},
	}
	drawing_storage: [2]host.Reducer_Argument
	drawing_count, drawing_error := host.table_columns_into_type(Drawing, drawing_storage[:])
	if drawing_error != .None do return
	nested_storage: [4]host.Reducer_Argument
	nested_count, nested_error := host.table_columns_into_type(Nested, nested_storage[:])
	if nested_error != .None do return
	deep_storage: [3]host.Reducer_Argument
	deep_count, deep_error := host.table_columns_into_type(Deep, deep_storage[:])
	if deep_error != .None do return
	deeper_storage: [3]host.Reducer_Argument
	deeper_count, deeper_error := host.table_columns_into_type(Deeper, deeper_storage[:])
	if deeper_error != .None do return
	limit_storage: [1]host.Reducer_Argument
	limit_count, limit_error := host.table_columns_into_type(Limit_Args, limit_storage[:])
	if limit_error != .None do return
	id_storage: [1]host.Reducer_Argument
	id_count, id_error := host.table_columns_into_type(Id_Args, id_storage[:])
	if id_error != .None do return
	text_storage: [1]host.Reducer_Argument
	probe_storage: [3]host.Reducer_Argument
	probe_count, probe_error := host.table_columns_into_type(Probe_Args, probe_storage[:])
	if probe_error != .None do return
	text_count, text_error := host.table_columns_into_type(Text_Args, text_storage[:])
	if text_error != .None do return
	note_storage: [2]host.Reducer_Argument
	note_count, note_error := host.table_columns_into_type(Note, note_storage[:])
	if note_error != .None do return
	note_key := [1]u16{0}
	note_indexes := [?]host.Table_Index{
		{source_name = "notes_id_idx_btree", accessor_name = "id_idx", algorithm = .BTree, columns = note_key[:]},
	}
	note_unique := [?]host.Unique_Constraint{{columns = note_key[:]}}
	timer_storage: [2]host.Reducer_Argument
	timer_count, timer_error := host.table_columns_into_type(Timer, timer_storage[:])
	if timer_error != .None do return
	timer_key := [1]u16{0}
	timer_indexes := [?]host.Table_Index{
		{source_name = "timers_scheduled_id_idx_btree", accessor_name = "scheduled_id_idx", algorithm = .BTree, columns = timer_key[:]},
	}
	timer_unique := [?]host.Unique_Constraint{{columns = timer_key[:]}}
	reducers := [?]host.Reducer_Definition{
		{name = "set_score", args = argument_storage[:argument_count]},
		{name = "ping", args = nil},
		{name = "update_score", args = argument_storage[:argument_count]},
		{name = "delete_score", args = argument_storage[:argument_count]},
		{name = "clear_items", args = nil},
		{name = "count_items", args = nil},
		{name = "scan_items", args = nil},
		{name = "add_shape", args = shape_storage[:shape_count]},
		{name = "init", lifecycle = .Init},
		{name = "client_connected", lifecycle = .On_Connect},
		{name = "client_disconnected", lifecycle = .On_Disconnect},
		{name = "prune_items", args = limit_storage[:limit_count]},
		{name = "touch_item", args = id_storage[:id_count]},
		{name = "add_note", args = text_storage[:text_count]},
		{name = "tick", row_table = "timers", private = true},
		{name = "start_ticker", args = nil},
		{name = "stop_ticker", args = nil},
		{name = "purge_items", args = limit_storage[:limit_count]},
		{name = "add_drawing", args = drawing_storage[:drawing_count]},
		{name = "add_nested", args = nested_storage[:nested_count]},
		{name = "add_deep", args = deep_storage[:deep_count]},
		{name = "add_deeper", args = deeper_storage[:deeper_count]},
	}
	session_storage: [2]host.Reducer_Argument
	session_count, session_error := host.table_columns_into_type(Session, session_storage[:])
	if session_error != .None do return
	session_key := [1]u16{0}
	session_indexes := [?]host.Table_Index{
		{
			source_name = "sessions_identity_idx_btree",
			accessor_name = "identity_idx",
			algorithm = .BTree,
			columns = session_key[:],
		},
	}
	session_unique := [?]host.Unique_Constraint{{columns = session_key[:]}}
	column_storage: [2]host.Reducer_Argument
	column_count, column_error := host.table_columns_into_type(Item, column_storage[:])
	if column_error != .None do return
	key_columns := [1]u16{0}
	indexes := [?]host.Table_Index{
		{
			source_name = "items_id_idx_btree",
			accessor_name = "id_idx",
			algorithm = .BTree,
			columns = key_columns[:],
		},
	}
	unique_constraints := [?]host.Unique_Constraint{
		{columns = key_columns[:]},
	}
	tables := [?]host.Table_Definition{
		{
			name = "timers",
			columns = timer_storage[:timer_count],
			access = .Private,
			primary_key_columns = timer_key[:],
			indexes = timer_indexes[:],
			unique_constraints = timer_unique[:],
			auto_increment_columns = timer_key[:],
			scheduled_reducer = "tick",
			schedule_at_column = 1,
		},
		{
			name = "notes",
			columns = note_storage[:note_count],
			access = .Public,
			primary_key_columns = note_key[:],
			indexes = note_indexes[:],
			unique_constraints = note_unique[:],
			auto_increment_columns = note_key[:],
		},
		{
			name = "sessions",
			columns = session_storage[:session_count],
			access = .Public,
			primary_key_columns = session_key[:],
			indexes = session_indexes[:],
			unique_constraints = session_unique[:],
		},
		{
			name = "shapes",
			columns = shape_storage[:shape_count],
			access = .Public,
			indexes = shape_indexes[:],
		},
		{
			name = "drawings",
			columns = drawing_storage[:drawing_count],
			access = .Public,
		},
		{
			name = "nested",
			columns = nested_storage[:nested_count],
			access = .Public,
		},
		{
			name = "deep",
			columns = deep_storage[:deep_count],
			access = .Public,
		},
		{
			name = "deeper",
			columns = deeper_storage[:deeper_count],
			access = .Public,
		},
		{
			name = "items",
			columns = column_storage[:column_count],
			access = .Public,
			primary_key_columns = key_columns[:],
			indexes = indexes[:],
			unique_constraints = unique_constraints[:],
		},
	}
	views := [?]host.View_Definition{
		{name = "all_notes", row_info = type_info_of(Note), is_anonymous = true, primary_key = "id"},
		{name = "my_sessions", row_info = type_info_of(Session)},
	}
	procedures := [?]host.Procedure_Definition{
		{name = "add_note_tx", args = text_storage[:text_count], return_info = type_info_of(u64)},
		{name = "fetch_code", args = text_storage[:text_count], return_info = type_info_of(u16)},
		{name = "post_echo", args = text_storage[:text_count], return_info = type_info_of(string)},
		{name = "fetch_with_timeout", args = text_storage[:text_count], return_info = type_info_of(u16)},
		{name = "http_probe", args = probe_storage[:probe_count], return_info = type_info_of(u32)},
	}
	handlers := [?]string{"hello", "echo", "anything"}
	routes := [?]host.Http_Route{
		{handler = "hello", path = "/hello", method = .Get},
		{handler = "echo", path = "/echo", method = .Post},
		{handler = "anything", path = "/any", any_method = true},
	}
	_, _ = host.write_module_def_all(description, reducers[:], tables[:], views[:], procedures[:], handlers[:], routes[:])
}

@(export, link_name="__call_reducer__")
call_reducer :: proc "c" (
	id: uint,
	sender_0, sender_1, sender_2, sender_3: u64,
	conn_id_0, conn_id_1: u64,
	timestamp: u64,
	args: host.Bytes_Source,
	error: host.Bytes_Sink,
) -> i16 {
	context = host.scratch_context()
	reducer_context := host.reducer_context(sender_0, sender_1, sender_2, sender_3, conn_id_0, conn_id_1, timestamp)
	items, table_error := host.typed_table(Item, "items", "items_id_idx_btree")
	if table_error != .None do return report_failure(error, "invalid typed table")
	argument_buffer: [32]u8
	row_buffer: [256]u8
	if id == 0 {
		values, codec_error := host.read_reducer_args(Arguments, args, argument_buffer[:])
		if codec_error != .None do return report_failure(error, "invalid set_score arguments")
		status, operation_error := host.typed_insert(Item, items, values, row_buffer[:])
		if operation_error != .None || status != host.Status(0) do return report_failure(error, "insert failed")
		return 0
	}
	if id == 1 do return 0
	if id == 2 {
		values, codec_error := host.read_reducer_args(Arguments, args, argument_buffer[:])
		if codec_error != .None do return report_failure(error, "invalid update_score arguments")
		status, operation_error := host.typed_update(Item, items, values, row_buffer[:])
		if operation_error != .None || status != host.Status(0) do return report_failure(error, "update failed")
		return 0
	}
	if id == 3 {
		values, codec_error := host.read_reducer_args(Arguments, args, argument_buffer[:])
		if codec_error != .None do return report_failure(error, "invalid delete_score arguments")
		_, status, operation_error := host.typed_delete(Item, items, values, row_buffer[:])
		if operation_error != .None || status != host.Status(0) do return report_failure(error, "delete failed")
		return 0
	}
	if id == 4 {
		_, status := host.clear_table(items.name)
		if status != host.Status(0) do return report_failure(error, "clear failed")
		return 0
	}
	if id == 5 {
		_, status := host.typed_count(Item, items)
		if status != host.Status(0) do return report_failure(error, "count failed")
		return 0
	}
	if id == 6 {
		batch: [4096]u8
		scan, status := host.typed_scan_open(Item, items, batch[:])
		if status != host.Status(0) do return report_failure(error, "scan failed")
		for {
			row, has_row, scan_status, codec_error := host.typed_scan_next(Item, &scan)
			if codec_error != .None || (scan_status != 0 && scan_status != -1) {
				_ = host.typed_scan_close(Item, &scan)
				return report_failure(error, "scan failed")
			}
			if !has_row do break
			_ = row
		}
		_ = host.typed_scan_close(Item, &scan)
		return 0
	}
	if id == 8 do return 0
	if id == 11 {
		limit_args, codec_error := host.read_reducer_args(Limit_Args, args, argument_buffer[:])
		if codec_error != .None do return report_failure(error, "invalid prune_items arguments")
		batch: [4096]u8
		key_buffer: [64]u8
		scan, scan_status, scan_error := host.typed_scan_index_range(
			Item, items.unique_index_name,
			host.bound_unbounded(u32), host.bound_excluded(limit_args.limit), key_buffer[:], batch[:],
		)
		if scan_error != .None || scan_status != host.Status(0) do return report_failure(error, "range scan failed")
		// Rows borrow from batch, so everything must fit in one batch.
		matched: [32]Item
		matched_count := 0
		for {
			row, has_row, next_status, next_error := host.typed_scan_next(Item, &scan)
			if next_error != .None || (next_status != 0 && next_status != -1) {
				_ = host.typed_scan_close(Item, &scan)
				return report_failure(error, "range scan failed")
			}
			if !has_row do break
			if matched_count < len(matched) {
				matched[matched_count] = row
				matched_count += 1
			}
		}
		_ = host.typed_scan_close(Item, &scan)
		for index in 0 ..< matched_count {
			_, delete_status, delete_error := host.typed_delete(Item, items, matched[index], row_buffer[:])
			if delete_error != .None || delete_status != host.Status(0) do return report_failure(error, "delete failed")
		}
		return 0
	}
	if id == 21 {
		deeper_args_buffer: [768]u8
		deeper, deeper_codec_error := host.read_reducer_args(Deeper, args, deeper_args_buffer[:])
		if deeper_codec_error != .None do return report_failure(error, "invalid add_deeper arguments")
		deeper_table, deeper_table_error := host.typed_table(Deeper, "deeper", "")
		if deeper_table_error != .None do return report_failure(error, "invalid deeper table")
		deeper_row: [768]u8
		deeper_status, deeper_insert_error := host.typed_insert(Deeper, deeper_table, deeper, deeper_row[:])
		if deeper_insert_error != .None || deeper_status != host.Status(0) do return report_failure(error, "deeper insert failed")
		return 0
	}
	if id == 20 {
		deep_args_buffer: [512]u8
		deep, deep_codec_error := host.read_reducer_args(Deep, args, deep_args_buffer[:])
		if deep_codec_error != .None do return report_failure(error, "invalid add_deep arguments")
		deep_table, deep_table_error := host.typed_table(Deep, "deep", "")
		if deep_table_error != .None do return report_failure(error, "invalid deep table")
		deep_row: [512]u8
		deep_status, deep_insert_error := host.typed_insert(Deep, deep_table, deep, deep_row[:])
		if deep_insert_error != .None || deep_status != host.Status(0) do return report_failure(error, "deep insert failed")
		return 0
	}
	if id == 19 {
		nested_args_buffer: [512]u8
		nested, nested_codec_error := host.read_reducer_args(Nested, args, nested_args_buffer[:])
		if nested_codec_error != .None do return report_failure(error, "invalid add_nested arguments")
		nested_table, nested_table_error := host.typed_table(Nested, "nested", "")
		if nested_table_error != .None do return report_failure(error, "invalid nested table")
		nested_row: [512]u8
		nested_status, nested_insert_error := host.typed_insert(Nested, nested_table, nested, nested_row[:])
		if nested_insert_error != .None || nested_status != host.Status(0) do return report_failure(error, "nested insert failed")
		return 0
	}
	if id == 18 {
		drawing_buffer: [128]u8
		drawing, drawing_codec_error := host.read_reducer_args(Drawing, args, drawing_buffer[:])
		if drawing_codec_error != .None do return report_failure(error, "invalid add_drawing arguments")
		drawings, drawings_error := host.typed_table(Drawing, "drawings", "")
		if drawings_error != .None do return report_failure(error, "invalid drawings table")
		drawing_row: [128]u8
		status, insert_error := host.typed_insert(Drawing, drawings, drawing, drawing_row[:])
		if insert_error != .None || status != host.Status(0) do return report_failure(error, "drawing insert failed")
		return 0
	}
	if id == 17 {
		limit_args, codec_error := host.read_reducer_args(Limit_Args, args, argument_buffer[:])
		if codec_error != .None do return report_failure(error, "invalid purge_items arguments")
		key_buffer: [32]u8
		_, status, delete_error := host.typed_delete_index_range(
			items.unique_index_name,
			host.bound_unbounded(u32), host.bound_excluded(limit_args.limit), key_buffer[:],
		)
		if delete_error != .None || status != host.Status(0) do return report_failure(error, "range delete failed")
		return 0
	}
	if id == 14 || id == 15 || id == 16 {
		if id == 14 {
			notes, notes_error := host.typed_table(Note, "notes", "notes_id_idx_btree")
			if notes_error != .None do return report_failure(error, "invalid notes table")
			status, insert_error := host.typed_insert(Note, notes, Note{text = "tick"}, row_buffer[:])
			if insert_error != .None || status != host.Status(0) do return report_failure(error, "tick insert failed")
			return 0
		}
		if id == 16 {
			_, status := host.clear_table("timers")
			if status != host.Status(0) do return report_failure(error, "stop failed")
			return 0
		}
		timers, timers_error := host.typed_table(Timer, "timers", "timers_scheduled_id_idx_btree")
		if timers_error != .None do return report_failure(error, "invalid timers table")
		timer := Timer{scheduled_at = host.schedule_every(host.Time_Duration(500_000))}
		status, insert_error := host.typed_insert(Timer, timers, timer, row_buffer[:])
		if insert_error != .None || status != host.Status(0) do return report_failure(error, "schedule failed")
		return 0
	}
	if id == 13 {
		text_args, codec_error := host.read_reducer_args(Text_Args, args, argument_buffer[:])
		if codec_error != .None do return report_failure(error, "invalid add_note arguments")
		auto_columns := [1]u16{0}
		notes, notes_error := host.typed_table(Note, "notes", "notes_id_idx_btree")
		if notes_error != .None do return report_failure(error, "invalid notes table")
		notes.auto_columns = auto_columns[:]
		stored, status, insert_error := host.typed_insert_returning(Note, notes, Note{text = text_args.text}, row_buffer[:])
		if insert_error != .None || status != host.Status(0) do return report_failure(error, "note insert failed")
		// The generated id is also usable immediately.
		if stored.id == 0 do return report_failure(error, "id was not generated")
		return 0
	}
	if id == 12 {
		id_args, codec_error := host.read_reducer_args(Id_Args, args, argument_buffer[:])
		if codec_error != .None do return report_failure(error, "invalid touch_item arguments")
		batch: [1024]u8
		key_buffer: [16]u8
		scan, scan_status, scan_error := host.typed_scan_index_point(Item, items.unique_index_name, id_args.id, key_buffer[:], batch[:])
		if scan_error != .None || scan_status != host.Status(0) do return report_failure(error, "point scan failed")
		row, has_row, next_status, next_error := host.typed_scan_next(Item, &scan)
		_ = host.typed_scan_close(Item, &scan)
		if next_error != .None || next_status < -1 do return report_failure(error, "point scan failed")
		if !has_row do return report_failure(error, "no such item")
		row.name = "touched"
		update_status, update_error := host.typed_update(Item, items, row, row_buffer[:])
		if update_error != .None || update_status != host.Status(0) do return report_failure(error, "update failed")
		return 0
	}
	if id == 9 || id == 10 {
		sessions, sessions_error := host.typed_table(Session, "sessions", "sessions_identity_idx_btree")
		if sessions_error != .None do return report_failure(error, "invalid sessions table")
		if id == 9 {
			session := Session{identity = reducer_context.sender, connected_at = reducer_context.timestamp}
			status, operation_error := host.typed_insert(Session, sessions, session, row_buffer[:])
			if operation_error != .None || status != host.Status(0) do return report_failure(error, "session insert failed")
			return 0
		}
		point: [32]u8 = transmute([32]u8)reducer_context.sender
		_, status := host.delete_by_index_point_bsatn(sessions.unique_index_name, point[:])
		if status != host.Status(0) do return report_failure(error, "session delete failed")
		return 0
	}
	if id == 7 {
		shapes, shapes_error := host.typed_table(Shape, "shapes", "")
		if shapes_error != .None do return report_failure(error, "invalid shapes table")
		shape_buffer: [512]u8
		value, codec_error := host.read_reducer_args(Shape, args, shape_buffer[:])
		if codec_error != .None do return report_failure(error, reflect.enum_string(codec_error))
		status, operation_error := host.typed_insert(Shape, shapes, value, row_buffer[:])
		if operation_error != .None || status != host.Status(0) do return report_failure(error, "insert failed")
		return 0
	}
	return -1
}

@(export, link_name="__call_http_handler__")
call_http_handler :: proc "c" (
	id: uint,
	sender_0, sender_1, sender_2, sender_3: u64,
	sender_jwt: host.Bytes_Source,
	timestamp: u64,
	request: host.Bytes_Source,
	request_body: host.Bytes_Source,
	response_sink: host.Bytes_Sink,
	response_body_sink: host.Bytes_Sink,
) -> i16 {
	context = host.scratch_context()
	sender_jwt_payload, jwt_ok := host.read_bytes_source(sender_jwt)
	if !jwt_ok {
		_ = host.write_http_response(response_sink, response_body_sink, 500, nil, transmute([]u8)string("failed to read handler auth"))
		return host.HTTP_HANDLER_OK
	}
	handler_context := host.http_handler_context(
		sender_0, sender_1, sender_2, sender_3,
		sender_jwt_payload,
		timestamp,
	)
	incoming, ok := host.read_http_request(request, request_body)
	if !ok {
		_ = host.write_http_response(response_sink, response_body_sink, 400, nil, transmute([]u8)string("bad request"))
		return host.HTTP_HANDLER_OK
	}
	plain := [?]host.Http_Header{{name = "content-type", value = transmute([]u8)string("text/plain")}}
	switch id {
	case 0:
		_ = host.write_http_response(response_sink, response_body_sink, 200, plain[:], transmute([]u8)string("hello from odin"))
	case 1:
		// Echo the body and report the request's content-type back in a custom header.
		content_type, _ := host.http_header_value(incoming.headers, "Content-Type")
		echoed := [?]host.Http_Header{{name = "x-echo-content-type", value = content_type}}
		_ = host.write_http_response(response_sink, response_body_sink, 201, echoed[:], incoming.body)
	case 2:
		// Reports the method and URI the handler saw.
		description := strings.concatenate({reflect.enum_string(incoming.method), " ", incoming.uri})
		_ = host.write_http_response(response_sink, response_body_sink, 200, plain[:], transmute([]u8)description)
	case:
		_ = host.write_http_response(response_sink, response_body_sink, 404, nil, transmute([]u8)string("no such handler"))
	}
	return host.HTTP_HANDLER_OK
}

@(export, link_name="__call_view_anon__")
call_view_anon :: proc "c" (id: uint, args: host.Bytes_Source, sink: host.Bytes_Sink) -> i16 {
	context = host.scratch_context()
	if id != 0 do return -1
	notes, table_error := host.typed_table(Note, "notes", "notes_id_idx_btree")
	if table_error != .None do return -1
	batch: [4096]u8
	rows: [64]Note
	count := 0
	scan, scan_status := host.typed_scan_open(Note, notes, batch[:])
	if scan_status != host.Status(0) do return -1
	for {
		row, has_row, status, codec_error := host.typed_scan_next(Note, &scan)
		if codec_error != .None || (status != 0 && status != -1) {
			_ = host.typed_scan_close(Note, &scan)
			return -1
		}
		if !has_row do break
		if count < len(rows) {
			rows[count] = row
			count += 1
		}
	}
	_ = host.typed_scan_close(Note, &scan)
	encoded: [256]u8
	if host.write_view_rows(Note, sink, rows[:count], encoded[:]) != .None do return -1
	return host.VIEW_ABI_RESULT
}

@(export, link_name="__call_view__")
call_view :: proc "c" (
	id: uint,
	sender_0, sender_1, sender_2, sender_3: u64,
	args: host.Bytes_Source,
	sink: host.Bytes_Sink,
) -> i16 {
	context = host.scratch_context()
	if id != 0 do return -1
	caller := host.reducer_context(sender_0, sender_1, sender_2, sender_3, 0, 0, 0).sender
	sessions, table_error := host.typed_table(Session, "sessions", "sessions_identity_idx_btree")
	if table_error != .None do return -1
	batch: [1024]u8
	key_buffer: [32]u8
	rows: [8]Session
	count := 0
	scan, scan_status, scan_error := host.typed_scan_index_point(Session, sessions.unique_index_name, caller, key_buffer[:], batch[:])
	if scan_error != .None || scan_status != host.Status(0) do return -1
	for {
		row, has_row, status, codec_error := host.typed_scan_next(Session, &scan)
		if codec_error != .None || (status != 0 && status != -1) {
			_ = host.typed_scan_close(Session, &scan)
			return -1
		}
		if !has_row do break
		if count < len(rows) {
			rows[count] = row
			count += 1
		}
	}
	_ = host.typed_scan_close(Session, &scan)
	encoded: [128]u8
	if host.write_view_rows(Session, sink, rows[:count], encoded[:]) != .None do return -1
	return host.VIEW_ABI_RESULT
}

@(export, link_name="__call_procedure__")
call_procedure :: proc "c" (
	id: uint,
	sender_0, sender_1, sender_2, sender_3: u64,
	conn_id_0, conn_id_1: u64,
	timestamp: u64,
	args: host.Bytes_Source,
	result: host.Bytes_Sink,
) -> i16 {
	context = host.scratch_context()
	if id == 1 {
		fetch_args_buffer: [256]u8
		fetch_args, fetch_codec_error := host.read_reducer_args(Text_Args, args, fetch_args_buffer[:])
		if fetch_codec_error != .None do return -1
		response, http_status, http_error := host.http_request(host.Http_Request{method = .Get, uri = fetch_args.text})
		// Failures are reported as 1000 + Http_Error, with the host status in the next thousand.
		code := response.code
		if http_error != .None do code = u16(1000 + int(http_error) + 100 * int(http_status))
		encoded_code: [8]u8
		if host.write_procedure_result(u16, result, code, encoded_code[:]) != .None do return -1
		return 0
	}
	if id == 2 {
		echo_args_buffer: [256]u8
		echo_args, echo_codec_error := host.read_reducer_args(Text_Args, args, echo_args_buffer[:])
		if echo_codec_error != .None do return -1
		headers := [?]host.Http_Header{
			{name = "content-type", value = transmute([]u8)string("text/plain")},
			{name = "x-odin-test", value = transmute([]u8)string("header-value")},
		}
		request := host.Http_Request{method = .Post, uri = echo_args.text, headers = headers[:], timeout = host.Time_Duration(10_000_000)}
		response, _, http_error := host.http_request(request, transmute([]u8)string("hello=odin"))
		if http_error != .None do return -1
		echoed: [4096]u8
		if host.write_procedure_result(string, result, transmute(string)response.body, echoed[:]) != .None do return -1
		return 0
	}
	if id == 4 {
		probe_args_buffer: [512]u8
		probe, probe_codec_error := host.read_reducer_args(Probe_Args, args, probe_args_buffer[:])
		if probe_codec_error != .None do return -1
		request := host.Http_Request{method = .Get, uri = probe.url, version = host.Http_Version(probe.version)}
		if len(probe.method) > 0 {
			request.method = .Extension
			request.method_extension = probe.method
		}
		response, probe_status, probe_error := host.http_request(request)
		// Success is code * 10 + response version; failures start at 1,000,000.
		probe_result := u32(response.code) * 10 + u32(response.version)
		if probe_error != .None do probe_result = u32(1_000_000 + int(probe_error) + 100 * int(probe_status))
		probe_encoded: [8]u8
		if host.write_procedure_result(u32, result, probe_result, probe_encoded[:]) != .None do return -1
		return 0
	}
	if id == 3 {
		slow_args_buffer: [256]u8
		slow_args, slow_codec_error := host.read_reducer_args(Text_Args, args, slow_args_buffer[:])
		if slow_codec_error != .None do return -1
		// A one-second timeout against a slow endpoint must fail with a request error.
		_, slow_status, slow_error := host.http_request(host.Http_Request{method = .Get, uri = slow_args.text, timeout = host.Time_Duration(1_000_000)})
		slow_code := u16(1000 + int(slow_error) + 100 * int(slow_status))
		slow_encoded: [8]u8
		if host.write_procedure_result(u16, result, slow_code, slow_encoded[:]) != .None do return -1
		return 0
	}
	if id != 0 do return -1
	argument_buffer: [64]u8
	text_args, codec_error := host.read_reducer_args(Text_Args, args, argument_buffer[:])
	if codec_error != .None do return -1
	if _, start_status := host.procedure_start_tx(); start_status != host.Status(0) do return -1
	auto_columns := [1]u16{0}
	notes, notes_error := host.typed_table(Note, "notes", "notes_id_idx_btree")
	row_buffer: [256]u8
	stored: Note
	insert_status := host.Status(1)
	insert_error := host.Codec_Error.Unsupported_Type
	if notes_error == .None {
		notes.auto_columns = auto_columns[:]
		stored, insert_status, insert_error = host.typed_insert_returning(Note, notes, Note{text = text_args.text}, row_buffer[:])
	}
	if insert_error != .None || insert_status != host.Status(0) {
		_ = host.procedure_abort_tx()
		return -1
	}
	if host.procedure_commit_tx() != host.Status(0) do return -1
	encoded: [16]u8
	if host.write_procedure_result(u64, result, stored.id, encoded[:]) != .None do return -1
	return 0
}
