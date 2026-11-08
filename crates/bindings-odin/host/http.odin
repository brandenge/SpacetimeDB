package host

Http_Method :: enum u8 {
	Get,
	Head,
	Post,
	Put,
	Delete,
	Connect,
	Options,
	Trace,
	Patch,
	Extension, // any other method; the name goes in Http_Request.method_extension
}

// Default sends HTTP/1.1.
Http_Version :: enum u8 {
	Default,
	Http09,
	Http10,
	Http11,
	Http2,
	Http3,
}

Http_Header :: struct {
	name: string,
	value: []u8,
}

Http_Request :: struct {
	method: Http_Method,
	method_extension: string, // used only when method is .Extension
	uri: string,
	headers: []Http_Header,
	timeout: Time_Duration, // zero uses the host default
	version: Http_Version,
}

// Header names, header values and body are allocated with context.allocator.
Http_Response :: struct {
	code: u16,
	version: Http_Version,
	headers: []Http_Header,
	body: []u8,
}

Http_Error :: enum u8 {
	None,
	Rejected, // e.g. called inside a transaction, or the request was malformed
	Request_Failed, // no HTTP response was produced; the status code is not meaningful
	Decode_Failed,
	Allocation_Failed,
}

read_bytes_source :: proc(source: Bytes_Source) -> ([]u8, bool) {
	if source == INVALID_BYTES_SOURCE do return nil, true
	remaining: u32
	if bytes_source_remaining_length(source, &remaining) != 0 do return nil, false
	total := int(remaining)
	buffer := make([]u8, total)
	offset := 0
	for offset < total {
		length := uint(total - offset)
		status := bytes_source_read(source, raw_data(buffer[offset:]), &length)
		if (status != 0 && status != -1) || length == 0 {
			delete(buffer)
			return nil, false
		}
		offset += int(length)
		if status == -1 && offset < total {
			delete(buffer)
			return nil, false
		}
	}
	return buffer, true
}

// Use from a procedure or HTTP handler, but outside a transaction started with procedure_start_tx.
http_request :: proc(request: Http_Request, body: []u8 = nil) -> (response: Http_Response, status: Status, err: Http_Error) {
	if len(request.uri) == 0 do return response, Status(0), .Rejected
	if request.method == .Extension && len(request.method_extension) == 0 do return response, Status(0), .Rejected
	encoded := make([dynamic]u8, 0, 128)
	defer delete(encoded)
	append(&encoded, u8(request.method))
	if request.method == .Extension {
		append_u32(&encoded, u32(len(request.method_extension)))
		append(&encoded, ..transmute([]u8)request.method_extension)
	}
	append_u32(&encoded, u32(len(request.headers)))
	for header in request.headers {
		append_u32(&encoded, u32(len(header.name)))
		append(&encoded, ..transmute([]u8)header.name)
		append_u32(&encoded, u32(len(header.value)))
		append(&encoded, ..header.value)
	}
	if request.timeout != 0 {
		append(&encoded, 0)
		micros := u64(i64(request.timeout))
		for shift in 0 ..< 8 do append(&encoded, u8(micros >> u64(shift * 8)))
	} else {
		append(&encoded, 1)
	}
	append_u32(&encoded, u32(len(request.uri)))
	append(&encoded, ..transmute([]u8)request.uri)
	wire_version := u8(Http_Version.Http11) - 1
	if request.version != .Default do wire_version = u8(request.version) - 1
	append(&encoded, wire_version)

	// The host requires a non-null body pointer even for empty bodies.
	placeholder: [1]u8
	body_ptr := raw_data(body)
	if body_ptr == nil do body_ptr = raw_data(placeholder[:])

	sources: [2]Bytes_Source = {INVALID_BYTES_SOURCE, INVALID_BYTES_SOURCE}
	status = procedure_http_request(raw_data(encoded), uint(len(encoded)), body_ptr, uint(len(body)), raw_data(sources[:]))
	if status != Status(0) {
		// Only some failures write a source; the failure text itself is not decoded.
		return response, status, .Request_Failed if sources[0] != INVALID_BYTES_SOURCE else .Rejected
	}

	head, head_ok := read_bytes_source(sources[0])
	if !head_ok do return response, status, .Decode_Failed
	defer delete(head)
	body_bytes, body_ok := read_bytes_source(sources[1])
	if !body_ok do return response, status, .Decode_Failed

	reader := Byte_Reader{buffer = head}
	count, count_err := read_codec_u32(&reader)
	if count_err != .None || int(count) > len(head) {
		delete(body_bytes)
		return response, status, .Decode_Failed
	}
	headers := make([]Http_Header, int(count))
	for index in 0 ..< int(count) {
		name, value, ok := read_http_header(&reader)
		if !ok {
			delete(body_bytes)
			delete_http_headers(headers[:index])
			return response, status, .Decode_Failed
		}
		headers[index] = Http_Header{name = name, value = value}
	}
	version_bytes, version_err := read_codec_bytes(&reader, 3) // version tag, then the u16 status code
	if version_err != .None || reader.offset != len(head) || version_bytes[0] > 4 {
		delete(body_bytes)
		delete_http_headers(headers)
		return response, status, .Decode_Failed
	}
	response = Http_Response{
		code = u16(version_bytes[1]) | u16(version_bytes[2]) << 8,
		version = Http_Version(version_bytes[0] + 1),
		headers = headers,
		body = body_bytes,
	}
	return response, status, .None
}

delete_http_response :: proc(response: ^Http_Response) {
	delete_http_headers(response.headers)
	delete(response.body)
	response^ = {}
}

@(private)
delete_http_headers :: proc(headers: []Http_Header) {
	for header in headers {
		delete(header.name)
		delete(header.value)
	}
	delete(headers)
}

@(private)
append_u32 :: proc(out: ^[dynamic]u8, value: u32) {
	append(out, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
}

@(private)
read_http_header :: proc(reader: ^Byte_Reader) -> (name: string, value: []u8, ok: bool) {
	name_length, name_err := read_codec_u32(reader)
	if name_err != .None do return
	name_bytes, name_bytes_err := read_codec_bytes(reader, int(name_length))
	if name_bytes_err != .None do return
	value_length, value_err := read_codec_u32(reader)
	if value_err != .None do return
	value_bytes, value_bytes_err := read_codec_bytes(reader, int(value_length))
	if value_bytes_err != .None do return
	name = transmute(string)clone_bytes(name_bytes)
	value = clone_bytes(value_bytes)
	return name, value, true
}

@(private)
clone_bytes :: proc(bytes: []u8) -> []u8 {
	copy_of := make([]u8, len(bytes))
	copy(copy_of, bytes)
	return copy_of
}
