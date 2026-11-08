package main

import "core:fmt"
import "core:os"
import "core:time"
import "stdb:client"
import module_bindings "module_bindings"

fail :: proc(message: string) {
	fmt.eprintln(message)
	os.exit(1)
}

Event_State :: struct {
	selector: string,
	count: int,
	invalid: bool,
}

record_event :: proc(row: ^module_bindings.TestEvent, user: rawptr) {
	state := cast(^Event_State)user
	state.count += 1
	valid := false
	switch state.selector {
	case "event-table":
		valid = row.name == "odin-event" && row.value == 42
	case "multiple-events":
		valid = (row.name == "a" && row.value == 11) ||
			(row.name == "b" && row.value == 12) ||
			(row.name == "c" && row.value == 13)
	case "events-dont-persist":
		valid = row.name == "transient" && row.value == 1
	}
	if !valid do state.invalid = true
}

apply_message :: proc(cache: ^client.Cache, message: client.Message, state: ^Event_State) {
	changes: [dynamic]client.Row_Change
	defer delete(changes)
	client.cache_apply(cache, message, &changes)
	callbacks := module_bindings.Table_Callbacks{
		test_event = module_bindings.Test_Event_Handlers{on_insert = record_event},
	}
	module_bindings.dispatch_all(changes[:], callbacks, state)
}

await_subscription :: proc(connection: ^client.Connection, cache: ^client.Cache, state: ^Event_State, request_id: u32) {
	for _ in 0 ..< 20 {
		message, err := client.poll(connection, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("event subscription poll failed")
		apply_message(cache, message, state)
		if body, ok := message.body.(client.Subscribe_Applied); ok && body.request_id == request_id {
			client.message_destroy(&message)
			return
		}
		if _, failed := message.body.(client.Subscription_Error); failed do fail("event subscription rejected")
		client.message_destroy(&message)
	}
	fail("event subscription was not applied")
}

await_reducer :: proc(connection: ^client.Connection, cache: ^client.Cache, state: ^Event_State, request_id: u32) {
	for _ in 0 ..< 20 {
		message, err := client.poll(connection, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("event reducer poll failed")
		apply_message(cache, message, state)
		if body, ok := message.body.(client.Reducer_Result); ok && body.request_id == request_id {
			client.message_destroy(&message)
			if body.outcome != .Ok && body.outcome != .Ok_Empty do fail("event reducer failed")
			return
		}
		client.message_destroy(&message)
	}
	fail("event reducer result was not received")
}

main :: proc() {
	if len(os.args) != 2 do fail("expected one event test selector")
	server_url, server_found := os.lookup_env("SPACETIME_SDK_TEST_SERVER_URL", context.allocator)
	database, database_found := os.lookup_env("SPACETIME_SDK_TEST_DB_NAME", context.allocator)
	if !server_found || !database_found do fail("missing SDK test server environment")
	selector := os.args[1]
	state := Event_State{selector = selector}
	connection, connect_err := client.connect({host = server_url, database = database})
	if connect_err != .None do fail("event client connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	query_set_id := u32(1)
	request, subscribe_err := client.subscribe(&connection, query_set_id, {"SELECT * FROM test_event"})
	if subscribe_err != .None do fail("event subscription failed")
	await_subscription(&connection, &cache, &state, request)

	if selector == "event-table" {
		request, call_err := module_bindings.call_emit_test_event(&connection, "odin-event", 42)
		if call_err != .None do fail("event reducer call failed")
		await_reducer(&connection, &cache, &state, request)
		if state.count != 1 || state.invalid do fail("event row was not delivered")
		return
	}
	if selector == "multiple-events" {
		request, call_err := module_bindings.call_emit_multiple_test_events(&connection, 10)
		if call_err != .None do fail("multiple-events reducer call failed")
		await_reducer(&connection, &cache, &state, request)
		if state.count != 3 || state.invalid do fail("multiple event rows were not delivered")
		return
	}
	if selector == "events-dont-persist" {
		request, call_err := module_bindings.call_emit_test_event(&connection, "transient", 1)
		if call_err != .None do fail("event reducer call failed")
		await_reducer(&connection, &cache, &state, request)
		if state.count != 1 || state.invalid do fail("initial event was not delivered")
		noop_request, noop_err := module_bindings.call_noop(&connection, 1)
		if noop_err != .None do fail("noop reducer call failed")
		await_reducer(&connection, &cache, &state, noop_request)
		if state.count != 1 do fail("event row was replayed on a later transaction")
		return
	}
	fail("unknown event test selector")
}
