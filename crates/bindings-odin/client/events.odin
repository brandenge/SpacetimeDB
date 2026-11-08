package client

import "base:runtime"
import "core:strings"
import "stdb:host"

Row_Change_Kind :: enum u8 {
	Insert,
	Delete,
}

// Rows are BSATN bytes that borrow the polled message; use them before message_destroy.
Row_Change :: struct {
	table: string,
	kind: Row_Change_Kind,
	row: []u8,
}

Row_Change_Listener_Id :: distinct u64
Row_Change_Event_Callback :: proc(change: Row_Change, user: rawptr)
Row_Change_Event_Destroy :: proc(user: rawptr)

Row_Change_Listener :: struct {
	id: Row_Change_Listener_Id,
	callback: Row_Changes_Callback,
	event_callback: Row_Change_Event_Callback,
	table: string,
	kind: Row_Change_Kind,
	user: rawptr,
	destroy_user: Row_Change_Event_Destroy,
}

Row_Change_Listener_Registry :: struct {
	next_id: u64,
	dispatch_depth: int,
	destroy_pending: bool,
	entries: [dynamic]Row_Change_Listener,
	removed_entries: [dynamic]Row_Change_Listener,
}

row_change_listener_add :: proc(
	registry: ^Row_Change_Listener_Registry,
	callback: Row_Changes_Callback,
	user: rawptr = nil,
) -> (id: Row_Change_Listener_Id, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	if registry == nil || registry.destroy_pending || callback == nil do return 0, .Invalid_Argument
	registry.next_id += 1
	if registry.next_id == 0 do registry.next_id = 1
	for entry in registry.entries {
		if entry.id == Row_Change_Listener_Id(registry.next_id) do return 0, .Invalid_Argument
	}
	id = Row_Change_Listener_Id(registry.next_id)
	append(&registry.entries, Row_Change_Listener{id = id, callback = callback, user = user})
	return id, .None
}

row_change_event_listener_add :: proc(
	registry: ^Row_Change_Listener_Registry,
	table: string,
	kind: Row_Change_Kind,
	callback: Row_Change_Event_Callback,
	user: rawptr = nil,
	destroy_user: Row_Change_Event_Destroy = nil,
) -> (id: Row_Change_Listener_Id, err: Error) {
	when ODIN_OS == .JS do context = runtime.default_context()
	if registry == nil || registry.destroy_pending || callback == nil || len(table) == 0 do return 0, .Invalid_Argument
	registry.next_id += 1
	if registry.next_id == 0 do registry.next_id = 1
	for entry in registry.entries {
		if entry.id == Row_Change_Listener_Id(registry.next_id) do return 0, .Invalid_Argument
	}
	id = Row_Change_Listener_Id(registry.next_id)
	append(&registry.entries, Row_Change_Listener{
		id = id,
		event_callback = callback,
		table = strings.clone(table),
		kind = kind,
		user = user,
		destroy_user = destroy_user,
	})
	return id, .None
}

row_change_listener_remove :: proc(
	registry: ^Row_Change_Listener_Registry,
	id: Row_Change_Listener_Id,
) -> bool {
	when ODIN_OS == .JS do context = runtime.default_context()
	if registry == nil do return false
	for entry, index in registry.entries {
		if entry.id != id do continue
		removed := entry
		ordered_remove(&registry.entries, index)
		if registry.dispatch_depth > 0 {
			append(&registry.removed_entries, removed)
		} else {
			row_change_listener_destroy_entry(removed)
		}
		return true
	}
	return false
}

row_change_listener_registry_destroy :: proc(registry: ^Row_Change_Listener_Registry) {
	when ODIN_OS == .JS do context = runtime.default_context()
	if registry == nil do return
	if registry.dispatch_depth > 0 {
		append(&registry.removed_entries, ..registry.entries[:])
		delete(registry.entries)
		registry.entries = nil
		registry.destroy_pending = true
		return
	}
	for entry in registry.entries do row_change_listener_destroy_entry(entry)
	for entry in registry.removed_entries do row_change_listener_destroy_entry(entry)
	delete(registry.entries)
	delete(registry.removed_entries)
	registry^ = {}
}

