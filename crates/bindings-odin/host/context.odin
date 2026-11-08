package host

Identity :: distinct U256
Connection_Id :: distinct u128
Timestamp :: distinct i64 // microseconds since the Unix epoch
Time_Duration :: distinct i64 // microseconds

Reducer_Context :: struct {
	env: Environment,
	sender: Identity,
	connection_id: Connection_Id,
	has_connection_id: bool, // false for calls without a client connection, e.g. scheduled reducers
	timestamp: Timestamp,
	rng_state: Uuid_Rng_State,
	uuid_counter: u32,
}

Procedure_Context :: Reducer_Context

// Rebuilds the context from the raw __call_reducer__ arguments, which carry little-endian u64 limbs.
reducer_context :: proc "contextless" (
	sender_0, sender_1, sender_2, sender_3: u64,
	conn_id_0, conn_id_1: u64,
	timestamp: u64,
) -> Reducer_Context {
	result: Reducer_Context
	limbs := [4]u64{sender_0, sender_1, sender_2, sender_3}
	sender: [32]u8
	for limb, limb_index in limbs {
		for byte_index in 0 ..< 8 do sender[limb_index * 8 + byte_index] = u8(limb >> u64(byte_index * 8))
	}
	result.sender = Identity(U256(sender))
	result.connection_id = Connection_Id(u128(conn_id_0) | u128(conn_id_1) << 64)
	result.has_connection_id = conn_id_0 != 0 || conn_id_1 != 0
	result.timestamp = Timestamp(i64(timestamp))
	result.rng_state = uuid_rng_from_seed(timestamp)
	return result
}

// Rebuilds the procedure caller and execution context from __call_procedure__ arguments.
procedure_context :: proc "contextless" (
	sender_0, sender_1, sender_2, sender_3: u64,
	conn_id_0, conn_id_1: u64,
	timestamp: u64,
) -> Procedure_Context {
	return reducer_context(sender_0, sender_1, sender_2, sender_3, conn_id_0, conn_id_1, timestamp)
}

context_procedure_sleep_until :: proc(ctx: ^Procedure_Context, wake_at: Timestamp) {
	ctx.timestamp = Timestamp(procedure_sleep_until(i64(wake_at)))
}

// Fills bytes from the deterministic ChaCha12 stream seeded by the invocation timestamp.
context_random_bytes :: proc(ctx: ^Reducer_Context, output: []u8) {
	uuid_rng_fill(&ctx.rng_state, output)
}

context_random_u64 :: proc(ctx: ^Reducer_Context) -> u64 {
	bytes: [8]u8
	context_random_bytes(ctx, bytes[:])
	value: u64
	for byte, index in bytes do value |= u64(byte) << u64(index * 8)
	return value
}

context_new_uuid_v4 :: proc(ctx: ^Reducer_Context) -> u128 {
	bytes: [16]u8
	context_random_bytes(ctx, bytes[:])
	bytes[6] = bytes[6] & 0x0f | 0x40
	bytes[8] = bytes[8] & 0x3f | 0x80
	return uuid_from_bytes(bytes)
}

context_new_uuid_v7 :: proc(ctx: ^Reducer_Context) -> (uuid: u128, err: Uuid_Generation_Error) {
	if i64(ctx.timestamp) < 0 do return 0, .Timestamp_Before_Unix_Epoch
	random_bytes: [4]u8
	context_random_bytes(ctx, random_bytes[:])
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

// Returns the identity of the current database module.
database_identity :: proc "contextless" () -> Identity {
	bytes: [32]u8
	identity(raw_data(bytes[:]))
	return Identity(U256(bytes))
}

Schedule_At_Kind :: enum u8 {
	Interval,
	Time,
}

// Encodes like the server's ScheduleAt sum: a variant tag followed by microseconds.
Schedule_At :: struct {
	kind: Schedule_At_Kind,
	micros: i64,
}

schedule_every :: proc "contextless" (interval: Time_Duration) -> Schedule_At {
	return Schedule_At{kind = .Interval, micros = i64(interval)}
}

schedule_at_time :: proc "contextless" (time: Timestamp) -> Schedule_At {
	return Schedule_At{kind = .Time, micros = i64(time)}
}

// Return the result from __call_reducer__ to abort the transaction; clients receive message as a string error.
reducer_fail :: proc "contextless" (error: Bytes_Sink, message: string) -> i16 {
	_, _ = write_all(error, transmute([]u8)message)
	return 1
}

VIEW_ABI_RESULT :: i16(2) // return code announcing the header-prefixed result format

// Writes a Vec<Row> result; the view export must then return VIEW_ABI_RESULT.
write_view_rows :: proc($Row: typeid, sink: Bytes_Sink, rows: []Row, buffer: []u8) -> Codec_Error {
	header := [5]u8{0, u8(len(rows)), u8(len(rows) >> 8), u8(len(rows) >> 16), u8(len(rows) >> 24)}
	if _, complete := write_all(sink, header[:]); !complete do return .Host_Read_Failed
	for row in rows {
		encoded_len, err := encode_row_into(Row, row, buffer)
		if err != .None do return err
		if _, complete := write_all(sink, buffer[:encoded_len]); !complete do return .Host_Read_Failed
	}
	return .None
}

write_view_query :: proc "contextless" (sink: Bytes_Sink, sql: string) -> (Status, bool) {
	status, complete := write_all(sink, []u8{1})
	if status != Status(0) || !complete do return status, false
	return write_string(sink, sql)
}

procedure_start_tx :: proc "contextless" () -> (Timestamp, Status) {
	micros: i64
	status := procedure_start_mut_tx(&micros)
	return Timestamp(micros), status
}

procedure_commit_tx :: proc "contextless" () -> Status {
	return procedure_commit_mut_tx()
}

procedure_abort_tx :: proc "contextless" () -> Status {
	return procedure_abort_mut_tx()
}

// Procedures write their BSATN return value to the sink and always return 0 from __call_procedure__.
write_procedure_result :: proc($T: typeid, sink: Bytes_Sink, value: T, buffer: []u8) -> Codec_Error {
	encoded_len, err := encode_row_into(T, value, buffer)
	if err != .None do return err
	if _, complete := write_all(sink, buffer[:encoded_len]); !complete do return .Host_Read_Failed
	return .None
}
