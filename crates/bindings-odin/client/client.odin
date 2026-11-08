package client

MAX_V3_OUTBOUND_FRAME_BYTES :: 256 * 1024

import "core:fmt"
import "core:strings"
import "core:time"
import "base:runtime"
import "stdb:host"

Token_Provider :: proc(identity: [32]u8, current_token: string, user: rawptr) -> (token: string, ok: bool)
Connection_Callback :: proc(identity: [32]u8, connection_id: [16]u8, token: string, user: rawptr)
Disconnect_Callback :: proc(error: Error, user: rawptr)
Connect_Error_Callback :: proc(error: Error, user: rawptr)
// message is nil when error is non-None; otherwise it is valid until poll returns.
Response_Callback :: proc(message: ^Message, error: Error, user: rawptr)
Response_Context :: struct {
	connection: ^Connection,
	identity: [32]u8,
	connection_id: [16]u8,
}

Subscription_Event_Context :: struct {
	connection: ^Connection,
	query_set_id: u32,
	state: Subscription_State,
}

// Context, result pointer, and payload slices are borrowed until the callback returns.
Reducer_Result_Callback :: proc(ctx: ^Response_Context, result: ^Reducer_Result, error: Error, user: rawptr)
Procedure_Result_Callback :: proc(ctx: ^Response_Context, result: ^Procedure_Result, error: Error, user: rawptr)
Row_Changes_Callback :: proc(changes: []Row_Change, user: rawptr)
Subscription_Event_Callback :: proc(ctx: ^Subscription_Event_Context, message: ^Message, error: Error, user: rawptr)

Subscription_State :: enum u8 {
	Pending,
	Active,
	Ended,
}

Subscription_Handle :: struct {
	connection: ^Connection,
	query_set_id: u32,
	state: Subscription_State,
	unsubscribe_requested: bool,
	callback: Subscription_Event_Callback,
	user: rawptr,
}

Response_Registration :: struct {
	callback: Response_Callback,
	reducer_result_callback: Reducer_Result_Callback,
	procedure_result_callback: Procedure_Result_Callback,
	user: rawptr,
}

Connect_Options :: struct {
	host: string, // ws://, wss://, http:// or https:// URI, or a bare host (plain ws); may include :port and a path prefix
	port: int, // used when host has no port; 0 means 80, or 443 for wss/https
	database: string, // database name or identity
	token: string, // optional bearer token; empty connects anonymously
	handshake_timeout: time.Duration,
	compression: Compression, // the server compresses only messages above its size threshold
	light_mode: bool,
	confirmed_reads: runtime.Maybe(bool),
	automatic_reconnect: bool, // poll retries dropped sockets and replays subscriptions
	token_provider: Token_Provider,
	on_connect: Connection_Callback,
	on_reconnect: Connection_Callback,
	on_disconnect: Disconnect_Callback,
	on_connect_error: Connect_Error_Callback,
	on_row_changes: Row_Changes_Callback,
	callback_user: rawptr,
}

Subscription :: struct {
	queries: []string,
}

Outbound_Message :: struct {
	bytes: []u8,
	request_id: u32,
}

Connection :: struct {
	ws: WebSocket,
	identity: [32]u8,
	connection_id: [16]u8,
	token: string, // owned; reuse it to reconnect with the same identity
	next_request_id: u32,
	next_query_set_id: u32,
	batching_outbound: bool,
	outbound_batch: [dynamic]Outbound_Message,
	auto_outbound_batch: [dynamic]Outbound_Message,
	host: string,
	port: int,
	database: string,
	compression: Compression,
	light_mode: bool,
	confirmed_reads: runtime.Maybe(bool),
	handshake_timeout: time.Duration,
	automatic_reconnect: bool,
	connected: bool,
	reconnect_attempt: u32,
	reconnect_started_at: time.Time,
	subscriptions: map[u32]Subscription,
	token_provider: Token_Provider,
	on_connect: Connection_Callback,
	on_reconnect: Connection_Callback,
	on_disconnect: Disconnect_Callback,
	on_connect_error: Connect_Error_Callback,
	on_row_changes: Row_Changes_Callback,
	callback_user: rawptr,
	cache: Cache,
	pending_responses: map[u32]Response_Registration,
	subscription_callbacks: map[u32]Response_Registration,
	handshaking: bool,
	reconnecting: bool,
	reconnect_pending: bool,
}

// Blocks until the server's InitialConnection message arrives.
connect :: proc(options: Connect_Options) -> (connection: Connection, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	endpoint, endpoint_ok := parse_endpoint(options.host, options.port)
	if !endpoint_ok || options.port < 0 || len(options.database) == 0 {
		if options.on_connect_error != nil do options.on_connect_error(.Invalid_Argument, options.callback_user)
		return connection, .Invalid_Argument
	}
	path := subscription_path(endpoint, options.database, options.compression, options.light_mode, options.confirmed_reads)
	connection.ws, err = ws_connect(endpoint.host, endpoint.port, path, options.token, endpoint.secure)
	if err != .None {
		if options.on_connect_error != nil do options.on_connect_error(err, options.callback_user)
		return
	}
	timeout := options.handshake_timeout if options.handshake_timeout > 0 else 10 * time.Second
	when ODIN_OS == .JS {
		connection.host = strings.clone(options.host)
		connection.port = options.port
		connection.database = strings.clone(options.database)
		connection.compression = options.compression
		connection.light_mode = options.light_mode
		connection.confirmed_reads = options.confirmed_reads
		connection.handshake_timeout = timeout
		connection.automatic_reconnect = options.automatic_reconnect
		connection.subscriptions = make(map[u32]Subscription)
		connection.token_provider = options.token_provider
		connection.on_connect = options.on_connect
		connection.on_reconnect = options.on_reconnect
		connection.on_disconnect = options.on_disconnect
		connection.on_connect_error = options.on_connect_error
		connection.on_row_changes = options.on_row_changes
		connection.callback_user = options.callback_user
		connection.pending_responses = make(map[u32]Response_Registration)
		connection.subscription_callbacks = make(map[u32]Response_Registration)
		connection.handshaking = true
		return connection, .None
	}
	if err = ws_set_receive_timeout(&connection.ws, timeout); err != .None {
		ws_close(&connection.ws)
		if options.on_connect_error != nil do options.on_connect_error(err, options.callback_user)
		return
	}

	message: Message
	message, err = poll_socket(&connection.ws, timeout)
	if err != .None {
		ws_close(&connection.ws)
		if options.on_connect_error != nil do options.on_connect_error(err, options.callback_user)
		return
	}
	defer message_destroy(&message)
	initial, is_initial := message.body.(Initial_Connection)
	if !is_initial {
		ws_close(&connection.ws)
		if options.on_connect_error != nil do options.on_connect_error(.Protocol_Error, options.callback_user)
		return connection, .Protocol_Error
	}
	connection.identity = initial.identity
	connection.connection_id = initial.connection_id
	connection.token = strings.clone(initial.token)
	connection.host = strings.clone(options.host)
	connection.port = options.port
	connection.database = strings.clone(options.database)
	connection.compression = options.compression
	connection.light_mode = options.light_mode
	connection.confirmed_reads = options.confirmed_reads
	connection.handshake_timeout = timeout
	connection.automatic_reconnect = options.automatic_reconnect
	connection.subscriptions = make(map[u32]Subscription)
	connection.token_provider = options.token_provider
	connection.on_connect = options.on_connect
	connection.on_reconnect = options.on_reconnect
	connection.on_disconnect = options.on_disconnect
	connection.on_connect_error = options.on_connect_error
	connection.on_row_changes = options.on_row_changes
	connection.callback_user = options.callback_user
	connection.pending_responses = make(map[u32]Response_Registration)
	connection.subscription_callbacks = make(map[u32]Response_Registration)
	connection.connected = true
	if connection.on_connect != nil {
		connection.on_connect(connection.identity, connection.connection_id, connection.token, connection.callback_user)
	}
	return connection, .None
}

