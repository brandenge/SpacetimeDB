#+build !js
package client

import "core:crypto"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:net"
import "core:strings"
import "core:time"

Error :: enum u8 {
	None,
	Invalid_Argument,
	Connect_Failed,
	Tls_Failed, // TLS setup or certificate verification failed
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

PROTOCOL_NAME_V2 :: "v2.bsatn.spacetimedb"
PROTOCOL_NAME_V3 :: "v3.bsatn.spacetimedb"
WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_MESSAGE_BYTES :: 64 * 1024 * 1024
MAX_HEADER_BYTES :: 16 * 1024

WebSocket :: struct {
	socket: net.TCP_Socket,
	tls: ^Tls_Session, // nil for plain ws://
	buffer: [dynamic]u8,
	cursor: int,
	message: [dynamic]u8,
	pending_messages: []u8,
	in_message: bool,
	protocol_v3: bool,
	open: bool,
}

ws_set_receive_timeout :: proc(ws: ^WebSocket, timeout: time.Duration) -> Error {
	if net.set_option(ws.socket, .Receive_Timeout, timeout) != nil do return .Connect_Failed
	return .None
}

// A timeout leaves already-received bytes buffered so the next call resumes cleanly.
ws_fill :: proc(ws: ^WebSocket, needed: int) -> Error {
	if ws.cursor > 0 && ws.cursor == len(ws.buffer) {
		clear(&ws.buffer)
		ws.cursor = 0
	} else if ws.cursor > 64 * 1024 {
		remaining := len(ws.buffer) - ws.cursor
		copy(ws.buffer[:remaining], ws.buffer[ws.cursor:])
		resize(&ws.buffer, remaining)
		ws.cursor = 0
	}
	for len(ws.buffer) - ws.cursor < needed {
		chunk: [8192]u8
		count: int
		if ws.tls != nil {
			tls_err: Error
			count, tls_err = tls_recv(ws.tls, chunk[:])
			if tls_err == .Closed do ws.open = false
			if tls_err != .None do return tls_err
		} else {
			recv_err: net.TCP_Recv_Error
			count, recv_err = net.recv_tcp(ws.socket, chunk[:])
			if recv_err != nil {
				if recv_err == .Timeout || recv_err == .Would_Block || recv_err == .Interrupted do return .Timeout
				return .Receive_Failed
			}
		}
		if count == 0 {
			ws.open = false
			return .Closed
		}
		if _, alloc_err := append(&ws.buffer, ..chunk[:count]); alloc_err != nil do return .Allocation_Failed
	}
	return .None
}

ws_send_all :: proc(ws: ^WebSocket, bytes: []u8) -> Error {
	if ws.tls != nil do return tls_send(ws.tls, bytes)
	sent := 0
	for sent < len(bytes) {
		count, err := net.send_tcp(ws.socket, bytes[sent:])
		if err != nil || count <= 0 do return .Send_Failed
		sent += count
	}
	return .None
}

ws_accept_key :: proc(key: string) -> (string, bool) {
	context_hash: sha1.Context
	sha1.init(&context_hash)
	sha1.update(&context_hash, transmute([]u8)key)
	sha1.update(&context_hash, transmute([]u8)string(WS_GUID))
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&context_hash, digest[:])
	encoded, err := base64.encode(digest[:])
	return encoded, err == nil
}

ws_connect :: proc(
	host: string,
	port: int,
	path: string,
	token: string,
	secure := false,
) -> (ws: WebSocket, err: Error) {
	socket, dial_err := net.dial_tcp_from_hostname_with_port_override(host, port)
	if dial_err != nil do return ws, .Connect_Failed
	ws.socket = socket
	ws.open = true
	defer if err != .None {
		tls_close(ws.tls)
		ws.tls = nil
		net.close(ws.socket)
		delete(ws.buffer)
		delete(ws.message)
	}
	if secure {
		ws.tls, err = tls_connect(socket, host)
		if err != .None do return ws, err
	}

	nonce: [16]u8
	crypto.rand_bytes(nonce[:])
	key, key_err := base64.encode(nonce[:])
	if key_err != nil do return ws, .Allocation_Failed
	defer delete(key)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "GET ")
	strings.write_string(&builder, path)
	strings.write_string(&builder, " HTTP/1.1\r\nHost: ")
	strings.write_string(&builder, host)
	if port != (443 if secure else 80) {
		strings.write_string(&builder, ":")
		strings.write_int(&builder, port)
	}
	strings.write_string(&builder, "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ")
	strings.write_string(&builder, key)
	strings.write_string(&builder, "\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: ")
	strings.write_string(&builder, PROTOCOL_NAME_V3)
	strings.write_string(&builder, ", ")
	strings.write_string(&builder, PROTOCOL_NAME_V2)
	strings.write_string(&builder, "\r\n")
	if len(token) > 0 {
		strings.write_string(&builder, "Authorization: Bearer ")
		strings.write_string(&builder, token)
		strings.write_string(&builder, "\r\n")
	}
	strings.write_string(&builder, "\r\n")
	if send_err := ws_send_all(&ws, transmute([]u8)strings.to_string(builder)); send_err != .None do return ws, send_err

	header_end := -1
	for header_end < 0 {
		unread := len(ws.buffer) - ws.cursor
		if unread > MAX_HEADER_BYTES do return ws, .Handshake_Failed
		if fill_err := ws_fill(&ws, unread + 1); fill_err != .None do return ws, .Handshake_Failed
		header_end = strings.index(string(ws.buffer[ws.cursor:]), "\r\n\r\n")
	}
	head := string(ws.buffer[ws.cursor:ws.cursor + header_end])
	ws.cursor += header_end + 4

	lines := strings.split(head, "\r\n", context.temp_allocator)
	if len(lines) == 0 || !strings.has_prefix(lines[0], "HTTP/1.1 101") do return ws, .Handshake_Failed
	expected, accept_ok := ws_accept_key(key)
	if !accept_ok do return ws, .Allocation_Failed
	defer delete(expected)
	accepted := false
	selected_protocol := ""
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon < 0 do continue
		name := strings.trim_space(line[:colon])
		value := strings.trim_space(line[colon + 1:])
		if strings.equal_fold(name, "sec-websocket-accept") && value == expected do accepted = true
		if strings.equal_fold(name, "sec-websocket-protocol") do selected_protocol = value
	}
	if !accepted do return ws, .Handshake_Failed
	if selected_protocol == PROTOCOL_NAME_V3 {
		ws.protocol_v3 = true
	} else if len(selected_protocol) > 0 && selected_protocol != PROTOCOL_NAME_V2 {
		return ws, .Handshake_Failed
	}
	return ws, .None
}

