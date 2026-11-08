package host

import "base:runtime"
import "core:reflect"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

Codec_Error :: enum u8 {
	None,
	Buffer_Too_Small,
	Malformed_Data,
	Unsupported_Type,
	Unsupported_Endianness,
	Invalid_Boolean,
	Invalid_Utf8,
	Allocation_Failed,
	Host_Read_Failed,
	Trailing_Bytes,
	Value_Too_Large,
	Missing_Unique_Index,
}

Byte_Writer :: struct {
	buffer: []u8,
	offset: int,
}

Byte_Reader :: struct {
	buffer: []u8,
	offset: int,
}

MAX_CODEC_STRING_BYTES :: 16 * 1024 * 1024
MAX_CODEC_ARRAY_ITEMS :: 1 * 1024 * 1024

base_type_info :: proc(info: ^reflect.Type_Info) -> ^reflect.Type_Info {
	info := info
	for info != nil {
		named, ok := info.variant.(reflect.Type_Info_Named)
		if !ok do break
		info = named.base
	}
	return info
}

type_is_256 :: proc(id: typeid) -> (Reducer_Argument_Type, bool) {
	info := type_info_of(id)
	for info != nil {
		named, ok := info.variant.(reflect.Type_Info_Named)
		if !ok do break
		if named.name == "I256" do return .I256, true
		if named.name == "U256" || (named.name == "Identity" && info.size == 32) do return .U256, true
		info = named.base
	}
	return .U8, false
}

write_codec_bytes :: proc(writer: ^Byte_Writer, bytes: []u8) -> Codec_Error {
	if writer.offset < 0 || writer.offset > len(writer.buffer) do return .Malformed_Data
	if len(bytes) > len(writer.buffer) - writer.offset do return .Buffer_Too_Small
	end := writer.offset + len(bytes)
	copy(writer.buffer[writer.offset:end], bytes)
	writer.offset = end
	return .None
}

write_codec_u32 :: proc(writer: ^Byte_Writer, value: u32) -> Codec_Error {
	bytes := [4]u8{u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)}
	return write_codec_bytes(writer, bytes[:])
}

encode_array_items :: proc(
	writer: ^Byte_Writer,
	data: rawptr,
	count: int,
	elem_size: int,
	elem_info: ^reflect.Type_Info,
) -> Codec_Error {
	if count < 0 || count > MAX_CODEC_ARRAY_ITEMS || elem_size <= 0 do return .Value_Too_Large
	if count > 0 && data == nil do return .Malformed_Data
	err := write_codec_u32(writer, u32(count))
	if err != .None do return err
	for index in 0..<count {
		address := rawptr(uintptr(data) + uintptr(index * elem_size))
		err = encode_any(writer, any{data = address, id = elem_info.id})
		if err != .None do return err
	}
	return .None
}

encode_option :: proc(writer: ^Byte_Writer, value: any, info: reflect.Type_Info_Union) -> Codec_Error {
	if info.no_nil || len(info.variants) != 1 do return .Unsupported_Type
	variant_id := reflect.union_variant_typeid(value)
	if variant_id == nil do return write_codec_bytes(writer, []u8{1})
	err := write_codec_bytes(writer, []u8{0})
	if err != .None do return err
	return encode_any(writer, reflect.get_union_variant(value))
}

// Sum types are `union #no_nil` values: a one-byte variant index followed by that variant's payload.
encode_sum :: proc(writer: ^Byte_Writer, value: any, info: reflect.Type_Info_Union) -> Codec_Error {
	if !info.no_nil || len(info.variants) == 0 || len(info.variants) > 256 do return .Unsupported_Type
	tag := reflect.get_union_variant_raw_tag(value)
	if tag < 0 || int(tag) >= len(info.variants) do return .Malformed_Data
	err := write_codec_bytes(writer, []u8{u8(tag)})
	if err != .None do return err
	return encode_any(writer, any{data = value.data, id = info.variants[tag].id})
}

enum_value :: proc(data: rawptr, base: ^reflect.Type_Info) -> (i64, bool) {
	info := base_type_info(base)
	if info == nil do return 0, false
	integer, ok := info.variant.(reflect.Type_Info_Integer)
	if !ok do return 0, false
	switch info.size {
	case 1:
		if integer.signed { pointer := cast(^i8)data; return i64(pointer^), true }
		pointer := cast(^u8)data
		return i64(pointer^), true
	case 2:
		if integer.signed { pointer := cast(^i16)data; return i64(pointer^), true }
		pointer := cast(^u16)data
		return i64(pointer^), true
	case 4:
		if integer.signed { pointer := cast(^i32)data; return i64(pointer^), true }
		pointer := cast(^u32)data
		return i64(pointer^), true
	case 8:
		if integer.signed { pointer := cast(^i64)data; return pointer^, true }
		pointer := cast(^u64)data
		value := pointer^
		if value > u64(0x7fff_ffff_ffff_ffff) do return 0, false
		return i64(value), true
	}
	return 0, false
}