disconnect :: proc(connection: ^Connection) {
	when ODIN_OS == .JS do context = runtime.default_context()
	connection.automatic_reconnect = false
	connection.connected = false
	connection.batching_outbound = false
	clear_outbound_batch(connection)
	clear_outbound_messages(&connection.auto_outbound_batch)
	fail_pending_responses(connection, .Closed)
	if connection.on_disconnect != nil do connection.on_disconnect(.Closed, connection.callback_user)
	ws_close(&connection.ws)
	delete(connection.token)
	connection.token = ""
	delete(connection.host)
	connection.host = ""
	delete(connection.database)
	connection.database = ""
	for _, &subscription in connection.subscriptions do delete_subscription(&subscription)
	delete(connection.subscriptions)
	connection.subscriptions = nil
	delete(connection.pending_responses)
	connection.pending_responses = nil
	delete(connection.subscription_callbacks)
	connection.subscription_callbacks = nil
	cache_destroy(&connection.cache)
}

// Waits up to timeout for the next server message; a non-positive timeout blocks indefinitely.
poll :: proc(connection: ^Connection, timeout: time.Duration = 0) -> (message: Message, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	if connection.batching_outbound do return message, .Invalid_Argument
	if len(connection.auto_outbound_batch) > 0 {
		if send_err := flush_outbound_messages(connection, &connection.auto_outbound_batch); send_err != .None {
			return message, send_err
		}
	}
	when ODIN_OS == .JS {
		if connection.handshaking {
			message, err = poll_socket(&connection.ws, timeout)
			if err == .Timeout do return
			if err != .None {
				connection.handshaking = false
				ws_close(&connection.ws)
				if connection.reconnecting {
					if connection.on_disconnect != nil do connection.on_disconnect(err, connection.callback_user)
					connection.reconnect_pending = connection.automatic_reconnect
					return message, .Timeout
				}
				if connection.on_connect_error != nil do connection.on_connect_error(err, connection.callback_user)
				return
			}
			initial, is_initial := message.body.(Initial_Connection)
			if !is_initial {
				message_destroy(&message)
				connection.handshaking = false
				ws_close(&connection.ws)
				if connection.reconnecting {
					if connection.on_disconnect != nil do connection.on_disconnect(.Protocol_Error, connection.callback_user)
					connection.reconnect_pending = true
					return message, .Timeout
				}
				if connection.on_connect_error != nil do connection.on_connect_error(.Protocol_Error, connection.callback_user)
				return message, .Protocol_Error
			}
			if connection.reconnecting && initial.identity != connection.identity {
				message_destroy(&message)
				connection.handshaking = false
				connection.reconnect_pending = connection.automatic_reconnect
				ws_close(&connection.ws)
				if connection.on_disconnect != nil do connection.on_disconnect(.Protocol_Error, connection.callback_user)
				return message, .Protocol_Error
			}
			connection.identity = initial.identity
			connection.connection_id = initial.connection_id
			delete(connection.token)
			connection.token = strings.clone(initial.token)
			connection.connected = true
			connection.handshaking = false
			if connection.reconnecting {
				if connection.on_reconnect != nil {
					connection.on_reconnect(connection.identity, connection.connection_id, connection.token, connection.callback_user)
				}
				if send_err := send_subscription_replay_batch(connection); send_err != .None {
					message_destroy(&message)
					return message, send_err
				}
				connection.reconnect_attempt = 0
				connection.reconnecting = false
				connection.reconnect_pending = false
			} else if connection.on_connect != nil {
				connection.on_connect(connection.identity, connection.connection_id, connection.token, connection.callback_user)
			}
			apply_polled_message(connection, &message)
			return message, .None
		}
		if connection.reconnect_pending {
			if reconnect_err := begin_browser_reconnect(connection); reconnect_err != .None {
				if reconnect_err == .Timeout || reconnect_err == .Connect_Failed do return message, .Timeout
				return message, reconnect_err
			}
			connection.reconnect_pending = false
			return message, .Timeout
		}
	}
	message, err = poll_socket(&connection.ws, timeout)
	if err == .None {
		apply_polled_message(connection, &message)
		return
	}
	if err != .Closed && err != .Receive_Failed do return
	if connection.connected && connection.on_disconnect != nil do connection.on_disconnect(err, connection.callback_user)
	connection.connected = false
	fail_pending_responses(connection, .Unknown_Result)
	if !connection.automatic_reconnect do return
	when ODIN_OS == .JS {
		connection.reconnect_pending = true
		if reconnect_err := begin_browser_reconnect(connection); reconnect_err != .None {
			if reconnect_err == .Timeout || reconnect_err == .Connect_Failed do return message, .Timeout
			return message, reconnect_err
		}
		connection.reconnect_pending = false
		return message, .Timeout
	} else {
		if connection.reconnect_attempt > 0 do time.sleep(reconnect_delay(connection.reconnect_attempt))
		message, err = reconnect_once(connection)
		if err != .None {
			connection.reconnect_attempt += 1
			return
		}
		connection.reconnect_attempt = 0
		connection.connected = true
		apply_polled_message(connection, &message)
		return
	}
}

// Apply a received message to the connection cache and dispatch request and row callbacks.
apply_polled_message :: proc(connection: ^Connection, message: ^Message) {
	when ODIN_OS == .JS do context = runtime.default_context()
	changes: [dynamic]Row_Change
	changes_ptr: ^[dynamic]Row_Change
	if connection.on_row_changes != nil do changes_ptr = &changes
	cache_apply(&connection.cache, message^, changes_ptr)
	dispatch_response_callbacks(connection, message)
	if connection.on_row_changes != nil do connection.on_row_changes(changes[:], connection.callback_user)
	delete(changes)
}

