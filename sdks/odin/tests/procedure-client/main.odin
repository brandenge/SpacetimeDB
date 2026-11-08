package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "stdb:client"
import module_bindings "module_bindings"

fail :: proc(message: string) {
	fmt.eprintln(message)
	os.exit(1)
}

Procedure_Args :: struct {
	left: u32,
	right: u32,
}

Point_Args :: struct {
	x: u32,
	y: u32,
}

Return_Point :: struct {
	x: u32,
	y: u32,
}

No_Args :: struct {}

Schema_Args :: struct {
	uri: string,
}

check_transaction_result :: proc(connection: ^client.Connection, procedure: string, expected: u64) {
	request, call_err := client.call_procedure(connection, procedure, No_Args{})
	if call_err != .None do fail("transaction procedure call failed")
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("transaction procedure poll failed")
		if result, ok := message.body.(client.Procedure_Result); ok && result.request_id == request {
			if !result.returned {
				fmt.eprintln("transaction procedure returned no count: ", result.message)
				fail("transaction procedure returned no count")
			}
			value, decode_err := client.procedure_return_value(result, u64)
			client.message_destroy(&message)
			if decode_err != .None || value != expected do fail("transaction procedure row count mismatch")
			return
		}
		client.message_destroy(&message)
	}
	fail("transaction procedure result was not received")
}

check_primitive_return :: proc(connection: ^client.Connection) {
	request, call_err := client.call_procedure(connection, "return_primitive", Procedure_Args{19, 23})
	if call_err != .None do fail("primitive procedure call failed")
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("primitive procedure poll failed")
		if result, ok := message.body.(client.Procedure_Result); ok && result.request_id == request {
			if !result.returned do fail("primitive procedure returned no value")
			value, decode_err := client.procedure_return_value(result, u32)
			client.message_destroy(&message)
			if decode_err != .None || value != 42 do fail("primitive procedure return mismatch")
			return
		}
		client.message_destroy(&message)
	}
	fail("primitive procedure result was not received")
}

check_struct_return :: proc(connection: ^client.Connection) {
	request, call_err := client.call_procedure(connection, "return_struct", Point_Args{13, 29})
	if call_err != .None do fail("struct procedure call failed")
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("struct procedure poll failed")
		if result, ok := message.body.(client.Procedure_Result); ok && result.request_id == request {
			if !result.returned do fail("struct procedure returned no value")
			value, decode_err := client.procedure_return_value(result, Return_Point)
			client.message_destroy(&message)
			if decode_err != .None || value.x != 13 || value.y != 29 do fail("struct procedure return mismatch")
			return
		}
		client.message_destroy(&message)
	}
	fail("struct procedure result was not received")
}

check_panic_result :: proc(connection: ^client.Connection) {
	request, call_err := client.call_procedure(connection, "will_panic", No_Args{})
	if call_err != .None do fail("panic procedure call failed")
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("panic procedure poll failed")
		if result, ok := message.body.(client.Procedure_Result); ok && result.request_id == request {
			client.message_destroy(&message)
			if result.returned do fail("panicking procedure unexpectedly returned")
			return
		}
		client.message_destroy(&message)
	}
	fail("panic procedure result was not received")
}

check_http_result :: proc(connection: ^client.Connection, procedure: string, args: any, contains: string) {
	request, call_err := client.call_procedure(connection, procedure, args)
	if call_err != .None do fail("HTTP procedure call failed")
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("HTTP procedure poll failed")
		if result, ok := message.body.(client.Procedure_Result); ok && result.request_id == request {
			if !result.returned do fail("HTTP procedure returned no value")
			value, decode_err := client.procedure_return_value(result, string)
			client.message_destroy(&message)
			if decode_err != .None do fail("HTTP procedure result decode failed")
			defer delete(value)
			if !strings.contains(value, contains) do fail("HTTP procedure result did not contain the expected text")
			return
		}
		client.message_destroy(&message)
	}
	fail("HTTP procedure result was not received")
}

