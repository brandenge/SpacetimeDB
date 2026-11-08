package tests

import "core:slice"
import "core:strings"
import "core:testing"
import "stdb:client"
import "stdb:host"

Callback_Observations :: struct {
	calls: int,
	reducer_request_id: u32,
	subscription_query_set_id: u32,
	unsubscribed: bool,
	error: client.Error,
}

observe_client_response :: proc(message: ^client.Message, err: client.Error, user: rawptr) {
	observations := cast(^Callback_Observations)user
	observations.calls += 1
	observations.error = err
	if message == nil do return
	#partial switch body in message.body {
	case client.Reducer_Result:
		observations.reducer_request_id = body.request_id
	case client.Subscribe_Applied:
		observations.subscription_query_set_id = body.query_set_id
	case client.Unsubscribe_Applied:
		observations.subscription_query_set_id = body.query_set_id
		observations.unsubscribed = true
	}
}

Typed_Result_Observations :: struct {
	connection: ^client.Connection,
	response_context_valid: bool,
	reducer_calls: int,
	reducer_request_id: u32,
	reducer_error: client.Error,
	reducer_was_nil: bool,
	procedure_calls: int,
	procedure_request_id: u32,
	procedure_error: client.Error,
	procedure_was_nil: bool,
}

observe_typed_reducer_result :: proc(ctx: ^client.Response_Context, result: ^client.Reducer_Result, err: client.Error, user: rawptr) {
	observations := cast(^Typed_Result_Observations)user
	observations.response_context_valid = ctx != nil &&
		ctx.connection == observations.connection &&
		ctx.identity == observations.connection.identity &&
		ctx.connection_id == observations.connection.connection_id
	observations.reducer_calls += 1
	observations.reducer_error = err
	observations.reducer_was_nil = result == nil
	if result != nil && err == .None do observations.reducer_request_id = result.request_id
}

observe_typed_procedure_result :: proc(ctx: ^client.Response_Context, result: ^client.Procedure_Result, err: client.Error, user: rawptr) {
	observations := cast(^Typed_Result_Observations)user
	observations.response_context_valid = ctx != nil &&
		ctx.connection == observations.connection &&
		ctx.identity == observations.connection.identity &&
		ctx.connection_id == observations.connection.connection_id
	observations.procedure_calls += 1
	observations.procedure_error = err
	observations.procedure_was_nil = result == nil
	if result != nil && err == .None do observations.procedure_request_id = result.request_id
}

Subscription_Context_Observations :: struct {
	connection: ^client.Connection,
	query_set_id: u32,
	state: client.Subscription_State,
	valid: bool,
}

observe_subscription_context :: proc(
	ctx: ^client.Subscription_Event_Context,
	message: ^client.Message,
	err: client.Error,
	user: rawptr,
) {
	_ = message
	_ = err
	observations := cast(^Subscription_Context_Observations)user
	observations.valid = ctx != nil && ctx.connection == observations.connection
	if ctx != nil {
		observations.query_set_id = ctx.query_set_id
		observations.state = ctx.state
	}
}

Row_Callback_Observations :: struct {
	connection: ^client.Connection,
	calls: int,
	changes: int,
	cache_rows: int,
}

Listener_Observations :: struct {
	calls: int,
	changes: int,
}

Event_Listener_Observations :: struct {
	inserts: int,
	deletes: int,
}

Self_Removing_Event_Observations :: struct {
	registry: ^client.Row_Change_Listener_Registry,
	id: client.Row_Change_Listener_Id,
	calls: int,
	destroy_calls: int,
}

observe_listener_changes :: proc(changes: []client.Row_Change, user: rawptr) {
	observations := cast(^Listener_Observations)user
	observations.calls += 1
	observations.changes = len(changes)
}

observe_insert_event :: proc(change: client.Row_Change, user: rawptr) {
	observations := cast(^Event_Listener_Observations)user
	if change.kind == .Insert do observations.inserts += 1
	if change.kind == .Delete do observations.deletes += 1
}

remove_event_listener_during_dispatch :: proc(change: client.Row_Change, user: rawptr) {
	_ = change
	observations := cast(^Self_Removing_Event_Observations)user
	observations.calls += 1
	_ = client.row_change_listener_remove(observations.registry, observations.id)
}

observe_event_listener_destroy :: proc(user: rawptr) {
	observations := cast(^Self_Removing_Event_Observations)user
	observations.destroy_calls += 1
}

observe_row_changes :: proc(changes: []client.Row_Change, user: rawptr) {
	observations := cast(^Row_Callback_Observations)user
	observations.calls += 1
	observations.changes = len(changes)
	observations.cache_rows = client.cache_row_count(&observations.connection.cache, "items")
}

row_id_is_twelve :: proc(row: ^Query_Result_Row, user: rawptr) -> bool {
	_ = user
	return row.id == 12
}

extract_query_result_row_id :: proc(encoded_row: []u8, user: rawptr) -> ([]u8, host.Codec_Error) {
	_ = user
	row, consumed, err := host.decode_row_from(Query_Result_Row, encoded_row)
	if err != .None do return nil, err
	if consumed != len(encoded_row) {
		host.delete_decoded_row(Query_Result_Row, &row)
		return nil, .Trailing_Bytes
	}
	key, encode_err := client.encode_value(u32, row.id)
	host.delete_decoded_row(Query_Result_Row, &row)
	return key, encode_err
}

extract_query_result_row_name :: proc(encoded_row: []u8, user: rawptr) -> ([]u8, host.Codec_Error) {
	_ = user
	row, consumed, err := host.decode_row_from(Query_Result_Row, encoded_row)
	if err != .None do return nil, err
	if consumed != len(encoded_row) {
		host.delete_decoded_row(Query_Result_Row, &row)
		return nil, .Trailing_Bytes
	}
	key, encode_err := client.encode_value(string, row.name)
	host.delete_decoded_row(Query_Result_Row, &row)
	return key, encode_err
}

query_result_row_id_less :: proc(left, right: []u8, user: rawptr) -> (bool, host.Codec_Error) {
	_ = user
	left_id, left_consumed, left_err := host.decode_row_from(u32, left)
	if left_err != .None do return false, left_err
	if left_consumed != len(left) do return false, .Trailing_Bytes
	right_id, right_consumed, right_err := host.decode_row_from(u32, right)
	if right_err != .None do return false, right_err
	if right_consumed != len(right) do return false, .Trailing_Bytes
	return left_id < right_id, .None
}

Cache_Composite_Key :: struct {
	group: u32,
	name: string,
}

extract_query_result_row_composite_key :: proc(encoded_row: []u8, user: rawptr) -> ([]u8, host.Codec_Error) {
	_ = user
	row, consumed, err := host.decode_row_from(Query_Result_Row, encoded_row)
	if err != .None do return nil, err
	if consumed != len(encoded_row) {
		host.delete_decoded_row(Query_Result_Row, &row)
		return nil, .Trailing_Bytes
	}
	key, encode_err := client.encode_value(Cache_Composite_Key, Cache_Composite_Key{group = row.id / 10, name = row.name})
	host.delete_decoded_row(Query_Result_Row, &row)
	return key, encode_err
}

query_result_composite_key_prefix_matches :: proc(key, prefix: []u8, user: rawptr) -> (bool, host.Codec_Error) {
	_ = user
	decoded_key, key_consumed, key_err := host.decode_row_from(Cache_Composite_Key, key)
	if key_err != .None do return false, key_err
	defer host.delete_decoded_row(Cache_Composite_Key, &decoded_key)
	if key_consumed != len(key) do return false, .Trailing_Bytes
	group, prefix_consumed, prefix_err := host.decode_row_from(u32, prefix)
	if prefix_err != .None do return false, prefix_err
	if prefix_consumed != len(prefix) do return false, .Trailing_Bytes
	return decoded_key.group == group, .None
}

