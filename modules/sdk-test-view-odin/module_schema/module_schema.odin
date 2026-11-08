package module_schema

import "base:runtime"
import "stdb:host"

No_Args :: struct {}

Player :: struct {
	id: u64,
	owner: host.Identity,
	name: string,
	score: u64,
}

Player_Summary :: struct {
	id: u64,
	owner: host.Identity,
	score: u64,
}

Insert_Player_Args :: struct {
	id: u64,
	name: string,
	score: u64,
}

Update_Player_Args :: struct {
	id: u64,
	score: u64,
}

Delete_Player_Args :: struct {
	id: u64,
}

write_module_definition :: proc(description: host.Bytes_Sink) -> (host.Status, bool) {
	context = host.scratch_context()
	reducers: [dynamic]host.Reducer_Definition
	defer for reducer in reducers do delete(reducer.args)
	reducer, reducer_err := host.typed_reducer_definition(Insert_Player_Args, "insert_player", .None, private = false)
	if reducer_err != .None do return host.Status(0), false
	append(&reducers, reducer)
	update_reducer, update_reducer_err := host.typed_reducer_definition(Update_Player_Args, "update_player", .None, private = false)
	if update_reducer_err != .None do return host.Status(0), false
	append(&reducers, update_reducer)
	disconnect_reducer, disconnect_reducer_err := host.typed_reducer_definition(No_Args, "disconnect_player", .On_Disconnect, private = true)
	if disconnect_reducer_err != .None do return host.Status(0), false
	append(&reducers, disconnect_reducer)
	delete_reducer, delete_reducer_err := host.typed_reducer_definition(Delete_Player_Args, "delete_player", .None, private = false)
	if delete_reducer_err != .None do return host.Status(0), false
	append(&reducers, delete_reducer)
	tables: [dynamic]host.Table_Definition
	defer for table in tables do host.delete_table_definition(table)
	index_columns := [?]u16{0}
	index := host.Table_Index{source_name = "players_id_idx_btree", accessor_name = "by_id", algorithm = .BTree, columns = index_columns[:]}
	indexes := [?]host.Table_Index{index}
	unique := host.Unique_Constraint{columns = index_columns[:]}
	unique_constraints := [?]host.Unique_Constraint{unique}
	table, table_err := host.typed_table_definition(Player, "players", .Public, []u16{0}, indexes[:], unique_constraints[:])
	if table_err != .None do return host.Status(0), false
	append(&tables, table)
	procedures: [dynamic]host.Procedure_Definition
	defer for procedure in procedures do delete(procedure.args)
	views: [dynamic]host.View_Definition
	defer for view in views do delete(view.args)
	view, view_err := host.typed_view_definition(No_Args, Player, "all_players", is_anonymous = true)
	if view_err != .None do return host.Status(0), false
	view.return_kind = .Query
	append(&views, view)
	players_view, players_view_err := host.typed_view_definition(No_Args, Player, "my_players", primary_key = "id")
	if players_view_err != .None do return host.Status(0), false
	append(&views, players_view)
	summary_view, summary_view_err := host.typed_view_definition(No_Args, Player_Summary, "my_player_summary", primary_key = "id")
	if summary_view_err != .None do return host.Status(0), false
	append(&views, summary_view)
	handlers: []string = nil
	routes: [dynamic]host.Http_Route
	environment: [dynamic]host.Environment_Definition
	return host.write_module_def_all(description, reducers[:], tables[:], views[:], procedures[:], handlers[:], routes[:], environment[:])
}
