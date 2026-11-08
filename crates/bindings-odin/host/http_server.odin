package host

import "base:runtime"
import json "core:encoding/json"
import "core:strings"

// Routes map an HTTP method and path to a handler; handler ids are indices into the handler name list.
Http_Route :: struct {
	handler: string,
	path: string, // must start with '/'
	any_method: bool, // when true, method and method_extension are ignored
	method: Http_Method,
	method_extension: string, // used only when method is .Extension
}

Http_Handler_Auth_Context :: struct {
	has_jwt: bool,
	jwt_payload: string,
}

Http_Jwt_Claims :: struct {
	has_subject: bool,
	subject: string,
	has_issuer: bool,
	issuer: string,
	audience: [dynamic]string,
}

// The payload is the validated JSON claims object, valid for the current export call.
Http_Handler_Context :: struct {
	env: Environment,
	sender: Identity,
	timestamp: Timestamp,
	sender_auth: Http_Handler_Auth_Context,
	rng_state: Uuid_Rng_State,
	uuid_counter: u32,
}

Uuid_Generation_Error :: enum u8 {
	None,
	Random_Failed,
	Timestamp_Before_Unix_Epoch,
}

http_handler_context :: proc (
	sender_0, sender_1, sender_2, sender_3: u64,
	sender_jwt_payload: []u8,
	timestamp: u64,
) -> Http_Handler_Context {
	reducer := reducer_context(sender_0, sender_1, sender_2, sender_3, 0, 0, timestamp)
	return Http_Handler_Context{
		env = Environment{},
		sender = reducer.sender,
		timestamp = Timestamp(i64(timestamp)),
		sender_auth = Http_Handler_Auth_Context{
			has_jwt = len(sender_jwt_payload) > 0,
			jwt_payload = transmute(string)sender_jwt_payload,
		},
		rng_state = uuid_rng_from_seed(timestamp),
	}
}

http_jwt_claims :: proc(auth: Http_Handler_Auth_Context) -> (claims: Http_Jwt_Claims, ok: bool) {
	if !auth.has_jwt do return claims, false
	value, parse_error := json.parse_string(auth.jwt_payload)
	if parse_error != .None do return claims, false
	defer json.destroy_value(value)
	object, is_object := value.(json.Object)
	if !is_object do return claims, false

	if subject, found := object["sub"]; found {
		if text, is_string := subject.(json.String); is_string {
			claims.subject = strings.clone(text)
			claims.has_subject = true
		}
	}
	if issuer, found := object["iss"]; found {
		if text, is_string := issuer.(json.String); is_string {
			claims.issuer = strings.clone(text)
			claims.has_issuer = true
		}
	}
	if audience, found := object["aud"]; found {
		#partial switch audience_value in audience {
		case json.String:
			append(&claims.audience, strings.clone(audience_value))
		case json.Array:
			for item in audience_value {
				text, is_string := item.(json.String)
				if !is_string {
					http_jwt_claims_destroy(&claims)
					return Http_Jwt_Claims{}, false
				}
				append(&claims.audience, strings.clone(text))
			}
		case:
			http_jwt_claims_destroy(&claims)
			return Http_Jwt_Claims{}, false
		}
	}
	return claims, true
}

http_jwt_claims_destroy :: proc(claims: ^Http_Jwt_Claims) {
	delete(claims.subject)
	delete(claims.issuer)
	for audience in claims.audience do delete(audience)
	delete(claims.audience)
	claims^ = {}
}

@(private)
uuid_from_bytes :: proc(bytes: [16]u8) -> u128 {
	value: u128
	for byte in bytes do value = value << 8 | u128(byte)
	return value
}

new_uuid_v4 :: proc(ctx: ^Http_Handler_Context) -> (uuid: u128, err: Uuid_Generation_Error) {
	bytes: [16]u8
	uuid_rng_fill(&ctx.rng_state, bytes[:])
	bytes[6] = bytes[6] & 0x0f | 0x40
	bytes[8] = bytes[8] & 0x3f | 0x80
	return uuid_from_bytes(bytes), .None
}