Batch_Reentry_Observations :: struct {
	connection: ^client.Connection,
	calls: int,
	error: client.Error,
}

begin_batch_after_cancel :: proc(message: ^client.Message, err: client.Error, user: rawptr) {
	_ = message
	observations := cast(^Batch_Reentry_Observations)user
	observations.calls += 1
	observations.error = err
	if err == .Cancelled {
		_ = client.begin_message_batch(observations.connection)
		_, _ = client.one_off_query(observations.connection, "SELECT 2")
	}
}

@(test)
response_callbacks_correlate_requests_and_subscription_lifecycle :: proc(t: ^testing.T) {
	connection := client.Connection{
		pending_responses = make(map[u32]client.Response_Registration),
		subscription_callbacks = make(map[u32]client.Response_Registration),
	}
	defer delete(connection.pending_responses)
	defer delete(connection.subscription_callbacks)
	observations: Callback_Observations

	connection.pending_responses[7] = client.Response_Registration{callback = observe_client_response, user = &observations}
	reducer_message := client.Message{body = client.Reducer_Result{request_id = 7}}
	client.dispatch_response_callbacks(&connection, &reducer_message)
	testing.expect_value(t, observations.calls, 1)
	testing.expect_value(t, observations.error, client.Error.None)
	testing.expect_value(t, observations.reducer_request_id, u32(7))
	_, request_callback_remains := connection.pending_responses[7]
	testing.expect(t, !request_callback_remains)
	typed_observations := Typed_Result_Observations{connection = &connection}
	connection.pending_responses[8] = client.Response_Registration{
		reducer_result_callback = observe_typed_reducer_result,
		user = &typed_observations,
	}
	typed_reducer_message := client.Message{body = client.Reducer_Result{request_id = 8}}
	client.dispatch_response_callbacks(&connection, &typed_reducer_message)
	testing.expect_value(t, typed_observations.reducer_calls, 1)
	testing.expect_value(t, typed_observations.reducer_request_id, u32(8))
	testing.expect(t, typed_observations.response_context_valid)
	connection.pending_responses[9] = client.Response_Registration{
		procedure_result_callback = observe_typed_procedure_result,
		user = &typed_observations,
	}
	typed_procedure_message := client.Message{body = client.Procedure_Result{request_id = 9}}
	client.dispatch_response_callbacks(&connection, &typed_procedure_message)
	testing.expect_value(t, typed_observations.procedure_calls, 1)
	testing.expect_value(t, typed_observations.procedure_request_id, u32(9))
	testing.expect(t, typed_observations.response_context_valid)
	connection.pending_responses[10] = client.Response_Registration{
		reducer_result_callback = observe_typed_reducer_result,
		user = &typed_observations,
	}
	connection.pending_responses[11] = client.Response_Registration{
		procedure_result_callback = observe_typed_procedure_result,
		user = &typed_observations,
	}
	client.disconnect(&connection)
	testing.expect_value(t, typed_observations.reducer_calls, 2)
	testing.expect_value(t, typed_observations.reducer_error, client.Error.Closed)
	testing.expect(t, typed_observations.reducer_was_nil)
	testing.expect_value(t, typed_observations.procedure_calls, 2)
	testing.expect_value(t, typed_observations.procedure_error, client.Error.Closed)
	testing.expect(t, typed_observations.procedure_was_nil)
	testing.expect(t, typed_observations.response_context_valid)

	connection.subscription_callbacks[10] = client.Response_Registration{callback = observe_client_response, user = &observations}
	subscribe_message := client.Message{body = client.Subscribe_Applied{query_set_id = 10}}
	client.dispatch_response_callbacks(&connection, &subscribe_message)
	testing.expect_value(t, observations.calls, 2)
	testing.expect_value(t, observations.subscription_query_set_id, u32(10))

	unsubscribe_message := client.Message{body = client.Unsubscribe_Applied{query_set_id = 10}}
	client.dispatch_response_callbacks(&connection, &unsubscribe_message)
	testing.expect_value(t, observations.calls, 3)
	testing.expect(t, observations.unsubscribed)
	_, subscription_callback_remains := connection.subscription_callbacks[10]
	testing.expect(t, !subscription_callback_remains)
}

@(test)
managed_subscription_tracks_applied_and_ended_states :: proc(t: ^testing.T) {
	connection := client.Connection{subscription_callbacks = make(map[u32]client.Response_Registration)}
	defer delete(connection.subscription_callbacks)
	observations := Subscription_Context_Observations{connection = &connection}
	handle := client.Subscription_Handle{
		connection = &connection,
		query_set_id = 12,
		state = .Pending,
		callback = observe_subscription_context,
		user = &observations,
	}
	connection.subscription_callbacks[12] = client.Response_Registration{callback = client.subscription_handle_response, user = &handle}
	applied_results := [?]client.Subscribe_Set_Result{{
		query_set_id = 12,
		outcome = client.Subscribe_Set_Applied{},
	}}
	applied := client.Message{body = client.Subscribe_Batch_Applied{request_id = 30, results = applied_results[:]}}
	client.dispatch_response_callbacks(&connection, &applied)
	testing.expect_value(t, handle.state, client.Subscription_State.Active)
	testing.expect(t, observations.valid)
	testing.expect_value(t, observations.query_set_id, u32(12))
	testing.expect_value(t, observations.state, client.Subscription_State.Active)

	unsubscribed := client.Message{body = client.Unsubscribe_Applied{query_set_id = 12}}
	client.dispatch_response_callbacks(&connection, &unsubscribed)
	testing.expect_value(t, handle.state, client.Subscription_State.Ended)
	_, callback_remains := connection.subscription_callbacks[12]
	testing.expect(t, !callback_remains)
}

@(test)
failed_managed_subscription_is_not_replayed :: proc(t: ^testing.T) {
	connection := client.Connection{
		subscriptions = make(map[u32]client.Subscription),
		subscription_callbacks = make(map[u32]client.Response_Registration),
	}
	defer delete(connection.subscriptions)
	defer delete(connection.subscription_callbacks)
	queries := make([]string, 1)
	queries[0] = strings.clone("SELECT * FROM items")
	connection.subscriptions[13] = client.Subscription{queries = queries}
	handle := client.Subscription_Handle{query_set_id = 13, state = .Pending}
	connection.subscription_callbacks[13] = client.Response_Registration{callback = client.subscription_handle_response, user = &handle}
	error_results := [?]client.Subscribe_Set_Result{{
		query_set_id = 13,
		outcome = client.Subscribe_Set_Error{error = "invalid query"},
	}}
	message := client.Message{body = client.Subscribe_Batch_Applied{request_id = 31, results = error_results[:]}}
	client.dispatch_response_callbacks(&connection, &message)
	_, subscription_remains := connection.subscriptions[13]
	testing.expect(t, !subscription_remains)
	testing.expect_value(t, handle.state, client.Subscription_State.Ended)
}

@(test)
failed_subscription_without_callback_is_not_replayed :: proc(t: ^testing.T) {
	connection := client.Connection{subscriptions = make(map[u32]client.Subscription)}
	defer delete(connection.subscriptions)
	queries := make([]string, 1)
	queries[0] = strings.clone("SELECT * FROM items")
	connection.subscriptions[14] = client.Subscription{queries = queries}
	message := client.Message{body = client.Subscription_Error{query_set_id = 14, error = "invalid query"}}
	client.dispatch_response_callbacks(&connection, &message)
	_, subscription_remains := connection.subscriptions[14]
	testing.expect(t, !subscription_remains)
}