ws_close :: proc(ws: ^WebSocket) {
	if ws.open {
		_ = ws_send_frame(ws, 0x8, nil)
		ws.open = false
	}
	tls_close(ws.tls)
	ws.tls = nil
	net.close(ws.socket)
	delete(ws.buffer)
	delete(ws.message)
	delete(ws.pending_messages)
	ws.buffer = nil
	ws.message = nil
	ws.pending_messages = nil
}

ws_send_frame :: proc(ws: ^WebSocket, opcode: u8, payload: []u8) -> Error {
	frame := make([dynamic]u8, 0, len(payload) + 14)
	defer delete(frame)
	append(&frame, 0x80 | opcode)
	length := len(payload)
	switch {
	case length <= 125:
		append(&frame, 0x80 | u8(length))
	case length <= 0xffff:
		append(&frame, 0x80 | 126, u8(length >> 8), u8(length))
	case:
		append(&frame, 0x80 | 127)
		for shift := 56; shift >= 0; shift -= 8 do append(&frame, u8(u64(length) >> u64(shift)))
	}
	mask: [4]u8
	crypto.rand_bytes(mask[:])
	append(&frame, ..mask[:])
	for byte, index in payload do append(&frame, byte ~ mask[index & 3])
	return ws_send_all(ws, frame[:])
}

ws_send_binary :: proc(ws: ^WebSocket, payload: []u8) -> Error {
	return ws_send_frame(ws, 0x2, payload)
}

// Returned payload aliases the receive buffer and is valid until the next ws_fill.
ws_read_frame :: proc(ws: ^WebSocket) -> (opcode: u8, fin: bool, payload: []u8, err: Error) {
	if err = ws_fill(ws, 2); err != .None do return
	second := ws.buffer[ws.cursor + 1]
	masked := second & 0x80 != 0
	length := u64(second & 0x7f)
	offset := 2
	if length == 126 {
		if err = ws_fill(ws, 4); err != .None do return
		length = u64(ws.buffer[ws.cursor + 2]) << 8 | u64(ws.buffer[ws.cursor + 3])
		offset = 4
	} else if length == 127 {
		if err = ws_fill(ws, 10); err != .None do return
		length = 0
		for index in 0 ..< 8 do length = length << 8 | u64(ws.buffer[ws.cursor + 2 + index])
		offset = 10
	}
	if length > MAX_MESSAGE_BYTES {
		err = .Message_Too_Large
		return
	}
	mask_offset := offset
	if masked do offset += 4
	if err = ws_fill(ws, offset + int(length)); err != .None do return

	first := ws.buffer[ws.cursor]
	opcode = first & 0x0f
	fin = first & 0x80 != 0
	payload = ws.buffer[ws.cursor + offset:ws.cursor + offset + int(length)]
	if masked {
		for index in 0 ..< len(payload) do payload[index] ~= ws.buffer[ws.cursor + mask_offset + (index & 3)]
	}
	ws.cursor += offset + int(length)
	return
}

// Blocks until a complete data message arrives; control frames are handled here.
ws_recv_message :: proc(ws: ^WebSocket) -> (message: []u8, err: Error) {
	for {
		opcode, fin, payload, frame_err := ws_read_frame(ws)
		if frame_err != .None do return nil, frame_err
		switch opcode {
		case 0x8:
			_ = ws_send_frame(ws, 0x8, nil)
			ws.open = false
			return nil, .Closed
		case 0x9:
			if send_err := ws_send_frame(ws, 0xa, payload); send_err != .None do return nil, send_err
		case 0xa:
		case 0x0, 0x1, 0x2:
			if opcode != 0 {
				clear(&ws.message)
				ws.in_message = true
			} else if !ws.in_message {
				return nil, .Protocol_Error
			}
			if len(ws.message) + len(payload) > MAX_MESSAGE_BYTES do return nil, .Message_Too_Large
			append(&ws.message, ..payload)
			if fin {
				ws.in_message = false
				result, clone_err := make([]u8, len(ws.message))
				if clone_err != nil do return nil, .Allocation_Failed
				copy(result, ws.message[:])
				clear(&ws.message)
				return result, .None
			}
		case:
			return nil, .Protocol_Error
		}
	}
}
