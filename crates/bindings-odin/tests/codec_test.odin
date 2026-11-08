package tests

import "base:runtime"
import "core:reflect"
import "core:slice"
import "core:testing"
import "stdb:host"

All_Primitives :: struct {
	flag: bool,
	u8_value: u8,
	i8_value: i8,
	u16_value: u16,
	i16_value: i16,
	u32_value: u32,
	i32_value: i32,
	u64_value: u64,
	i64_value: i64,
	u128_value: u128,
	i128_value: i128,
	f32_value: f32,
	f64_value: f64,
	text: string,
}

String_Value :: struct {
	text: string,
}

Single_Field :: struct {
	id: u32,
}

Wide_Integers :: struct {
	signed: host.I256,
	unsigned: host.U256,
}

Color :: enum u8 {
	Red,
	Green,
	Blue,
}

Compound_Values :: struct {
	values: [3]u16,
	color: Color,
	optional: runtime.Maybe(u32),
}

Array_Option_Columns :: struct {
	values: [3]u16,
	optional: runtime.Maybe(u32),
}

@(test)
codec_round_trips_primitives_and_owned_string :: proc(t: ^testing.T) {
	value := All_Primitives{
		flag = true,
		u8_value = 0xfe,
		i8_value = -8,
		u16_value = 0x1234,
		i16_value = -1234,
		u32_value = 0x1234_5678,
		i32_value = -123456,
		u64_value = 0x1234_5678_9abc_def0,
		i64_value = -123456789,
		u128_value = 0x1234,
		i128_value = -456,
		f32_value = 1.25,
		f64_value = -9.5,
		text = "typed Odin",
	}

	buffer: [256]u8
	encoded_len, encode_error := host.encode_row_into(All_Primitives, value, buffer[:])
	testing.expect_value(t, encode_error, host.Codec_Error.None)

	decoded, consumed, decode_error := host.decode_row_from(All_Primitives, buffer[:encoded_len])
	testing.expect_value(t, decode_error, host.Codec_Error.None)
	testing.expect_value(t, consumed, encoded_len)
	testing.expect_value(t, decoded.flag, value.flag)
	testing.expect_value(t, decoded.u8_value, value.u8_value)
	testing.expect_value(t, decoded.i8_value, value.i8_value)
	testing.expect_value(t, decoded.u16_value, value.u16_value)
	testing.expect_value(t, decoded.i16_value, value.i16_value)
	testing.expect_value(t, decoded.u32_value, value.u32_value)
	testing.expect_value(t, decoded.i32_value, value.i32_value)
	testing.expect_value(t, decoded.u64_value, value.u64_value)
	testing.expect_value(t, decoded.i64_value, value.i64_value)
	testing.expect_value(t, decoded.u128_value, value.u128_value)
	testing.expect_value(t, decoded.i128_value, value.i128_value)
	testing.expect_value(t, decoded.f32_value, value.f32_value)
	testing.expect_value(t, decoded.f64_value, value.f64_value)
	testing.expect_value(t, decoded.text, value.text)
	host.delete_decoded_row(All_Primitives, &decoded)
}

@(test)
codec_rejects_small_buffers_and_invalid_booleans :: proc(t: ^testing.T) {
	value := All_Primitives{u32_value = 42}
	too_small: [1]u8
	_, encode_error := host.encode_row_into(All_Primitives, value, too_small[:])
	testing.expect_value(t, encode_error, host.Codec_Error.Buffer_Too_Small)

	invalid_bool := [1]u8{2}
	_, _, decode_error := host.decode_row_from(bool, invalid_bool[:])
	testing.expect_value(t, decode_error, host.Codec_Error.Invalid_Boolean)
}

@(test)
codec_rejects_invalid_utf8_and_reports_consumed_prefix :: proc(t: ^testing.T) {
	invalid_utf8 := [6]u8{2, 0, 0, 0, 0xc0, 0xaf}
	_, _, utf8_error := host.decode_row_from(String_Value, invalid_utf8[:])
	testing.expect_value(t, utf8_error, host.Codec_Error.Invalid_Utf8)

	u32_bytes := [5]u8{42, 0, 0, 0, 99}
	decoded, consumed, err := host.decode_row_from(u32, u32_bytes[:])
	testing.expect_value(t, err, host.Codec_Error.None)
	testing.expect_value(t, decoded, 42)
	testing.expect_value(t, consumed, 4)
}

@(test)
typed_table_uses_reflected_primitive_columns :: proc(t: ^testing.T) {
	buffer: [14]host.Reducer_Argument
	count, err := host.table_columns_into_type(All_Primitives, buffer[:])
	testing.expect_value(t, err, host.Codec_Error.None)
	testing.expect_value(t, count, 14)
	testing.expect_value(t, buffer[0].name, "flag")
	testing.expect_value(t, buffer[0].type, host.Reducer_Argument_Type.Bool)
	testing.expect_value(t, buffer[13].name, "text")
	testing.expect_value(t, buffer[13].type, host.Reducer_Argument_Type.String)
}