@(private)
begin_browser_reconnect :: proc(connection: ^Connection) -> Error {
	if connection.reconnect_attempt > 0 {
		elapsed := time.diff(connection.reconnect_started_at, time.now())
		if elapsed < reconnect_delay(connection.reconnect_attempt) do return .Timeout
	}
	endpoint, endpoint_ok := parse_endpoint(connection.host, connection.port)
	if !endpoint_ok do return .Invalid_Argument
	path := subscription_path(endpoint, connection.database, connection.compression, connection.light_mode, connection.confirmed_reads)
	token := connection.token
	if connection.token_provider != nil {
		refreshed_token, token_ok := connection.token_provider(connection.identity, connection.token, connection.callback_user)
		if !token_ok do return .Token_Provider_Failed
		token = refreshed_token
	}
	ws, err := ws_connect(endpoint.host, endpoint.port, path, token, endpoint.secure)
	if err != .None {
		connection.reconnect_attempt += 1
		connection.reconnect_started_at = time.now()
		return err
	}
	ws_close(&connection.ws)
	connection.ws = ws
	connection.handshaking = true
	connection.reconnecting = true
	connection.reconnect_attempt += 1
	connection.reconnect_started_at = time.now()
	return .None
}

subscription_path :: proc(
	endpoint: Endpoint,
	database: string,
	compression: Compression,
	light_mode: bool,
	confirmed_reads: runtime.Maybe(bool),
) -> string {
	path := fmt.tprintf("%sv1/database/%s/subscribe?compression=%v", endpoint.path_prefix, database, compression)
	if light_mode do path = fmt.tprintf("%s&light=true", path)
	if confirmed, present := confirmed_reads.(bool); present {
		path = fmt.tprintf("%s&confirmed=%v", path, confirmed)
	}
	return path
}

@(private)
poll_socket :: proc(ws: ^WebSocket, timeout: time.Duration) -> (message: Message, err: Error) {
	payload: []u8
	if ws.protocol_v3 && len(ws.pending_messages) > 0 {
		payload = make([]u8, len(ws.pending_messages) + 1)
		payload[0] = COMPRESSION_TAG_NONE
		copy(payload[1:], ws.pending_messages)
		delete(ws.pending_messages)
		ws.pending_messages = nil
	} else {
		if err = ws_set_receive_timeout(ws, timeout); err != .None do return
		payload, err = ws_recv_message(ws)
		if err != .None do return
		if len(payload) > 0 && (payload[0] == COMPRESSION_TAG_GZIP || payload[0] == COMPRESSION_TAG_BROTLI) {
			inflated: []u8
			inflated_ok: bool
			if payload[0] == COMPRESSION_TAG_GZIP {
				inflated, inflated_ok = inflate_gzip_frame(payload[1:])
			} else {
				inflated, inflated_ok = inflate_brotli_frame(payload[1:])
			}
			delete(payload)
			if !inflated_ok do return message, .Decode_Failed
			payload = inflated
		}
	}
	if ws.protocol_v3 {
		if len(payload) == 0 || payload[0] != COMPRESSION_TAG_NONE {
			delete(payload)
			return message, .Decode_Failed
		}
		body, consumed, parsed := parse_server_message_prefix(payload[1:])
		if !parsed || consumed == 0 {
			server_message_destroy(&body)
			delete(payload)
			return message, .Decode_Failed
		}
		if consumed < len(payload) - 1 {
			delete(ws.pending_messages)
			ws.pending_messages = make([]u8, len(payload) - 1 - consumed)
			copy(ws.pending_messages, payload[consumed + 1:])
		}
		return Message{payload = payload, body = body}, .None
	}
	body, ok := parse_server_frame(payload)
	if !ok {
		delete(payload)
		return message, .Decode_Failed
	}
	return Message{payload = payload, body = body}, .None
}

@(private)
reconnect_delay :: proc(attempt: u32) -> time.Duration {
	delay := time.Second
	for _ in 0 ..< min(attempt, 5) do delay = min(delay * 2, 30 * time.Second)
	return delay
}

@(private)
reconnect_once :: proc(connection: ^Connection) -> (message: Message, err: Error) {
	endpoint, endpoint_ok := parse_endpoint(connection.host, connection.port)
	if !endpoint_ok do return message, .Invalid_Argument
	path := subscription_path(endpoint, connection.database, connection.compression, connection.light_mode, connection.confirmed_reads)
	token := connection.token
	if connection.token_provider != nil {
		refreshed_token, token_ok := connection.token_provider(connection.identity, connection.token, connection.callback_user)
		if !token_ok do return message, .Token_Provider_Failed
		token = refreshed_token
	}
	ws: WebSocket
	ws, err = ws_connect(endpoint.host, endpoint.port, path, token, endpoint.secure)
	if err != .None do return message, err
	message, err = poll_socket(&ws, connection.handshake_timeout)
	if err != .None {
		ws_close(&ws)
		return
	}
	initial, is_initial := message.body.(Initial_Connection)
	if !is_initial || initial.identity != connection.identity {
		message_destroy(&message)
		ws_close(&ws)
		return message, .Protocol_Error
	}
	new_token := strings.clone(initial.token)
	ws_close(&connection.ws)
	connection.ws = ws
	connection.connection_id = initial.connection_id
	delete(connection.token)
	connection.token = new_token
	connection.connected = true
	if connection.on_reconnect != nil {
		connection.on_reconnect(connection.identity, connection.connection_id, connection.token, connection.callback_user)
	}
	if send_err := send_subscription_replay_batch(connection); send_err != .None {
		message_destroy(&message)
		ws_close(&connection.ws)
		return message, send_err
	}
	return message, .None
}

@(private)
send_message :: proc(connection: ^Connection, builder: ^Builder) -> Error {
	defer delete(builder.bytes)
	if !connection.connected do return .Not_Connected
	if connection.batching_outbound {
		if len(builder.bytes) < 5 || builder.bytes[0] < 2 || builder.bytes[0] > 4 do return .Invalid_Argument
		if len(builder.bytes) > MAX_MESSAGE_BYTES do return .Message_Too_Large
		request_id := u32(builder.bytes[1]) | u32(builder.bytes[2]) << 8 |
			u32(builder.bytes[3]) << 16 | u32(builder.bytes[4]) << 24
		encoded_copy := make([]u8, len(builder.bytes))
		copy(encoded_copy, builder.bytes[:])
		append(&connection.outbound_batch, Outbound_Message{bytes = encoded_copy, request_id = request_id})
		return .None
	}
	if connection.ws.protocol_v3 && len(builder.bytes) >= 5 && builder.bytes[0] >= 2 && builder.bytes[0] <= 4 {
		if len(builder.bytes) > MAX_MESSAGE_BYTES do return .Message_Too_Large
		request_id := u32(builder.bytes[1]) | u32(builder.bytes[2]) << 8 |
			u32(builder.bytes[3]) << 16 | u32(builder.bytes[4]) << 24
		encoded_copy := make([]u8, len(builder.bytes))
		copy(encoded_copy, builder.bytes[:])
		append(&connection.auto_outbound_batch, Outbound_Message{bytes = encoded_copy, request_id = request_id})
		return .None
	}
	return ws_send_binary(&connection.ws, builder.bytes[:])
}