store_enum_value :: proc(data: rawptr, base: ^reflect.Type_Info, value: i64) -> bool {
	info := base_type_info(base)
	if info == nil || (info.size != 1 && info.size != 2 && info.size != 4 && info.size != 8) do return false
	integer, ok := info.variant.(reflect.Type_Info_Integer)
	if !ok || (integer.endianness == .Big || (integer.endianness == .Platform && ODIN_ENDIAN != .Little)) do return false
	bits := u64(value)
	destination := cast([^]u8)data
	for index in 0..<info.size {
		destination[index] = u8(bits >> u32(index * 8))
	}
	return true
}

enum_variant_index :: proc(info: reflect.Type_Info_Enum, value: i64) -> (u8, bool) {
	if len(info.names) == 0 || len(info.names) > 256 || len(info.names) != len(info.values) do return 0, false
	for index, variant_value in info.values {
		if i64(variant_value) == value do return u8(index), true
	}
	return 0, false
}

encode_enum :: proc(writer: ^Byte_Writer, value: any, info: reflect.Type_Info_Enum) -> Codec_Error {
	value_number, ok := enum_value(value.data, info.base)
	if !ok do return .Unsupported_Type
	index, found := enum_variant_index(info, value_number)
	if !found do return .Malformed_Data
	return write_codec_bytes(writer, []u8{index})
}

decode_enum :: proc(reader: ^Byte_Reader, value: any, info: reflect.Type_Info_Enum) -> Codec_Error {
	bytes, err := read_codec_bytes(reader, 1)
	if err != .None do return err
	index := int(bytes[0])
	if index >= len(info.values) do return .Malformed_Data
	if !store_enum_value(value.data, info.base, i64(info.values[index])) do return .Unsupported_Type
	return .None
}

decode_array_items :: proc(
	reader: ^Byte_Reader,
	data: rawptr,
	count: int,
	elem_size: int,
	elem_info: ^reflect.Type_Info,
	borrow_strings: bool,
) -> Codec_Error {
	for index in 0..<count {
		address := rawptr(uintptr(data) + uintptr(index * elem_size))
		err := decode_any(reader, any{data = address, id = elem_info.id}, borrow_strings)
		if err != .None do return err
	}
	return .None
}

decode_owned_array :: proc(
	reader: ^Byte_Reader,
	count: int,
	elem_size: int,
	elem_info: ^reflect.Type_Info,
	borrow_strings: bool,
) -> (rawptr, Codec_Error) {
	if count < 0 || count > MAX_CODEC_ARRAY_ITEMS || elem_size <= 0 do return nil, .Value_Too_Large
	if count == 0 do return nil, .None
	data, alloc_err := mem.alloc(count * elem_size, elem_info.align)
	if alloc_err != .None do return nil, .Allocation_Failed
	err := decode_array_items(reader, data, count, elem_size, elem_info, borrow_strings)
	if err != .None {
		for index in 0..<count {
			address := rawptr(uintptr(data) + uintptr(index * elem_size))
			delete_any_strings(any{data = address, id = elem_info.id})
		}
		_ = mem.free(data)
		return nil, err
	}
	return data, .None
}

decode_option :: proc(reader: ^Byte_Reader, value: any, info: reflect.Type_Info_Union, borrow_strings: bool) -> Codec_Error {
	if info.no_nil || len(info.variants) != 1 do return .Unsupported_Type
	bytes, err := read_codec_bytes(reader, 1)
	if err != .None do return err
	if bytes[0] == 1 {
		if !reflect.set_union_value(value, any{}) do return .Malformed_Data
		return .None
	}
	if bytes[0] != 0 do return .Malformed_Data
	variant := any{data = value.data, id = info.variants[0].id}
	err = decode_any(reader, variant, borrow_strings)
	if err != .None do return err
	if !reflect.set_union_value(value, variant) do return .Malformed_Data
	return .None
}

decode_sum :: proc(reader: ^Byte_Reader, value: any, info: reflect.Type_Info_Union, borrow_strings: bool) -> Codec_Error {
	if !info.no_nil || len(info.variants) == 0 || len(info.variants) > 256 do return .Unsupported_Type
	bytes, err := read_codec_bytes(reader, 1)
	if err != .None do return err
	index := int(bytes[0])
	if index >= len(info.variants) do return .Malformed_Data
	err = decode_any(reader, any{data = value.data, id = info.variants[index].id}, borrow_strings)
	if err != .None do return err
	reflect.set_union_variant_raw_tag(value, i64(index))
	return .None
}

read_codec_bytes :: proc(reader: ^Byte_Reader, size: int) -> ([]u8, Codec_Error) {
	if size < 0 || reader.offset < 0 || reader.offset > len(reader.buffer) do return nil, .Malformed_Data
	if size > len(reader.buffer) - reader.offset do return nil, .Malformed_Data
	start := reader.offset
	reader.offset += size
	return reader.buffer[start:reader.offset], .None
}

read_codec_u32 :: proc(reader: ^Byte_Reader) -> (u32, Codec_Error) {
	bytes, err := read_codec_bytes(reader, 4)
	if err != .None do return 0, err
	value := u32(bytes[0]) | u32(bytes[1]) << 8 | u32(bytes[2]) << 16 | u32(bytes[3]) << 24
	return value, .None
}