@(test)
typed_table_definition_owns_derived_columns :: proc(t: ^testing.T) {
	key := [1]u16{0}
	definition, err := host.typed_table_definition(
		All_Primitives,
		"values",
		.Public,
		key[:],
		nil,
		 nil,
	)
	testing.expect_value(t, err, host.Codec_Error.None)
	testing.expect_value(t, len(definition.columns), 14)
	host.delete_table_definition(definition)
}

@(test)
typed_insert_only_table_does_not_require_update_index :: proc(t: ^testing.T) {
	table, err := host.typed_table(Single_Field, "records", "")
	testing.expect_value(t, err, host.Codec_Error.None)
	testing.expect_value(t, table.name, "records")
	testing.expect_value(t, table.unique_index_name, "")
}

@(test)
codec_round_trips_256_bit_wrappers :: proc(t: ^testing.T) {
	signed_bytes: [32]u8
	unsigned_bytes: [32]u8
	for i in 0..<32 {
		signed_bytes[i] = u8(i)
		unsigned_bytes[i] = u8(255 - i)
	}
	value := Wide_Integers{
		signed = host.I256(signed_bytes),
		unsigned = host.U256(unsigned_bytes),
	}
	buffer: [64]u8
	encoded_len, encode_error := host.encode_row_into(Wide_Integers, value, buffer[:])
	testing.expect_value(t, encode_error, host.Codec_Error.None)
	testing.expect_value(t, encoded_len, 64)

	decoded, consumed, decode_error := host.decode_row_from(Wide_Integers, buffer[:encoded_len])
	testing.expect_value(t, decode_error, host.Codec_Error.None)
	testing.expect_value(t, consumed, encoded_len)
	testing.expect_value(t, decoded.signed, value.signed)
	testing.expect_value(t, decoded.unsigned, value.unsigned)
	columns: [2]host.Reducer_Argument
	_, column_error := host.table_columns_into_type(Wide_Integers, columns[:])
	testing.expect_value(t, column_error, host.Codec_Error.None)
	testing.expect_value(t, columns[0].type, host.Reducer_Argument_Type.I256)
	testing.expect_value(t, columns[1].type, host.Reducer_Argument_Type.U256)
}

@(test)
typed_table_detects_array_and_option_columns :: proc(t: ^testing.T) {
	columns: [2]host.Reducer_Argument
	count, err := host.table_columns_into_type(Array_Option_Columns, columns[:])
	testing.expect_value(t, err, host.Codec_Error.None)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, columns[0].container, host.Reducer_Argument_Container.Array)
	testing.expect_value(t, columns[1].container, host.Reducer_Argument_Container.Option)
}

@(test)
codec_round_trips_fixed_arrays_options_and_enums :: proc(t: ^testing.T) {
	value := Compound_Values{
		values = {7, 11, 23},
		color = .Green,
		optional = 0x1234,
	}
	buffer: [64]u8
	encoded_len, encode_error := host.encode_row_into(Compound_Values, value, buffer[:])
	testing.expect_value(t, encode_error, host.Codec_Error.None)
	decoded, consumed, decode_error := host.decode_row_from(Compound_Values, buffer[:encoded_len])
	testing.expect_value(t, decode_error, host.Codec_Error.None)
	testing.expect_value(t, consumed, encoded_len)
	testing.expect_value(t, decoded.values, value.values)
	testing.expect_value(t, decoded.color, value.color)
	testing.expect_value(t, reflect.union_variant_typeid(any{data = &decoded.optional, id = typeid_of(runtime.Maybe(u32))}), typeid_of(u32))
	decoded_optional := reflect.get_union_variant(any{data = &decoded.optional, id = typeid_of(runtime.Maybe(u32))})
	testing.expect_value(t, (^u32)(decoded_optional.data)^, u32(0x1234))

	none: Compound_Values
	none_buffer: [64]u8
	none_len, none_encode_error := host.encode_row_into(Compound_Values, none, none_buffer[:])
	testing.expect_value(t, none_encode_error, host.Codec_Error.None)
	none_decoded, _, none_decode_error := host.decode_row_from(Compound_Values, none_buffer[:none_len])
	testing.expect_value(t, none_decode_error, host.Codec_Error.None)
	testing.expect_value(t, reflect.union_variant_typeid(any{data = &none_decoded.optional, id = typeid_of(runtime.Maybe(u32))}), typeid(nil))
}

Point :: struct {
	x: i32,
	y: i32,
}

Shape :: struct {
	origin: Point,
	corners: []Point,
	label: runtime.Maybe(string),
	kind: Color,
	ids: [2]host.U256,
}