// Queue client requests until end_message_batch; they remain owned by the connection.
begin_message_batch :: proc(connection: ^Connection) -> Error {
	if !connection.connected do return .Not_Connected
	if connection.batching_outbound do return .Invalid_Argument
	if len(connection.auto_outbound_batch) > 0 {
		if send_err := flush_outbound_messages(connection, &connection.auto_outbound_batch); send_err != .None do return send_err
	}
	connection.batching_outbound = true
	return .None
}

// Sends queued requests. V3 concatenates messages into bounded frames; v2 sends them separately.
end_message_batch :: proc(connection: ^Connection) -> Error {
	when ODIN_OS == .JS do context = runtime.default_context()
	if !connection.batching_outbound do return .Invalid_Argument
	connection.batching_outbound = false
	if len(connection.outbound_batch) == 0 do return .None
	if !connection.connected {
		fail_batched_responses(connection, .Not_Connected)
		return .Not_Connected
	}
	return flush_outbound_messages(connection, &connection.outbound_batch)
}


@(private)
flush_outbound_messages :: proc(connection: ^Connection, messages: ^[dynamic]Outbound_Message) -> Error {
	if !connection.connected {
		fail_outbound_responses(connection, messages, .Not_Connected)
		return .Not_Connected
	}
	if !connection.ws.protocol_v3 {
		for message in messages^ {
			if err := ws_send_binary(&connection.ws, message.bytes); err != .None {
				fail_outbound_responses(connection, messages, err)
				return err
			}
		}
		clear_outbound_messages(messages)
		return .None
	}
	start := 0
	for start < len(messages^) {
		end := start
		frame_size := 0
		for end < len(messages^) {
			message_size := len(messages^[end].bytes)
			if message_size > MAX_MESSAGE_BYTES {
				fail_outbound_responses(connection, messages, .Message_Too_Large)
				return .Message_Too_Large
			}
			if end > start && frame_size + message_size > MAX_V3_OUTBOUND_FRAME_BYTES do break
			frame_size += message_size
			end += 1
		}
		frame_messages := make([][]u8, end - start)
		for index in start ..< end do frame_messages[index - start] = messages^[index].bytes
		frame := encode_client_messages_v3(frame_messages)
		delete(frame_messages)
		send_err := ws_send_binary(&connection.ws, frame)
		delete(frame)
		if send_err != .None {
			fail_outbound_responses(connection, messages, send_err)
			return send_err
		}
		start = end
	}
	clear_outbound_messages(messages)
	return .None
}

cancel_message_batch :: proc(connection: ^Connection) -> Error {
	when ODIN_OS == .JS do context = runtime.default_context()
	if !connection.batching_outbound do return .Invalid_Argument
	connection.batching_outbound = false
	fail_batched_responses(connection, .Cancelled)
	return .None
}

@(private)
clear_outbound_batch :: proc(connection: ^Connection) {
	clear_outbound_messages(&connection.outbound_batch)
}

@(private)
clear_outbound_messages :: proc(messages: ^[dynamic]Outbound_Message) {
	for message in messages^ do delete(message.bytes)
	delete(messages^)
	messages^ = nil
}

@(private)
fail_batched_responses :: proc(connection: ^Connection, err: Error) {
	fail_outbound_responses(connection, &connection.outbound_batch, err)
}

@(private)
fail_outbound_responses :: proc(
	connection: ^Connection,
	messages: ^[dynamic]Outbound_Message,
	err: Error,
) {
	registrations: [dynamic]Response_Registration
	for message in messages^ {
		if registration, found := connection.pending_responses[message.request_id]; found {
			delete_key(&connection.pending_responses, message.request_id)
			append(&registrations, registration)
		}
	}
	clear_outbound_messages(messages)
	for registration in registrations {
		notify_response_registration(connection, registration, nil, err)
	}
	delete(registrations)
}

@(private)
next_id :: proc(connection: ^Connection) -> u32 {
	connection.next_request_id += 1
	return connection.next_request_id
}

@(private)
send_subscription_replay_batch :: proc(connection: ^Connection) -> Error {
	when ODIN_OS == .JS do context = runtime.default_context()
	if len(connection.subscriptions) == 0 do return .None
	sets := make([]Client_Subscribe_Set, len(connection.subscriptions))
	index := 0
	for query_set_id, subscription in connection.subscriptions {
		sets[index] = Client_Subscribe_Set{query_set_id = query_set_id, queries = subscription.queries}
		index += 1
	}
	builder: Builder
	encode_subscribe_batch(&builder, next_id(connection), sets)
	delete(sets)
	return send_message(connection, &builder)
}

dispatch_response_callbacks :: proc(connection: ^Connection, message: ^Message) {
	request_id: u32
	has_request_id := false
	query_set_id: u32
	has_query_set_id := false
	#partial switch body in message.body {
	case Reducer_Result:
		request_id = body.request_id
		has_request_id = true
	case Procedure_Result:
		request_id = body.request_id
		has_request_id = true
	case One_Off_Query_Result:
		request_id = body.request_id
		has_request_id = true
	case Subscription_Error:
		request_id = body.request_id
		has_request_id = body.has_request_id
		query_set_id = body.query_set_id
		has_query_set_id = true
	case Subscribe_Applied:
		query_set_id = body.query_set_id
		has_query_set_id = true
	case Unsubscribe_Applied:
		query_set_id = body.query_set_id
		has_query_set_id = true
	case Subscribe_Batch_Applied:
		request_id = body.request_id
		has_request_id = true
	}
	if has_request_id {
		if registration, found := connection.pending_responses[request_id]; found {
			delete_key(&connection.pending_responses, request_id)
			notify_response_registration(connection, registration, message, .None)
		}
	}
	if has_query_set_id {
		_, is_unsubscribed := message.body.(Unsubscribe_Applied)
		_, is_error := message.body.(Subscription_Error)
		if is_error do forget_subscription(connection, query_set_id)
		if registration, found := connection.subscription_callbacks[query_set_id]; found {
			if registration.callback != nil do registration.callback(message, .None, registration.user)
		}
		if is_unsubscribed || is_error do delete_key(&connection.subscription_callbacks, query_set_id)
	}
	if batch, is_batch := message.body.(Subscribe_Batch_Applied); is_batch {
		for result in batch.results {
			_, is_error := result.outcome.(Subscribe_Set_Error)
			if is_error do forget_subscription(connection, result.query_set_id)
			if registration, found := connection.subscription_callbacks[result.query_set_id]; found {
				if registration.callback != nil do registration.callback(message, .None, registration.user)
			}
			if is_error do delete_key(&connection.subscription_callbacks, result.query_set_id)
		}
	}
}