validate_codec_utf8 :: proc(bytes: []u8) -> bool {
	offset := 0
	for offset < len(bytes) {
		rune, rune_size := utf8.decode_rune_in_bytes(bytes[offset:])
		if rune_size <= 0 do return false
		encoded, encoded_size := utf8.encode_rune(rune)
		if encoded_size != rune_size do return false
		for i in 0..<rune_size {
			if encoded[i] != bytes[offset + i] do return false
		}
		offset += rune_size
	}
	return true
}

encode_any :: proc(writer: ^Byte_Writer, value: any) -> Codec_Error {
	if value == nil do return .Unsupported_Type
	if _, is_256 := type_is_256(value.id); is_256 {
		data := cast([^]u8)value.data
		return write_codec_bytes(writer, data[:32])
	}
	info := base_type_info(type_info_of(value.id))
	if info == nil do return .Unsupported_Type

	if bool_info, ok := info.variant.(reflect.Type_Info_Boolean); ok {
		_ = bool_info
		data := cast([^]u8)value.data
		if data[0] > 1 do return .Invalid_Boolean
		return write_codec_bytes(writer, data[:1])
	}

	if integer_info, ok := info.variant.(reflect.Type_Info_Integer); ok {
		if integer_info.endianness == .Big || (integer_info.endianness == .Platform && ODIN_ENDIAN != .Little) {
			return .Unsupported_Endianness
		}
		if info.size != 1 && info.size != 2 && info.size != 4 && info.size != 8 && info.size != 16 {
			return .Unsupported_Type
		}
		data := cast([^]u8)value.data
		return write_codec_bytes(writer, data[:info.size])
	}

	if float_info, ok := info.variant.(reflect.Type_Info_Float); ok {
		if float_info.endianness == .Big || (float_info.endianness == .Platform && ODIN_ENDIAN != .Little) {
			return .Unsupported_Endianness
		}
		if info.size != 4 && info.size != 8 do return .Unsupported_Type
		data := cast([^]u8)value.data
		return write_codec_bytes(writer, data[:info.size])
	}

	if string_info, ok := info.variant.(reflect.Type_Info_String); ok {
		if string_info.is_cstring || string_info.encoding != .UTF_8 do return .Unsupported_Type
		string_ptr := cast(^string)value.data
		item := string_ptr^
		if len(item) > MAX_CODEC_STRING_BYTES || u64(len(item)) > u64(0xffff_ffff) do return .Value_Too_Large
		bytes := transmute([]u8)item
		if !validate_codec_utf8(bytes) do return .Invalid_Utf8
		err := write_codec_u32(writer, u32(len(bytes)))
		if err != .None do return err
		return write_codec_bytes(writer, bytes)
	}

	if array_info, ok := info.variant.(reflect.Type_Info_Array); ok {
		return encode_array_items(writer, value.data, array_info.count, array_info.elem_size, array_info.elem)
	}
	if array_info, ok := info.variant.(reflect.Type_Info_Enumerated_Array); ok {
		return encode_array_items(writer, value.data, array_info.count, array_info.elem_size, array_info.elem)
	}
	if slice_info, ok := info.variant.(reflect.Type_Info_Slice); ok {
		slice := cast(^runtime.Raw_Slice)value.data
		return encode_array_items(writer, slice.data, slice.len, slice_info.elem_size, slice_info.elem)
	}
	if array_info, ok := info.variant.(reflect.Type_Info_Dynamic_Array); ok {
		array := cast(^runtime.Raw_Dynamic_Array)value.data
		return encode_array_items(writer, array.data, array.len, array_info.elem_size, array_info.elem)
	}
	if union_info, ok := info.variant.(reflect.Type_Info_Union); ok {
		if union_info.no_nil do return encode_sum(writer, value, union_info)
		return encode_option(writer, value, union_info)
	}
	if enum_info, ok := info.variant.(reflect.Type_Info_Enum); ok {
		return encode_enum(writer, value, enum_info)
	}

	if reflect.is_struct(info) {
		struct_info, _ := info.variant.(reflect.Type_Info_Struct)
		for index in 0..<int(struct_info.field_count) {
			field := reflect.struct_field_at(value.id, index)
			field_value := reflect.struct_field_value(value, field)
			err := encode_any(writer, field_value)
			if err != .None do return err
		}
		return .None
	}

	return .Unsupported_Type
}

