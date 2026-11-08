package host

Environment :: struct {}

// Returns an owned UTF-8 value. `found` is false only when an optional declaration is absent;
// `status` reports host declaration/access errors, and `ok` reports source-read or UTF-8 errors.
environment_get :: proc(_environment: Environment, key: string) -> (value: string, found: bool, status: Status, ok: bool) {
	source: Bytes_Source
	status = env_get(raw_data(transmute([]u8)key), u32(len(key)), &source)
	if status != Status(0) do return "", false, status, true
	if source == INVALID_BYTES_SOURCE do return "", false, status, true
	bytes, bytes_ok := read_bytes_source(source)
	if !bytes_ok do return "", false, status, false
	if !validate_codec_utf8(bytes) {
		delete(bytes)
		return "", false, status, false
	}
	return transmute(string)bytes, true, status, true
}

environment_value_destroy :: proc(value: ^string) {
	delete(value^)
	value^ = ""
}
