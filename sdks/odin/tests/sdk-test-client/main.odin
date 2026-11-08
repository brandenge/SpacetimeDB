package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:time"
import "stdb:client"
import "stdb:host"
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

await_reducer :: proc(connection: ^client.Connection, cache: ^client.Cache, request_id: u32) {
	for _ in 0 ..< 20 {
		message, err := client.poll(connection, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("reducer poll failed")
		client.cache_apply(cache, message)
		if body, ok := message.body.(client.Reducer_Result); ok && body.request_id == request_id {
			if body.outcome != .Ok && body.outcome != .Ok_Empty {
				fmt.eprintln("reducer failed: ", body.outcome, " ", body.message, " ", string(body.return_value))
				os.exit(1)
			}
			client.message_destroy(&message)
			return
		}
		client.message_destroy(&message)
	}
	fail("reducer result was not received")
}

await_reducer_error :: proc(connection: ^client.Connection, cache: ^client.Cache, request_id: u32) {
	for _ in 0 ..< 20 {
		message, err := client.poll(connection, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("reducer error poll failed")
		client.cache_apply(cache, message)
		if body, ok := message.body.(client.Reducer_Result); ok && body.request_id == request_id {
			client.message_destroy(&message)
			if body.outcome != .Err do fail("failing reducer did not return an error")
			return
		}
		client.message_destroy(&message)
	}
	fail("failing reducer result was not received")
}

await_unsubscribe :: proc(connection: ^client.Connection, cache: ^client.Cache, request_id, query_set_id: u32) {
	for _ in 0 ..< 20 {
		message, err := client.poll(connection, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("unsubscribe poll failed")
		client.cache_apply(cache, message)
		if body, ok := message.body.(client.Unsubscribe_Applied); ok && body.request_id == request_id && body.query_set_id == query_set_id {
			client.message_destroy(&message)
			return
		}
		client.message_destroy(&message)
	}
	fail("unsubscribe result was not received")
}

await_subscription_error :: proc(connection: ^client.Connection, request_id: u32) {
	for _ in 0 ..< 20 {
		message, err := client.poll(connection, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("subscription error poll failed")
		if _, ok := message.body.(client.Subscription_Error); ok {
			client.message_destroy(&message)
			return
		}
		if body, ok := message.body.(client.Subscribe_Applied); ok && body.request_id == request_id {
			client.message_destroy(&message)
			fail("invalid subscription was unexpectedly applied")
		}
		client.message_destroy(&message)
	}
	fail("subscription error was not received")
}

counter_state :: proc(cache: ^client.Cache, id: u64) -> (u64, bool) {
	rows, err := module_bindings.counters_rows(cache)
	if err != .None do fail("counter cache decode failed")
	defer client.delete_rows(rows)
	for row in rows do if row.id == id do return row.value, true
	return 0, false
}

run_values_roundtrip :: proc(connection: ^client.Connection, cache: ^client.Cache) {
	subscription, subscribe_err := client.subscribe(connection, 12, {"SELECT * FROM test_values"})
	if subscribe_err != .None do fail("values subscription failed")
	await_subscription(connection, cache, subscription)
	request, call_err := module_bindings.call_record_values(connection, u128(0), 74, 1)
	if call_err != .None do fail("values reducer call failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.test_values_rows(cache)
	if decode_err != .None do fail("values cache decode failed")
	defer client.delete_rows(rows)
	expected_identity := host.Identity(host.U256(connection.identity))
	found := false
	for row in rows {
		if row.id != 74 do continue
		if row.identity != expected_identity do fail("caller identity roundtrip failed")
		if row.connection_id == host.Connection_Id(0) do fail("connection ID roundtrip failed")
		if row.timestamp == host.Timestamp(0) do fail("timestamp roundtrip failed")
		found = true
	}
	if !found do fail("values row was not inserted")
}

run_uuid_roundtrip :: proc(connection: ^client.Connection, cache: ^client.Cache, generated_version: u8) {
	subscription, subscribe_err := client.subscribe(connection, 22, {"SELECT * FROM test_values"})
	if subscribe_err != .None do fail("UUID subscription failed")
	await_subscription(connection, cache, subscription)
	expected: u128 = 0x00112233445566778899aabbccddeeff
	if generated_version == 1 {
		request, call_err := module_bindings.call_record_generated_uuid(connection, 75)
		if call_err != .None do fail("generated UUID reducer call failed")
		await_reducer(connection, cache, request)
	} else if generated_version == 2 {
		request, call_err := module_bindings.call_record_generated_uuid_v7(connection, 75)
		if call_err != .None do fail("generated UUIDv7 reducer call failed")
		await_reducer(connection, cache, request)
	} else {
		request, call_err := module_bindings.call_record_values(connection, expected, 75, 1)
		if call_err != .None do fail("UUID reducer call failed")
		await_reducer(connection, cache, request)
	}
	rows, decode_err := module_bindings.test_values_rows(cache)
	if decode_err != .None do fail("UUID cache decode failed")
	defer client.delete_rows(rows)
	for row in rows {
		if row.id != 75 do continue
		if generated_version != 0 {
			if row.uuid == 0 do fail("generated UUID was zero")
		} else if row.uuid != expected {
			fmt.eprintln("expected UUID ", expected, " but received ", row.uuid)
			fail("UUID roundtrip changed the value")
		}
		return
	}
	fail("UUID row was not inserted")
}

run_uuid_mutation :: proc(connection: ^client.Connection, cache: ^client.Cache, deleting: bool) {
	subscription, subscribe_err := client.subscribe(connection, 24, {"SELECT * FROM test_values"})
	if subscribe_err != .None do fail("UUID mutation subscription failed")
	await_subscription(connection, cache, subscription)
	initial_uuid: u128 = 0x00112233445566778899aabbccddeeff
	updated_uuid: u128 = 0x102132435465768798a9bacbdcedfe0f
	request, call_err := module_bindings.call_record_values(connection, initial_uuid, 105, 1)
	if call_err != .None do fail("UUID insert call failed")
	await_reducer(connection, cache, request)
	if deleting {
		request, call_err = module_bindings.call_delete_uuid(connection, 105)
	} else {
		request, call_err = module_bindings.call_update_uuid(connection, updated_uuid, 105)
	}
	if call_err != .None do fail("UUID mutation call failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.test_values_rows(cache)
	if decode_err != .None do fail("UUID mutation cache decode failed")
	defer client.delete_rows(rows)
	found := false
	for row in rows {
		if row.id != 105 do continue
		found = true
		if deleting do fail("UUID delete left a row")
		if row.uuid != updated_uuid do fail("UUID update did not change the value")
	}
	if !deleting && !found do fail("UUID update removed the row")
}

run_context_mutation :: proc(connection: ^client.Connection, cache: ^client.Cache, deleting: bool) {
	subscription, subscribe_err := client.subscribe(connection, 23, {"SELECT * FROM test_values"})
	if subscribe_err != .None do fail("context mutation subscription failed")
	await_subscription(connection, cache, subscription)
	request, call_err := module_bindings.call_record_values(connection, u128(0), 104, 1)
	if call_err != .None do fail("context values insert failed")
	await_reducer(connection, cache, request)
	if deleting {
		request, call_err = module_bindings.call_delete_values(connection, 104)
	} else {
		request, call_err = module_bindings.call_update_values(connection, 104, 99)
	}
	if call_err != .None do fail("context values mutation call failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.test_values_rows(cache)
	if decode_err != .None do fail("context mutation cache decode failed")
	defer client.delete_rows(rows)
	found := false
	for row in rows {
		if row.id != 104 do continue
		found = true
		if deleting do fail("context values delete left a row")
		if row.score != 99 do fail("context values update did not change the row")
	}
	if !deleting && !found do fail("context values update removed the row")
}

run_vector_roundtrip :: proc(connection: ^client.Connection, cache: ^client.Cache) {
	subscription, subscribe_err := client.subscribe(connection, 14, {"SELECT * FROM test_vectors"})
	if subscribe_err != .None do fail("vector subscription failed")
	await_subscription(connection, cache, subscription)
	values := make([]i32, 3)
	values[0], values[1], values[2] = -7, 0, 42
	defer delete(values)
	request, call_err := module_bindings.call_record_vector(connection, 81, values)
	if call_err != .None do fail("vector reducer call failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.test_vectors_rows(cache)
	if decode_err != .None do fail("vector cache decode failed")
	defer client.delete_rows(rows)
	for row in rows {
		if row.id != 81 do continue
		if len(row.values) != 3 || row.values[0] != -7 || row.values[1] != 0 || row.values[2] != 42 do fail("vector roundtrip changed the values")
		return
	}
	fail("vector row was not inserted")
}

run_option_roundtrip :: proc(connection: ^client.Connection, cache: ^client.Cache, present: bool) {
	subscription, subscribe_err := client.subscribe(connection, 15, {"SELECT * FROM test_options"})
	if subscribe_err != .None do fail("option subscription failed")
	await_subscription(connection, cache, subscription)
	option: runtime.Maybe(i32)
	if present do option = 123
	request, call_err := module_bindings.call_record_option(connection, 91, option)
	if call_err != .None do fail("option reducer call failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.test_options_rows(cache)
	if decode_err != .None do fail("option cache decode failed")
	defer client.delete_rows(rows)
	for row_index in 0 ..< len(rows) {
		row := &rows[row_index]
		if row.id != 91 do continue
		variant := reflect.union_variant_typeid(any{data = &row.value, id = typeid_of(runtime.Maybe(i32))})
		if present {
			if variant != typeid_of(i32) do fail("Some option decoded as None")
			value := reflect.get_union_variant(any{data = &row.value, id = typeid_of(runtime.Maybe(i32))})
			if (^i32)(value.data)^ != 123 do fail("Some option value changed")
		} else if variant != nil {
			fail("None option decoded as Some")
		}
		return
	}
	fail("option row was not inserted")
}

run_enum_roundtrip :: proc(connection: ^client.Connection, cache: ^client.Cache) {
	subscription, subscribe_err := client.subscribe(connection, 19, {"SELECT * FROM test_enums"})
	if subscribe_err != .None do fail("enum subscription failed")
	await_subscription(connection, cache, subscription)
	request, call_err := module_bindings.call_record_enum(connection, .Blue, 42)
	if call_err != .None do fail("enum reducer call failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.test_enums_rows(cache)
	if decode_err != .None do fail("enum cache decode failed")
	defer client.delete_rows(rows)
	if len(rows) != 1 || rows[0].color != .Blue || rows[0].data != 42 do fail("enum variant changed")
	update_request, update_err := module_bindings.call_update_enum(connection, .Blue, 24)
	if update_err != .None do fail("enum primary-key update call failed")
	await_reducer(connection, cache, update_request)
	updated_rows, updated_decode_err := module_bindings.test_enums_rows(cache)
	if updated_decode_err != .None do fail("updated enum cache decode failed")
	defer client.delete_rows(updated_rows)
	if len(updated_rows) != 1 || updated_rows[0].color != .Blue || updated_rows[0].data != 24 do fail("enum primary-key update mismatch")
}

run_string_roundtrip :: proc(connection: ^client.Connection, cache: ^client.Cache) {
	subscription, subscribe_err := client.subscribe(connection, 20, {"SELECT * FROM test_strings"})
	if subscribe_err != .None do fail("string subscription failed")
	await_subscription(connection, cache, subscription)
	request, call_err := module_bindings.call_record_string(connection, 102, "odin-string-roundtrip")
	if call_err != .None do fail("string reducer call failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.test_strings_rows(cache)
	if decode_err != .None do fail("string cache decode failed")
	defer client.delete_rows(rows)
	for row in rows do if row.id == 102 {
		if row.text != "odin-string-roundtrip" do fail("string roundtrip changed the value")
		return
	}
	fail("string row was not inserted")
}

run_sum_roundtrip :: proc(connection: ^client.Connection, cache: ^client.Cache) {
	subscription, subscribe_err := client.subscribe(connection, 21, {"SELECT * FROM test_sums"})
	if subscribe_err != .None do fail("sum subscription failed")
	await_subscription(connection, cache, subscription)
	choice := module_bindings.TestChoice_Number{value = 123}
	request, call_err := module_bindings.call_record_sum(connection, 103, choice)
	if call_err != .None do fail("sum reducer call failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.test_sums_rows(cache)
	if decode_err != .None do fail("sum cache decode failed")
	defer client.delete_rows(rows)
	for row in rows {
		if row.id != 103 do continue
		payload, is_number := row.choice.(module_bindings.TestChoice_Number)
		if !is_number || payload.value != 123 do fail("sum variant or payload changed")
		return
	}
	fail("sum row was not inserted")
}

run_caller_and_subscriber :: proc(server_url, database: string) {
	alice, alice_err := client.connect({host = server_url, database = database})
	if alice_err != .None do fail("caller connection failed")
	defer client.disconnect(&alice)
	bob, bob_err := client.connect({host = server_url, database = database})
	if bob_err != .None do fail("subscriber connection failed")
	defer client.disconnect(&bob)
	alice_cache: client.Cache
	defer client.cache_destroy(&alice_cache)
	bob_cache: client.Cache
	defer client.cache_destroy(&bob_cache)
	alice_subscription, alice_subscribe_err := client.subscribe(&alice, 31, {"SELECT * FROM counters"})
	if alice_subscribe_err != .None do fail("caller subscription failed")
	bob_subscription, bob_subscribe_err := client.subscribe(&bob, 32, {"SELECT * FROM counters"})
	if bob_subscribe_err != .None do fail("subscriber subscription failed")
	await_subscription(&alice, &alice_cache, alice_subscription)
	await_subscription(&bob, &bob_cache, bob_subscription)
	alice_request, call_err := module_bindings.call_increment(&alice, 777)
	if call_err != .None do fail("caller reducer call failed")
	await_reducer(&alice, &alice_cache, alice_request)
	received_row := false
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(&bob, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("subscriber update poll failed")
		if result, ok := message.body.(client.Reducer_Result); ok && result.request_id == alice_request {
			client.message_destroy(&message)
			fail("subscriber received the caller's reducer result")
		}
		client.cache_apply(&bob_cache, message)
		client.message_destroy(&message)
		rows, decode_err := module_bindings.counters_rows(&bob_cache)
		if decode_err != .None do fail("subscriber cache decode failed")
		for row in rows do if row.id == 777 && row.value == 1 do received_row = true
		client.delete_rows(rows)
		if received_row do break
	}
	if !received_row do fail("subscriber did not receive the row update")
}

run_parameterized_subscription :: proc(server_url, database: string) {
	alice, alice_err := client.connect({host = server_url, database = database})
	if alice_err != .None do fail("first parameterized client connection failed")
	defer client.disconnect(&alice)
	bob, bob_err := client.connect({host = server_url, database = database})
	if bob_err != .None do fail("second parameterized client connection failed")
	defer client.disconnect(&bob)
	alice_cache: client.Cache
	defer client.cache_destroy(&alice_cache)
	bob_cache: client.Cache
	defer client.cache_destroy(&bob_cache)
	alice_subscription, alice_subscribe_err := client.subscribe(&alice, 41, {"SELECT * FROM test_values WHERE identity = :sender"})
	if alice_subscribe_err != .None do fail("first parameterized subscription failed")
	bob_subscription, bob_subscribe_err := client.subscribe(&bob, 42, {"SELECT * FROM test_values WHERE identity = :sender"})
	if bob_subscribe_err != .None do fail("second parameterized subscription failed")
	await_subscription(&alice, &alice_cache, alice_subscription)
	await_subscription(&bob, &bob_cache, bob_subscription)
	alice_request, alice_call_err := module_bindings.call_record_values(&alice, u128(0), 701, 1)
	if alice_call_err != .None do fail("first parameterized insert failed")
	bob_request, bob_call_err := module_bindings.call_record_values(&bob, u128(0), 702, 1)
	if bob_call_err != .None do fail("second parameterized insert failed")
	await_reducer(&alice, &alice_cache, alice_request)
	await_reducer(&bob, &bob_cache, bob_request)
	alice_rows, alice_decode_err := module_bindings.test_values_rows(&alice_cache)
	if alice_decode_err != .None do fail("first parameterized cache decode failed")
	defer client.delete_rows(alice_rows)
	bob_rows, bob_decode_err := module_bindings.test_values_rows(&bob_cache)
	if bob_decode_err != .None do fail("second parameterized cache decode failed")
	defer client.delete_rows(bob_rows)
	alice_identity := host.Identity(host.U256(alice.identity))
	bob_identity := host.Identity(host.U256(bob.identity))
	if len(alice_rows) != 1 || alice_rows[0].id != 701 || alice_rows[0].identity != alice_identity do fail("first parameterized result leaked or mismatched")
	if len(bob_rows) != 1 || bob_rows[0].id != 702 || bob_rows[0].identity != bob_identity do fail("second parameterized result leaked or mismatched")
}

Join_Observations :: struct {
	r_inserts: int,
	r_deletes: int,
	s_inserts: int,
	r_updates: int,
}

observe_join_changes :: proc(changes: []client.Row_Change, user: rawptr) {
	observations := cast(^Join_Observations)user
	for change in changes {
		switch change.table {
		case "join_r":
			if change.kind == .Insert {
				observations.r_inserts += 1
			} else {
				observations.r_deletes += 1
				observations.r_updates += 1
			}
		case "join_s":
			if change.kind == .Insert do observations.s_inserts += 1
		}
	}
}

run_row_deduplication :: proc(server_url, database, selector: string) {
	observations: Join_Observations
	connection, connect_err := client.connect({
		host = server_url,
		database = database,
		on_row_changes = observe_join_changes,
		callback_user = &observations,
	})
	if connect_err != .None do fail("dedup client connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	if selector == "row-deduplication-r-join-s-and-r-joint" {
		source_insert, source_err := module_bindings.call_insert_join_s(&connection, 42, 7)
		if source_err != .None do fail("multi-join source insert failed")
		await_reducer(&connection, &cache, source_insert)
		queries := [4]string{
			"SELECT * FROM join_r",
			"SELECT * FROM join_t",
			"SELECT join_s.* FROM join_s JOIN join_r ON join_s.r_id = join_r.id",
			"SELECT join_s.* FROM join_s JOIN join_t ON join_s.r_id = join_t.r_id",
		}
		for query_index in 0 ..< len(queries) {
			request, subscribe_err := client.subscribe(&connection, u32(66 + query_index), {queries[query_index]})
			if subscribe_err != .None do fail("multi-join subscription failed")
			await_subscription(&connection, &cache, request)
		}
		r_insert, r_err := module_bindings.call_insert_join_r(&connection, 42, 0)
		if r_err != .None do fail("multi-join first target insert failed")
		await_reducer(&connection, &cache, r_insert)
		if observations.s_inserts != 1 do fail("first join did not emit exactly one source insert")
		t_insert, t_err := module_bindings.call_insert_join_t(&connection, 42)
		if t_err != .None do fail("multi-join second target insert failed")
		await_reducer(&connection, &cache, t_insert)
		if observations.s_inserts != 1 do fail("second join duplicated the source row insert")
		return
	}
	if selector == "row-deduplication" {
		request, subscribe_err := client.subscribe(&connection, 61, {"SELECT * FROM join_r", "SELECT * FROM join_r"})
		if subscribe_err != .None do fail("duplicate query subscription failed")
		await_subscription(&connection, &cache, request)
		insert_request, insert_err := module_bindings.call_insert_join_r(&connection, 601, 0)
		if insert_err != .None do fail("join_r insert failed")
		await_reducer(&connection, &cache, insert_request)
		if observations.r_inserts != 1 do fail("duplicate subscription emitted duplicate join_r changes")
		return
	}
	join_builder, join_builder_err := client.sql_query("join_r", "r")
	if join_builder_err != .None do fail("join query builder initialization failed")
	defer client.sql_query_destroy(&join_builder)
	if client.sql_query_project_all(&join_builder, "s") != .None do fail("join query builder projection failed")
	if client.sql_query_inner_join(&join_builder, "join_s", "s", "r.id", "s.r_id") != .None do fail("join query builder join failed")
	join_query := client.sql_query_build(&join_builder)
	defer delete(join_query)
	join_request, join_err := client.subscribe(&connection, 62, {join_query})
	if join_err != .None do fail("join subscription failed")
	plain_request, plain_err := client.subscribe(&connection, 63, {"SELECT * FROM join_r"})
	if plain_err != .None do fail("plain join_r subscription failed")
	await_subscription(&connection, &cache, join_request)
	await_subscription(&connection, &cache, plain_request)
	r_insert, r_err := module_bindings.call_insert_join_r(&connection, 602, 0)
	if r_err != .None do fail("join_r insert failed")
	await_reducer(&connection, &cache, r_insert)
	s_insert, s_err := module_bindings.call_insert_join_s(&connection, 602, 0)
	if s_err != .None do fail("join_s insert failed")
	await_reducer(&connection, &cache, s_insert)
	if observations.r_inserts != 1 || observations.s_inserts != 1 do fail("joined subscriptions duplicated or lost row changes")
}

run_lhs_join_update :: proc(server_url, database: string, disjoint: bool) {
	observations: Join_Observations
	connection, connect_err := client.connect({
		host = server_url,
		database = database,
		on_row_changes = observe_join_changes,
		callback_user = &observations,
	})
	if connect_err != .None do fail("join-update client connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	join_query := "SELECT join_r.* FROM join_r JOIN join_s ON join_r.id = join_s.r_id WHERE join_s.score > 0 AND join_s.score < 5"
	if disjoint do join_query = "SELECT join_r.* FROM join_r JOIN join_s ON join_r.id = join_s.r_id WHERE join_s.score > 0 AND join_s.score < 5 AND join_s.r_id != 1"
	first_query, first_err := client.subscribe(&connection, 64, {"SELECT * FROM join_r WHERE id = 1"})
	if first_err != .None do fail("first join-update subscription failed")
	second_query, second_err := client.subscribe(&connection, 65, {join_query})
	if second_err != .None do fail("second join-update subscription failed")
	await_subscription(&connection, &cache, first_query)
	await_subscription(&connection, &cache, second_query)
	for index in 1 ..= 2 {
		r_insert, r_err := module_bindings.call_insert_join_r(&connection, u64(index), 0)
		if r_err != .None do fail("join-update left row insert call failed")
		await_reducer(&connection, &cache, r_insert)
		s_insert, s_err := module_bindings.call_insert_join_s(&connection, u64(index), i32(index + 2))
		if s_err != .None do fail("join-update right row insert call failed")
		await_reducer(&connection, &cache, s_insert)
	}
	observations.r_updates = 0
	observations.r_inserts = 0
	observations.r_deletes = 0
	for value in 1 ..= 2 {
		data := i32(value % 2)
		update_request, update_err := module_bindings.call_update_join_r(&connection, 2, data)
		if update_err != .None do fail("join-update reducer call failed")
		await_reducer(&connection, &cache, update_request)
		if observations.r_updates != value || observations.r_inserts != value || observations.r_deletes != value do fail("LHS join update change count mismatch")
	}
}

run_rls_subscription :: proc(server_url, database: string) {
	alice, alice_err := client.connect({host = server_url, database = database})
	if alice_err != .None do fail("first RLS client connection failed")
	defer client.disconnect(&alice)
	bob, bob_err := client.connect({host = server_url, database = database})
	if bob_err != .None do fail("second RLS client connection failed")
	defer client.disconnect(&bob)
	alice_cache: client.Cache
	defer client.cache_destroy(&alice_cache)
	bob_cache: client.Cache
	defer client.cache_destroy(&bob_cache)
	alice_subscription, alice_subscribe_err := client.subscribe(&alice, 51, {"SELECT * FROM test_users"})
	if alice_subscribe_err != .None do fail("first RLS subscription failed")
	bob_subscription, bob_subscribe_err := client.subscribe(&bob, 52, {"SELECT * FROM test_users"})
	if bob_subscribe_err != .None do fail("second RLS subscription failed")
	await_subscription(&alice, &alice_cache, alice_subscription)
	await_subscription(&bob, &bob_cache, bob_subscription)
	alice_identity := host.Identity(host.U256(alice.identity))
	bob_identity := host.Identity(host.U256(bob.identity))
	alice_request, alice_call_err := module_bindings.call_insert_test_user(&alice, "Alice", alice_identity)
	if alice_call_err != .None do fail("first RLS insert failed")
	bob_request, bob_call_err := module_bindings.call_insert_test_user(&bob, "Bob", bob_identity)
	if bob_call_err != .None do fail("second RLS insert failed")
	await_reducer(&alice, &alice_cache, alice_request)
	await_reducer(&bob, &bob_cache, bob_request)
	alice_rows, alice_decode_err := module_bindings.test_users_rows(&alice_cache)
	if alice_decode_err != .None do fail("first RLS cache decode failed")
	defer client.delete_rows(alice_rows)
	bob_rows, bob_decode_err := module_bindings.test_users_rows(&bob_cache)
	if bob_decode_err != .None do fail("second RLS cache decode failed")
	defer client.delete_rows(bob_rows)
	if len(alice_rows) != 1 || alice_rows[0].name != "Alice" || alice_rows[0].identity != alice_identity do fail("first RLS result leaked or mismatched")
	if len(bob_rows) != 1 || bob_rows[0].name != "Bob" || bob_rows[0].identity != bob_identity do fail("second RLS result leaked or mismatched")
}

run :: proc(selector, server_url, database: string) {
	if selector == "should-fail" do fail("intentional SDK client failure")
	connection, connect_err := client.connect({host = server_url, database = database})
	if connect_err != .None {
		fmt.eprintln("connection failed:", connect_err)
		os.exit(1)
	}
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	if selector == "fail-reducer" {
		request, call_err := module_bindings.call_fail_operation(&connection, 92)
		if call_err != .None do fail("failing reducer call was not sent")
		await_reducer_error(&connection, &cache, request)
		return
	}
	if selector == "insert-identity" || selector == "insert-caller-identity" ||
		selector == "insert-connection-id" || selector == "insert-caller-connection-id" ||
		selector == "insert-timestamp" || selector == "insert-call-timestamp" || selector == "insert-struct" {
		run_values_roundtrip(&connection, &cache)
		return
	}
	if selector == "delete-identity" || selector == "delete-connection-id" {
		run_context_mutation(&connection, &cache, true)
		return
	}
	if selector == "update-identity" || selector == "update-connection-id" {
		run_context_mutation(&connection, &cache, false)
		return
	}
	if selector == "insert-uuid" || selector == "insert-call-uuid-v4" || selector == "insert-call-uuid-v7" {
		version := u8(0)
		if selector == "insert-call-uuid-v4" do version = 1
		if selector == "insert-call-uuid-v7" do version = 2
		run_uuid_roundtrip(&connection, &cache, version)
		return
	}
	if selector == "delete-uuid" || selector == "update-uuid" {
		run_uuid_mutation(&connection, &cache, selector == "delete-uuid")
		return
	}
	if selector == "insert-vec" {
		run_vector_roundtrip(&connection, &cache)
		return
	}
	if selector == "insert-option-some" || selector == "insert-option-none" {
		run_option_roundtrip(&connection, &cache, selector == "insert-option-some")
		return
	}
	if selector == "insert-simple-enum" || selector == "pk-simple-enum" {
		run_enum_roundtrip(&connection, &cache)
		return
	}
	if selector == "insert-primitives-as-strings" {
		run_string_roundtrip(&connection, &cache)
		return
	}
	if selector == "insert-enum-with-payload" {
		run_sum_roundtrip(&connection, &cache)
		return
	}
	if selector == "on-reducer" || selector == "caller-always-notified" {
		request, call_err := module_bindings.call_increment(&connection, 778)
		if call_err != .None do fail("reducer callback call failed")
		await_reducer(&connection, &cache, request)
		return
	}

	switch selector {
	case "subscribe-all-select-star":
		request, subscribe_err := client.subscribe(&connection, 8, module_bindings.SUBSCRIBE_ALL_QUERIES[:])
		if subscribe_err != .None do fail("subscribe-all failed")
		await_subscription(&connection, &cache, request)
		return
	case "subscribe-and-cancel":
		_, subscribe_err := client.subscribe(&connection, 9, {"SELECT * FROM counters"})
		if subscribe_err != .None do fail("subscription failed")
		cancel_request, unsubscribe_err := client.unsubscribe(&connection, 9, true)
		if unsubscribe_err != .None do fail("subscription cancellation failed")
		await_unsubscribe(&connection, &cache, cancel_request, 9)
		return
	case "subscription-error-smoke-test":
		error_request, subscribe_err := client.subscribe(&connection, 10, {"SELEcCT * FROM counters"})
		if subscribe_err != .None do fail("invalid subscription was not sent")
		await_subscription_error(&connection, error_request)
		return
	case "subscribe-and-unsubscribe":
		insert_request, call_err := module_bindings.call_increment(&connection, 42)
		if call_err != .None do fail("increment reducer call failed")
		await_reducer(&connection, &cache, insert_request)
		active_subscription, subscribe_err := client.subscribe(&connection, 11, {"SELECT * FROM counters"})
		if subscribe_err != .None do fail("subscription failed")
		await_subscription(&connection, &cache, active_subscription)
		value, found := counter_state(&cache, 42)
		if !found || value != 1 do fail("subscription did not load the counter")
		remove_request, unsubscribe_err := client.unsubscribe(&connection, 11, true)
		if unsubscribe_err != .None do fail("unsubscribe failed")
		await_unsubscribe(&connection, &cache, remove_request, 11)
		_, found = counter_state(&cache, 42)
		if found do fail("unsubscribe did not remove dropped rows")
		return
	case "overlapping-subscriptions":
		first_subscription, first_err := client.subscribe(&connection, 16, {"SELECT * FROM counters"})
		if first_err != .None do fail("first overlapping subscription failed")
		second_subscription, second_err := client.subscribe(&connection, 17, {"SELECT * FROM counters"})
		if second_err != .None do fail("second overlapping subscription failed")
		await_subscription(&connection, &cache, first_subscription)
		await_subscription(&connection, &cache, second_subscription)
		request, call_err := module_bindings.call_increment(&connection, 43)
		if call_err != .None do fail("increment reducer call failed")
		await_reducer(&connection, &cache, request)
		rows, decode_err := module_bindings.counters_rows(&cache)
		if decode_err != .None do fail("counter cache decode failed")
		defer client.delete_rows(rows)
		if len(rows) != 1 || rows[0].id != 43 || rows[0].value != 1 do fail("overlapping subscriptions duplicated or lost the row")
		return
	case:
	}

	subscription, subscribe_err := client.subscribe(&connection, 1, {"SELECT * FROM counters"})
	if subscribe_err != .None do fail("subscription failed")
	await_subscription(&connection, &cache, subscription)

	id: u64 = 41
	request, call_err := module_bindings.call_increment(&connection, id)
	if call_err != .None do fail("increment reducer call failed")
	await_reducer(&connection, &cache, request)
	value, found := counter_state(&cache, id)
	if !found || value != 1 do fail("insert did not create the expected counter")

	switch selector {
	case "insert-primitive", "caller-always-notified":
	case "update-primitive":
		request, call_err = module_bindings.call_set_value(&connection, id, 2)
		if call_err != .None do fail("update reducer call failed")
		await_reducer(&connection, &cache, request)
		value, found = counter_state(&cache, id)
		if !found || value != 2 do fail("update did not change the counter")
	case "delete-primitive":
		request, call_err = module_bindings.call_delete_value(&connection, id, 1)
		if call_err != .None do fail("delete reducer call failed")
		await_reducer(&connection, &cache, request)
		_, found = counter_state(&cache, id)
		if found do fail("delete left the counter in the cache")
	case:
		fail("unknown SDK test selector")
	}
}

run_large_table :: proc(server_url, database: string) {
	connection, connect_err := client.connect({host = server_url, database = database})
	if connect_err != .None do fail("connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	subscription, subscribe_err := client.subscribe(&connection, 18, {"SELECT * FROM counters"})
	if subscribe_err != .None do fail("large-table subscription failed")
	await_subscription(&connection, &cache, subscription)

	for offset in 0 ..< 128 {
		id := u64(1000 + offset)
		request, call_err := module_bindings.call_increment(&connection, id)
		if call_err != .None do fail("large-table insert call failed")
		await_reducer(&connection, &cache, request)
	}
	rows, decode_err := module_bindings.counters_rows(&cache)
	if decode_err != .None do fail("large-table cache decode failed")
	if len(rows) != 128 do fail("large-table insert count mismatch")
	client.delete_rows(rows)

	for offset in 0 ..< 128 {
		id := u64(1000 + offset)
	request, call_err := module_bindings.call_delete_value(&connection, id, 1)
		if call_err != .None do fail("large-table delete call failed")
		await_reducer(&connection, &cache, request)
	}
	remaining, remaining_err := module_bindings.counters_rows(&cache)
	if remaining_err != .None do fail("large-table final cache decode failed")
	defer client.delete_rows(remaining)
	if len(remaining) != 0 do fail("large-table delete left cached rows")
}

run_reconnect :: proc(server_url, database: string) {
	first, first_err := client.connect({host = server_url, database = database})
	if first_err != .None do fail("first connection failed")
	first_id := first.connection_id
	client.disconnect(&first)
	second, second_err := client.connect({host = server_url, database = database})
	if second_err != .None do fail("second connection failed")
	defer client.disconnect(&second)
	if first_id == second.connection_id do fail("reconnect reused the connection ID")
}

run_reauth :: proc(server_url, database: string) {
	first, first_err := client.connect({host = server_url, database = database})
	if first_err != .None do fail("initial token connection failed")
	token := strings.clone(first.token)
	identity := first.identity
	client.disconnect(&first)
	defer delete(token)
	second, second_err := client.connect({host = server_url, database = database, token = token})
	if second_err != .None do fail("token reauthentication failed")
	defer client.disconnect(&second)
	if second.identity != identity do fail("token reauthentication changed identity")
	if second.token != token do fail("token reauthentication changed token")
}

main :: proc() {
	if len(os.args) != 2 do fail("expected one SDK test selector")
	server_url, server_found := os.lookup_env("SPACETIME_SDK_TEST_SERVER_URL", context.allocator)
	database, database_found := os.lookup_env("SPACETIME_SDK_TEST_DB_NAME", context.allocator)
	if !server_found || !database_found do fail("missing SDK test server environment")
	if os.args[1] == "reconnect-different-connection-id" {
		run_reconnect(server_url, database)
		return
	}
	if os.args[1] == "reauth" {
		run_reauth(server_url, database)
		return
	}
	if os.args[1] == "caller-alice-receives-reducer-callback-but-not-bob" {
		run_caller_and_subscriber(server_url, database)
		return
	}
	if os.args[1] == "insert-delete-large-table" {
		run_large_table(server_url, database)
		return
	}
	if os.args[1] == "test-parameterized-subscription" {
		run_parameterized_subscription(server_url, database)
		return
	}
	if os.args[1] == "test-rls-subscription" {
		run_rls_subscription(server_url, database)
		return
	}
	if os.args[1] == "row-deduplication" || os.args[1] == "row-deduplication-join-r-and-s" || os.args[1] == "row-deduplication-r-join-s-and-r-joint" {
		run_row_deduplication(server_url, database, os.args[1])
		return
	}
	if os.args[1] == "test-lhs-join-update" || os.args[1] == "test-lhs-join-update-disjoint-queries" {
		run_lhs_join_update(server_url, database, os.args[1] == "test-lhs-join-update-disjoint-queries")
		return
	}
	run(os.args[1], server_url, database)
}