decode_any :: proc(reader: ^Byte_Reader, value: any, borrow_strings: bool) -> Codec_Error {
	if value == nil do return .Unsupported_Type
	if _, is_256 := type_is_256(value.id); is_256 {
		bytes, err := read_codec_bytes(reader, 32)
		if err != .None do return err
		dst := cast([^]u8)value.data
		copy(dst[:32], bytes)
		return .None
	}
	info := base_type_info(type_info_of(value.id))
	if info == nil do return .Unsupported_Type

	if _, ok := info.variant.(reflect.Type_Info_Boolean); ok {
		bytes, err := read_codec_bytes(reader, 1)
		if err != .None do return err
		if bytes[0] > 1 do return .Invalid_Boolean
		dst := cast([^]u8)value.data
		dst[0] = bytes[0]
		return .None
	}

	if integer_info, ok := info.variant.(reflect.Type_Info_Integer); ok {
		if integer_info.endianness == .Big || (integer_info.endianness == .Platform && ODIN_ENDIAN != .Little) {
			return .Unsupported_Endianness
		}
		if info.size != 1 && info.size != 2 && info.size != 4 && info.size != 8 && info.size != 16 {
			return .Unsupported_Type
		}
		bytes, err := read_codec_bytes(reader, info.size)
		if err != .None do return err
		dst := cast([^]u8)value.data
		copy(dst[:info.size], bytes)
		return .None
	}

	if float_info, ok := info.variant.(reflect.Type_Info_Float); ok {
		if float_info.endianness == .Big || (float_info.endianness == .Platform && ODIN_ENDIAN != .Little) {
			return .Unsupported_Endianness
		}
		if info.size != 4 && info.size != 8 do return .Unsupported_Type
		bytes, err := read_codec_bytes(reader, info.size)
		if err != .None do return err
		dst := cast([^]u8)value.data
		copy(dst[:info.size], bytes)
		return .None
	}

	if string_info, ok := info.variant.(reflect.Type_Info_String); ok {
		if string_info.is_cstring || string_info.encoding != .UTF_8 do return .Unsupported_Type
		length, err := read_codec_u32(reader)
		if err != .None do return err
		if length > MAX_CODEC_STRING_BYTES do return .Value_Too_Large
		bytes, bytes_err := read_codec_bytes(reader, int(length))
		if bytes_err != .None do return bytes_err
		if !validate_codec_utf8(bytes) do return .Invalid_Utf8
		dst := cast(^string)value.data
		if borrow_strings {
			dst^ = string(bytes)
			return .None
		}
		cloned, alloc_err := strings.clone(string(bytes))
		if alloc_err != nil do return .Allocation_Failed
		dst^ = cloned
		return .None
	}

	if array_info, ok := info.variant.(reflect.Type_Info_Array); ok {
		count, err := read_codec_u32(reader)
		if err != .None do return err
		if count != u32(array_info.count) do return .Malformed_Data
		return decode_array_items(reader, value.data, array_info.count, array_info.elem_size, array_info.elem, borrow_strings)
	}
	if array_info, ok := info.variant.(reflect.Type_Info_Enumerated_Array); ok {
		count, err := read_codec_u32(reader)
		if err != .None do return err
		if count != u32(array_info.count) do return .Malformed_Data
		return decode_array_items(reader, value.data, array_info.count, array_info.elem_size, array_info.elem, borrow_strings)
	}
	if slice_info, ok := info.variant.(reflect.Type_Info_Slice); ok {
		count, err := read_codec_u32(reader)
		if err != .None do return err
		data, array_err := decode_owned_array(reader, int(count), slice_info.elem_size, slice_info.elem, borrow_strings)
		if array_err != .None do return array_err
		destination := cast(^runtime.Raw_Slice)value.data
		destination^ = runtime.Raw_Slice{data = data, len = int(count)}
		return .None
	}
	if array_info, ok := info.variant.(reflect.Type_Info_Dynamic_Array); ok {
		count, err := read_codec_u32(reader)
		if err != .None do return err
		data, array_err := decode_owned_array(reader, int(count), array_info.elem_size, array_info.elem, borrow_strings)
		if array_err != .None do return array_err
		destination := cast(^runtime.Raw_Dynamic_Array)value.data
		destination^ = runtime.Raw_Dynamic_Array{
			data = data,
			len = int(count),
			cap = int(count),
			allocator = context.allocator,
		}
		return .None
	}
	if union_info, ok := info.variant.(reflect.Type_Info_Union); ok {
		if union_info.no_nil do return decode_sum(reader, value, union_info, borrow_strings)
		return decode_option(reader, value, union_info, borrow_strings)
	}
	if enum_info, ok := info.variant.(reflect.Type_Info_Enum); ok {
		return decode_enum(reader, value, enum_info)
	}

	if reflect.is_struct(info) {
		struct_info, _ := info.variant.(reflect.Type_Info_Struct)
		for index in 0..<int(struct_info.field_count) {
			field := reflect.struct_field_at(value.id, index)
			field_value := reflect.struct_field_value(value, field)
			err := decode_any(reader, field_value, borrow_strings)
			if err != .None do return err
		}
		return .None
	}

	return .Unsupported_Type
}

encode_row_into :: proc($T: typeid, row: T, buffer: []u8) -> (int, Codec_Error) {
	writer := Byte_Writer{buffer = buffer}
	value: any = row
	err := encode_any(&writer, value)
	return writer.offset, err
}

decode_row_from :: proc($T: typeid, bytes: []u8) -> (T, int, Codec_Error) {
	return decode_row_with_string_ownership(T, bytes, false)
}

decode_row_borrowed :: proc($T: typeid, bytes: []u8) -> (T, int, Codec_Error) {
	return decode_row_with_string_ownership(T, bytes, true)
}

