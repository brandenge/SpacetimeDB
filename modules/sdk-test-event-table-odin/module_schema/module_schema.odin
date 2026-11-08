package module_schema

import "base:runtime"
import "stdb:host"

Test_Event :: struct {
	name: string,
	value: u64,
}

Emit_Event_Args :: struct {
	name: string,
	value: u64,
}

Emit_Multiple_Args :: struct {
	seed: u64,
}

Noop_Args :: struct {
	marker: u64,
}

write_module_definition :: proc(description: host.Bytes_Sink) -> (host.Status, bool) {
	context = host.scratch_context()
	reducers: [dynamic]host.Reducer_Definition
	defer for reducer in reducers do delete(reducer.args)
	one, one_err := host.typed_reducer_definition(Emit_Event_Args, "emit_test_event", .None, private = false)
	if one_err != .None do return host.Status(0), false
	append(&reducers, one)
	many, many_err := host.typed_reducer_definition(Emit_Multiple_Args, "emit_multiple_test_events", .None, private = false)
	if many_err != .None do return host.Status(0), false
	append(&reducers, many)
	noop, noop_err := host.typed_reducer_definition(Noop_Args, "noop", .None, private = false)
	if noop_err != .None do return host.Status(0), false
	append(&reducers, noop)
	tables: [dynamic]host.Table_Definition
	defer for table in tables do host.delete_table_definition(table)
	table, table_err := host.typed_table_definition(Test_Event, "test_event", .Public, nil, nil, nil)
	if table_err != .None do return host.Status(0), false
	table.is_event = true
	append(&tables, table)
	procedures: [dynamic]host.Procedure_Definition
	defer for procedure in procedures do delete(procedure.args)
	views: [dynamic]host.View_Definition
	defer for view in views do delete(view.args)
	handlers: []string = nil
	routes: [dynamic]host.Http_Route
	environment: [dynamic]host.Environment_Definition
	return host.write_module_def_all(description, reducers[:], tables[:], views[:], procedures[:], handlers[:], routes[:], environment[:])
}
