package host

Bound_Kind :: enum u8 {
	Included,
	Excluded,
	Unbounded,
}

Bound :: struct($T: typeid) {
	kind: Bound_Kind,
	value: T,
}

bound_included :: proc(value: $T) -> Bound(T) {
	return Bound(T){kind = .Included, value = value}
}

bound_excluded :: proc(value: $T) -> Bound(T) {
	return Bound(T){kind = .Excluded, value = value}
}

bound_unbounded :: proc($T: typeid) -> Bound(T) {
	return Bound(T){kind = .Unbounded}
}

begin_index_point_scan :: proc "contextless" (index_name: string, point: []u8) -> (Row_Iterator, Status) {
	index_id, status := lookup_index_id(index_name)
	if status != Status(0) do return INVALID_ROW_ITERATOR, status
	iterator: Row_Iterator
	status = datastore_index_scan_point_bsatn(index_id, raw_data(point), uint(len(point)), &iterator)
	return iterator, status
}

// Matches the first prefix_elems columns exactly, then bounds the next column.
begin_index_range_scan :: proc "contextless" (
	index_name: string,
	prefix: []u8,
	prefix_elems: u16,
	range_start, range_end: []u8,
) -> (Row_Iterator, Status) {
	index_id, status := lookup_index_id(index_name)
	if status != Status(0) do return INVALID_ROW_ITERATOR, status
	iterator: Row_Iterator
	status = datastore_index_scan_range_bsatn(
		index_id,
		raw_data(prefix),
		uint(len(prefix)),
		Column_Id(prefix_elems),
		raw_data(range_start),
		uint(len(range_start)),
		raw_data(range_end),
		uint(len(range_end)),
		&iterator,
	)
	return iterator, status
}

encode_value :: proc(writer: ^Byte_Writer, value: $T) -> Codec_Error {
	local := value
	return encode_any(writer, any{data = &local, id = typeid_of(T)})
}

encode_bound :: proc(writer: ^Byte_Writer, bound: Bound($T)) -> Codec_Error {
	err := write_codec_bytes(writer, []u8{u8(bound.kind)})
	if err != .None || bound.kind == .Unbounded do return err
	return encode_value(writer, bound.value)
}

// key may be a struct holding every indexed column in order; key_buffer holds its encoding.
typed_scan_index_point :: proc(
	$Row: typeid,
	index_name: string,
	key: $K,
	key_buffer: []u8,
	buffer: []u8,
) -> (Typed_Scan(Row), Status, Codec_Error) {
	writer := Byte_Writer{buffer = key_buffer}
	if err := encode_value(&writer, key); err != .None do return Typed_Scan(Row){}, Status(0), err
	iterator, status := begin_index_point_scan(index_name, key_buffer[:writer.offset])
	if status != Status(0) do return Typed_Scan(Row){}, status, .None
	return Typed_Scan(Row){iterator = iterator, buffer = buffer}, Status(0), .None
}

// Bounds the first indexed column; use typed_scan_index_range_prefixed to match leading columns first.
typed_scan_index_range :: proc(
	$Row: typeid,
	index_name: string,
	range_start: Bound($T),
	range_end: Bound(T),
	key_buffer: []u8,
	buffer: []u8,
) -> (Typed_Scan(Row), Status, Codec_Error) {
	writer := Byte_Writer{buffer = key_buffer}
	return open_range_scan(Row, index_name, &writer, 0, range_start, range_end, buffer)
}

// prefix is a struct of the first prefix_elems indexed columns; the bounds apply to the next column.
typed_scan_index_range_prefixed :: proc(
	$Row: typeid,
	index_name: string,
	prefix: $P,
	prefix_elems: u16,
	range_start: Bound($T),
	range_end: Bound(T),
	key_buffer: []u8,
	buffer: []u8,
) -> (Typed_Scan(Row), Status, Codec_Error) {
	writer := Byte_Writer{buffer = key_buffer}
	if err := encode_value(&writer, prefix); err != .None do return Typed_Scan(Row){}, Status(0), err
	return open_range_scan(Row, index_name, &writer, prefix_elems, range_start, range_end, buffer)
}