decode_row_with_string_ownership :: proc($T: typeid, bytes: []u8, borrow_strings: bool) -> (T, int, Codec_Error) {
	row: T
	value := any{data = &row, id = typeid_of(T)}
	reader := Byte_Reader{buffer = bytes}
	err := decode_any(&reader, value, borrow_strings)
	if err != .None {
		if !borrow_strings do delete_decoded_row(T, &row)
		return row, reader.offset, err
	}
	return row, reader.offset, .None
}

delete_decoded_row :: proc($T: typeid, row: ^T) {
	value := any{data = row, id = typeid_of(T)}
	delete_any_strings(value)
}

delete_any_strings :: proc(value: any) {
	if value == nil do return
	info := base_type_info(type_info_of(value.id))
	if info == nil do return
	if string_info, ok := info.variant.(reflect.Type_Info_String); ok {
		if !string_info.is_cstring && string_info.encoding == .UTF_8 {
			ptr := cast(^string)value.data
			delete(ptr^)
			ptr^ = ""
		}
		return
	}
	if array_info, ok := info.variant.(reflect.Type_Info_Array); ok {
		for index in 0..<array_info.count {
			address := rawptr(uintptr(value.data) + uintptr(index * array_info.elem_size))
			delete_any_strings(any{data = address, id = array_info.elem.id})
		}
		return
	}
	if array_info, ok := info.variant.(reflect.Type_Info_Enumerated_Array); ok {
		for index in 0..<array_info.count {
			address := rawptr(uintptr(value.data) + uintptr(index * array_info.elem_size))
			delete_any_strings(any{data = address, id = array_info.elem.id})
		}
		return
	}
	if slice_info, ok := info.variant.(reflect.Type_Info_Slice); ok {
		slice := cast(^runtime.Raw_Slice)value.data
		for index in 0..<slice.len {
			address := rawptr(uintptr(slice.data) + uintptr(index * slice_info.elem_size))
			delete_any_strings(any{data = address, id = slice_info.elem.id})
		}
		if slice.data != nil do _ = mem.free(slice.data)
		return
	}
	if array_info, ok := info.variant.(reflect.Type_Info_Dynamic_Array); ok {
		array := cast(^runtime.Raw_Dynamic_Array)value.data
		for index in 0..<array.len {
			address := rawptr(uintptr(array.data) + uintptr(index * array_info.elem_size))
			delete_any_strings(any{data = address, id = array_info.elem.id})
		}
		if array.data != nil do _ = mem.free(array.data, allocator = array.allocator)
		array^ = runtime.Raw_Dynamic_Array{}
		return
	}
	if union_info, ok := info.variant.(reflect.Type_Info_Union); ok {
		if !union_info.no_nil && reflect.union_variant_typeid(value) != nil {
			delete_any_strings(reflect.get_union_variant(value))
		} else if union_info.no_nil {
			delete_any_strings(reflect.get_union_variant(value))
		}
		return
	}
	if reflect.is_struct(info) {
		struct_info, _ := info.variant.(reflect.Type_Info_Struct)
		for index in 0..<int(struct_info.field_count) {
			field := reflect.struct_field_at(value.id, index)
			delete_any_strings(reflect.struct_field_value(value, field))
		}
	}
}

descriptor_type :: proc(info: ^reflect.Type_Info) -> (Reducer_Argument_Type, Codec_Error) {
	if wide_type, is_256 := type_is_256(info.id); is_256 do return wide_type, .None
	info := base_type_info(info)
	if info == nil do return .U8, .Unsupported_Type
	if _, ok := info.variant.(reflect.Type_Info_Boolean); ok do return .Bool, .None
	if integer_info, ok := info.variant.(reflect.Type_Info_Integer); ok {
		if integer_info.endianness == .Big || (integer_info.endianness == .Platform && ODIN_ENDIAN != .Little) {
			return .U8, .Unsupported_Endianness
		}
		switch info.size {
		case 1:
			if integer_info.signed do return .I8, .None
			return .U8, .None
		case 2:
			if integer_info.signed do return .I16, .None
			return .U16, .None
		case 4:
			if integer_info.signed do return .I32, .None
			return .U32, .None
		case 8:
			if integer_info.signed do return .I64, .None
			return .U64, .None
		case 16:
			if integer_info.signed do return .I128, .None
			return .U128, .None
		}
		return .U8, .Unsupported_Type
	}
	if float_info, ok := info.variant.(reflect.Type_Info_Float); ok {
		if float_info.endianness == .Big || (float_info.endianness == .Platform && ODIN_ENDIAN != .Little) {
			return .U8, .Unsupported_Endianness
		}
		switch info.size {
		case 4: return .F32, .None
		case 8: return .F64, .None
		}
		return .U8, .Unsupported_Type
	}
	if string_info, ok := info.variant.(reflect.Type_Info_String); ok {
		if string_info.is_cstring || string_info.encoding != .UTF_8 do return .U8, .Unsupported_Type
		return .String, .None
	}
	return .U8, .Unsupported_Type
}