@(private)
fail_pending_responses :: proc(connection: ^Connection, err: Error) {
	registrations: [dynamic]Response_Registration
	for request_id, registration in connection.pending_responses {
		append(&registrations, registration)
		delete_key(&connection.pending_responses, request_id)
	}
	for registration in registrations {
		notify_response_registration(connection, registration, nil, err)
	}
	delete(registrations)
}

@(private)
notify_response_registration :: proc(
	connection: ^Connection,
	registration: Response_Registration,
	message: ^Message,
	error: Error,
) {
	if registration.callback != nil {
		registration.callback(message, error, registration.user)
		return
	}
	call_context := Response_Context{
		connection = connection,
		identity = connection.identity,
		connection_id = connection.connection_id,
	}
	if registration.reducer_result_callback != nil {
		if message != nil {
			if result, ok := message.body.(Reducer_Result); ok {
				registration.reducer_result_callback(&call_context, &result, error, registration.user)
				return
			}
		}
		registration.reducer_result_callback(&call_context, nil, .Protocol_Error if error == .None else error, registration.user)
		return
	}
	if registration.procedure_result_callback != nil {
		if message != nil {
			if result, ok := message.body.(Procedure_Result); ok {
				registration.procedure_result_callback(&call_context, &result, error, registration.user)
				return
			}
		}
		registration.procedure_result_callback(&call_context, nil, .Protocol_Error if error == .None else error, registration.user)
	}
}

subscription_handle_response :: proc(message: ^Message, error: Error, user: rawptr) {
	handle := cast(^Subscription_Handle)user
	if handle == nil do return
	if error != .None {
		handle.state = .Ended
	} else if message != nil {
		#partial switch body in message.body {
		case Subscribe_Applied:
			handle.state = .Active
		case Subscription_Error, Unsubscribe_Applied:
			handle.state = .Ended
		case Subscribe_Batch_Applied:
			for result in body.results {
				if result.query_set_id != handle.query_set_id do continue
				if _, applied := result.outcome.(Subscribe_Set_Applied); applied {
					handle.state = .Active
				} else {
					handle.state = .Ended
				}
			}
		}
	}
	if handle.callback != nil {
		subscription_context := Subscription_Event_Context{
			connection = handle.connection,
			query_set_id = handle.query_set_id,
			state = handle.state,
		}
		handle.callback(&subscription_context, message, error, handle.user)
	}
}

// The handle must remain at a stable address until it reaches .Ended or is abandoned.
subscribe_managed :: proc(
	connection: ^Connection,
	handle: ^Subscription_Handle,
	query_set_id: u32,
	queries: []string,
	callback: Subscription_Event_Callback = nil,
	user: rawptr = nil,
) -> (request_id: u32, err: Error) {
	if handle == nil do return 0, .Invalid_Argument
	handle^ = Subscription_Handle{
		connection = connection,
		query_set_id = query_set_id,
		state = .Pending,
		callback = callback,
		user = user,
	}
	request_id, err = subscribe_with_callback(connection, query_set_id, queries, subscription_handle_response, handle)
	if err != .None do handle.state = .Ended
	return
}

unsubscribe_managed :: proc(
	connection: ^Connection,
	handle: ^Subscription_Handle,
	send_dropped_rows := false,
) -> (request_id: u32, err: Error) {
	if handle == nil || handle.state == .Ended || handle.unsubscribe_requested do return 0, .Invalid_Argument
	request_id, err = unsubscribe(connection, handle.query_set_id, send_dropped_rows)
	if err == .None do handle.unsubscribe_requested = true
	return
}

@(private)
allocate_query_set_id :: proc(connection: ^Connection) -> u32 {
	for _ in 0 ..< len(connection.subscriptions) + len(connection.subscription_callbacks) + 1 {
		connection.next_query_set_id += 1
		if connection.next_query_set_id == 0 do connection.next_query_set_id = 1
		if connection.next_query_set_id not_in connection.subscriptions &&
			connection.next_query_set_id not_in connection.subscription_callbacks {
			return connection.next_query_set_id
		}
	}
	return 0
}

// Allocates a query-set ID and stores it in handle before sending the subscription.
subscribe_managed_auto :: proc(
	connection: ^Connection,
	handle: ^Subscription_Handle,
	queries: []string,
	callback: Subscription_Event_Callback = nil,
	user: rawptr = nil,
) -> (request_id: u32, err: Error) {
	query_set_id := allocate_query_set_id(connection)
	if query_set_id == 0 do return 0, .Invalid_Argument
	return subscribe_managed(connection, handle, query_set_id, queries, callback, user)
}

subscribe :: proc(connection: ^Connection, query_set_id: u32, queries: []string) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	if len(queries) == 0 do return 0, .Invalid_Argument
	request_id = next_id(connection)
	builder: Builder
	encode_subscribe(&builder, request_id, query_set_id, queries)
	if err = send_message(connection, &builder); err != .None do return
	remember_subscription(connection, query_set_id, queries)
	return request_id, .None
}

subscribe_with_callback :: proc(
	connection: ^Connection,
	query_set_id: u32,
	queries: []string,
	callback: Response_Callback,
	user: rawptr = nil,
) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	request_id, err = subscribe(connection, query_set_id, queries)
	if err == .None && callback != nil {
			connection.subscription_callbacks[query_set_id] = Response_Registration{callback = callback, user = user}
	}
	return
}

unsubscribe :: proc(connection: ^Connection, query_set_id: u32, send_dropped_rows := false) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	request_id = next_id(connection)
	builder: Builder
	encode_unsubscribe(&builder, request_id, query_set_id, send_dropped_rows)
	if err = send_message(connection, &builder); err != .None do return
	forget_subscription(connection, query_set_id)
	return request_id, .None
}

@(private)
remember_subscription :: proc(connection: ^Connection, query_set_id: u32, queries: []string) {
	forget_subscription(connection, query_set_id)
	copy := make([]string, len(queries))
	for query, index in queries do copy[index] = strings.clone(query)
	connection.subscriptions[query_set_id] = Subscription{queries = copy}
}

@(private)
delete_subscription :: proc(subscription: ^Subscription) {
	for query in subscription.queries do delete(query)
	delete(subscription.queries)
	subscription^ = {}
}