@(test)
managed_subscription_auto_ids_skip_active_sets :: proc(t: ^testing.T) {
	connection := client.Connection{
		subscriptions = make(map[u32]client.Subscription),
		subscription_callbacks = make(map[u32]client.Response_Registration),
	}
	defer delete(connection.subscriptions)
	defer delete(connection.subscription_callbacks)
	connection.subscriptions[1] = client.Subscription{}
	handle: client.Subscription_Handle
	_, err := client.subscribe_managed_auto(&connection, &handle, []string{"SELECT * FROM items"})
	testing.expect_value(t, err, client.Error.Not_Connected)
	testing.expect_value(t, handle.query_set_id, u32(2))
	testing.expect_value(t, handle.state, client.Subscription_State.Ended)
}

@(test)
poll_message_processing_updates_cache_before_row_callback :: proc(t: ^testing.T) {
	connection := client.Connection{on_row_changes = observe_row_changes}
	observations := Row_Callback_Observations{connection = &connection}
	connection.callback_user = &observations
	encoded: [64]u8
	encoded_len, encode_err := host.encode_row_into(Query_Result_Row, Query_Result_Row{12, "twelve"}, encoded[:])
	testing.expect_value(t, encode_err, host.Codec_Error.None)
	data := make([]u8, encoded_len)
	copy(data, encoded[:encoded_len])
	offsets := make([]u64, 1)
	tables := make([]client.Table_Rows, 1)
	tables[0] = client.Table_Rows{table = "items", rows = {offsets = offsets[:], data = data}}
	message := client.Message{
		payload = data,
		body = client.Subscribe_Applied{
			query_set_id = 4,
			rows = client.Query_Rows{tables = tables},
		},
	}
	client.apply_polled_message(&connection, &message)
	testing.expect_value(t, observations.calls, 1)
	testing.expect_value(t, observations.changes, 1)
	testing.expect_value(t, observations.cache_rows, 1)
	selected_rows, filter_err := client.cache_filter_rows(&connection.cache, "items", Query_Result_Row, row_id_is_twelve)
	testing.expect_value(t, filter_err, host.Codec_Error.None)
	testing.expect_value(t, len(selected_rows), 1)
	testing.expect_value(t, selected_rows[0].id, u32(12))
	client.delete_rows(selected_rows)
	index_err := client.cache_index_register(&connection.cache, "items.id", "items", extract_query_result_row_id)
	testing.expect_value(t, index_err, host.Codec_Error.None)
	key, key_err := client.encode_value(u32, 12)
	testing.expect_value(t, key_err, host.Codec_Error.None)
	defer delete(key)
	indexed_rows, indexed := client.cache_index_lookup(&connection.cache, "items.id", key)
	testing.expect(t, indexed)
	testing.expect_value(t, len(indexed_rows), 1)
	testing.expect_value(t, client.cache_index_register(&connection.cache, "items.name", "items", extract_query_result_row_name), host.Codec_Error.None)
	name_key, name_key_err := client.encode_value(string, "twelve")
	testing.expect_value(t, name_key_err, host.Codec_Error.None)
	defer delete(name_key)
	indexed_rows, indexed = client.cache_index_lookup(&connection.cache, "items.name", name_key)
	testing.expect(t, indexed)
	testing.expect_value(t, len(indexed_rows), 1)

	overlap_offsets := make([]u64, 1)
	overlap_tables := make([]client.Table_Rows, 1)
	overlap_tables[0] = client.Table_Rows{table = "items", rows = {offsets = overlap_offsets, data = data}}
	overlap := client.Message{body = client.Subscribe_Applied{query_set_id = 5, rows = {tables = overlap_tables}}}
	client.cache_apply(&connection.cache, overlap)
	client.cache_apply(&connection.cache, client.Message{body = client.Unsubscribe_Applied{query_set_id = 4}})
	indexed_rows, indexed = client.cache_index_lookup(&connection.cache, "items.id", key)
	testing.expect(t, indexed)
	testing.expect_value(t, len(indexed_rows), 1)
	indexed_rows, indexed = client.cache_index_lookup(&connection.cache, "items.name", name_key)
	testing.expect(t, indexed)
	testing.expect_value(t, len(indexed_rows), 1)
	client.cache_apply(&connection.cache, client.Message{body = client.Unsubscribe_Applied{query_set_id = 5}})
	indexed_rows, indexed = client.cache_index_lookup(&connection.cache, "items.id", key)
	testing.expect(t, indexed)
	testing.expect_value(t, len(indexed_rows), 0)
	indexed_rows, indexed = client.cache_index_lookup(&connection.cache, "items.name", name_key)
	testing.expect(t, indexed)
	testing.expect_value(t, len(indexed_rows), 0)
	delete(overlap_tables)
	delete(overlap_offsets)
	client.message_destroy(&message)
	client.cache_destroy(&connection.cache)
}

@(test)
ordered_cache_index_obeys_inclusive_and_exclusive_bounds :: proc(t: ^testing.T) {
	rows := [?]Query_Result_Row{{3, "three"}, {1, "one"}, {2, "two"}}
	encoded_data: [dynamic]u8
	offsets: [dynamic]u64
	for row in rows {
		append(&offsets, u64(len(encoded_data)))
		buffer: [64]u8
		encoded_len, encode_err := host.encode_row_into(Query_Result_Row, row, buffer[:])
		testing.expect_value(t, encode_err, host.Codec_Error.None)
		append(&encoded_data, ..buffer[:encoded_len])
	}
	tables := make([]client.Table_Rows, 1)
	tables[0] = client.Table_Rows{
		table = "items",
		rows = {offsets = offsets[:], data = encoded_data[:]},
	}
	message := client.Message{
		body = client.Subscribe_Applied{
			query_set_id = 20,
			rows = {tables = tables},
		},
	}
	cache: client.Cache
	client.cache_apply(&cache, message)
	index_err := client.cache_index_register(&cache, "items.id", "items", extract_query_result_row_id, nil, query_result_row_id_less)
	testing.expect_value(t, index_err, host.Codec_Error.None)
	lower, lower_err := client.encode_value(u32, 1)
	upper, upper_err := client.encode_value(u32, 3)
	testing.expect_value(t, lower_err, host.Codec_Error.None)
	testing.expect_value(t, upper_err, host.Codec_Error.None)
	defer delete(lower)
	defer delete(upper)

	selected, range_err := client.cache_index_decode_range_rows(
		&cache,
		"items.id",
		lower,
		.Inclusive,
		upper,
		.Exclusive,
		Query_Result_Row,
	)
	testing.expect_value(t, range_err, host.Codec_Error.None)
	testing.expect_value(t, len(selected), 2)
	testing.expect_value(t, selected[0].id, u32(1))
	testing.expect_value(t, selected[1].id, u32(2))
	client.delete_rows(selected)

	selected, range_err = client.cache_index_decode_range_rows(
		&cache,
		"items.id",
		lower,
		.Exclusive,
		upper,
		.Inclusive,
		Query_Result_Row,
	)
	testing.expect_value(t, range_err, host.Codec_Error.None)
	testing.expect_value(t, len(selected), 2)
	testing.expect_value(t, selected[0].id, u32(2))
	testing.expect_value(t, selected[1].id, u32(3))
	client.delete_rows(selected)

	selected, range_err = client.cache_index_decode_range_rows(
		&cache,
		"items.id",
		nil,
		.Unbounded,
		upper,
		.Exclusive,
		Query_Result_Row,
	)
	testing.expect_value(t, range_err, host.Codec_Error.None)
	testing.expect_value(t, len(selected), 2)
	client.delete_rows(selected)
	client.cache_apply(&cache, client.Message{body = client.Unsubscribe_Applied{query_set_id = 20}})
	selected, range_err = client.cache_index_decode_range_rows(
		&cache,
		"items.id",
		lower,
		.Inclusive,
		upper,
		.Exclusive,
		Query_Result_Row,
	)
	testing.expect_value(t, range_err, host.Codec_Error.None)
	testing.expect_value(t, len(selected), 0)
	client.delete_rows(selected)
	client.cache_destroy(&cache)
	delete(tables)
	delete(offsets)
	delete(encoded_data)
}