column_descriptor_type :: proc(info: ^reflect.Type_Info) -> (Reducer_Argument_Type, Reducer_Argument_Container, Codec_Error) {
	container := Reducer_Argument_Container.None
	if info == nil do return .U8, container, .Unsupported_Type
	if wide_type, is_256 := type_is_256(info.id); is_256 do return wide_type, container, .None
	info := base_type_info(info)
	if info == nil do return .U8, container, .Unsupported_Type
	if array, ok := info.variant.(reflect.Type_Info_Array); ok {
		container = .Array
		info = array.elem
	} else if array, ok := info.variant.(reflect.Type_Info_Enumerated_Array); ok {
		container = .Array
		info = array.elem
	} else if slice, ok := info.variant.(reflect.Type_Info_Slice); ok {
		container = .Array
		info = slice.elem
	} else if dynamic_array, ok := info.variant.(reflect.Type_Info_Dynamic_Array); ok {
		container = .Array
		info = dynamic_array.elem
	} else if maybe, ok := info.variant.(reflect.Type_Info_Union); ok {
		if maybe.no_nil || len(maybe.variants) != 1 do return .U8, container, .Unsupported_Type
		container = .Option
		info = maybe.variants[0]
	}
	primitive, err := descriptor_type(info)
	return primitive, container, err
}

validate_row_type :: proc($T: typeid) -> Codec_Error {
	info := base_type_info(type_info_of(T))
	if info == nil || !reflect.is_struct(info) do return .Unsupported_Type
	struct_info, _ := info.variant.(reflect.Type_Info_Struct)
	if struct_info.field_count == 0 do return .Unsupported_Type
	for index in 0..<int(struct_info.field_count) {
		field := reflect.struct_field_at(T, index)
		if len(field.name) == 0 || !type_supported(field.type) do return .Unsupported_Type
	}
	return .None
}

table_columns_from_type :: proc($T: typeid) -> ([]Reducer_Argument, Codec_Error) {
	info := base_type_info(type_info_of(T))
	if info == nil || !reflect.is_struct(info) do return nil, .Unsupported_Type
	struct_info, _ := info.variant.(reflect.Type_Info_Struct)
	if struct_info.field_count == 0 do return nil, .Unsupported_Type
	columns := make([]Reducer_Argument, int(struct_info.field_count))
	for index in 0..<int(struct_info.field_count) {
		field := reflect.struct_field_at(T, index)
		if len(field.name) == 0 || !type_supported(field.type) {
			delete(columns)
			return nil, .Unsupported_Type
		}
		columns[index] = column_argument(field)
	}
	return columns, .None
}

table_columns_into_type :: proc($T: typeid, columns: []Reducer_Argument) -> (int, Codec_Error) {
	info := base_type_info(type_info_of(T))
	if info == nil || !reflect.is_struct(info) do return 0, .Unsupported_Type
	struct_info, _ := info.variant.(reflect.Type_Info_Struct)
	field_count := int(struct_info.field_count)
	if field_count == 0 do return 0, .Unsupported_Type
	if len(columns) < field_count do return field_count, .Buffer_Too_Small
	for index in 0..<field_count {
		field := reflect.struct_field_at(T, index)
		if len(field.name) == 0 || !type_supported(field.type) do return 0, .Unsupported_Type
		columns[index] = column_argument(field)
	}
	return field_count, .None
}

// Primitive/container fields are best-effort; compound types rely on info.
column_argument :: proc(field: reflect.Struct_Field) -> Reducer_Argument {
	column_type, container, _ := column_descriptor_type(field.type)
	return Reducer_Argument{name = field.name, type = column_type, container = container, info = field.type}
}

typed_table_definition :: proc(
	$T: typeid,
	name: string,
	access: Table_Access,
	primary_key_columns: []u16,
	indexes: []Table_Index,
	unique_constraints: []Unique_Constraint,
) -> (Table_Definition, Codec_Error) {
	columns, err := table_columns_from_type(T)
	if err != .None do return Table_Definition{}, err
	return Table_Definition{
		name = name,
		row_info = type_info_of(T),
		columns = columns,
		access = access,
		primary_key_columns = primary_key_columns,
		indexes = indexes,
		unique_constraints = unique_constraints,
		outbox = nil,
	}, .None
}

typed_argument_definitions :: proc($Args: typeid) -> ([]Reducer_Argument, Codec_Error) {
	info := base_type_info(type_info_of(Args))
	if info == nil || !reflect.is_struct(info) do return nil, .Unsupported_Type
	struct_info, _ := info.variant.(reflect.Type_Info_Struct)
	if struct_info.field_count == 0 do return nil, .None
	return table_columns_from_type(Args)
}

// Argument definitions are owned by the caller and must remain alive through module description writing.
typed_reducer_definition :: proc(
	$Args: typeid,
	name: string,
	lifecycle: Lifecycle = .None,
	private := false,
	row_table: string = "",
) -> (Reducer_Definition, Codec_Error) {
	if len(name) == 0 do return Reducer_Definition{}, .Unsupported_Type
	arguments, err := typed_argument_definitions(Args)
	if err != .None do return Reducer_Definition{}, err
	return Reducer_Definition{
		name = name,
		args = arguments,
		lifecycle = lifecycle,
		private = private,
		row_table = row_table,
	}, .None
}