@(private)
open_range_scan :: proc(
	$Row: typeid,
	index_name: string,
	writer: ^Byte_Writer,
	prefix_elems: u16,
	range_start: Bound($T),
	range_end: Bound(T),
	buffer: []u8,
) -> (Typed_Scan(Row), Status, Codec_Error) {
	prefix_end := writer.offset
	if err := encode_bound(writer, range_start); err != .None do return Typed_Scan(Row){}, Status(0), err
	start_end := writer.offset
	if err := encode_bound(writer, range_end); err != .None do return Typed_Scan(Row){}, Status(0), err
	iterator, status := begin_index_range_scan(
		index_name,
		writer.buffer[:prefix_end],
		prefix_elems,
		writer.buffer[prefix_end:start_end],
		writer.buffer[start_end:writer.offset],
	)
	if status != Status(0) do return Typed_Scan(Row){}, status, .None
	return Typed_Scan(Row){iterator = iterator, buffer = buffer}, Status(0), .None
}

delete_by_index_range_bsatn :: proc "contextless" (
	index_name: string,
	prefix: []u8,
	prefix_elems: u16,
	range_start, range_end: []u8,
) -> (u32, Status) {
	index_id, status := lookup_index_id(index_name)
	if status != Status(0) do return 0, status
	deleted: u32
	status = datastore_delete_by_index_scan_range_bsatn(
		index_id,
		raw_data(prefix),
		uint(len(prefix)),
		Column_Id(prefix_elems),
		raw_data(range_start),
		uint(len(range_start)),
		raw_data(range_end),
		uint(len(range_end)),
		&deleted,
	)
	return deleted, status
}

// Returns the number of rows deleted.
typed_delete_index_point :: proc(index_name: string, key: $K, key_buffer: []u8) -> (u32, Status, Codec_Error) {
	writer := Byte_Writer{buffer = key_buffer}
	if err := encode_value(&writer, key); err != .None do return 0, Status(0), err
	deleted, status := delete_by_index_point_bsatn(index_name, key_buffer[:writer.offset])
	return deleted, status, .None
}

typed_delete_index_range :: proc(
	index_name: string,
	range_start: Bound($T),
	range_end: Bound(T),
	key_buffer: []u8,
) -> (u32, Status, Codec_Error) {
	writer := Byte_Writer{buffer = key_buffer}
	return delete_range(index_name, &writer, 0, range_start, range_end)
}

typed_delete_index_range_prefixed :: proc(
	index_name: string,
	prefix: $P,
	prefix_elems: u16,
	range_start: Bound($T),
	range_end: Bound(T),
	key_buffer: []u8,
) -> (u32, Status, Codec_Error) {
	writer := Byte_Writer{buffer = key_buffer}
	if err := encode_value(&writer, prefix); err != .None do return 0, Status(0), err
	return delete_range(index_name, &writer, prefix_elems, range_start, range_end)
}

@(private)
delete_range :: proc(
	index_name: string,
	writer: ^Byte_Writer,
	prefix_elems: u16,
	range_start: Bound($T),
	range_end: Bound(T),
) -> (u32, Status, Codec_Error) {
	prefix_end := writer.offset
	if err := encode_bound(writer, range_start); err != .None do return 0, Status(0), err
	start_end := writer.offset
	if err := encode_bound(writer, range_end); err != .None do return 0, Status(0), err
	deleted, status := delete_by_index_range_bsatn(
		index_name,
		writer.buffer[:prefix_end],
		prefix_elems,
		writer.buffer[prefix_end:start_end],
		writer.buffer[start_end:writer.offset],
	)
	return deleted, status, .None
}