@(test)
composite_cache_index_supports_prefix_and_full_key_lookups :: proc(t: ^testing.T) {
	rows := [?]Query_Result_Row{{10, "alpha"}, {11, "beta"}, {20, "gamma"}}
	encoded_data: [dynamic]u8
	offsets: [dynamic]u64
	for row in rows {
		append(&offsets, u64(len(encoded_data)))
		buffer: [64]u8
		encoded_len, encode_err := host.encode_row_into(Query_Result_Row, row, buffer[:])
		testing.expect_value(t, encode_err, host.Codec_Error.None)
		append(&encoded_data, ..buffer[:encoded_len])
	}
	tables := make([]client.Table_Rows, 1)
	tables[0] = client.Table_Rows{table = "items", rows = {offsets = offsets[:], data = encoded_data[:]}}
	cache: client.Cache
	client.cache_apply(&cache, client.Message{body = client.Subscribe_Applied{query_set_id = 21, rows = {tables = tables}}})
	testing.expect_value(
		t,
		client.cache_index_register(
			&cache,
			"items.group_name",
			"items",
			extract_query_result_row_composite_key,
			nil,
			nil,
			query_result_composite_key_prefix_matches,
		),
		host.Codec_Error.None,
	)
	prefix, prefix_err := client.encode_value(u32, 1)
	testing.expect_value(t, prefix_err, host.Codec_Error.None)
	selected, decode_err := client.cache_index_decode_prefix_rows(&cache, "items.group_name", prefix, Query_Result_Row)
	defer client.delete_rows(selected)
	testing.expect_value(t, decode_err, host.Codec_Error.None)
	testing.expect_value(t, len(selected), 2)
	ids := map[u32]bool{}
	for row in selected do ids[row.id] = true
	testing.expect(t, u32(10) in ids && u32(11) in ids)
	delete(ids)
	delete(prefix)

	full_key, key_err := client.encode_value(Cache_Composite_Key, Cache_Composite_Key{group = 2, name = "gamma"})
	testing.expect_value(t, key_err, host.Codec_Error.None)
	full_key_rows, full_key_err := client.cache_index_decode_rows(&cache, "items.group_name", full_key, Query_Result_Row)
	testing.expect_value(t, full_key_err, host.Codec_Error.None)
	testing.expect_value(t, len(full_key_rows), 1)
	testing.expect_value(t, full_key_rows[0].id, u32(20))
	client.delete_rows(full_key_rows)
	delete(full_key)
	client.cache_destroy(&cache)
	delete(tables)
	delete(offsets)
	delete(encoded_data)
}