check_scheduled_procedure :: proc(connection: ^client.Connection) {
	cache: client.Cache
	defer client.cache_destroy(&cache)
	subscription, subscribe_err := client.subscribe(connection, 1, {"SELECT * FROM scheduled_results"})
	if subscribe_err != .None do fail("scheduled result subscription failed")
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("scheduled procedure poll failed")
		client.cache_apply(&cache, message)
		if applied, ok := message.body.(client.Subscribe_Applied); ok && applied.request_id == subscription {
			client.message_destroy(&message)
			break
		}
		client.message_destroy(&message)
	}
	request, call_err := module_bindings.call_schedule_proc(connection)
	if call_err != .None do fail("schedule reducer call failed")
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("scheduled procedure result poll failed")
		client.cache_apply(&cache, message)
		if reducer, ok := message.body.(client.Reducer_Result); ok && reducer.request_id == request {
			if reducer.outcome != .Ok && reducer.outcome != .Ok_Empty do fail("schedule reducer failed")
		}
		client.message_destroy(&message)
		rows, decode_err := module_bindings.scheduled_results_rows(&cache)
		if decode_err != .None do fail("scheduled result cache decode failed")
		if len(rows) == 0 {
			client.delete_rows(rows)
			continue
		}
		defer client.delete_rows(rows)
		row := rows[0]
		elapsed := i64(row.procedure_ts) - i64(row.reducer_ts)
		if row.x != 42 || row.y != 24 || elapsed < 1_000_000 || elapsed > 2_000_000 do fail("scheduled procedure result mismatch")
		return
	}
	fail("scheduled procedure did not write its result")
}

concurrency_row_exists :: proc(cache: ^client.Cache, insertion_context: string) -> bool {
	rows, decode_err := module_bindings.procedure_concurrency_rows_rows(cache)
	if decode_err != .None do fail("procedure concurrency cache decode failed")
	defer client.delete_rows(rows)
	for row in rows do if row.insertion_context == insertion_context do return true
	return false
}

