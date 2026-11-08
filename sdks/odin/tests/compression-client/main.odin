package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"
import "stdb:client"
import module_bindings "module_bindings"

fail :: proc(message: string) {
	fmt.eprintln(message)
	os.exit(1)
}

connect_and_subscribe :: proc(server_url, database: string, compression: client.Compression, query_set_id: u32) -> (client.Connection, client.Cache) {
	connection, connect_err := client.connect({host = server_url, database = database, compression = compression})
	if connect_err != .None do fail("compression client connection failed")
	cache: client.Cache
	request, subscribe_err := client.subscribe(&connection, query_set_id, {"SELECT * FROM test_vectors"})
	if subscribe_err != .None do fail("compression subscription failed")
	for _ in 0 ..< 20 {
		message, err := client.poll(&connection, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("compression subscription poll failed")
		client.cache_apply(&cache, message)
		if body, ok := message.body.(client.Subscribe_Applied); ok && body.request_id == request {
			client.message_destroy(&message)
			return connection, cache
		}
		if _, failed := message.body.(client.Subscription_Error); failed do fail("compression subscription rejected")
		client.message_destroy(&message)
	}
	fail("compression subscription was not applied")
	return {}, {}
}

wait_for_vector :: proc(connection: ^client.Connection, cache: ^client.Cache, expected: []i32) {
	for _ in 0 ..< 20 {
		rows, decode_err := module_bindings.test_vectors_rows(cache)
		if decode_err != .None do fail("compressed vector cache decode failed")
		for row in rows {
			if row.id != 313 do continue
			if !slice.equal(row.values, expected) do fail("compressed vector bytes changed")
			client.delete_rows(rows)
			return
		}
		client.delete_rows(rows)
		message, poll_err := client.poll(connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("compressed vector poll failed")
		client.cache_apply(cache, message)
		client.message_destroy(&message)
	}
	fail("compressed vector update was not received")
}

main :: proc() {
	if len(os.args) != 2 || os.args[1] != "two-different-compression-algos" do fail("expected compression test selector")
	server_url, server_found := os.lookup_env("SPACETIME_SDK_TEST_SERVER_URL", context.allocator)
	database, database_found := os.lookup_env("SPACETIME_SDK_TEST_DB_NAME", context.allocator)
	if !server_found || !database_found do fail("missing SDK test server environment")
	brotli, brotli_cache := connect_and_subscribe(server_url, database, .Brotli, 1)
	defer client.disconnect(&brotli)
	defer client.cache_destroy(&brotli_cache)
	gzip, gzip_cache := connect_and_subscribe(server_url, database, .Gzip, 2)
	defer client.disconnect(&gzip)
	defer client.cache_destroy(&gzip_cache)
	plain, plain_cache := connect_and_subscribe(server_url, database, .None, 3)
	defer client.disconnect(&plain)
	defer client.cache_destroy(&plain_cache)
	expected := make([]i32, 8192)
	state: u32 = 0x1234_5678
	for &value in expected {
		state = state * 1_664_525 + 1_013_904_223
		value = i32(state)
	}
	defer delete(expected)
	request, call_err := module_bindings.call_record_vector(&plain, 313, expected)
	if call_err != .None do fail("plain reducer call failed")
	for _ in 0 ..< 20 {
		message, err := client.poll(&plain, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("plain reducer poll failed")
		client.cache_apply(&plain_cache, message)
		if result, ok := message.body.(client.Reducer_Result); ok && result.request_id == request {
			client.message_destroy(&message)
			if result.outcome != .Ok && result.outcome != .Ok_Empty do fail("plain reducer failed")
			break
		}
		client.message_destroy(&message)
	}
	wait_for_vector(&plain, &plain_cache, expected)
	wait_for_vector(&brotli, &brotli_cache, expected)
	wait_for_vector(&gzip, &gzip_cache, expected)
}