@(test)
websocket_accept_key_matches_rfc_6455_vector :: proc(t: ^testing.T) {
	accept, ok := client.ws_accept_key("dGhlIHNhbXBsZSBub25jZQ==")
	defer delete(accept)
	testing.expect(t, ok)
	testing.expect_value(t, accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
}

@(test)
row_lists_split_fixed_and_offset_rows :: proc(t: ^testing.T) {
	fixed := client.Row_List{fixed_size = 2, data = {1, 2, 3, 4}}
	testing.expect_value(t, client.row_list_len(fixed), 2)
	row, ok := client.row_list_row(fixed, 1)
	testing.expect(t, ok)
	testing.expect(t, slice.equal(row, []u8{3, 4}))

	offsets := client.Row_List{offsets = {0, 1}, data = {9, 8, 7}}
	first, _ := client.row_list_row(offsets, 0)
	second, _ := client.row_list_row(offsets, 1)
	testing.expect(t, slice.equal(first, []u8{9}))
	testing.expect(t, slice.equal(second, []u8{8, 7}))
	_, out_of_range := client.row_list_row(offsets, 2)
	testing.expect(t, !out_of_range)
}

@(test)
row_change_listeners_can_be_added_and_removed_dynamically :: proc(t: ^testing.T) {
	registry: client.Row_Change_Listener_Registry
	first_observations: Listener_Observations
	second_observations: Listener_Observations
	first_id, first_err := client.row_change_listener_add(&registry, observe_listener_changes, &first_observations)
	second_id, second_err := client.row_change_listener_add(&registry, observe_listener_changes, &second_observations)
	testing.expect_value(t, first_err, client.Error.None)
	testing.expect_value(t, second_err, client.Error.None)
	changes := []client.Row_Change{{table = "items", kind = .Insert}}
	client.dispatch_row_change_listeners(changes, &registry)
	testing.expect_value(t, first_observations.calls, 1)
	testing.expect_value(t, second_observations.calls, 1)
	testing.expect_value(t, first_observations.changes, 1)
	testing.expect(t, client.row_change_listener_remove(&registry, first_id))
	testing.expect(t, !client.row_change_listener_remove(&registry, first_id))
	client.dispatch_row_change_listeners(changes, &registry)
	testing.expect_value(t, first_observations.calls, 1)
	testing.expect_value(t, second_observations.calls, 2)
	testing.expect(t, client.row_change_listener_remove(&registry, second_id))
	delete(registry.entries)
}

@(test)
event_listeners_filter_table_and_kind_and_can_be_removed :: proc(t: ^testing.T) {
	registry: client.Row_Change_Listener_Registry
	observations: Event_Listener_Observations
	id, err := client.row_change_event_listener_add(&registry, "items", .Insert, observe_insert_event, &observations)
	testing.expect_value(t, err, client.Error.None)
	changes := []client.Row_Change{
		{table = "items", kind = .Insert},
		{table = "items", kind = .Delete},
		{table = "other", kind = .Insert},
	}
	client.dispatch_row_change_listeners(changes, &registry)
	testing.expect_value(t, observations.inserts, 1)
	testing.expect_value(t, observations.deletes, 0)
	testing.expect(t, client.row_change_listener_remove(&registry, id))
	client.dispatch_row_change_listeners(changes, &registry)
	testing.expect_value(t, observations.inserts, 1)
	client.row_change_listener_registry_destroy(&registry)
}

@(test)
event_listener_removal_waits_for_dispatch_snapshot :: proc(t: ^testing.T) {
	registry: client.Row_Change_Listener_Registry
	observations := Self_Removing_Event_Observations{registry = &registry}
	id, err := client.row_change_event_listener_add(
		&registry,
		"items",
		.Insert,
		remove_event_listener_during_dispatch,
		&observations,
		observe_event_listener_destroy,
	)
	testing.expect_value(t, err, client.Error.None)
	observations.id = id
	changes := []client.Row_Change{
		{table = "items", kind = .Insert},
		{table = "items", kind = .Insert},
	}
	client.dispatch_row_change_listeners(changes, &registry)
	testing.expect_value(t, observations.calls, 2)
	testing.expect_value(t, observations.destroy_calls, 1)
	client.row_change_listener_registry_destroy(&registry)
}

@(test)
client_messages_encode_as_bsatn :: proc(t: ^testing.T) {
	builder: client.Builder
	defer delete(builder.bytes)
	client.encode_call_reducer(&builder, 7, "go", {0xaa})
	// tag 3, request 7, flags 0, "go", args [0xaa]
	expected := []u8{3, 7, 0, 0, 0, 0, 2, 0, 0, 0, 'g', 'o', 1, 0, 0, 0, 0xaa}
	testing.expect(t, slice.equal(builder.bytes[:], expected))
}

@(test)
subscribe_batches_encode_and_parse_per_set_outcomes :: proc(t: ^testing.T) {
	builder: client.Builder
	defer delete(builder.bytes)
	queries := [?]string{"SELECT * FROM items", "SELECT * FROM users"}
	sets := [?]client.Client_Subscribe_Set{{query_set_id = 9, queries = queries[:]}}
	client.encode_subscribe_batch(&builder, 7, sets[:])
	expected := []u8{
		5, 7, 0, 0, 0, 1, 0, 0, 0, 9, 0, 0, 0, 2, 0, 0, 0,
		19, 0, 0, 0, 'S', 'E', 'L', 'E', 'C', 'T', ' ', '*', ' ', 'F', 'R', 'O', 'M', ' ', 'i', 't', 'e', 'm', 's',
		19, 0, 0, 0, 'S', 'E', 'L', 'E', 'C', 'T', ' ', '*', ' ', 'F', 'R', 'O', 'M', ' ', 'u', 's', 'e', 'r', 's',
	}
	testing.expect(t, slice.equal(builder.bytes[:], expected))

	frame := []u8{
		0, 8, 7, 0, 0, 0, 2, 0, 0, 0,
		10, 0, 0, 0, 1, 3, 0, 0, 0, 'b', 'a', 'd',
		11, 0, 0, 0, 0, 0, 0, 0, 0,
	}
	body, ok := client.parse_server_frame(frame)
	testing.expect(t, ok)
	batch, is_batch := body.(client.Subscribe_Batch_Applied)
	testing.expect(t, is_batch)
	testing.expect_value(t, batch.request_id, u32(7))
	testing.expect_value(t, len(batch.results), 2)
	testing.expect_value(t, batch.results[0].query_set_id, u32(10))
	_, first_is_error := batch.results[0].outcome.(client.Subscribe_Set_Error)
	testing.expect(t, first_is_error)
	testing.expect_value(t, batch.results[1].query_set_id, u32(11))
	second_applied, second_is_applied := batch.results[1].outcome.(client.Subscribe_Set_Applied)
	testing.expect(t, second_is_applied)
	testing.expect_value(t, len(second_applied.rows.tables), 0)
	cache: client.Cache
	client.cache_apply(&cache, client.Message{body = body})
	testing.expect(t, u32(10) not_in cache.sets)
	testing.expect(t, u32(11) in cache.sets)
	client.cache_destroy(&cache)
	client.server_message_destroy(&body)
}

@(test)
outbound_message_batches_preserve_owned_v3_order :: proc(t: ^testing.T) {
	connection := client.Connection{connected = true, ws = client.WebSocket{protocol_v3 = true}}
	testing.expect_value(t, client.begin_message_batch(&connection), client.Error.None)
	first_request, first_err := client.one_off_query(&connection, "SELECT 1")
	second_request, second_err := client.one_off_query(&connection, "SELECT 2")
	testing.expect_value(t, first_err, client.Error.None)
	testing.expect_value(t, second_err, client.Error.None)
	testing.expect_value(t, first_request, u32(1))
	testing.expect_value(t, second_request, u32(2))
	_, subscribe_err := client.subscribe(&connection, 77, []string{"SELECT * FROM items"})
	testing.expect_value(t, subscribe_err, client.Error.Invalid_Argument)
	_, poll_err := client.poll(&connection)
	testing.expect_value(t, poll_err, client.Error.Invalid_Argument)
	queued_messages := make([][]u8, len(connection.outbound_batch))
	for message, index in connection.outbound_batch do queued_messages[index] = message.bytes
	frame := client.encode_client_messages_v3(queued_messages)
	delete(queued_messages)
	first_expected: client.Builder
	second_expected: client.Builder
	defer delete(first_expected.bytes)
	defer delete(second_expected.bytes)
	client.encode_one_off_query(&first_expected, 1, "SELECT 1")
	client.encode_one_off_query(&second_expected, 2, "SELECT 2")
	expected_messages := [?][]u8{first_expected.bytes[:], second_expected.bytes[:]}
	expected := client.encode_client_messages_v3(expected_messages[:])
	testing.expect(t, slice.equal(frame, expected))
	delete(expected)
	delete(frame)
	testing.expect_value(t, client.cancel_message_batch(&connection), client.Error.None)
	testing.expect_value(t, len(connection.outbound_batch), 0)
}

@(test)
ordinary_v3_requests_queue_for_automatic_poll_batching :: proc(t: ^testing.T) {
	connection := client.Connection{connected = true, ws = client.WebSocket{protocol_v3 = true}}
	first_request, first_err := client.one_off_query(&connection, "SELECT 1")
	second_request, second_err := client.one_off_query(&connection, "SELECT 2")
	testing.expect_value(t, first_err, client.Error.None)
	testing.expect_value(t, second_err, client.Error.None)
	testing.expect_value(t, first_request, u32(1))
	testing.expect_value(t, second_request, u32(2))
	testing.expect_value(t, len(connection.auto_outbound_batch), 2)
	testing.expect_value(t, len(connection.outbound_batch), 0)
	queued := make([][]u8, len(connection.auto_outbound_batch))
	for message, index in connection.auto_outbound_batch do queued[index] = message.bytes
	expected_builders: [2]client.Builder
	client.encode_one_off_query(&expected_builders[0], 1, "SELECT 1")
	client.encode_one_off_query(&expected_builders[1], 2, "SELECT 2")
	expected_messages := [?][]u8{expected_builders[0].bytes[:], expected_builders[1].bytes[:]}
	actual_frame := client.encode_client_messages_v3(queued)
	expected_frame := client.encode_client_messages_v3(expected_messages[:])
	testing.expect(t, slice.equal(actual_frame, expected_frame))
	delete(actual_frame)
	delete(expected_frame)
	delete(queued)
	for &builder in expected_builders do delete(builder.bytes)
	for message in connection.auto_outbound_batch do delete(message.bytes)
	delete(connection.auto_outbound_batch)
}

@(test)
cancelled_outbound_batch_fails_request_callbacks :: proc(t: ^testing.T) {
	connection := client.Connection{
		connected = true,
		ws = client.WebSocket{protocol_v3 = true},
		pending_responses = make(map[u32]client.Response_Registration),
	}
	defer delete(connection.pending_responses)
	observations := Batch_Reentry_Observations{connection = &connection}
	testing.expect_value(t, client.begin_message_batch(&connection), client.Error.None)
	request_id, call_err := client.one_off_query_with_callback(&connection, "SELECT 1", begin_batch_after_cancel, &observations)
	testing.expect_value(t, call_err, client.Error.None)
	testing.expect_value(t, client.cancel_message_batch(&connection), client.Error.None)
	testing.expect_value(t, observations.calls, 1)
	testing.expect_value(t, observations.error, client.Error.Cancelled)
	_, callback_remains := connection.pending_responses[request_id]
	testing.expect(t, !callback_remains)
	testing.expect(t, connection.batching_outbound)
	testing.expect_value(t, len(connection.outbound_batch), 1)
	testing.expect_value(t, client.cancel_message_batch(&connection), client.Error.None)
	testing.expect_value(t, len(connection.outbound_batch), 0)
}

@(test)
typed_view_queries_escape_string_arguments :: proc(t: ^testing.T) {
	arguments := [?]string{
		client.sql_string_literal("O'Brien"),
		client.sql_literal(bool, true),
		client.sql_literal(u64, 42),
	}
	query := client.sql_view_query("person_by_name", arguments[:])
	defer delete(query)
	testing.expect_value(t, query, "SELECT * FROM person_by_name('O''Brien', TRUE, 42)")
	uuid_literal := client.sql_uuid_literal(0x00112233445566778899aabbccddeeff)
	defer delete(uuid_literal)
	testing.expect_value(t, uuid_literal, "'00112233-4455-6677-8899-aabbccddeeff'")
	timestamp_literal := client.sql_literal(host.Timestamp, host.Timestamp(1_700_000_000_000_000))
	defer delete(timestamp_literal)
	testing.expect_value(t, timestamp_literal, "'2023-11-14T22:13:20Z'")
	identity_bytes := [32]u8{
		0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
		16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
	}
	identity := transmute(host.Identity)identity_bytes
	identity_literal := client.sql_literal(host.Identity, identity)
	defer delete(identity_literal)
	testing.expect_value(t, identity_literal, "0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	bytes_literal := client.sql_bytes_literal([]u8{0x0a, 0xff})
	defer delete(bytes_literal)
	testing.expect_value(t, bytes_literal, "0x0aff")
}

Query_Result_Row :: struct {
	id: u32,
	name: string,
}

@(test)
one_off_query_results_decode_typed_rows :: proc(t: ^testing.T) {
	encoded_buffer: [128]u8
	encoded_len, encode_err := host.encode_row_into(Query_Result_Row, Query_Result_Row{7, "seven"}, encoded_buffer[:])
	testing.expect_value(t, encode_err, host.Codec_Error.None)
	data := make([]u8, encoded_len)
	copy(data, encoded_buffer[:encoded_len])
	offsets := [?]u64{0}
	result := client.One_Off_Query_Result{
		rows = {tables = {{table = "items", rows = {offsets = offsets[:], data = data}}}},
	}
	rows, decode_err := client.one_off_query_result_rows(result, "items", Query_Result_Row)
	defer client.delete_rows(rows)
	testing.expect_value(t, decode_err, host.Codec_Error.None)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].id, u32(7))
	testing.expect_value(t, rows[0].name, "seven")

	empty_rows, empty_err := client.one_off_query_result_rows(result, "missing", Query_Result_Row)
	testing.expect_value(t, empty_err, host.Codec_Error.None)
	testing.expect_value(t, len(empty_rows), 0)

	failed := client.One_Off_Query_Result{failed = true}
	_, failed_err := client.one_off_query_result_rows(failed, "items", Query_Result_Row)
	testing.expect_value(t, failed_err, host.Codec_Error.Malformed_Data)
	delete(data)
}