@(test)
codec_round_trips_nested_products_and_compound_containers :: proc(t: ^testing.T) {
	corners := []Point{{1, 2}, {3, 4}}
	value := Shape{
		origin = {-5, 6},
		corners = corners,
		label = "tri",
		kind = .Blue,
	}
	buffer: [256]u8
	encoded_len, encode_error := host.encode_row_into(Shape, value, buffer[:])
	testing.expect_value(t, encode_error, host.Codec_Error.None)
	decoded, consumed, decode_error := host.decode_row_from(Shape, buffer[:encoded_len])
	testing.expect_value(t, decode_error, host.Codec_Error.None)
	testing.expect_value(t, consumed, encoded_len)
	testing.expect_value(t, decoded.origin, value.origin)
	testing.expect_value(t, len(decoded.corners), 2)
	testing.expect_value(t, decoded.corners[1], Point{3, 4})
	testing.expect_value(t, decoded.kind, Color.Blue)
	label, has_label := decoded.label.?
	testing.expect(t, has_label)
	testing.expect_value(t, label, "tri")
	host.delete_decoded_row(Shape, &decoded)
}

@(test)
schema_describes_nested_enum_option_and_array_columns :: proc(t: ^testing.T) {
	columns: [5]host.Reducer_Argument
	count, err := host.table_columns_into_type(Shape, columns[:])
	testing.expect_value(t, err, host.Codec_Error.None)
	testing.expect_value(t, count, 5)

	point_type, point_ok := host.encode_algebraic_type(columns[0].info)
	defer delete(point_type)
	testing.expect(t, point_ok)
	// Product, 2 fields: (Some "x" I32) (Some "y" I32).
	expected_point := []u8{2, 2, 0, 0, 0, 0, 1, 0, 0, 0, 'x', 10, 0, 1, 0, 0, 0, 'y', 10}
	testing.expect(t, slice.equal(point_type[:], expected_point))

	kind_type, kind_ok := host.encode_algebraic_type(columns[3].info)
	defer delete(kind_type)
	testing.expect(t, kind_ok)
	testing.expect_value(t, kind_type[0], u8(1))
	testing.expect_value(t, kind_type[1], u8(3))

	ids_type, ids_ok := host.encode_algebraic_type(columns[4].info)
	defer delete(ids_type)
	testing.expect(t, ids_ok)
	testing.expect(t, slice.equal(ids_type[:], []u8{3, 17}))
}

Unsupported_Column :: struct {
	value: map[string]u32,
}

@(test)
schema_rejects_unsupported_column_types :: proc(t: ^testing.T) {
	columns: [1]host.Reducer_Argument
	_, err := host.table_columns_into_type(Unsupported_Column, columns[:])
	testing.expect_value(t, err, host.Codec_Error.Unsupported_Type)
}

Session_Row :: struct {
	identity: host.Identity,
	connection: host.Connection_Id,
	at: host.Timestamp,
}

@(test)
special_types_encode_raw_and_describe_as_reserved_products :: proc(t: ^testing.T) {
	row := Session_Row{connection = 5, at = -3}
	row.identity[0] = 0xab
	buffer: [64]u8
	encoded_len, err := host.encode_row_into(Session_Row, row, buffer[:])
	testing.expect_value(t, err, host.Codec_Error.None)
	testing.expect_value(t, encoded_len, 32 + 16 + 8)
	decoded, _, decode_err := host.decode_row_from(Session_Row, buffer[:encoded_len])
	testing.expect_value(t, decode_err, host.Codec_Error.None)
	testing.expect_value(t, decoded, row)

	columns: [3]host.Reducer_Argument
	_, column_err := host.table_columns_into_type(Session_Row, columns[:])
	testing.expect_value(t, column_err, host.Codec_Error.None)
	identity_type, ok := host.encode_algebraic_type(columns[0].info)
	defer delete(identity_type)
	testing.expect(t, ok)
	expected := []u8{2, 1, 0, 0, 0, 0, 12, 0, 0, 0, '_', '_', 'i', 'd', 'e', 'n', 't', 'i', 't', 'y', '_', '_', 17}
	testing.expect(t, slice.equal(identity_type[:], expected))
}

@(test)
reducer_context_reassembles_little_endian_limbs :: proc(t: ^testing.T) {
	ctx := host.reducer_context(0x0807060504030201, 0, 0, 0xff, 0x11, 0, 1234)
	identity := transmute([32]u8)ctx.sender
	testing.expect_value(t, identity[0], u8(1))
	testing.expect_value(t, identity[7], u8(8))
	testing.expect_value(t, identity[24], u8(0xff))
	testing.expect_value(t, ctx.connection_id, host.Connection_Id(0x11))
	testing.expect(t, ctx.has_connection_id)
	testing.expect_value(t, ctx.timestamp, host.Timestamp(1234))
	testing.expect(t, !host.reducer_context(0, 0, 0, 0, 0, 0, 0).has_connection_id)
}