new_uuid_v7 :: proc(ctx: ^Http_Handler_Context) -> (uuid: u128, err: Uuid_Generation_Error) {
	if i64(ctx.timestamp) < 0 do return 0, .Timestamp_Before_Unix_Epoch
	random_bytes: [4]u8
	uuid_rng_fill(&ctx.rng_state, random_bytes[:])

	timestamp_ms := u64(i64(ctx.timestamp)) / 1000 & 0xffff_ffff_ffff
	counter := ctx.uuid_counter & 0x7fff_ffff
	ctx.uuid_counter = (counter + 1) & 0x7fff_ffff
	bytes := [16]u8{
		u8(timestamp_ms >> 40),
		u8(timestamp_ms >> 32),
		u8(timestamp_ms >> 24),
		u8(timestamp_ms >> 16),
		u8(timestamp_ms >> 8),
		u8(timestamp_ms),
		0x70,
		u8(counter >> 23),
		0x80,
		u8(counter >> 15),
		u8(counter >> 7),
		u8((counter & 0x7f) << 1),
		random_bytes[0] & 0x7f,
		random_bytes[1],
		random_bytes[2],
		random_bytes[3],
	}
	return uuid_from_bytes(bytes), .None
}

Http_Transaction_Context :: struct {
	env: Environment,
	sender: Identity,
	timestamp: Timestamp,
	sender_auth: Http_Handler_Auth_Context,
}

Http_Transaction_Body :: proc(ctx: Http_Transaction_Context, user: rawptr) -> Status

http_transaction_context :: proc(handler: Http_Handler_Context, timestamp: Timestamp) -> Http_Transaction_Context {
	return Http_Transaction_Context{
		env = handler.env,
		sender = handler.sender,
		timestamp = timestamp,
		sender_auth = handler.sender_auth,
	}
}

@(private)
run_http_handler_tx :: proc(
	handler: Http_Handler_Context,
	body: Http_Transaction_Body,
	user: rawptr,
) -> (status: Status, should_retry: bool) {
	if body == nil do return Status(1), false
	timestamp, start_status := procedure_start_tx()
	if start_status != Status(0) do return start_status, false
	active := true
	defer {
		if active do _ = procedure_abort_tx()
	}
	callback_status := body(http_transaction_context(handler, timestamp), user)
	if callback_status != Status(0) {
		abort_status := procedure_abort_tx()
		active = false
		return (abort_status if abort_status != Status(0) else callback_status), false
	}
	status = procedure_commit_tx()
	active = false
	return status, status != Status(0)
}

// Commits when body returns Status(0); nonzero results abort. A failed commit reruns the
// callback once in a fresh transaction, matching the Rust HandlerContext retry policy.
// A deferred abort also covers a trap raised by body.
http_handler_with_tx :: proc(
	handler: Http_Handler_Context,
	body: Http_Transaction_Body,
	user: rawptr = nil,
) -> Status {
	status, should_retry := run_http_handler_tx(handler, body, user)
	if !should_retry do return status
	retry_status, _ := run_http_handler_tx(handler, body, user)
	return retry_status
}

// Strings, headers and body are allocated with context.allocator.
Http_Incoming :: struct {
	method: Http_Method,
	method_extension: string,
	uri: string,
	headers: []Http_Header,
	version: Http_Version,
	body: []u8,
}

HTTP_HANDLER_OK :: i16(0) // __call_http_handler__ always returns 0

write_http_method :: proc "contextless" (sink: Bytes_Sink, method: Http_Method, extension: string) -> (Status, bool) {
	status, complete := write_all(sink, []u8{u8(method)})
	if status != Status(0) || !complete do return status, false
	if method == .Extension do return write_string(sink, extension)
	return Status(0), true
}

