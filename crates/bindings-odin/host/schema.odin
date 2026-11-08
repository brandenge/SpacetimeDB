package host

import "base:runtime"
import "core:reflect"
import "core:strings"

// Named structs and enums are registered in the typespace and referenced by index.
Type_Registry :: struct {
	types: [dynamic]^reflect.Type_Info,
	count: int,
	ref_base: u32,
}

// Set by write_module_def while a module description is being written.
schema_registry: ^Type_Registry
schema_tables: []Table_Definition
schema_table_type_refs: []u32
schema_table_type_count: int
schema_sum_variants: []Sum_Variant_Definition
schema_enum_variants: []Enum_Variant_Definition
schema_type_fields: []Type_Field_Definition

Sum_Variant_Definition :: struct {
	info: ^reflect.Type_Info,
	name: string,
}

Enum_Variant_Definition :: struct {
	info: ^reflect.Type_Info,
	names: []string,
}

Type_Export_Definition :: struct {
	info: ^reflect.Type_Info,
	scope: []string,
	name: string,
	custom_ordering: bool,
}

Type_Field_Definition :: struct {
	info: ^reflect.Type_Info,
	names: []string,
}

named_type_name :: proc "contextless" (info: ^reflect.Type_Info) -> string {
	named, ok := info.variant.(reflect.Type_Info_Named)
	return named.name if ok else ""
}

Result_Parts :: struct {
	ok: ^reflect.Type_Info,
	err: ^reflect.Type_Info,
}

@(private)
result_wrapper_payload :: proc(info: ^reflect.Type_Info, wrapper_name: string) -> (^reflect.Type_Info, bool) {
	name := named_type_name(info)
	if name != wrapper_name && !(strings.has_prefix(name, wrapper_name) && len(name) > len(wrapper_name) && name[len(wrapper_name)] == '(') {
		return nil, false
	}
	base := base_type_info(info)
	if base == nil do return nil, false
	struct_info, is_struct := base.variant.(reflect.Type_Info_Struct)
	if !is_struct || struct_info.field_count != 1 do return nil, false
	field := reflect.struct_field_at(base.id, 0)
	if field.name != "value" do return nil, false
	return field.type, true
}

@(private)
result_parts :: proc(info: ^reflect.Type_Info) -> (Result_Parts, bool) {
	if len(named_type_name(info)) == 0 do return {}, false
	base := base_type_info(info)
	if base == nil do return {}, false
	union_info, is_union := base.variant.(reflect.Type_Info_Union)
	if !is_union || !union_info.no_nil || len(union_info.variants) != 2 do return {}, false
	ok, ok_valid := result_wrapper_payload(union_info.variants[0], "Result_Ok")
	err, err_valid := result_wrapper_payload(union_info.variants[1], "Result_Err")
	if !ok_valid || !err_valid do return {}, false
	return Result_Parts{ok = ok, err = err}, true
}

Special_Type :: struct {
	field: string,
	inner: Reducer_Argument_Type,
	is_schedule_at: bool,
}

// Identity, Connection_Id, Timestamp and Time_Duration are single-field products with reserved field names.
special_type :: proc "contextless" (info: ^reflect.Type_Info) -> (Special_Type, bool) {
	cursor := info
	for cursor != nil {
		named, is_named := cursor.variant.(reflect.Type_Info_Named)
		if !is_named do break
		size := named.base.size if named.base != nil else 0
		switch named.name {
		case "Schedule_At":
			if size == 16 do return {is_schedule_at = true}, true
		case "Identity":
			if size == 32 do return {field = "__identity__", inner = .U256}, true
		case "Connection_Id":
			if size == 16 do return {field = "__connection_id__", inner = .U128}, true
		case "Timestamp":
			if size == 8 do return {field = "__timestamp_micros_since_unix_epoch__", inner = .I64}, true
		case "Time_Duration":
			if size == 8 do return {field = "__time_duration_micros__", inner = .I64}, true
		}
		cursor = named.base
	}
	return {}, false
}

registry_index :: proc(registry: ^Type_Registry, info: ^reflect.Type_Info) -> (int, bool) {
	for index in 0 ..< registry.count {
		if registry.types[index].id == info.id do return index, true
	}
	return 0, false
}

table_type_index :: proc(info: ^reflect.Type_Info) -> (int, bool) {
	if info == nil do return 0, false
	for table, index in schema_tables {
		if table.row_info != nil && table.row_info.id == info.id do return int(schema_table_type_refs[index]), true
	}
	return 0, false
}

