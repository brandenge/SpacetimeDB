package module_schema

import "stdb:host"

@(export, link_name = "__describe_module__")
describe_module :: proc "c" (description: host.Bytes_Sink) {
	context = host.scratch_context()
	_, _ = write_module_definition(description)
}

@(export, link_name = "__call_reducer__")
call_reducer :: proc "c" (
	id: uint,
	sender_0, sender_1, sender_2, sender_3: u64,
	conn_id_0, conn_id_1: u64,
	timestamp: u64,
	args: host.Bytes_Source,
	error: host.Bytes_Sink,
) -> i16 {
	context = host.scratch_context()
	caller := host.reducer_context(sender_0, sender_1, sender_2, sender_3, conn_id_0, conn_id_1, timestamp)
	if id == 0 {
		_ = args
		return handle_identity_connected_reducer(caller, No_Args{}, error)
	}
	if id == 1 {
		_ = args
		return handle_identity_disconnected_reducer(caller, No_Args{}, error)
	}
	return host.reducer_fail(error, "unknown reducer id")
}