@(test)
subscription_paths_include_connection_modes :: proc(t: ^testing.T) {
	endpoint, ok := client.parse_endpoint("wss://db.example/proxy")
	testing.expect(t, ok)
	default_path := client.subscription_path(endpoint, "world", .Brotli, false, nil)
	testing.expect_value(t, default_path, "/proxy/v1/database/world/subscribe?compression=Brotli")
	light_path := client.subscription_path(endpoint, "world", .Brotli, true, nil)
	testing.expect_value(t, light_path, "/proxy/v1/database/world/subscribe?compression=Brotli&light=true")
	confirmed_path := client.subscription_path(endpoint, "world", .Brotli, false, true)
	testing.expect_value(t, confirmed_path, "/proxy/v1/database/world/subscribe?compression=Brotli&confirmed=true")
	unconfirmed_path := client.subscription_path(endpoint, "world", .Brotli, false, false)
	testing.expect_value(t, unconfirmed_path, "/proxy/v1/database/world/subscribe?compression=Brotli&confirmed=false")
}

@(test)
sql_query_builder_composes_typed_filters_and_rejects_bad_identifiers :: proc(t: ^testing.T) {
	query, query_err := client.sql_query("public.items")
	defer client.sql_query_destroy(&query)
	testing.expect_value(t, query_err, client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_where(u32, &query, "age", .Greater, u32(18)), client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_where(string, &query, "name", .Equal, "O'Brien"), client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_order_by(&query, "age", true, true), client.Sql_Query_Error.None)
	client.sql_query_limit(&query, 20)
	sql := client.sql_query_build(&query)
	defer delete(sql)
	testing.expect_value(t, sql, `SELECT * FROM "public"."items" WHERE "age" > 18 AND "name" = 'O''Brien' ORDER BY "age" DESC NULLS FIRST LIMIT 20`)

	_, invalid_table_err := client.sql_query("items; DROP TABLE users")
	testing.expect_value(t, invalid_table_err, client.Sql_Query_Error.Invalid_Identifier)
	invalid_column_err := client.sql_query_where(string, &query, "name; DROP TABLE users", .Equal, "x")
	testing.expect_value(t, invalid_column_err, client.Sql_Query_Error.Invalid_Identifier)

	join_query, join_err := client.sql_query("public.items", "i")
	defer client.sql_query_destroy(&join_query)
	testing.expect_value(t, join_err, client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_project_all(&join_query, "i"), client.Sql_Query_Error.None)
	testing.expect_value(
		t,
		client.sql_query_inner_join(&join_query, "public.orders", "o", "i.id", "o.item_id"),
		client.Sql_Query_Error.None,
	)
	join_sql := client.sql_query_build(&join_query)
	defer delete(join_sql)
	testing.expect_value(
		t,
		join_sql,
		`SELECT "i".* FROM "public"."items" AS "i" INNER JOIN "public"."orders" AS "o" ON "i"."id" = "o"."item_id"`,
	)

	or_query, or_query_err := client.sql_query("items", "i")
	defer client.sql_query_destroy(&or_query)
	testing.expect_value(t, or_query_err, client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_where(string, &or_query, "i.status", .Equal, "open"), client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_or_where(string, &or_query, "i.status", .Equal, "pending"), client.Sql_Query_Error.None)
	or_sql := client.sql_query_build(&or_query)
	defer delete(or_sql)
	testing.expect_value(t, or_sql, `SELECT * FROM "items" AS "i" WHERE "i"."status" = 'open' OR "i"."status" = 'pending'`)

	cross_query, cross_query_err := client.sql_query("items", "i")
	defer client.sql_query_destroy(&cross_query)
	testing.expect_value(t, cross_query_err, client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_cross_join(&cross_query, "users", "u"), client.Sql_Query_Error.None)
	cross_sql := client.sql_query_build(&cross_query)
	defer delete(cross_sql)
	testing.expect_value(t, cross_sql, `SELECT * FROM "items" AS "i" CROSS JOIN "users" AS "u"`)

	projection_query, projection_query_err := client.sql_query("items")
	defer client.sql_query_destroy(&projection_query)
	testing.expect_value(t, projection_query_err, client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_project_column(&projection_query, "id"), client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_project_column(&projection_query, "name", "item_name"), client.Sql_Query_Error.None)
	projection_sql := client.sql_query_build(&projection_query)
	defer delete(projection_sql)
	testing.expect_value(t, projection_sql, `SELECT "id", "name" AS "item_name" FROM "items"`)

	count_query, count_query_err := client.sql_query("items")
	defer client.sql_query_destroy(&count_query)
	testing.expect_value(t, count_query_err, client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_count(&count_query, "row_count"), client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_project_column(&count_query, "id"), client.Sql_Query_Error.Invalid_Projection)
	count_sql := client.sql_query_build(&count_query)
	defer delete(count_sql)
	testing.expect_value(t, count_sql, `SELECT COUNT(*) AS "row_count" FROM "items"`)

	sum_query, sum_query_err := client.sql_query("items")
	defer client.sql_query_destroy(&sum_query)
	testing.expect_value(t, sum_query_err, client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_sum(&sum_query, "amount", "total"), client.Sql_Query_Error.None)
	testing.expect_value(t, client.sql_query_project_column(&sum_query, "id"), client.Sql_Query_Error.Invalid_Projection)
	sum_sql := client.sql_query_build(&sum_query)
	defer delete(sum_sql)
	testing.expect_value(t, sum_sql, `SELECT SUM("amount") AS "total" FROM "items"`)
}