// Argument definitions are owned by the caller and must remain alive through module description writing.
typed_procedure_definition :: proc(
	$Args: typeid,
	name: string,
	return_info: ^reflect.Type_Info = nil,
	private := false,
) -> (Procedure_Definition, Codec_Error) {
	if len(name) == 0 do return Procedure_Definition{}, .Unsupported_Type
	arguments, err := typed_argument_definitions(Args)
	if err != .None do return Procedure_Definition{}, err
	if return_info != nil && !type_supported(return_info) {
		delete(arguments)
		return Procedure_Definition{}, .Unsupported_Type
	}
	return Procedure_Definition{name = name, args = arguments, return_info = return_info, private = private}, .None
}

// Argument definitions are owned by the caller and must remain alive through module description writing.
typed_view_definition :: proc(
	$Args: typeid,
	$Row: typeid,
	name: string,
	is_anonymous := false,
	primary_key: string = "",
) -> (View_Definition, Codec_Error) {
	if len(name) == 0 do return View_Definition{}, .Unsupported_Type
	arguments, err := typed_argument_definitions(Args)
	if err != .None do return View_Definition{}, err
	if validate_row_type(Row) != .None {
		delete(arguments)
		return View_Definition{}, .Unsupported_Type
	}
	return View_Definition{
		name = name,
		args = arguments,
		row_info = type_info_of(Row),
		is_anonymous = is_anonymous,
		primary_key = primary_key,
	}, .None
}

delete_table_definition :: proc(definition: Table_Definition) {
	delete(definition.columns)
}

Typed_Table :: struct($Row: typeid) {
	name: string,
	unique_index_name: string,
	auto_columns: []u16, // ascending column indices of auto-increment columns, for typed_insert_returning
}

// Typed facade for a table described with outbox metadata.
Outbox_Table :: struct($Row: typeid) {
	table_name: string,
	unique_index_name: string,
	auto_columns: []u16,
}

typed_table :: proc($Row: typeid, name, unique_index_name: string) -> (Typed_Table(Row), Codec_Error) {
	err := validate_row_type(Row)
	if err != .None do return Typed_Table(Row){}, err
	if len(name) == 0 do return Typed_Table(Row){}, .Unsupported_Type
	return Typed_Table(Row){name = name, unique_index_name = unique_index_name}, .None
}

outbox_table :: proc(
	$Row: typeid,
	name: string,
	auto_columns: []u16 = nil,
	unique_index_name: string = "",
) -> (Outbox_Table(Row), Codec_Error) {
	table, err := typed_table(Row, name, "")
	if err != .None do return Outbox_Table(Row){}, err
	table.auto_columns = auto_columns
	return Outbox_Table(Row){
		table_name = table.name,
		unique_index_name = unique_index_name,
		auto_columns = table.auto_columns,
	}, .None
}

@(private)
outbox_as_typed_table :: proc($Row: typeid, table: Outbox_Table(Row)) -> Typed_Table(Row) {
	return Typed_Table(Row){
		name = table.table_name,
		unique_index_name = table.unique_index_name,
		auto_columns = table.auto_columns,
	}
}

outbox_insert :: proc(
	$Row: typeid,
	table: Outbox_Table(Row),
	row: Row,
	buffer: []u8,
) -> (Status, Codec_Error) {
	return typed_insert(Row, outbox_as_typed_table(Row, table), row, buffer)
}

outbox_insert_returning :: proc(
	$Row: typeid,
	table: Outbox_Table(Row),
	row: Row,
	buffer: []u8,
) -> (Row, Status, Codec_Error) {
	return typed_insert_returning(Row, outbox_as_typed_table(Row, table), row, buffer)
}

outbox_update :: proc(
	$Row: typeid,
	table: Outbox_Table(Row),
	row: Row,
	buffer: []u8,
) -> (Status, Codec_Error) {
	return typed_update(Row, outbox_as_typed_table(Row, table), row, buffer)
}

outbox_delete :: proc(
	$Row: typeid,
	table: Outbox_Table(Row),
	row: Row,
	buffer: []u8,
) -> (u32, Status, Codec_Error) {
	return typed_delete(Row, outbox_as_typed_table(Row, table), row, buffer)
}

outbox_count :: proc($Row: typeid, table: Outbox_Table(Row)) -> (u64, Status) {
	return typed_count(Row, outbox_as_typed_table(Row, table))
}

outbox_scan_open :: proc(
	$Row: typeid,
	table: Outbox_Table(Row),
	buffer: []u8,
) -> (Typed_Scan(Row), Status) {
	return typed_scan_open(Row, outbox_as_typed_table(Row, table), buffer)
}

typed_insert :: proc(
	$Row: typeid,
	table: Typed_Table(Row),
	row: Row,
	buffer: []u8,
) -> (Status, Codec_Error) {
	encoded_len, err := encode_row_into(Row, row, buffer)
	if err != .None do return Status(0), err
	status, _ := insert_row_bsatn(table.name, buffer[:encoded_len])
	return status, .None
}