@(private)
forget_subscription :: proc(connection: ^Connection, query_set_id: u32) {
	if subscription := &connection.subscriptions[query_set_id]; subscription != nil {
		delete_subscription(subscription)
		delete_key(&connection.subscriptions, query_set_id)
	}
}

one_off_query :: proc(connection: ^Connection, query: string) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	request_id = next_id(connection)
	builder: Builder
	encode_one_off_query(&builder, request_id, query)
	return request_id, send_message(connection, &builder)
}

one_off_query_with_callback :: proc(
	connection: ^Connection,
	query: string,
	callback: Response_Callback,
	user: rawptr = nil,
) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	request_id, err = one_off_query(connection, query)
	if err == .None && callback != nil {
		connection.pending_responses[request_id] = Response_Registration{callback = callback, user = user}
	}
	return
}

Sql_Query_Error :: enum u8 {
	None,
	Invalid_Identifier,
	Invalid_Projection,
}

Sql_Query_Operator :: enum u8 {
	Equal,
	Not_Equal,
	Less,
	Less_Or_Equal,
	Greater,
	Greater_Or_Equal,
}

Sql_Query_Projection_Mode :: enum u8 {
	Star,
	Columns,
	Count,
	Sum,
}

Sql_Query_Builder :: struct {
	table: string,
	table_alias: string,
	projection: string,
	projection_mode: Sql_Query_Projection_Mode,
	joins: [dynamic]string,
	filters: [dynamic]string,
	filter_operators: [dynamic]string,
	order_by: [dynamic]string,
	has_limit: bool,
	limit: u64,
}

sql_query :: proc(table: string, alias: string = "") -> (Sql_Query_Builder, Sql_Query_Error) {
	quoted_table, ok := sql_quote_identifier(table)
	if !ok do return {}, .Invalid_Identifier
	query := Sql_Query_Builder{table = quoted_table, projection = strings.clone("*")}
	if len(alias) > 0 {
		query.table_alias, ok = sql_quote_identifier(alias)
		if !ok {
			sql_query_destroy(&query)
			return {}, .Invalid_Identifier
		}
	}
	return query, .None
}