@(test)
procedure_context_exposes_caller_and_deterministic_randomness :: proc(t: ^testing.T) {
	ctx := host.procedure_context(0x0807060504030201, 0, 0, 0xff, 0x11, 0, 1_700_000_000_000_000)
	replay := host.procedure_context(0x0807060504030201, 0, 0, 0xff, 0x11, 0, 1_700_000_000_000_000)
	identity := transmute([32]u8)ctx.sender
	testing.expect_value(t, identity[0], u8(1))
	testing.expect_value(t, identity[24], u8(0xff))
	testing.expect_value(t, ctx.connection_id, host.Connection_Id(0x11))
	testing.expect(t, ctx.has_connection_id)
	testing.expect_value(t, ctx.timestamp, host.Timestamp(1_700_000_000_000_000))

	first_random := host.context_random_u64(&ctx)
	replay_random := host.context_random_u64(&replay)
	testing.expect_value(t, first_random, replay_random)

	first_v4 := host.context_new_uuid_v4(&ctx)
	replay_v4 := host.context_new_uuid_v4(&replay)
	testing.expect_value(t, first_v4, replay_v4)
	testing.expect_value(t, u8((first_v4 >> 76) & 0x0f), u8(4))
	testing.expect_value(t, u8((first_v4 >> 62) & 0x03), u8(2))

	v7_context := host.procedure_context(0, 0, 0, 0, 0, 0, 1_686_000_000_000)
	first_v7, first_v7_err := host.context_new_uuid_v7(&v7_context)
	second_v7, second_v7_err := host.context_new_uuid_v7(&v7_context)
	testing.expect_value(t, first_v7_err, host.Uuid_Generation_Error.None)
	testing.expect_value(t, second_v7_err, host.Uuid_Generation_Error.None)
	testing.expect(t, second_v7 > first_v7)
	testing.expect_value(t, u8((first_v7 >> 76) & 0x0f), u8(7))

	before_epoch := host.procedure_context(0, 0, 0, 0, 0, 0, 0)
	before_epoch.timestamp = host.Timestamp(-1)
	_, before_epoch_err := host.context_new_uuid_v7(&before_epoch)
	testing.expect_value(t, before_epoch_err, host.Uuid_Generation_Error.Timestamp_Before_Unix_Epoch)
}

@(test)
http_handler_context_exposes_sender_timestamp_and_jwt_payload :: proc(t: ^testing.T) {
	payload := transmute([]u8)string(`{"iss":"issuer","sub":"subject"}`)
	ctx := host.http_handler_context(0x0807060504030201, 0, 0, 0xff, payload, 1234)
	identity := transmute([32]u8)ctx.sender
	testing.expect_value(t, identity[0], u8(1))
	testing.expect_value(t, identity[7], u8(8))
	testing.expect_value(t, identity[24], u8(0xff))
	testing.expect_value(t, ctx.timestamp, host.Timestamp(1234))
	testing.expect(t, ctx.sender_auth.has_jwt)
	testing.expect_value(t, ctx.sender_auth.jwt_payload, transmute(string)payload)
	tx_ctx := host.http_transaction_context(ctx, host.Timestamp(5678))
	testing.expect_value(t, tx_ctx.sender, ctx.sender)
	testing.expect_value(t, tx_ctx.timestamp, host.Timestamp(5678))
	testing.expect(t, tx_ctx.sender_auth.has_jwt)
	testing.expect_value(t, tx_ctx.sender_auth.jwt_payload, ctx.sender_auth.jwt_payload)

	no_jwt := host.http_handler_context(0, 0, 0, 0, nil, 0)
	testing.expect(t, !no_jwt.sender_auth.has_jwt)
}

@(test)
http_handler_jwt_claims_parse_subject_issuer_and_audience :: proc(t: ^testing.T) {
	auth := host.Http_Handler_Auth_Context{
		has_jwt = true,
		jwt_payload = `{"sub":"user-7","iss":"issuer.example","aud":["web","api"]}`,
	}
	claims, ok := host.http_jwt_claims(auth)
	defer host.http_jwt_claims_destroy(&claims)
	testing.expect(t, ok)
	testing.expect(t, claims.has_subject)
	testing.expect_value(t, claims.subject, "user-7")
	testing.expect(t, claims.has_issuer)
	testing.expect_value(t, claims.issuer, "issuer.example")
	testing.expect_value(t, len(claims.audience), 2)
	testing.expect_value(t, claims.audience[0], "web")
	testing.expect_value(t, claims.audience[1], "api")

	string_audience, string_ok := host.http_jwt_claims({has_jwt = true, jwt_payload = `{"aud":"single"}`})
	defer host.http_jwt_claims_destroy(&string_audience)
	testing.expect(t, string_ok)
	testing.expect_value(t, len(string_audience.audience), 1)
	testing.expect_value(t, string_audience.audience[0], "single")
}

