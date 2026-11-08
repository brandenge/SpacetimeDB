#+build js
package client

import "core:time"

Error :: enum u8 {
	None,
	Invalid_Argument,
	Connect_Failed,
	Tls_Failed,
	Handshake_Failed,
	Send_Failed,
	Receive_Failed,
	Timeout,
	Closed,
	Protocol_Error,
	Message_Too_Large,
	Decode_Failed,
	Encode_Failed,
	Allocation_Failed,
	Token_Provider_Failed,
	Not_Connected,
	Unknown_Result,
	Cancelled,
}

PROTOCOL_ID_V2 :: 2
PROTOCOL_ID_V3 :: 3
MAX_MESSAGE_BYTES :: 64 * 1024 * 1024

foreign import browser_transport "stdb_browser"

@(default_calling_convention = "c")
foreign browser_transport {
	browser_ws_open :: proc(
		host_ptr: [^]u8,
		host_len: uintptr,
		port: i32,
		path_ptr: [^]u8,
		path_len: uintptr,
		token_ptr: [^]u8,
		token_len: uintptr,
		secure: i32,
	) -> i32 ---
	browser_ws_close :: proc(handle: i32) ---
	browser_ws_send :: proc(handle: i32, data_ptr: [^]u8, data_len: uintptr) -> i32 ---
	browser_ws_message_length :: proc(handle: i32) -> i32 ---
	browser_ws_receive :: proc(handle: i32, data_ptr: [^]u8, capacity: uintptr) -> i32 ---
	browser_ws_protocol :: proc(handle: i32) -> i32 ---
}

WebSocket :: struct {
	handle: i32,
	pending_messages: []u8,
	protocol_v3: bool,
	open: bool,
}

ws_set_receive_timeout :: proc(ws: ^WebSocket, timeout: time.Duration) -> Error {
	_ = ws
	_ = timeout
	return .None
}

ws_connect :: proc(host: string, port: int, path, token: string, secure := false) -> (ws: WebSocket, err: Error) {
	handle := browser_ws_open(
		raw_data(transmute([]u8)host), uintptr(len(host)), i32(port),
		raw_data(transmute([]u8)path), uintptr(len(path)),
		raw_data(transmute([]u8)token), uintptr(len(token)),
		1 if secure else 0,
	)
	if handle < 0 do return ws, .Connect_Failed
	return WebSocket{handle = handle, open = true}, .None
}

ws_send_all :: proc(ws: ^WebSocket, bytes: []u8) -> Error {
	if !ws.open do return .Closed
	if browser_ws_send(ws.handle, raw_data(bytes), uintptr(len(bytes))) != 0 do return .Send_Failed
	return .None
}

ws_send_binary :: proc(ws: ^WebSocket, payload: []u8) -> Error {
	return ws_send_all(ws, payload)
}

ws_recv_message :: proc(ws: ^WebSocket) -> (message: []u8, err: Error) {
	if !ws.open do return nil, .Closed
	length := browser_ws_message_length(ws.handle)
	if length == 0 do return nil, .Timeout
	if length == -1 {
		ws.open = false
		return nil, .Closed
	}
	if length < 0 || length > MAX_MESSAGE_BYTES do return nil, .Decode_Failed
	protocol := browser_ws_protocol(ws.handle)
	if protocol != PROTOCOL_ID_V2 && protocol != PROTOCOL_ID_V3 do return nil, .Handshake_Failed
	ws.protocol_v3 = protocol == PROTOCOL_ID_V3
	message = make([]u8, int(length))
	received := browser_ws_receive(ws.handle, raw_data(message), uintptr(length))
	if received != length {
		delete(message)
		return nil, .Receive_Failed
	}
	return message, .None
}

ws_close :: proc(ws: ^WebSocket) {
	if ws.open do browser_ws_close(ws.handle)
	ws.open = false
	delete(ws.pending_messages)
	ws.pending_messages = nil
}