// Rows inserted with a zero auto-increment column come back with the generated values filled in.
typed_insert_returning :: proc(
	$Row: typeid,
	table: Typed_Table(Row),
	row: Row,
	buffer: []u8,
) -> (Row, Status, Codec_Error) {
	encoded_len, err := encode_row_into(Row, row, buffer)
	if err != .None do return row, Status(0), err
	status, generated_len := insert_row_bsatn(table.name, buffer[:encoded_len])
	if status != Status(0) do return row, status, .None
	result := row
	value := any{data = &result, id = typeid_of(Row)}
	reader := Byte_Reader{buffer = buffer[:generated_len]}
	for column in table.auto_columns {
		field_value := reflect.struct_field_value(value, reflect.struct_field_at(Row, int(column)))
		if !is_zero_value(field_value) do continue
		if decode_err := decode_any(&reader, field_value, true); decode_err != .None do return result, status, decode_err
	}
	return result, status, .None
}

is_zero_value :: proc(value: any) -> bool {
	bytes := cast([^]u8)value.data
	for index in 0 ..< type_info_of(value.id).size do if bytes[index] != 0 do return false
	return true
}

typed_update :: proc(
	$Row: typeid,
	table: Typed_Table(Row),
	row: Row,
	buffer: []u8,
) -> (Status, Codec_Error) {
	if len(table.unique_index_name) == 0 do return Status(0), .Missing_Unique_Index
	encoded_len, err := encode_row_into(Row, row, buffer)
	if err != .None do return Status(0), err
	status, _ := update_row_bsatn(table.name, table.unique_index_name, buffer[:encoded_len])
	return status, .None
}

typed_delete :: proc(
	$Row: typeid,
	table: Typed_Table(Row),
	row: Row,
	buffer: []u8,
) -> (u32, Status, Codec_Error) {
	writer := Byte_Writer{buffer = buffer}
	err := write_codec_u32(&writer, 1)
	if err != .None do return 0, Status(0), err
	encoded_len: int
	encoded_len, err = encode_row_into(Row, row, buffer[writer.offset:])
	if err != .None do return 0, Status(0), err
	return delete_rows_equal_bsatn(table.name, buffer[:writer.offset + encoded_len]), .None
}

typed_count :: proc($Row: typeid, table: Typed_Table(Row)) -> (u64, Status) {
	return table_row_count(table.name)
}

Typed_Scan :: struct($Row: typeid) {
	iterator: Row_Iterator,
	buffer: []u8,
	cursor: int,
	valid: int,
	required_buffer_len: int,
	exhausted: bool,
}

typed_scan_open :: proc($Row: typeid, table: Typed_Table(Row), buffer: []u8) -> (Typed_Scan(Row), Status) {
	iterator, status := begin_table_scan(table.name)
	if status != Status(0) do return Typed_Scan(Row){}, status
	return Typed_Scan(Row){iterator = iterator, buffer = buffer}, Status(0)
}

typed_scan_next :: proc($Row: typeid, scan: ^Typed_Scan(Row)) -> (Row, bool, i16, Codec_Error) {
	row: Row
	if scan.exhausted && scan.cursor >= scan.valid do return row, false, -1, .None
	if len(scan.buffer) == 0 {
		scan.required_buffer_len = 1
		return row, false, 0, .Buffer_Too_Small
	}
	if scan.cursor >= scan.valid {
		status, length := next_table_rows(scan.iterator, scan.buffer)
		if status == -1 {
			scan.exhausted = true
			if length == 0 do return row, false, status, .None
		} else if status != 0 {
			scan.required_buffer_len = int(length)
			return row, false, status, .None
		}
		if length == 0 do return row, false, status, .Malformed_Data
		scan.cursor = 0
		scan.valid = int(length)
		scan.required_buffer_len = 0
	}
	decoded, consumed, err := decode_row_borrowed(Row, scan.buffer[scan.cursor:scan.valid])
	if err != .None do return row, false, 0, err
	if consumed == 0 do return row, false, 0, .Malformed_Data
	scan.cursor += consumed
	return decoded, true, 0, .None
}

typed_scan_close :: proc($Row: typeid, scan: ^Typed_Scan(Row)) -> Status {
	if scan.exhausted do return Status(0)
	scan.exhausted = true
	return close_table_scan(scan.iterator)
}

read_reducer_args :: proc(
	$Args: typeid,
	source: Bytes_Source,
	buffer: []u8,
) -> (Args, Codec_Error) {
	args: Args
	remaining: u32
	if source != INVALID_BYTES_SOURCE {
		status := bytes_source_remaining_length(source, &remaining)
		if status != 0 do return args, .Host_Read_Failed
	}
	if u64(remaining) > u64(len(buffer)) do return args, .Buffer_Too_Small

	offset := 0
	for offset < int(remaining) {
		length := uint(int(remaining) - offset)
		read_status := bytes_source_read(source, raw_data(buffer[offset:]), &length)
		if read_status != 0 && read_status != -1 do return args, .Host_Read_Failed
		if length == 0 do return args, .Malformed_Data
		offset += int(length)
		if read_status == -1 && offset < int(remaining) do return args, .Malformed_Data
	}
	decoded, consumed, err := decode_row_borrowed(Args, buffer[:offset])
	if err != .None do return args, err
	if consumed != offset do return args, .Trailing_Bytes
	return decoded, .None
}