@(test)
uuid_rng_matches_rust_std_rng_seed_stream :: proc(t: ^testing.T) {
	rng := host.uuid_rng_from_seed(1_700_000_000_000_000)
	bytes: [16]u8
	host.uuid_rng_fill(&rng, bytes[:])
	expected := [16]u8{
		0x5e, 0x24, 0xd5, 0xc2, 0xf4, 0x13, 0x56, 0xa2,
		0xa6, 0x03, 0xc4, 0xc1, 0x5f, 0x81, 0x08, 0x14,
	}
	for actual, index in bytes do testing.expect_value(t, actual, expected[index])
}

@(test)
http_handler_uuids_use_seeded_randomness_and_v7_counter :: proc(t: ^testing.T) {
	first_context := host.http_handler_context(0, 0, 0, 0, nil, 1_686_000_000_000)
	replay_context := host.http_handler_context(0, 0, 0, 0, nil, 1_686_000_000_000)
	first_v4, first_v4_err := host.new_uuid_v4(&first_context)
	replay_v4, replay_v4_err := host.new_uuid_v4(&replay_context)
	testing.expect_value(t, first_v4_err, host.Uuid_Generation_Error.None)
	testing.expect_value(t, replay_v4_err, host.Uuid_Generation_Error.None)
	testing.expect_value(t, first_v4, replay_v4)
	testing.expect_value(t, u8((first_v4 >> 76) & 0x0f), u8(4))
	testing.expect_value(t, u8((first_v4 >> 62) & 0x03), u8(2))
	second_v4, second_v4_err := host.new_uuid_v4(&first_context)
	testing.expect_value(t, second_v4_err, host.Uuid_Generation_Error.None)
	testing.expect(t, first_v4 != second_v4)

	first_v7_context := host.http_handler_context(0, 0, 0, 0, nil, 1_686_000_000_000)
	replay_v7_context := host.http_handler_context(0, 0, 0, 0, nil, 1_686_000_000_000)
	first_v7, first_v7_err := host.new_uuid_v7(&first_v7_context)
	replay_v7, replay_v7_err := host.new_uuid_v7(&replay_v7_context)
	testing.expect_value(t, first_v7_err, host.Uuid_Generation_Error.None)
	testing.expect_value(t, replay_v7_err, host.Uuid_Generation_Error.None)
	testing.expect_value(t, first_v7, replay_v7)
	testing.expect_value(t, u8((first_v7 >> 76) & 0x0f), u8(7))
	testing.expect_value(t, u8((first_v7 >> 62) & 0x03), u8(2))
	testing.expect_value(t, u64((first_v7 >> 80) & 0xffff_ffff_ffff), u64(1_686_000_000))
	second_v7, second_v7_err := host.new_uuid_v7(&first_v7_context)
	testing.expect_value(t, second_v7_err, host.Uuid_Generation_Error.None)
	testing.expect(t, second_v7 > first_v7)

	before_epoch := host.http_handler_context(0, 0, 0, 0, nil, 0)
	before_epoch.timestamp = host.Timestamp(-1)
	_, before_epoch_err := host.new_uuid_v7(&before_epoch)
	testing.expect_value(t, before_epoch_err, host.Uuid_Generation_Error.Timestamp_Before_Unix_Epoch)
}

@(test)
outbox_section_matches_v10_bsatn_layout :: proc(t: ^testing.T) {
	arguments := [2]u16{2, 3}
	signature_hash: [32]u8
	for index in 0 ..< len(signature_hash) do signature_hash[index] = u8(index)
	outbox := host.Outbox_Definition{
		remote_reducer = "go",
		target_column = 1,
		arg_columns = arguments[:],
		on_result_reducer = "done",
		signature_hash = signature_hash,
	}
	tables := [?]host.Table_Definition{{
		name = "box",
		outbox = outbox,
	}}
	buffer: [128]u8
	encoded_len, ok := host.encode_outbox_section_into(tables[:], buffer[:])
	testing.expect(t, ok)
	expected := []u8{
		16, 1, 0, 0, 0,
		3, 0, 0, 0, 'b', 'o', 'x',
		2, 0, 0, 0, 'g', 'o',
		1, 0,
		2, 0, 0, 0, 2, 0, 3, 0,
		0, 4, 0, 0, 0, 'd', 'o', 'n', 'e',
		0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
		16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
	}
	testing.expect(t, slice.equal(buffer[:encoded_len], expected))

	outbox.on_result_reducer = nil
	tables[0].outbox = outbox
	encoded_len, ok = host.encode_outbox_section_into(tables[:], buffer[:])
	testing.expect(t, ok)
	testing.expect_value(t, buffer[28], u8(1)) // None tag follows the arg-column list.
	testing.expect_value(t, encoded_len, len(expected) - 8)
}

