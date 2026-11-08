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

await_subscription :: proc(connection: ^client.Connection, cache: ^client.Cache, request_id: u32) {
	for _ in 0 ..< 20 {
		message, err := client.poll(connection, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("subscription poll failed")
		client.cache_apply(cache, message)
		if body, ok := message.body.(client.Subscribe_Applied); ok && body.request_id == request_id {
			client.message_destroy(&message)
			return
		}
		if _, failed := message.body.(client.Subscription_Error); failed do fail("subscription rejected")
		client.message_destroy(&message)
	}
	fail("subscription was not applied")
}

lifecycle_counts :: proc(cache: ^client.Cache) -> (int, int) {
	connected, connected_err := module_bindings.connected_rows(cache)
	if connected_err != .None do fail("connected cache decode failed")
	defer client.delete_rows(connected)
	disconnected, disconnected_err := module_bindings.disconnected_rows(cache)
	if disconnected_err != .None do fail("disconnected cache decode failed")
	defer client.delete_rows(disconnected)
	return len(connected), len(disconnected)
}

main :: proc() {
	if len(os.args) != 1 do fail("unexpected connect/disconnect arguments")
	server_url, server_found := os.lookup_env("SPACETIME_SDK_TEST_SERVER_URL", context.allocator)
	database, database_found := os.lookup_env("SPACETIME_SDK_TEST_DB_NAME", context.allocator)
	if !server_found || !database_found do fail("missing SDK test server environment")

	first, first_err := client.connect({host = server_url, database = database})
	if first_err != .None do fail("first connection failed")
	first_cache: client.Cache
	first_subscription, first_subscribe_err := client.subscribe(&first, 1, {"SELECT * FROM connected"})
	if first_subscribe_err != .None do fail("first subscription failed")
	await_subscription(&first, &first_cache, first_subscription)
	connected_count, _ := lifecycle_counts(&first_cache)
	if connected_count < 1 do fail("connect lifecycle row was not observed")
	client.disconnect(&first)
	client.cache_destroy(&first_cache)

	second, second_err := client.connect({host = server_url, database = database})
	if second_err != .None do fail("reconnection failed")
	defer client.disconnect(&second)
	second_cache: client.Cache
	defer client.cache_destroy(&second_cache)
	connected_subscription, connected_err := client.subscribe(&second, 2, {"SELECT * FROM connected"})
	if connected_err != .None do fail("connected subscription failed")
	disconnected_subscription, disconnected_err := client.subscribe(&second, 3, {"SELECT * FROM disconnected"})
	if disconnected_err != .None do fail("disconnected subscription failed")
	await_subscription(&second, &second_cache, connected_subscription)
	await_subscription(&second, &second_cache, disconnected_subscription)

	for _ in 0 ..< 20 {
		connected_count, disconnected_count := lifecycle_counts(&second_cache)
		if connected_count >= 2 && disconnected_count >= 1 do return
		message, poll_err := client.poll(&second, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("lifecycle poll failed")
		client.cache_apply(&second_cache, message)
		client.message_destroy(&message)
	}
	fail("connect/disconnect lifecycle rows were incomplete")
}