generated_sum_variant :: proc(info: ^reflect.Type_Info) -> (string, ^reflect.Type_Info, bool) {
	if info == nil do return "", nil, false
	for definition in schema_sum_variants {
		if definition.info == nil || definition.info.id != info.id do continue
		base := base_type_info(info)
		if base == nil do return "", nil, false
		structure, ok := base.variant.(reflect.Type_Info_Struct)
		if !ok || structure.field_count > 1 do return "", nil, false
		if structure.field_count == 0 do return definition.name, nil, true
		field := reflect.struct_field_at(base.id, 0)
		return definition.name, field.type, true
	}
	return "", nil, false
}

registry_collect :: proc(registry: ^Type_Registry, info: ^reflect.Type_Info) {
	if info == nil do return
	if _, found := table_type_index(info); found do return
	if _, found := registry_index(registry, info); found do return
	if _, is_special := special_type(info); is_special do return
	if _, is_256 := type_is_256(info.id); is_256 do return
	if result_payload_is_unit(info) do return
	if result, is_result := result_parts(info); is_result {
		if !result_payload_is_unit(result.ok) do registry_collect(registry, result.ok)
		if !result_payload_is_unit(result.err) do registry_collect(registry, result.err)
		return
	}
	base := base_type_info(info)
	if base == nil do return
	#partial switch variant in base.variant {
	case reflect.Type_Info_Array:
		registry_collect(registry, variant.elem)
	case reflect.Type_Info_Enumerated_Array:
		registry_collect(registry, variant.elem)
	case reflect.Type_Info_Slice:
		registry_collect(registry, variant.elem)
	case reflect.Type_Info_Dynamic_Array:
		registry_collect(registry, variant.elem)
	case reflect.Type_Info_Union:
		if variant.no_nil {
			registry_add(registry, info)
			for payload in variant.variants {
				if _, inner, generated := generated_sum_variant(payload); generated {
					if inner != nil do registry_collect(registry, inner)
				} else {
					registry_collect(registry, payload)
				}
			}
		} else if len(variant.variants) == 1 {
			registry_collect(registry, variant.variants[0])
		}
	case reflect.Type_Info_Enum:
		registry_add(registry, info)
	case reflect.Type_Info_Struct:
		registry_add(registry, info)
		for index in 0 ..< int(variant.field_count) {
			field := reflect.struct_field_at(base.id, index)
			registry_collect(registry, field.type)
		}
	}
}

registry_add :: proc(registry: ^Type_Registry, info: ^reflect.Type_Info) {
	if _, found := registry_index(registry, info); found do return
	append(&registry.types, info)
	registry.count = len(registry.types)
}

type_supported :: proc(info: ^reflect.Type_Info, depth := 0) -> bool {
	seen := make(map[typeid]struct{}, allocator = context.temp_allocator)
	defer delete(seen)
	return type_supported_seen(info, &seen)
}

@(private)
type_supported_seen :: proc(info: ^reflect.Type_Info, seen: ^map[typeid]struct{}) -> bool {
	if info == nil do return false
	if info.id in seen^ do return true
	seen^[info.id] = {}
	if _, is_special := special_type(info); is_special do return true
	if _, is_256 := type_is_256(info.id); is_256 do return true
	if result, is_result := result_parts(info); is_result {
		return result_payload_supported(result.ok, seen) && result_payload_supported(result.err, seen)
	}
	base := base_type_info(info)
	if base == nil do return false
	#partial switch variant in base.variant {
	case reflect.Type_Info_Array:
		return type_supported_seen(variant.elem, seen)
	case reflect.Type_Info_Enumerated_Array:
		return type_supported_seen(variant.elem, seen)
	case reflect.Type_Info_Slice:
		return type_supported_seen(variant.elem, seen)
	case reflect.Type_Info_Dynamic_Array:
		return type_supported_seen(variant.elem, seen)
	case reflect.Type_Info_Union:
		if variant.no_nil {
			// Sum types need a name for themselves and for every variant, so primitives must be wrapped in a named type.
			if len(named_type_name(info)) == 0 || len(variant.variants) == 0 || len(variant.variants) > 256 do return false
			for payload in variant.variants {
				if len(named_type_name(payload)) == 0 || !type_supported_seen(payload, seen) do return false
			}
			return true
		}
		if len(variant.variants) != 1 do return false
		return type_supported_seen(variant.variants[0], seen)
	case reflect.Type_Info_Enum:
		count := len(variant.names)
		if len(named_type_name(info)) == 0 do return false
		if count == 0 || count > 256 || count != len(variant.values) do return false
		_, err := descriptor_type(variant.base)
		return err == .None
	case reflect.Type_Info_Struct:
		if variant.field_count == 0 && len(named_type_name(info)) == 0 do return true
		if len(named_type_name(info)) == 0 do return false
		for index in 0 ..< int(variant.field_count) {
			field := reflect.struct_field_at(base.id, index)
			if len(field.name) == 0 || !type_supported_seen(field.type, seen) do return false
		}
		return true
	}
	_, err := descriptor_type(base)
	return err == .None
}

