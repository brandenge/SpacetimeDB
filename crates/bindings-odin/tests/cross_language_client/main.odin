package main

import "core:fmt"
import "core:os"
import "core:time"
import "stdb:client"
import "stdb:host"
import bindings "module_bindings"

fail :: proc(message: string) {
	fmt.eprintln(message)
	os.exit(1)
}

main :: proc() {
	if len(os.args) != 3 do fail("expected server URL and database")
	connection, err := client.connect({host = os.args[1], database = os.args[2]})
	if err != .None do fail("connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)

	subscription, subscribe_err := client.subscribe(&connection, 1, {"SELECT * FROM person"})
	if subscribe_err != .None do fail("subscription failed")
	applied := false
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(&connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None {
			fmt.eprintln("subscription poll failed:", poll_err)
			os.exit(1)
		}
		client.cache_apply(&cache, message)
		if body, ok := message.body.(client.Subscribe_Applied); ok && body.request_id == subscription do applied = true
		if _, failed := message.body.(client.Subscription_Error); failed do fail("subscription rejected")
		client.message_destroy(&message)
		if applied do break
	}
	if !applied do fail("subscription was not applied")

	request, call_err := bindings.call_add(&connection, "odin-parity", 7)
	if call_err != .None do fail("reducer call failed")
	completed, found := false, false
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(&connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None {
			fmt.eprintln("reducer poll failed:", poll_err)
			os.exit(1)
		}
		client.cache_apply(&cache, message)
		if body, ok := message.body.(client.Reducer_Result); ok && body.request_id == request {
			if body.outcome != .Ok && body.outcome != .Ok_Empty do fail("reducer rejected")
			completed = true
		}
		client.message_destroy(&message)
		rows, decode_err := bindings.person_rows(&cache)
		if decode_err != .None do fail("cache decode failed")
		for row in rows do if row.name == "odin-parity" && row.age == 7 do found = true
		client.delete_rows(rows)
		if completed && found do break
	}
	if !completed || !found do fail("reducer update missing from cache")

	rows, range_err := bindings.person_cache_range_age(&cache, 7, .Inclusive, 7, .Inclusive)
	if range_err != .None do fail("cache range failed")
	defer client.delete_rows(rows)
	for row in rows {
		if row.name != "odin-parity" do continue
		indexed, exists, lookup_err := bindings.person_cache_by_id(&cache, row.id)
		if lookup_err != .None || !exists do fail("primary-key lookup failed")
		defer host.delete_decoded_row(bindings.Person, &indexed)
		if indexed.name != row.name do fail("primary-key lookup returned wrong row")
		return
	}
	fail("cache range did not contain the inserted row")
}