@(private)
sql_quote_identifier :: proc(identifier: string) -> (string, bool) {
	if len(identifier) == 0 do return "", false
	quoted: [dynamic]u8
	append(&quoted, '"')
	segment_start := true
	for byte in transmute([]u8)identifier {
		if byte == '.' {
			if segment_start {
				delete(quoted)
				return "", false
			}
			append(&quoted, '"')
			append(&quoted, '.')
			append(&quoted, '"')
			segment_start = true
			continue
		}
		is_alpha := (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z')
		is_digit := byte >= '0' && byte <= '9'
		if segment_start {
			if !is_alpha && byte != '_' {
				delete(quoted)
				return "", false
			}
			segment_start = false
		} else if !is_alpha && !is_digit && byte != '_' {
			delete(quoted)
			return "", false
		}
		append(&quoted, byte)
	}
	if segment_start {
		delete(quoted)
		return "", false
	}
	append(&quoted, '"')
	result := strings.clone(string(quoted[:]))
	delete(quoted)
	return result, true
}

sql_typed_literal :: proc($T: typeid, value: T) -> string {
	when T == string {
		return sql_string_literal(value)
	} else when T == []u8 {
		return sql_bytes_literal(value)
	} else {
		return sql_literal(T, value)
	}
}

sql_query_where :: proc($T: typeid, query: ^Sql_Query_Builder, column: string, operator: Sql_Query_Operator, value: T) -> Sql_Query_Error {
	return sql_query_where_with_operator(T, query, column, operator, value, "AND")
}

sql_query_or_where :: proc($T: typeid, query: ^Sql_Query_Builder, column: string, operator: Sql_Query_Operator, value: T) -> Sql_Query_Error {
	return sql_query_where_with_operator(T, query, column, operator, value, "OR")
}

@(private)
sql_query_where_with_operator :: proc(
	$T: typeid,
	query: ^Sql_Query_Builder,
	column: string,
	operator: Sql_Query_Operator,
	value: T,
	logical_operator: string,
) -> Sql_Query_Error {
	quoted_column, ok := sql_quote_identifier(column)
	if !ok do return .Invalid_Identifier
	operator_text := "="
	switch operator {
	case .Equal: operator_text = " = "
	case .Not_Equal: operator_text = " != "
	case .Less: operator_text = " < "
	case .Less_Or_Equal: operator_text = " <= "
	case .Greater: operator_text = " > "
	case .Greater_Or_Equal: operator_text = " >= "
	}
	literal := sql_typed_literal(T, value)
	filter := strings.concatenate({quoted_column, operator_text, literal})
	delete(quoted_column)
	delete(literal)
	if len(query.filters) > 0 do append(&query.filter_operators, strings.clone(logical_operator))
	append(&query.filters, filter)
	return .None
}

sql_query_project_all :: proc(query: ^Sql_Query_Builder, alias: string = "") -> Sql_Query_Error {
	if len(alias) == 0 {
		delete(query.projection)
		query.projection = strings.clone("*")
		query.projection_mode = .Star
		return .None
	}
	quoted_alias, ok := sql_quote_identifier(alias)
	if !ok do return .Invalid_Identifier
	projection := strings.concatenate({quoted_alias, ".*"})
	delete(quoted_alias)
	delete(query.projection)
	query.projection = projection
	query.projection_mode = .Star
	return .None
}

sql_query_project_column :: proc(query: ^Sql_Query_Builder, column: string, alias: string = "") -> Sql_Query_Error {
	if query.projection_mode == .Count || query.projection_mode == .Sum do return .Invalid_Projection
	quoted_column, column_ok := sql_quote_identifier(column)
	quoted_alias := ""
	alias_ok := true
	if len(alias) > 0 {
		quoted_alias, alias_ok = sql_quote_identifier(alias)
	}
	if !column_ok || !alias_ok {
		delete(quoted_column)
		if len(quoted_alias) > 0 do delete(quoted_alias)
		return .Invalid_Identifier
	}
	projection := quoted_column
	if len(quoted_alias) > 0 {
		projection = strings.concatenate({quoted_column, " AS ", quoted_alias})
		delete(quoted_column)
		delete(quoted_alias)
	}
	if query.projection_mode == .Star {
		delete(query.projection)
		query.projection = projection
		query.projection_mode = .Columns
	} else {
		combined := strings.concatenate({query.projection, ", ", projection})
		delete(query.projection)
		delete(projection)
		query.projection = combined
	}
	return .None
}

sql_query_count :: proc(query: ^Sql_Query_Builder, alias: string) -> Sql_Query_Error {
	if query.projection_mode != .Star do return .Invalid_Projection
	quoted_alias, ok := sql_quote_identifier(alias)
	if !ok do return .Invalid_Identifier
	delete(query.projection)
	query.projection = strings.concatenate({"COUNT(*) AS ", quoted_alias})
	delete(quoted_alias)
	query.projection_mode = .Count
	return .None
}

sql_query_sum :: proc(query: ^Sql_Query_Builder, column, alias: string) -> Sql_Query_Error {
	if query.projection_mode != .Star do return .Invalid_Projection
	quoted_column, column_ok := sql_quote_identifier(column)
	quoted_alias, alias_ok := sql_quote_identifier(alias)
	if !column_ok || !alias_ok {
		delete(quoted_column)
		delete(quoted_alias)
		return .Invalid_Identifier
	}
	delete(query.projection)
	query.projection = strings.concatenate({"SUM(", quoted_column, ") AS ", quoted_alias})
	delete(quoted_column)
	delete(quoted_alias)
	query.projection_mode = .Sum
	return .None
}

sql_query_inner_join :: proc(
	query: ^Sql_Query_Builder,
	table: string,
	alias: string,
	left_field: string,
	right_field: string,
) -> Sql_Query_Error {
	quoted_table, table_ok := sql_quote_identifier(table)
	quoted_alias, alias_ok := sql_quote_identifier(alias)
	quoted_left, left_ok := sql_quote_identifier(left_field)
	quoted_right, right_ok := sql_quote_identifier(right_field)
	if !table_ok || !alias_ok || !left_ok || !right_ok {
		delete(quoted_table)
		delete(quoted_alias)
		delete(quoted_left)
		delete(quoted_right)
		return .Invalid_Identifier
	}
	join := strings.concatenate({" INNER JOIN ", quoted_table, " AS ", quoted_alias, " ON ", quoted_left, " = ", quoted_right})
	delete(quoted_table)
	delete(quoted_alias)
	delete(quoted_left)
	delete(quoted_right)
	append(&query.joins, join)
	return .None
}

sql_query_cross_join :: proc(query: ^Sql_Query_Builder, table: string, alias: string = "") -> Sql_Query_Error {
	quoted_table, table_ok := sql_quote_identifier(table)
	quoted_alias := ""
	alias_ok := true
	if len(alias) > 0 {
		quoted_alias, alias_ok = sql_quote_identifier(alias)
	}
	if !table_ok || !alias_ok {
		delete(quoted_table)
		if len(quoted_alias) > 0 do delete(quoted_alias)
		return .Invalid_Identifier
	}
	join := strings.concatenate({" CROSS JOIN ", quoted_table})
	if len(quoted_alias) > 0 {
	aliased_join := strings.concatenate({join, " AS ", quoted_alias})
	delete(join)
	join = aliased_join
		delete(quoted_alias)
	}
	delete(quoted_table)
	append(&query.joins, join)
	return .None
}

sql_query_limit :: proc(query: ^Sql_Query_Builder, limit: u64) {
	query.has_limit = true
	query.limit = limit
}

sql_query_order_by :: proc(
	query: ^Sql_Query_Builder,
	column: string,
	descending := false,
	nulls_first: runtime.Maybe(bool) = nil,
) -> Sql_Query_Error {
	quoted_column, ok := sql_quote_identifier(column)
	if !ok do return .Invalid_Identifier
	direction := " ASC" if !descending else " DESC"
	order := strings.concatenate({quoted_column, direction})
	delete(quoted_column)
	if first, has_null_order := nulls_first.(bool); has_null_order {
		null_order := " NULLS FIRST" if first else " NULLS LAST"
		ordered := strings.concatenate({order, null_order})
		delete(order)
		order = ordered
	}
	append(&query.order_by, order)
	return .None
}

sql_query_build :: proc(query: ^Sql_Query_Builder) -> string {
	parts: [dynamic]string
	append(&parts, "SELECT ")
	append(&parts, query.projection)
	append(&parts, " FROM ")
	append(&parts, query.table)
	if len(query.table_alias) > 0 {
		append(&parts, " AS ")
		append(&parts, query.table_alias)
	}
	for join in query.joins do append(&parts, join)
	for filter, index in query.filters {
		if index == 0 {
			append(&parts, " WHERE ")
		} else {
			append(&parts, fmt.tprintf(" %s ", query.filter_operators[index - 1]))
		}
		append(&parts, filter)
	}
	for order, index in query.order_by {
		append(&parts, " ORDER BY " if index == 0 else ", ")
		append(&parts, order)
	}
	if query.has_limit {
		append(&parts, " LIMIT ")
		append(&parts, fmt.tprintf("%v", query.limit))
	}
	result := strings.concatenate(parts[:])
	delete(parts)
	return result
}

sql_query_destroy :: proc(query: ^Sql_Query_Builder) {
	delete(query.table)
	if len(query.table_alias) > 0 do delete(query.table_alias)
	delete(query.projection)
	for join in query.joins do delete(join)
	delete(query.joins)
	for filter in query.filters do delete(filter)
	delete(query.filters)
	for operator in query.filter_operators do delete(operator)
	delete(query.filter_operators)
	for order in query.order_by do delete(order)
	delete(query.order_by)
	query^ = {}
}

sql_string_literal :: proc(value: string) -> string {
	escaped: [dynamic]u8
	append(&escaped, '\'')
	for byte in transmute([]u8)value {
		append(&escaped, byte)
		if byte == '\'' do append(&escaped, byte)
	}
	append(&escaped, '\'')
	result := strings.clone(string(escaped[:]))
	delete(escaped)
	return result
}

sql_hex_literal :: proc(bytes: []u8) -> string {
	digits := "0123456789abcdef"
	encoded: [dynamic]u8
	append(&encoded, '0')
	append(&encoded, 'x')
	for byte in bytes {
		append(&encoded, digits[int(byte >> 4)])
		append(&encoded, digits[int(byte & 0x0f)])
	}
	result := strings.clone(string(encoded[:]))
	delete(encoded)
	return result
}

sql_uuid_literal :: proc(value: u128) -> string {
	digits := "0123456789abcdef"
	encoded: [dynamic]u8
	append(&encoded, '\'')
	for index in 0 ..< 32 {
		if index == 8 || index == 12 || index == 16 || index == 20 do append(&encoded, '-')
		nibble := u8((value >> u128((31-index)*4)) & 0x0f)
		append(&encoded, digits[int(nibble)])
	}
	append(&encoded, '\'')
	result := strings.clone(string(encoded[:]))
	delete(encoded)
	return result
}

sql_timestamp_literal :: proc(value: host.Timestamp) -> string {
	formatted, ok := time.time_to_rfc3339(time.Time{_nsec = i64(value) * 1000})
	if !ok do return ""
	defer delete(formatted)
	return sql_string_literal(formatted)
}

sql_literal :: proc($T: typeid, value: T) -> string {
	when T == bool {
		literal := "FALSE"
		if value do literal = "TRUE"
		return strings.clone(literal)
	} else when T == host.Identity {
		bytes := transmute([32]u8)value
		return sql_hex_literal(bytes[:])
	} else when T == host.Connection_Id {
		bytes: [16]u8
		for index in 0 ..< len(bytes) do bytes[index] = u8(u128(value) >> u128((15-index)*8))
		return sql_hex_literal(bytes[:])
	} else when T == host.Timestamp {
		return sql_timestamp_literal(value)
	} else {
		formatted := fmt.tprintf("%v", value)
		return strings.clone(formatted)
	}
}

sql_bytes_literal :: proc(value: []u8) -> string {
	return sql_hex_literal(value)
}

// Takes ownership of each argument literal and returns an allocated query string.
sql_view_query :: proc(name: string, arguments: []string) -> string {
	parts: [dynamic]string
	append(&parts, "SELECT * FROM ")
	append(&parts, name)
	append(&parts, "(")
	for argument, index in arguments {
		if index > 0 do append(&parts, ", ")
		append(&parts, argument)
		delete(argument)
	}
	append(&parts, ")")
	query := strings.concatenate(parts[:])
	delete(parts)
	return query
}

// args must be the BSATN encoding of the reducer's argument product.
call_reducer_raw :: proc(connection: ^Connection, reducer: string, args: []u8) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	if len(reducer) == 0 do return 0, .Invalid_Argument
	request_id = next_id(connection)
	builder: Builder
	encode_call_reducer(&builder, request_id, reducer, args)
	return request_id, send_message(connection, &builder)
}