@(private)
result_payload_is_unit :: proc(info: ^reflect.Type_Info) -> bool {
	if info == nil || len(named_type_name(info)) > 0 do return false
	base := base_type_info(info)
	if base == nil do return false
	if struct_info, is_struct := base.variant.(reflect.Type_Info_Struct); is_struct {
		return struct_info.field_count == 0
	}
	return false
}

@(private)
result_payload_supported :: proc(info: ^reflect.Type_Info, seen: ^map[typeid]struct{}) -> bool {
	if info == nil do return false
	if result_payload_is_unit(info) do return true
	return type_supported_seen(info, seen)
}

// Streams to the host sink, or into capture when set (used by native tests).
Schema_Writer :: struct {
	sink: Bytes_Sink,
	capture: ^[dynamic]u8,
	registry: ^Type_Registry,
	status: Status,
	failed: bool,
}

schema_emit :: proc(writer: ^Schema_Writer, bytes: []u8) {
	if writer.failed do return
	if writer.capture != nil {
		append(writer.capture, ..bytes)
		return
	}
	when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 {
		status, complete := write_all(writer.sink, bytes)
		if !complete {
			writer.failed = true
			writer.status = status
		}
	} else {
		writer.failed = true
	}
}

schema_emit_u32 :: proc(writer: ^Schema_Writer, value: u32) {
	bytes := [4]u8{u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)}
	schema_emit(writer, bytes[:])
}

schema_emit_string :: proc(writer: ^Schema_Writer, value: string) {
	schema_emit_u32(writer, u32(len(value)))
	schema_emit(writer, transmute([]u8)value)
}

schema_emit_unit_product :: proc(writer: ^Schema_Writer) {
	schema_emit(writer, []u8{2, 0, 0, 0, 0})
}