@(test)
server_frames_parse_reducer_results_and_reject_garbage :: proc(t: ^testing.T) {
	// compression 0, ReducerResult(6), request 9, timestamp 0, OkEmpty(1)
	frame := []u8{0, 6, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
	body, ok := client.parse_server_frame(frame)
	testing.expect(t, ok)
	result, is_result := body.(client.Reducer_Result)
	testing.expect(t, is_result)
	testing.expect_value(t, result.request_id, u32(9))
	testing.expect_value(t, result.outcome, client.Reducer_Outcome.Ok_Empty)

	_, trailing_ok := client.parse_server_frame([]u8{0, 6, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 99})
	testing.expect(t, !trailing_ok)
	_, compressed_ok := client.parse_server_frame([]u8{1, 6})
	testing.expect(t, !compressed_ok)
	_, truncated_ok := client.parse_server_frame([]u8{0, 4, 0xff, 0xff, 0xff, 0xff})
	testing.expect(t, !truncated_ok)
}

@(test)
server_frames_parse_initial_connection :: proc(t: ^testing.T) {
	frame := make([]u8, 59)
	frame[1] = 0
	frame[50] = 5
	token := []u8{'t', 'o', 'k', 'e', 'n'}
	copy(frame[54:], token)
	defer delete(frame)
	body, ok := client.parse_server_frame(frame)
	testing.expect(t, ok)
	initial, is_initial := body.(client.Initial_Connection)
	testing.expect(t, is_initial)
	testing.expect_value(t, initial.token, "token")
}

@(test)
cache_tracks_inserts_deletes_and_drops_sets :: proc(t: ^testing.T) {
	cache: client.Cache
	defer client.cache_destroy(&cache)

	initial := client.Subscribe_Applied{
		query_set_id = 1,
		rows = {tables = {{table = "t", rows = {fixed_size = 1, data = {1, 2}}}}},
	}
	client.cache_apply(&cache, client.Message{body = initial})
	testing.expect_value(t, client.cache_row_count(&cache, "t"), 2)

	update := client.Transaction_Update{
		query_sets = {{query_set_id = 1, tables = {{table = "t", groups = {{
			inserts = {fixed_size = 1, data = {3}},
			deletes = {fixed_size = 1, data = {1}},
		}}}}}},
	}
	client.cache_apply(&cache, client.Message{body = update})
	testing.expect_value(t, client.cache_row_count(&cache, "t"), 2)

	overlap := client.Subscribe_Applied{
		query_set_id = 2,
		rows = {tables = {{table = "t", rows = {fixed_size = 1, data = {3}}}}},
	}
	client.cache_apply(&cache, client.Message{body = overlap})
	testing.expect_value(t, client.cache_row_count(&cache, "t"), 2)

	client.cache_apply(&cache, client.Message{body = client.Subscription_Error{query_set_id = 1}})
	testing.expect_value(t, client.cache_row_count(&cache, "t"), 1)
}

@(test)
reducer_errors_decode_bsatn_messages :: proc(t: ^testing.T) {
	failed := client.Reducer_Result{outcome = .Err, return_value = {2, 0, 0, 0, 'n', 'o'}}
	text, ok := client.reducer_error_message(failed)
	testing.expect(t, ok)
	testing.expect_value(t, text, "no")

	truncated := client.Reducer_Result{outcome = .Err, return_value = {9, 0, 0, 0, 'n'}}
	_, truncated_ok := client.reducer_error_message(truncated)
	testing.expect(t, !truncated_ok)

	_, success_ok := client.reducer_error_message(client.Reducer_Result{outcome = .Ok_Empty})
	testing.expect(t, !success_ok)
}

@(test)
procedure_calls_encode_and_results_decode :: proc(t: ^testing.T) {
	builder: client.Builder
	defer delete(builder.bytes)
	client.encode_call_procedure(&builder, 3, "p", {1})
	testing.expect(t, slice.equal(builder.bytes[:], []u8{4, 3, 0, 0, 0, 0, 1, 0, 0, 0, 'p', 1, 0, 0, 0, 1}))

	result := client.Procedure_Result{returned = true, return_value = {7, 0, 0, 0, 0, 0, 0, 0}}
	value, err := client.procedure_return_value(result, u64)
	testing.expect_value(t, err, host.Codec_Error.None)
	testing.expect_value(t, value, u64(7))
	_, failed := client.procedure_return_value(client.Procedure_Result{message = "boom"}, u64)
	testing.expect_value(t, failed, host.Codec_Error.Malformed_Data)
}

@(test)
server_message_prefix_parser_splits_v3_payloads :: proc(t: ^testing.T) {
	first := []u8{6, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
	second := []u8{6, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
	joined := make([]u8, len(first) + len(second))
	copy(joined[:], first)
	copy(joined[len(first):], second)

	body, consumed, ok := client.parse_server_message_prefix(joined)
	testing.expect(t, ok)
	testing.expect_value(t, consumed, len(first))
	result, is_result := body.(client.Reducer_Result)
	testing.expect(t, is_result)
	testing.expect_value(t, result.request_id, u32(9))
	client.server_message_destroy(&body)

	second_body, second_consumed, second_ok := client.parse_server_message_prefix(joined[consumed:])
	testing.expect(t, second_ok)
	testing.expect_value(t, second_consumed, len(second))
	second_result, is_second_result := second_body.(client.Reducer_Result)
	testing.expect(t, is_second_result)
	testing.expect_value(t, second_result.request_id, u32(10))
	client.server_message_destroy(&second_body)
	delete(joined)
}

@(test)
poll_delivers_buffered_v3_messages_one_at_a_time :: proc(t: ^testing.T) {
	first := []u8{6, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 5, 0, 0, 0, 'h', 'e', 'l', 'l', 'o'}
	second := []u8{6, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}
	buffered := make([]u8, len(first) + len(second))
	copy(buffered[:], first)
	copy(buffered[len(first):], second)
	connection := client.Connection{
		connected = true,
		ws = client.WebSocket{protocol_v3 = true, pending_messages = buffered},
	}

	first_message, first_err := client.poll(&connection)
	testing.expect_value(t, first_err, client.Error.None)
	first_result, is_first := first_message.body.(client.Reducer_Result)
	testing.expect(t, is_first)
	testing.expect_value(t, first_result.request_id, u32(9))
	testing.expect_value(t, first_result.message, "hello")
	message_address := uintptr(raw_data(first_result.message))
	frame_address := uintptr(raw_data(first_message.payload))
	testing.expect(t, message_address >= frame_address && message_address + uintptr(len(first_result.message)) <= frame_address + uintptr(len(first_message.payload)))

	second_message, second_err := client.poll(&connection)
	testing.expect_value(t, second_err, client.Error.None)
	second_result, is_second := second_message.body.(client.Reducer_Result)
	testing.expect(t, is_second)
	testing.expect_value(t, second_result.request_id, u32(10))
	testing.expect_value(t, first_result.message, "hello")
	client.message_destroy(&first_message)
	client.message_destroy(&second_message)
	client.ws_close(&connection.ws)
	client.cache_destroy(&connection.cache)
}

@(test)
gzip_frames_inflate_to_parseable_server_messages :: proc(t: ^testing.T) {
	// gzip of a ReducerResult frame: request 9, timestamp 0, OkEmpty.
	compressed := []u8{31, 139, 8, 0, 0, 0, 0, 0, 2, 255, 99, 227, 100, 64, 0, 70, 0, 15, 8, 235, 217, 14, 0, 0, 0}
	frame, ok := client.inflate_gzip_frame(compressed)
	defer delete(frame)
	testing.expect(t, ok)
	testing.expect_value(t, frame[0], client.COMPRESSION_TAG_NONE)
	body, parsed := client.parse_server_frame(frame)
	testing.expect(t, parsed)
	result, is_result := body.(client.Reducer_Result)
	testing.expect(t, is_result)
	testing.expect_value(t, result.request_id, u32(9))

	_, garbage_ok := client.inflate_gzip_frame([]u8{1, 2, 3, 4})
	testing.expect(t, !garbage_ok)
}

@(test)
brotli_frames_inflate_to_parseable_server_messages :: proc(t: ^testing.T) {
	compressed := []u8{0x1f, 0x0d, 0x00, 0xf8, 0x27, 0x01, 0x0c, 0x12, 0xc2, 0xa0, 0x40, 0x89, 0x06, 0xb0, 0x2b}
	frame, ok := client.inflate_brotli_frame(compressed)
	defer delete(frame)
	testing.expect(t, ok)
	testing.expect_value(t, frame[0], client.COMPRESSION_TAG_NONE)
	body, parsed := client.parse_server_frame(frame)
	testing.expect(t, parsed)
	result, is_result := body.(client.Reducer_Result)
	testing.expect(t, is_result)
	testing.expect_value(t, result.request_id, u32(9))

	_, garbage_ok := client.inflate_brotli_frame([]u8{1, 2, 3, 4})
	testing.expect(t, !garbage_ok)
}

@(test)
endpoints_follow_the_sdk_scheme_and_port_conventions :: proc(t: ^testing.T) {
	plain, plain_ok := client.parse_endpoint("localhost:3000")
	testing.expect(t, plain_ok)
	testing.expect(t, !plain.secure)
	testing.expect_value(t, plain.host, "localhost")
	testing.expect_value(t, plain.port, 3000)
	testing.expect_value(t, plain.path_prefix, "/")

	secure, secure_ok := client.parse_endpoint("https://maincloud.spacetimedb.com")
	testing.expect(t, secure_ok)
	testing.expect(t, secure.secure)
	testing.expect_value(t, secure.port, 443)

	explicit, explicit_ok := client.parse_endpoint("wss://example.com:8443/proxy", 3000)
	testing.expect(t, explicit_ok)
	testing.expect(t, explicit.secure)
	testing.expect_value(t, explicit.port, 8443)
	testing.expect_value(t, explicit.path_prefix, "/proxy/")

	fallback, fallback_ok := client.parse_endpoint("http://example.com", 3000)
	testing.expect(t, fallback_ok)
	testing.expect(t, !fallback.secure)
	testing.expect_value(t, fallback.port, 3000)

	ipv6, ipv6_ok := client.parse_endpoint("ws://[::1]:3000")
	testing.expect(t, ipv6_ok)
	testing.expect_value(t, ipv6.host, "::1")
	testing.expect_value(t, ipv6.port, 3000)

	for bad in ([?]string{"", "ftp://example.com", "host:notaport", "host:70000", "ws://", "a b"}) {
		_, bad_ok := client.parse_endpoint(bad)
		testing.expect(t, !bad_ok)
	}
}

Change_Row :: struct {
	id: u32,
	name: string,
}

change_row_bytes :: proc(id: u32, name: string) -> []u8 {
	buffer := make([]u8, 64, context.temp_allocator)
	length, _ := host.encode_row_into(Change_Row, Change_Row{id, name}, buffer)
	return buffer[:length]
}

@(test)
cache_reports_each_row_change_once_across_query_sets :: proc(t: ^testing.T) {
	cache: client.Cache
	defer client.cache_destroy(&cache)
	changes: [dynamic]client.Row_Change
	defer delete(changes)

	a := change_row_bytes(1, "a")
	b := change_row_bytes(2, "b")
	first := client.Subscribe_Applied{query_set_id = 1, rows = {tables = {{table = "t", rows = {offsets = {0}, data = a}}}}}
	client.cache_apply(&cache, client.Message{body = first}, &changes)
	testing.expect_value(t, len(changes), 1)
	testing.expect_value(t, changes[0].kind, client.Row_Change_Kind.Insert)

	// The same row in a second query set is already visible, so it is not reported again.
	clear(&changes)
	second := client.Subscribe_Applied{query_set_id = 2, rows = {tables = {{table = "t", rows = {offsets = {0}, data = a}}}}}
	client.cache_apply(&cache, client.Message{body = second}, &changes)
	testing.expect_value(t, len(changes), 0)

	// Deleting it from set 1 changes nothing visible; inserting b does.
	update := client.Transaction_Update{
		query_sets = {{query_set_id = 1, tables = {{table = "t", groups = {{
			inserts = {offsets = {0}, data = b},
			deletes = {offsets = {0}, data = a},
		}}}}}},
	}
	client.cache_apply(&cache, client.Message{body = update}, &changes)
	testing.expect_value(t, len(changes), 1)
	testing.expect(t, slice.equal(changes[0].row, b))

	// Dropping set 2 removes the last copy of a.
	clear(&changes)
	client.cache_apply(&cache, client.Message{body = client.Unsubscribe_Applied{query_set_id = 2}}, &changes)
	testing.expect_value(t, len(changes), 1)
	testing.expect_value(t, changes[0].kind, client.Row_Change_Kind.Delete)
	testing.expect(t, slice.equal(changes[0].row, a))
}

Recorded :: struct {
	inserted: [dynamic]string,
	deleted: [dynamic]string,
	updated: [dynamic]string,
}

@(test)
keyed_dispatch_pairs_deletes_and_inserts_into_updates :: proc(t: ^testing.T) {
	recorded: Recorded
	defer {
		for text in recorded.inserted do delete(text)
		for text in recorded.deleted do delete(text)
		for text in recorded.updated do delete(text)
		delete(recorded.inserted)
		delete(recorded.deleted)
		delete(recorded.updated)
	}
	handlers := client.Table_Handlers(Change_Row){
		on_insert = proc(row: ^Change_Row, user: rawptr) {
			r := cast(^Recorded)user
			append(&r.inserted, strings.clone(row.name))
		},
		on_delete = proc(row: ^Change_Row, user: rawptr) {
			r := cast(^Recorded)user
			append(&r.deleted, strings.clone(row.name))
		},
		on_update = proc(old: ^Change_Row, new: ^Change_Row, user: rawptr) {
			r := cast(^Recorded)user
			append(&r.updated, strings.concatenate({old.name, ">", new.name}))
		},
	}
	changes := []client.Row_Change{
		{table = "t", kind = .Delete, row = change_row_bytes(1, "a")},
		{table = "t", kind = .Insert, row = change_row_bytes(1, "b")},
		{table = "t", kind = .Insert, row = change_row_bytes(2, "c")},
		{table = "t", kind = .Delete, row = change_row_bytes(3, "d")},
		{table = "other", kind = .Insert, row = change_row_bytes(9, "z")},
	}
	client.dispatch_keyed_changes(changes, "t", handlers, &recorded, proc(row: ^Change_Row) -> u32 { return row.id })
	testing.expect_value(t, len(recorded.updated), 1)
	testing.expect_value(t, recorded.updated[0], "a>b")
	testing.expect_value(t, len(recorded.inserted), 1)
	testing.expect_value(t, recorded.inserted[0], "c")
	testing.expect_value(t, len(recorded.deleted), 1)
	testing.expect_value(t, recorded.deleted[0], "d")

	plain: Recorded
	defer {
		for text in plain.inserted do delete(text)
		for text in plain.deleted do delete(text)
		delete(plain.inserted)
		delete(plain.deleted)
		delete(plain.updated)
	}
	client.dispatch_changes(changes, "t", handlers, &plain)
	testing.expect_value(t, len(plain.inserted), 2)
	testing.expect_value(t, len(plain.deleted), 2)
	testing.expect_value(t, len(plain.updated), 0)
}