run_procedure_reducer_interleaving :: proc(server_url, database: string, same_client, scheduled: bool) {
	procedure_connection, procedure_connect_err := client.connect({host = server_url, database = database})
	if procedure_connect_err != .None do fail("procedure connection failed")
	defer client.disconnect(&procedure_connection)
	procedure_cache: client.Cache
	defer client.cache_destroy(&procedure_cache)
	external_reducer_connection: client.Connection
	external_reducer_cache: client.Cache
	external_reducer_connected := false
	defer {
		if external_reducer_connected do client.disconnect(&external_reducer_connection)
		client.cache_destroy(&external_reducer_cache)
	}
	reducer_connection := &procedure_connection
	reducer_cache := &procedure_cache
	if !same_client {
		reducer_connect_err: client.Error
		external_reducer_connection, reducer_connect_err = client.connect({host = server_url, database = database})
		if reducer_connect_err != .None do fail("interleaving reducer connection failed")
		external_reducer_connected = true
		reducer_connection = &external_reducer_connection
		reducer_cache = &external_reducer_cache
	}
	subscription, subscribe_err := client.subscribe(&procedure_connection, 2, {"SELECT * FROM procedure_concurrency_rows"})
	if subscribe_err != .None do fail("procedure concurrency subscription failed")
	subscription_applied := false
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(&procedure_connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("procedure concurrency subscription poll failed")
		client.cache_apply(&procedure_cache, message)
		if applied, ok := message.body.(client.Subscribe_Applied); ok && applied.request_id == subscription do subscription_applied = true
		client.message_destroy(&message)
		if subscription_applied do break
	}
	if !subscription_applied do fail("procedure concurrency subscription was not applied")
	procedure_name := "procedure_sleep_between_inserts"
	if scheduled do procedure_name = "procedure_schedule_reducer_between_inserts"
	procedure_request, procedure_err := client.call_procedure(&procedure_connection, procedure_name, No_Args{})
	if procedure_err != .None do fail("interleaving procedure call failed")
	reducer_invoked := false
	procedure_returned := false
	for _ in 0 ..< 40 {
		message, poll_err := client.poll(&procedure_connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("procedure interleaving poll failed")
		client.cache_apply(&procedure_cache, message)
		if result, ok := message.body.(client.Procedure_Result); ok && result.request_id == procedure_request {
			if !result.returned do fail("interleaving procedure did not return successfully")
			procedure_returned = true
		}
		client.message_destroy(&message)
		if !reducer_invoked && concurrency_row_exists(&procedure_cache, "procedure_before") {
			if scheduled {
				reducer_invoked = concurrency_row_exists(&procedure_cache, "scheduled_reducer")
			} else {
				reducer_request, reducer_err := module_bindings.call_insert_reducer_row(reducer_connection, "reducer")
				if reducer_err != .None {
					fmt.eprintln("interleaving reducer call error: ", reducer_err)
					fail("interleaving reducer call failed")
				}
			for _ in 0 ..< 20 {
				reducer_message, reducer_poll_err := client.poll(reducer_connection, 3 * time.Second)
				if reducer_poll_err == .Timeout do continue
				if reducer_poll_err != .None do fail("interleaving reducer poll failed")
				client.cache_apply(reducer_cache, reducer_message)
				if outcome, ok := reducer_message.body.(client.Reducer_Result); ok && outcome.request_id == reducer_request {
					if outcome.outcome != .Ok && outcome.outcome != .Ok_Empty do fail("interleaving reducer failed")
					client.message_destroy(&reducer_message)
					reducer_invoked = true
					break
				}
				client.message_destroy(&reducer_message)
			}
			if !reducer_invoked do fail("interleaving reducer result was not received")
			}
		}
		if reducer_invoked && concurrency_row_exists(&procedure_cache, "procedure_after") && procedure_returned do break
	}
	if !reducer_invoked || !procedure_returned do fail("procedure and reducer did not interleave")
	rows, rows_err := module_bindings.procedure_concurrency_rows_rows(&procedure_cache)
	if rows_err != .None do fail("final procedure concurrency cache decode failed")
	defer client.delete_rows(rows)
	if len(rows) != 3 do fail("procedure interleaving row count mismatch")
	before_order, reducer_order, after_order: u32
	for row in rows {
		switch row.insertion_context {
		case "procedure_before": before_order = row.insertion_order
		case "reducer", "scheduled_reducer": reducer_order = row.insertion_order
		case "procedure_after": after_order = row.insertion_order
		case: fail("unexpected procedure concurrency row")
		}
	}
	if !(before_order > 0 && before_order < reducer_order && reducer_order < after_order) do fail("procedure/reducer insertion order mismatch")
}

run_scheduled_procedure_concurrency :: proc(connection: ^client.Connection, cache: ^client.Cache, update_inflight: bool) {
	subscription, subscribe_err := client.subscribe(connection, 3, {"SELECT * FROM procedure_concurrency_rows"})
	if subscribe_err != .None do fail("scheduled concurrency subscription failed")
	subscription_applied := false
	for _ in 0 ..< 20 {
		message, poll_err := client.poll(connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("scheduled concurrency subscription poll failed")
		client.cache_apply(cache, message)
		if applied, ok := message.body.(client.Subscribe_Applied); ok && applied.request_id == subscription do subscription_applied = true
		client.message_destroy(&message)
		if subscription_applied do break
	}
	if !subscription_applied do fail("scheduled concurrency subscription was not applied")
	request: u32
	call_err: client.Error
	if update_inflight {
		request, call_err = module_bindings.call_schedule_procedure_update_while_inflight(connection)
	} else {
		request, call_err = module_bindings.call_schedule_procedure_then_reducer(connection)
	}
	if call_err != .None do fail("scheduled concurrency reducer call failed")
	reducer_done := false
	for _ in 0 ..< 30 {
		message, poll_err := client.poll(connection, 1 * time.Second)
		if poll_err != .Timeout {
			if poll_err != .None do fail("scheduled concurrency poll failed")
			client.cache_apply(cache, message)
			if result, ok := message.body.(client.Reducer_Result); ok && result.request_id == request {
				if result.outcome != .Ok && result.outcome != .Ok_Empty do fail("scheduled concurrency reducer failed")
				reducer_done = true
			}
			client.message_destroy(&message)
		}
		rows, decode_err := module_bindings.procedure_concurrency_rows_rows(cache)
		if decode_err != .None do fail("scheduled concurrency cache decode failed")
		expected_count := 4 if !update_inflight else 5
		if len(rows) == expected_count && reducer_done {
			orders: [5]u32
			seen: [5]bool
			for row in rows {
				index := -1
				if update_inflight {
					switch row.insertion_context {
					case "scheduled_procedure_update_first_before": index = 0
					case "scheduled_procedure_update_second_before": index = 1
					case "scheduled_procedure_update_second_after": index = 2
					case "scheduled_procedure_update_first_after": index = 3
					case "scheduled_procedure_update_verifier": index = 4
					case: fail("unexpected in-flight scheduled procedure row")
					}
				} else {
					switch row.insertion_context {
					case "scheduled_procedure_before": index = 0
					case "scheduled_reducer_1": index = 1
					case "scheduled_reducer_2": index = 2
					case "scheduled_procedure_after": index = 3
					case: fail("unexpected scheduled procedure row")
					}
				}
				orders[index], seen[index] = row.insertion_order, true
			}
			client.delete_rows(rows)
			for index in 0 ..< expected_count - 1 do if !seen[index] || orders[index] >= orders[index + 1] do fail("scheduled procedure ordering mismatch")
			return
		}
		client.delete_rows(rows)
	}
	debug_rows, debug_err := module_bindings.procedure_concurrency_rows_rows(cache)
	if debug_err == .None {
		fmt.eprintln("scheduled concurrency observed ", len(debug_rows), " rows")
		for row in debug_rows do fmt.eprintln(row.insertion_order, ": ", row.insertion_context)
		client.delete_rows(debug_rows)
	}
	fail("scheduled procedure concurrency rows were not observed")
}

main :: proc() {
	if len(os.args) != 2 do fail("expected one procedure test selector")
	server_url, server_found := os.lookup_env("SPACETIME_SDK_TEST_SERVER_URL", context.allocator)
	database, database_found := os.lookup_env("SPACETIME_SDK_TEST_DB_NAME", context.allocator)
	if !server_found || !database_found do fail("missing SDK test server environment")
	if os.args[1] == "procedure-reducer-interleaving" || os.args[1] == "procedure-reducer-same-client-interleaved" || os.args[1] == "procedure-concurrent-with-scheduled-reducer" {
		run_procedure_reducer_interleaving(server_url, database, os.args[1] == "procedure-reducer-same-client-interleaved", os.args[1] == "procedure-concurrent-with-scheduled-reducer")
		return
	}
	connection, connect_err := client.connect({host = server_url, database = database})
	if connect_err != .None do fail("procedure client connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	switch os.args[1] {
	case "procedure-return-values":
		check_primitive_return(&connection)
		check_struct_return(&connection)
	case "procedure-observe-panic":
		check_panic_result(&connection)
	case "insert-with-tx-commit":
		check_transaction_result(&connection, "insert_with_tx_commit", 1)
	case "insert-with-tx-rollback":
		check_transaction_result(&connection, "insert_with_tx_rollback", 0)
	case "procedure-http-ok":
		server_url, _ := os.lookup_env("SPACETIME_SDK_TEST_SERVER_URL", context.allocator)
		uri := fmt.tprintf("%s/v1/database/%s/schema?version=9", server_url, database)
		check_http_result(&connection, "read_my_schema", Schema_Args{uri = uri}, "read_my_schema")
	case "procedure-http-err":
		check_http_result(&connection, "invalid_request", No_Args{}, "http://foo.invalid/")
	case "schedule-procedure":
		check_scheduled_procedure(&connection)
	case "scheduled-procedure-scheduled-reducer-interleaved":
		run_scheduled_procedure_concurrency(&connection, &cache, false)
	case "scheduled-procedure-update-while-inflight":
		run_scheduled_procedure_concurrency(&connection, &cache, true)
	case:
		fail("unknown procedure test selector")
	}
}