@(private)
row_change_listener_destroy_entry :: proc(entry: Row_Change_Listener) {
	if entry.destroy_user != nil do entry.destroy_user(entry.user)
	delete(entry.table)
}

// Set as Connect_Options.on_row_changes. Listener changes during dispatch take effect next poll.
dispatch_row_change_listeners :: proc(changes: []Row_Change, user: rawptr) {
	when ODIN_OS == .JS do context = runtime.default_context()
	registry := cast(^Row_Change_Listener_Registry)user
	if registry == nil do return
	registry.dispatch_depth += 1
	listeners := make([]Row_Change_Listener, len(registry.entries), context.allocator)
	copy(listeners, registry.entries[:])
	for &listener in listeners {
		if listener.event_callback != nil do listener.table = strings.clone(listener.table, context.temp_allocator)
	}
	for listener in listeners {
		if listener.callback != nil do listener.callback(changes, listener.user)
		if listener.event_callback != nil {
			for change in changes {
				if change.table == listener.table && change.kind == listener.kind {
					listener.event_callback(change, listener.user)
				}
			}
		}
	}
	delete(listeners)
	registry.dispatch_depth -= 1
	if registry.dispatch_depth == 0 {
		for entry in registry.removed_entries do row_change_listener_destroy_entry(entry)
		delete(registry.removed_entries)
		registry.removed_entries = nil
		if registry.destroy_pending {
			delete(registry.entries)
			registry^ = {}
		}
	}
}

Table_Handlers :: struct($Row: typeid) {
	on_insert: proc(row: ^Row, user: rawptr),
	on_delete: proc(row: ^Row, user: rawptr),
	on_update: proc(old: ^Row, new: ^Row, user: rawptr), // only used by dispatch_keyed_changes
}

// Decodes the changes for one table and calls the matching handlers; rows are freed after each call.
dispatch_changes :: proc(changes: []Row_Change, table: string, handlers: Table_Handlers($Row), user: rawptr) {
	for change in changes {
		if change.table != table do continue
		row, consumed, err := host.decode_row_from(Row, change.row)
		if err != .None || consumed != len(change.row) {
			host.delete_decoded_row(Row, &row)
			continue
		}
		defer host.delete_decoded_row(Row, &row)
		switch change.kind {
		case .Insert:
			if handlers.on_insert != nil do handlers.on_insert(&row, user)
		case .Delete:
			if handlers.on_delete != nil do handlers.on_delete(&row, user)
		}
	}
}

// Like dispatch_changes, but a delete and an insert with the same primary key in one batch become on_update.
dispatch_keyed_changes :: proc(
	changes: []Row_Change,
	table: string,
	handlers: Table_Handlers($Row),
	user: rawptr,
	key_of: proc(row: ^Row) -> $Key,
) {
	Pending :: struct {
		row: Row,
		matched: bool,
	}
	inserted := make(map[Key]int, allocator = context.temp_allocator)
	pending := make([dynamic]Pending, allocator = context.temp_allocator)
	defer for &entry in pending do host.delete_decoded_row(Row, &entry.row)

	for change in changes {
		if change.table != table || change.kind != .Insert do continue
		row, consumed, err := host.decode_row_from(Row, change.row)
		if err != .None || consumed != len(change.row) {
			host.delete_decoded_row(Row, &row)
			continue
		}
		inserted[key_of(&row)] = len(pending)
		append(&pending, Pending{row = row})
	}
	for change in changes {
		if change.table != table || change.kind != .Delete do continue
		old, consumed, err := host.decode_row_from(Row, change.row)
		if err != .None || consumed != len(change.row) {
			host.delete_decoded_row(Row, &old)
			continue
		}
		defer host.delete_decoded_row(Row, &old)
		if index, found := inserted[key_of(&old)]; found && !pending[index].matched {
			pending[index].matched = true
			if handlers.on_update != nil do handlers.on_update(&old, &pending[index].row, user)
		} else if handlers.on_delete != nil {
			handlers.on_delete(&old, user)
		}
	}
	for &entry in pending {
		if !entry.matched && handlers.on_insert != nil do handlers.on_insert(&entry.row, user)
	}
}