@(test)
environment_section_matches_v10_bsatn_layout :: proc(t: ^testing.T) {
	definitions := [?]host.Environment_Definition{
		{name = "OPTIONAL", type = .String, optional = true},
		{name = "MODE", type = .String_Literal, literal = "prod"},
		{name = "TIER", type = .Union, values = []string{"dev", "prod"}},
	}
	buffer: [128]u8
	encoded_len, ok := host.encode_environment_section_into(definitions[:], buffer[:])
	testing.expect(t, ok)
	expected := []u8{
		15, 3, 0, 0, 0,
		8, 0, 0, 0, 'O', 'P', 'T', 'I', 'O', 'N', 'A', 'L',
		0, 1,
		4, 0, 0, 0, 'M', 'O', 'D', 'E', 1, 4, 0, 0, 0, 'p', 'r', 'o', 'd', 0,
		4, 0, 0, 0, 'T', 'I', 'E', 'R', 2, 2, 0, 0, 0,
		3, 0, 0, 0, 'd', 'e', 'v', 4, 0, 0, 0, 'p', 'r', 'o', 'd', 0,
	}
	testing.expect_value(t, encoded_len, len(expected))
	for index in 0 ..< min(encoded_len, len(expected)) {
		testing.expect_value(t, buffer[index], expected[index])
	}
}

Outbox_Row :: struct {
	id: u64,
	receiver: host.Identity,
	score: u32,
}

Typed_Descriptor_Args :: struct {
	name: string,
}

Typed_Descriptor_Row :: struct {
	id: u64,
	name: string,
}

Typed_Descriptor_Unit :: struct {}

@(test)
typed_module_descriptors_build_named_arguments_and_rows :: proc(t: ^testing.T) {
	reducer, reducer_err := host.typed_reducer_definition(Typed_Descriptor_Args, "update")
	testing.expect_value(t, reducer_err, host.Codec_Error.None)
	testing.expect_value(t, len(reducer.args), 1)
	testing.expect_value(t, reducer.args[0].name, "name")
	defer delete(reducer.args)

	unit_reducer, unit_err := host.typed_reducer_definition(Typed_Descriptor_Unit, "init", .Init)
	testing.expect_value(t, unit_err, host.Codec_Error.None)
	testing.expect_value(t, len(unit_reducer.args), 0)

	procedure, procedure_err := host.typed_procedure_definition(
		Typed_Descriptor_Args,
		"lookup",
		type_info_of(u64),
		true,
	)
	testing.expect_value(t, procedure_err, host.Codec_Error.None)
	testing.expect_value(t, procedure.return_info, type_info_of(u64))
	testing.expect(t, procedure.private)
	defer delete(procedure.args)

	view, view_err := host.typed_view_definition(
		Typed_Descriptor_Args,
		Typed_Descriptor_Row,
		"by_name",
		true,
		"id",
	)
	testing.expect_value(t, view_err, host.Codec_Error.None)
	testing.expect_value(t, len(view.args), 1)
	testing.expect(t, view.is_anonymous)
	testing.expect_value(t, view.primary_key, "id")
	defer delete(view.args)
}

test_registered_reducer_handler :: proc(args: host.Bytes_Source, error: host.Bytes_Sink) -> i16 {
	_ = args
	_ = error
	return 17
}

@(test)
reducer_handlers_dispatch_by_definition_order :: proc(t: ^testing.T) {
	reducers := [?]host.Reducer_Definition{
		{name = "normal"},
		{name = "delivery_result", handler = test_registered_reducer_handler},
	}
	status, handled := host.dispatch_reducer_handler(1, reducers[:], host.INVALID_BYTES_SOURCE, host.INVALID_BYTES_SINK)
	testing.expect(t, handled)
	testing.expect_value(t, status, i16(17))
	_, unknown := host.dispatch_reducer_handler(2, reducers[:], host.INVALID_BYTES_SOURCE, host.INVALID_BYTES_SINK)
	testing.expect(t, !unknown)
}

@(test)
outbox_definition_maps_receiver_arguments_by_name_and_type :: proc(t: ^testing.T) {
	outbox_table, outbox_table_err := host.outbox_table(Outbox_Row, "box", []u16{0}, "box_by_id")
	testing.expect_value(t, outbox_table_err, host.Codec_Error.None)
	testing.expect_value(t, outbox_table.table_name, "box")
	testing.expect_value(t, outbox_table.unique_index_name, "box_by_id")
	testing.expect_value(t, len(outbox_table.auto_columns), 1)

	table, table_err := host.typed_table_definition(Outbox_Row, "box", .Public, []u16{0}, nil, nil)
	testing.expect_value(t, table_err, host.Codec_Error.None)
	defer host.delete_table_definition(table)
	table.auto_increment_columns = []u16{0}

	remote_args := [?]host.Reducer_Argument{{name = "score", info = type_info_of(u32)}}
	arg_columns: [1]u16
	signature_hash: [32]u8
	outbox, outbox_err := host.make_outbox_definition(
		table,
		"receive",
		"receiver",
		remote_args[:],
		arg_columns[:],
		signature_hash,
	)
	testing.expect_value(t, outbox_err, host.Outbox_Error.None)
	testing.expect_value(t, outbox.target_column, u16(1))
	testing.expect_value(t, outbox.arg_columns[0], u16(2))

	wrong_type := [?]host.Reducer_Argument{{name = "score", info = type_info_of(string)}}
	_, mismatch := host.make_outbox_definition(table, "receive", "receiver", wrong_type[:], arg_columns[:], signature_hash)
	testing.expect_value(t, mismatch, host.Outbox_Error.Argument_Type_Mismatch)
}

