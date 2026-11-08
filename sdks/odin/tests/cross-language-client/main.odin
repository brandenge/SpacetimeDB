package main

import "core:fmt"
import "core:os"
import "core:time"
import "stdb:client"
import "stdb:host"
import module_bindings "module_bindings:."

One_U8_Row :: struct {
	n: u8,
}

Insert_One_U8_Args :: struct {
	n: u8,
}

fail :: proc(message: string) {
	fmt.eprintln(message)
	os.exit(1)
}

main :: proc() {
	if len(os.args) != 5 || os.args[1] != "insert-primitive" do fail("expected selector, module language, table, and reducer")
	server_url, server_found := os.lookup_env("SPACETIME_SDK_TEST_SERVER_URL", context.allocator)
	database, database_found := os.lookup_env("SPACETIME_SDK_TEST_DB_NAME", context.allocator)
	if !server_found || !database_found do fail("missing SDK test server environment")
	connection, connect_err := client.connect({host = server_url, database = database})
	if connect_err != .None do fail("cross-language connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	_ = module_bindings.SUBSCRIBE_ALL_QUERIES
	table_name := os.args[3]
	query := fmt.tprintf("SELECT * FROM %s", table_name)
	subscription, subscribe_err := client.subscribe(&connection, 1, {query})
	if subscribe_err != .None do fail("one_u8 subscription failed")
	subscription_applied := false
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(&connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("one_u8 subscription poll failed")
		client.cache_apply(&cache, message)
		if applied, ok := message.body.(client.Subscribe_Applied); ok && applied.request_id == subscription do subscription_applied = true
		client.message_destroy(&message)
		if subscription_applied do break
	}
	if !subscription_applied do fail("one_u8 subscription was not applied")
	request, call_err := client.call_reducer(&connection, os.args[4], Insert_One_U8_Args{n = 42})
	if call_err != .None do fail("insert_one_u8 reducer call failed")
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(&connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("insert_one_u8 reducer poll failed")
		client.cache_apply(&cache, message)
		if result, ok := message.body.(client.Reducer_Result); ok && result.request_id == request {
			if result.outcome != .Ok && result.outcome != .Ok_Empty {
				fmt.eprintln("insert_one_u8 outcome: ", result.outcome, " message: ", result.message)
				fail("insert_one_u8 reducer failed")
			}
			client.message_destroy(&message)
			rows, decode_err := client.cache_rows(&cache, table_name, One_U8_Row)
			if decode_err != .None do fail("one_u8 cache decode failed")
			defer client.delete_rows(rows)
			if len(rows) != 1 || rows[0].n != 42 do fail("cross-language one_u8 roundtrip mismatch")
			return
		}
		client.message_destroy(&message)
	}
	fail("insert_one_u8 reducer result was not received")
}
