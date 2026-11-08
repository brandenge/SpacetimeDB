package module_schema

import "base:runtime"
import "stdb:host"

No_Args :: struct {}

Connected :: struct {
	identity: host.Identity,
}

Disconnected :: struct {
	identity: host.Identity,
}

write_module_definition :: proc(description: host.Bytes_Sink) -> (host.Status, bool) {
	context = host.scratch_context()
	reducers: [dynamic]host.Reducer_Definition
	defer for reducer in reducers do delete(reducer.args)
	connected_reducer, connected_err := host.typed_reducer_definition(No_Args, "identity_connected", .On_Connect, private = true)
	if connected_err != .None do return host.Status(0), false
	append(&reducers, connected_reducer)
	disconnected_reducer, disconnected_err := host.typed_reducer_definition(No_Args, "identity_disconnected", .On_Disconnect, private = true)
	if disconnected_err != .None do return host.Status(0), false
	append(&reducers, disconnected_reducer)
	tables: [dynamic]host.Table_Definition
	defer for table in tables do host.delete_table_definition(table)
	connected_table, connected_table_err := host.typed_table_definition(Connected, "connected", .Public, nil, nil, nil)
	if connected_table_err != .None do return host.Status(0), false
	append(&tables, connected_table)
	disconnected_table, disconnected_table_err := host.typed_table_definition(Disconnected, "disconnected", .Public, nil, nil, nil)
	if disconnected_table_err != .None do return host.Status(0), false
	append(&tables, disconnected_table)
	procedures: [dynamic]host.Procedure_Definition
	defer for procedure in procedures do delete(procedure.args)
	views: [dynamic]host.View_Definition
	defer for view in views do delete(view.args)
	handlers: []string = nil
	routes: [dynamic]host.Http_Route
	environment: [dynamic]host.Environment_Definition
	return host.write_module_def_all(description, reducers[:], tables[:], views[:], procedures[:], handlers[:], routes[:], environment[:])
}