@(test)
outbox_result_arguments_describe_row_reference_and_result :: proc(t: ^testing.T) {
	arguments := host.outbox_result_arguments(Outbox_Row, "box")
	testing.expect_value(t, arguments[0].name, "row")
	testing.expect_value(t, arguments[0].table_ref, "box")
	testing.expect_value(t, arguments[1].name, "result")
	testing.expect(t, arguments[1].info == type_info_of(host.Outbox_Result))
	testing.expect(t, host.type_supported(type_info_of(host.Outbox_Result_Args(Outbox_Row))))

	buffer: [128]u8
	value := host.Outbox_Result_Args(Outbox_Row){
		row = Outbox_Row{id = 7, receiver = host.Identity{}, score = 9},
		result = host.Result_Err(string){"offline"},
	}
	encoded_len, encode_err := host.encode_row_into(host.Outbox_Result_Args(Outbox_Row), value, buffer[:])
	testing.expect_value(t, encode_err, host.Codec_Error.None)
	decoded, consumed, decode_err := host.decode_row_from(host.Outbox_Result_Args(Outbox_Row), buffer[:encoded_len])
	testing.expect_value(t, decode_err, host.Codec_Error.None)
	testing.expect_value(t, consumed, encoded_len)
	testing.expect_value(t, decoded.row.id, u64(7))
	result, is_err := decoded.result.(host.Result_Err(string))
	testing.expect(t, is_err)
	testing.expect_value(t, result.value, "offline")
	host.delete_decoded_row(host.Outbox_Result_Args(Outbox_Row), &decoded)
}

@(test)
index_bounds_encode_as_bsatn_bound_values :: proc(t: ^testing.T) {
	buffer: [16]u8
	writer := host.Byte_Writer{buffer = buffer[:]}
	testing.expect_value(t, host.encode_bound(&writer, host.bound_included(u32(5))), host.Codec_Error.None)
	testing.expect_value(t, host.encode_bound(&writer, host.bound_excluded(u32(7))), host.Codec_Error.None)
	testing.expect_value(t, host.encode_bound(&writer, host.bound_unbounded(u32)), host.Codec_Error.None)
	expected := []u8{0, 5, 0, 0, 0, 1, 7, 0, 0, 0, 2}
	testing.expect(t, slice.equal(buffer[:writer.offset], expected))
}

Circle :: struct {
	radius: u32,
}

Rect :: struct {
	width: u32,
	height: u32,
}

Label :: struct {
	text: string,
}

Nothing :: struct {}

Shape_Kind :: union #no_nil {
	Circle,
	Rect,
	Label,
	Nothing,
}

Drawing :: struct {
	kind: Shape_Kind,
	count: u8,
}

Unnamed_Variants :: union #no_nil {
	u32,
	string,
}

Bad_Drawing :: struct {
	kind: Unnamed_Variants,
}

Result_Row :: struct {
	value: host.Result(u32, string),
}

@(test)
sum_types_round_trip_every_variant_with_index_tags :: proc(t: ^testing.T) {
	buffer: [64]u8
	rect := Drawing{kind = Rect{3, 4}, count = 9}
	encoded_len, err := host.encode_row_into(Drawing, rect, buffer[:])
	testing.expect_value(t, err, host.Codec_Error.None)
	testing.expect(t, slice.equal(buffer[:encoded_len], []u8{1, 3, 0, 0, 0, 4, 0, 0, 0, 9}))
	decoded, consumed, decode_err := host.decode_row_from(Drawing, buffer[:encoded_len])
	testing.expect_value(t, decode_err, host.Codec_Error.None)
	testing.expect_value(t, consumed, encoded_len)
	decoded_rect, is_rect := decoded.kind.(Rect)
	testing.expect(t, is_rect)
	testing.expect_value(t, decoded_rect, Rect{3, 4})

	label := Drawing{kind = Label{"hi"}}
	label_len, label_err := host.encode_row_into(Drawing, label, buffer[:])
	testing.expect_value(t, label_err, host.Codec_Error.None)
	testing.expect_value(t, buffer[0], u8(2))
	owned, _, owned_err := host.decode_row_from(Drawing, buffer[:label_len])
	testing.expect_value(t, owned_err, host.Codec_Error.None)
	owned_label, is_label := owned.kind.(Label)
	testing.expect(t, is_label)
	testing.expect_value(t, owned_label.text, "hi")
	host.delete_decoded_row(Drawing, &owned)

	unit := Drawing{kind = Nothing{}}
	unit_len, unit_err := host.encode_row_into(Drawing, unit, buffer[:])
	testing.expect_value(t, unit_err, host.Codec_Error.None)
	testing.expect(t, slice.equal(buffer[:unit_len], []u8{3, 0}))

	invalid_tag := [2]u8{9, 0}
	_, _, invalid_err := host.decode_row_from(Drawing, invalid_tag[:])
	testing.expect_value(t, invalid_err, host.Codec_Error.Malformed_Data)
}