// Args is a struct whose fields match the reducer's parameters in order.
call_reducer :: proc(connection: ^Connection, reducer: string, args: $Args) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	encoded, codec_err := encode_value(Args, args)
	if codec_err != .None do return 0, .Encode_Failed
	defer delete(encoded)
	return call_reducer_raw(connection, reducer, encoded)
}

call_reducer_with_callback :: proc(
	connection: ^Connection,
	reducer: string,
	args: $Args,
	callback: Response_Callback,
	user: rawptr = nil,
) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	request_id, err = call_reducer(connection, reducer, args)
	if err == .None && callback != nil {
		connection.pending_responses[request_id] = Response_Registration{callback = callback, user = user}
	}
	return
}

call_reducer_with_result_callback :: proc(
	connection: ^Connection,
	reducer: string,
	args: $Args,
	callback: Reducer_Result_Callback,
	user: rawptr = nil,
) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	request_id, err = call_reducer(connection, reducer, args)
	if err == .None && callback != nil {
		connection.pending_responses[request_id] = Response_Registration{reducer_result_callback = callback, user = user}
	}
	return
}

// args must be the BSATN encoding of the procedure's argument product.
call_procedure_raw :: proc(connection: ^Connection, procedure: string, args: []u8) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	if len(procedure) == 0 do return 0, .Invalid_Argument
	request_id = next_id(connection)
	builder: Builder
	encode_call_procedure(&builder, request_id, procedure, args)
	return request_id, send_message(connection, &builder)
}

// Args is a struct whose fields match the procedure's parameters in order.
call_procedure :: proc(connection: ^Connection, procedure: string, args: $Args) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	encoded, codec_err := encode_value(Args, args)
	if codec_err != .None do return 0, .Encode_Failed
	defer delete(encoded)
	return call_procedure_raw(connection, procedure, encoded)
}

call_procedure_with_callback :: proc(
	connection: ^Connection,
	procedure: string,
	args: $Args,
	callback: Response_Callback,
	user: rawptr = nil,
) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	request_id, err = call_procedure(connection, procedure, args)
	if err == .None && callback != nil {
		connection.pending_responses[request_id] = Response_Registration{callback = callback, user = user}
	}
	return
}

call_procedure_with_result_callback :: proc(
	connection: ^Connection,
	procedure: string,
	args: $Args,
	callback: Procedure_Result_Callback,
	user: rawptr = nil,
) -> (request_id: u32, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	request_id, err = call_procedure(connection, procedure, args)
	if err == .None && callback != nil {
		connection.pending_responses[request_id] = Response_Registration{procedure_result_callback = callback, user = user}
	}
	return
}

// Decodes a returned value; the result owns its strings and arrays (see host.delete_decoded_row).
procedure_return_value :: proc(result: Procedure_Result, $T: typeid) -> (T, host.Codec_Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	value: T
	if !result.returned do return value, .Malformed_Data
	decoded, consumed, err := host.decode_row_from(T, result.return_value)
	if err == .None && consumed != len(result.return_value) do err = .Trailing_Bytes
	return decoded, err
}

MAX_ENCODED_ROW_BYTES :: 16 * 1024 * 1024

// Grows the scratch buffer until the codec fits the value.
encode_value :: proc($T: typeid, value: T) -> ([]u8, host.Codec_Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	size := 256
	for size <= MAX_ENCODED_ROW_BYTES {
		buffer := make([]u8, size)
		length, err := host.encode_row_into(T, value, buffer)
		if err == .None {
			return buffer[:length], .None
		}
		delete(buffer)
		if err != .Buffer_Too_Small do return nil, err
		size *= 4
	}
	return nil, .Value_Too_Large
}

// Rows own their strings and arrays; release them with delete_rows.
decode_rows :: proc(list: Row_List, $Row: typeid) -> ([]Row, host.Codec_Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	count := row_list_len(list)
	rows := make([]Row, count)
	for index in 0 ..< count {
		bytes, ok := row_list_row(list, index)
		if !ok {
			delete_rows(rows[:index])
			return nil, .Malformed_Data
		}
		row, consumed, err := host.decode_row_from(Row, bytes)
		if err == .None && consumed != len(bytes) do err = .Trailing_Bytes
		if err != .None {
			delete_rows(rows[:index])
			return nil, err
		}
		rows[index] = row
	}
	return rows, .None
}

one_off_query_result_rows :: proc(result: One_Off_Query_Result, table: string, $Row: typeid) -> ([]Row, host.Codec_Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	if result.failed do return nil, .Malformed_Data
	for table_rows in result.rows.tables {
		if table_rows.table == table do return decode_rows(table_rows.rows, Row)
	}
	return nil, .None
}

delete_rows :: proc(rows: []$Row) {
	when ODIN_OS == .JS do context = runtime.default_context()
	for &row in rows do host.delete_decoded_row(Row, &row)
	delete(rows)
}

// Err carries a BSATN string from reducer_fail; Internal_Error carries plain diagnostic text.
reducer_error_message :: proc(result: Reducer_Result) -> (string, bool) {
	#partial switch result.outcome {
	case .Err:
		reader := Reader{buffer = result.return_value}
		text, ok := read_string(&reader)
		return text, ok && reader_remaining(&reader) == 0
	case .Internal_Error:
		return result.message, true
	}
	return "", false
}