write_http_handler_section :: proc "contextless" (sink: Bytes_Sink, handlers: []string) -> (Status, bool) {
	status, complete := write_all(sink, []u8{11})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(len(handlers)))
	if status != Status(0) || !complete do return status, false
	for handler in handlers {
		if len(handler) == 0 do return Status(0), false
		status, complete = write_string(sink, handler)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

write_http_route_section :: proc "contextless" (sink: Bytes_Sink, handlers: []string, routes: []Http_Route) -> (Status, bool) {
	status, complete := write_all(sink, []u8{12})
	if status != Status(0) || !complete do return status, false
	status, complete = write_u32(sink, u32(len(routes)))
	if status != Status(0) || !complete do return status, false
	for route in routes {
		known := false
		for handler in handlers do if handler == route.handler do known = true
		if !known || len(route.path) == 0 || route.path[0] != '/' do return Status(0), false
		status, complete = write_string(sink, route.handler)
		if status != Status(0) || !complete do return status, false
		if route.any_method {
			status, complete = write_all(sink, []u8{0})
		} else {
			if route.method == .Extension && len(route.method_extension) == 0 do return Status(0), false
			status, complete = write_all(sink, []u8{1})
			if status != Status(0) || !complete do return status, false
			status, complete = write_http_method(sink, route.method, route.method_extension)
		}
		if status != Status(0) || !complete do return status, false
		status, complete = write_string(sink, route.path)
		if status != Status(0) || !complete do return status, false
	}
	return Status(0), true
}

// Reads the request metadata and body the host passes to __call_http_handler__.
read_http_request :: proc(request: Bytes_Source, body: Bytes_Source) -> (incoming: Http_Incoming, ok: bool) {
	raw, raw_ok := read_bytes_source(request)
	if !raw_ok || len(raw) == 0 do return incoming, false
	defer delete(raw)
	reader := Byte_Reader{buffer = raw}

	method_bytes, method_err := read_codec_bytes(&reader, 1)
	if method_err != .None || method_bytes[0] > u8(Http_Method.Extension) do return incoming, false
	incoming.method = Http_Method(method_bytes[0])
	if incoming.method == .Extension {
		text, text_ok := read_http_string(&reader)
		if !text_ok do return incoming, false
		incoming.method_extension = text
	}

	count, count_err := read_codec_u32(&reader)
	if count_err != .None || int(count) > len(raw) do return incoming, false
	headers := make([]Http_Header, int(count))
	for index in 0 ..< int(count) {
		name, value, header_ok := read_http_header(&reader)
		if !header_ok {
			delete_http_headers(headers[:index])
			delete(incoming.method_extension)
			return incoming, false
		}
		headers[index] = Http_Header{name = name, value = value}
	}
	incoming.headers = headers

	// timeout: Option<TimeDuration>
	timeout_tag, timeout_err := read_codec_bytes(&reader, 1)
	if timeout_err != .None || timeout_tag[0] > 1 do return incoming, false
	if timeout_tag[0] == 0 {
		if _, skip_err := read_codec_bytes(&reader, 8); skip_err != .None do return incoming, false
	}

	uri, uri_ok := read_http_string(&reader)
	if !uri_ok do return incoming, false
	incoming.uri = uri
	version_bytes, version_err := read_codec_bytes(&reader, 1)
	if version_err != .None || version_bytes[0] > 4 || reader.offset != len(raw) do return incoming, false
	incoming.version = Http_Version(version_bytes[0] + 1)

	body_bytes, body_ok := read_bytes_source(body)
	if !body_ok do return incoming, false
	incoming.body = body_bytes
	return incoming, true
}

delete_http_incoming :: proc(incoming: ^Http_Incoming) {
	delete_http_headers(incoming.headers)
	delete(incoming.method_extension)
	delete(incoming.uri)
	delete(incoming.body)
	incoming^ = {}
}

// Returns the first header with the given name, compared case-insensitively.
http_header_value :: proc(headers: []Http_Header, name: string) -> ([]u8, bool) {
	for header in headers {
		if len(header.name) != len(name) do continue
		matches := true
		for index in 0 ..< len(name) {
			a, b := header.name[index], name[index]
			if a >= 'A' && a <= 'Z' do a += 'a' - 'A'
			if b >= 'A' && b <= 'Z' do b += 'a' - 'A'
			if a != b {
				matches = false
				break
			}
		}
		if matches do return header.value, true
	}
	return nil, false
}

// Writes the response metadata and body; the handler then returns HTTP_HANDLER_OK.
write_http_response :: proc(
	response_sink: Bytes_Sink,
	body_sink: Bytes_Sink,
	code: u16,
	headers: []Http_Header,
	body: []u8,
	version := Http_Version.Default,
) -> bool {
	encoded := make([dynamic]u8, 0, 128)
	defer delete(encoded)
	append_u32(&encoded, u32(len(headers)))
	for header in headers {
		append_u32(&encoded, u32(len(header.name)))
		append(&encoded, ..transmute([]u8)header.name)
		append_u32(&encoded, u32(len(header.value)))
		append(&encoded, ..header.value)
	}
	wire_version := u8(Http_Version.Http11) - 1
	if version != .Default do wire_version = u8(version) - 1
	append(&encoded, wire_version, u8(code), u8(code >> 8))
	if _, complete := write_all(response_sink, encoded[:]); !complete do return false
	if len(body) > 0 {
		if _, complete := write_all(body_sink, body); !complete do return false
	}
	return true
}

@(private)
read_http_string :: proc(reader: ^Byte_Reader) -> (string, bool) {
	length, length_err := read_codec_u32(reader)
	if length_err != .None do return "", false
	bytes, bytes_err := read_codec_bytes(reader, int(length))
	if bytes_err != .None || !validate_codec_utf8(bytes) do return "", false
	return transmute(string)clone_bytes(bytes), true
}