// Callers must check type_supported first. Named structs/enums become refs when a registry is set.
emit_algebraic_type :: proc(writer: ^Schema_Writer, info: ^reflect.Type_Info, inline := false) {
	if special, is_special := special_type(info); is_special {
		if special.is_schedule_at {
			// Sum { Interval: TimeDuration, Time: Timestamp }.
			schema_emit(writer, []u8{1})
			schema_emit_u32(writer, 2)
			schema_emit(writer, []u8{0})
			schema_emit_string(writer, "Interval")
			schema_emit(writer, []u8{2})
			schema_emit_u32(writer, 1)
			schema_emit(writer, []u8{0})
			schema_emit_string(writer, "__time_duration_micros__")
			schema_emit(writer, []u8{u8(Reducer_Argument_Type.I64)})
			schema_emit(writer, []u8{0})
			schema_emit_string(writer, "Time")
			schema_emit(writer, []u8{2})
			schema_emit_u32(writer, 1)
			schema_emit(writer, []u8{0})
			schema_emit_string(writer, "__timestamp_micros_since_unix_epoch__")
			schema_emit(writer, []u8{u8(Reducer_Argument_Type.I64)})
			return
		}
		schema_emit(writer, []u8{2})
		schema_emit_u32(writer, 1)
		schema_emit(writer, []u8{0})
		schema_emit_string(writer, special.field)
		schema_emit(writer, []u8{u8(special.inner)})
		return
	}
	if wide, is_256 := type_is_256(info.id); is_256 {
		schema_emit(writer, []u8{u8(wide)})
		return
	}
	if result, is_result := result_parts(info); is_result {
		schema_emit(writer, []u8{1})
		schema_emit_u32(writer, 2)
		schema_emit(writer, []u8{0})
		schema_emit_string(writer, "ok")
		emit_result_payload(writer, result.ok)
		schema_emit(writer, []u8{0})
		schema_emit_string(writer, "err")
		emit_result_payload(writer, result.err)
		return
	}
	base := base_type_info(info)
	#partial switch variant in base.variant {
	case reflect.Type_Info_Array:
		schema_emit(writer, []u8{3})
		emit_algebraic_type(writer, variant.elem)
		return
	case reflect.Type_Info_Enumerated_Array:
		schema_emit(writer, []u8{3})
		emit_algebraic_type(writer, variant.elem)
		return
	case reflect.Type_Info_Slice:
		schema_emit(writer, []u8{3})
		emit_algebraic_type(writer, variant.elem)
		return
	case reflect.Type_Info_Dynamic_Array:
		schema_emit(writer, []u8{3})
		emit_algebraic_type(writer, variant.elem)
		return
	case reflect.Type_Info_Union:
		if variant.no_nil {
			if !inline && writer.registry != nil {
				emit_type_ref(writer, info)
				return
			}
			schema_emit(writer, []u8{1})
			schema_emit_u32(writer, u32(len(variant.variants)))
			for payload in variant.variants {
				schema_emit(writer, []u8{0})
				if name, inner, generated := generated_sum_variant(payload); generated {
					schema_emit_string(writer, name)
					if inner == nil do schema_emit_unit_product(writer)
					else do emit_algebraic_type(writer, inner)
				} else {
					schema_emit_string(writer, named_type_name(payload))
					emit_algebraic_type(writer, payload)
				}
			}
			return
		}
		// Option layout: some = 0, none = 1.
		schema_emit(writer, []u8{1})
		schema_emit_u32(writer, 2)
		schema_emit(writer, []u8{0})
		schema_emit_string(writer, "some")
		emit_algebraic_type(writer, variant.variants[0])
		schema_emit(writer, []u8{0})
		schema_emit_string(writer, "none")
		schema_emit_unit_product(writer)
		return
	case reflect.Type_Info_Enum:
		if !inline && writer.registry != nil {
			emit_type_ref(writer, info)
			return
		}
		schema_emit(writer, []u8{1})
		schema_emit_u32(writer, u32(len(variant.names)))
		names := variant.names
		for definition in schema_enum_variants {
			if definition.info != nil && definition.info.id == info.id && len(definition.names) == len(names) {
				names = definition.names
				break
			}
		}
		for name in names {
			schema_emit(writer, []u8{0})
			schema_emit_string(writer, name)
			schema_emit_unit_product(writer)
		}
		return
	case reflect.Type_Info_Struct:
		if result_payload_is_unit(info) {
			schema_emit_unit_product(writer)
			return
		}
		if !inline && writer.registry != nil {
			emit_type_ref(writer, info)
			return
		}
		schema_emit(writer, []u8{2})
		schema_emit_u32(writer, u32(variant.field_count))
		field_names: []string
		for definition in schema_type_fields {
			if definition.info != nil && definition.info.id == info.id && len(definition.names) == int(variant.field_count) {
				field_names = definition.names
				break
			}
		}
		for index in 0 ..< int(variant.field_count) {
			field := reflect.struct_field_at(base.id, index)
			schema_emit(writer, []u8{0})
			schema_emit_string(writer, field_names[index] if field_names != nil else field.name)
			emit_algebraic_type(writer, field.type)
		}
		return
	}
	primitive, _ := descriptor_type(base)
	schema_emit(writer, []u8{u8(primitive)})
}

@(private)
emit_result_payload :: proc(writer: ^Schema_Writer, info: ^reflect.Type_Info) {
	if result_payload_is_unit(info) {
		schema_emit_unit_product(writer)
		return
	}
	emit_algebraic_type(writer, info)
}

emit_type_ref :: proc(writer: ^Schema_Writer, info: ^reflect.Type_Info) {
	if index, found := table_type_index(info); found {
		schema_emit(writer, []u8{0})
		schema_emit_u32(writer, u32(index))
		return
	}
	index, found := registry_index(writer.registry, info)
	if !found {
		writer.failed = true
		return
	}
	schema_emit(writer, []u8{0})
	schema_emit_u32(writer, writer.registry.ref_base + u32(index))
}

encode_algebraic_type :: proc(info: ^reflect.Type_Info, registry: ^Type_Registry = nil) -> ([dynamic]u8, bool) {
	encoded: [dynamic]u8
	if !type_supported(info) do return encoded, false
	writer := Schema_Writer{capture = &encoded, registry = registry}
	emit_algebraic_type(&writer, info)
	return encoded, !writer.failed
}

write_type_info :: proc (sink: Bytes_Sink, info: ^reflect.Type_Info) -> (Status, bool) {
	if !type_supported(info) do return Status(0), false
	writer := Schema_Writer{sink = sink, registry = schema_registry}
	emit_algebraic_type(&writer, info)
	return writer.status, !writer.failed
}

// Writes the inline product/sum body for a registered named type.
write_type_definition :: proc (sink: Bytes_Sink, info: ^reflect.Type_Info) -> (Status, bool) {
	writer := Schema_Writer{sink = sink, registry = schema_registry}
	emit_algebraic_type(&writer, info, inline = true)
	return writer.status, !writer.failed
}