@(test)
sum_types_are_described_as_named_sums_and_need_named_variants :: proc(t: ^testing.T) {
	columns: [2]host.Reducer_Argument
	count, err := host.table_columns_into_type(Drawing, columns[:])
	testing.expect_value(t, err, host.Codec_Error.None)
	testing.expect_value(t, count, 2)

	kind_type, ok := host.encode_algebraic_type(columns[0].info)
	defer delete(kind_type)
	testing.expect(t, ok)
	testing.expect_value(t, kind_type[0], u8(1))
	testing.expect_value(t, kind_type[1], u8(4)) // four variants

	bad: [1]host.Reducer_Argument
	_, bad_err := host.table_columns_into_type(Bad_Drawing, bad[:])
	testing.expect_value(t, bad_err, host.Codec_Error.Unsupported_Type)
}

@(test)
result_types_round_trip_success_and_error_variants :: proc(t: ^testing.T) {
	buffer: [64]u8

	ok := Result_Row{value = host.Result_Ok(u32){42}}
	encoded_len, err := host.encode_row_into(Result_Row, ok, buffer[:])
	testing.expect_value(t, err, host.Codec_Error.None)
	testing.expect(t, slice.equal(buffer[:encoded_len], []u8{0, 42, 0, 0, 0}))
	decoded_ok, consumed_ok, decode_err_ok := host.decode_row_from(Result_Row, buffer[:encoded_len])
	testing.expect_value(t, decode_err_ok, host.Codec_Error.None)
	testing.expect_value(t, consumed_ok, encoded_len)
	ok_value, is_ok := decoded_ok.value.(host.Result_Ok(u32))
	testing.expect(t, is_ok)
	testing.expect_value(t, ok_value.value, u32(42))

	err_row := Result_Row{value = host.Result_Err(string){"denied"}}
	err_len, encode_err := host.encode_row_into(Result_Row, err_row, buffer[:])
	testing.expect_value(t, encode_err, host.Codec_Error.None)
	testing.expect(t, slice.equal(buffer[:err_len], []u8{1, 6, 0, 0, 0, 'd', 'e', 'n', 'i', 'e', 'd'}))
	decoded_err, consumed_err, decode_err := host.decode_row_from(Result_Row, buffer[:err_len])
	testing.expect_value(t, decode_err, host.Codec_Error.None)
	testing.expect_value(t, consumed_err, err_len)
	err_value, is_err := decoded_err.value.(host.Result_Err(string))
	testing.expect(t, is_err)
	testing.expect_value(t, err_value.value, "denied")
	host.delete_decoded_row(Result_Row, &decoded_err)

	columns: [1]host.Reducer_Argument
	column_count, schema_err := host.table_columns_into_type(Result_Row, columns[:])
	testing.expect_value(t, schema_err, host.Codec_Error.None)
	testing.expect_value(t, column_count, 1)
	result_type, schema_ok := host.encode_algebraic_type(columns[0].info)
	defer delete(result_type)
	testing.expect(t, schema_ok)
	expected_result_type := []u8{
		1, 2, 0, 0, 0,
		0, 2, 0, 0, 0, 'o', 'k', u8(host.Reducer_Argument_Type.U32),
		0, 3, 0, 0, 0, 'e', 'r', 'r', u8(host.Reducer_Argument_Type.String),
	}
	testing.expect_value(t, len(result_type), len(expected_result_type))
	for index in 0 ..< min(len(result_type), len(expected_result_type)) {
		testing.expect_value(t, result_type[index], expected_result_type[index])
	}

	outbox_result_type, outbox_result_ok := host.encode_algebraic_type(type_info_of(host.Outbox_Result))
	defer delete(outbox_result_type)
	testing.expect(t, outbox_result_ok)
	expected_outbox_result_type := []u8{
		1, 2, 0, 0, 0,
		0, 2, 0, 0, 0, 'o', 'k', 2, 0, 0, 0, 0,
		0, 3, 0, 0, 0, 'e', 'r', 'r', u8(host.Reducer_Argument_Type.String),
	}
	testing.expect_value(t, len(outbox_result_type), len(expected_outbox_result_type))
	for index in 0 ..< min(len(outbox_result_type), len(expected_outbox_result_type)) {
		testing.expect_value(t, outbox_result_type[index], expected_outbox_result_type[index])
	}
}

@(test)
schema_supports_types_nested_beyond_the_old_depth_limit :: proc(t: ^testing.T) {
	testing.expect(t, host.type_supported(type_info_of([][][][][][][][]u8)))
	too_deep := type_info_of([][][][][][][][][][][][][][][][][]u8)
	testing.expect(t, host.type_supported(too_deep))
}
