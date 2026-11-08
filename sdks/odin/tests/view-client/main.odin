package main

import "core:fmt"
import "core:os"
import "stdb:host"
import "core:time"
import "stdb:client"
import module_bindings "module_bindings"

fail :: proc(message: string) {
	fmt.eprintln(message)
	os.exit(1)
}

view_rows :: proc(cache: ^client.Cache, selector: string) -> ([]module_bindings.Players, host.Codec_Error) {
	if selector == "view-non-anonymous-subscribe" do return module_bindings.my_players_rows(cache)
	return module_bindings.all_players_rows(cache)
}

run_non_table_return :: proc(server_url, database: string, use_query_builder: bool) {
	connection, connect_err := client.connect({host = server_url, database = database})
	if connect_err != .None do fail("non-table view connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	query := "SELECT * FROM my_player_summary"
	if use_query_builder {
		builder, builder_err := client.sql_query("my_player_summary")
		if builder_err != .None do fail("non-table view query builder initialization failed")
		defer client.sql_query_destroy(&builder)
		if client.sql_query_where(u64, &builder, "id", .Equal, 201) != .None do fail("non-table view query builder filter failed")
		query = client.sql_query_build(&builder)
	}
	subscription, subscribe_err := client.subscribe(&connection, 2, {query})
	if subscribe_err != .None do fail("non-table view subscription failed")
	await_subscription(&connection, &cache, subscription)
	other, other_err := client.connect({host = server_url, database = database})
	if other_err != .None do fail("non-table view peer connection failed")
	defer client.disconnect(&other)
	other_cache: client.Cache
	defer client.cache_destroy(&other_cache)
	other_insert, other_call_err := module_bindings.call_insert_player(&other, 202, "foreign-view-row", 45)
	if other_call_err != .None do fail("foreign view row insert call failed")
	await_reducer(&other, &other_cache, other_insert)
	own_insert, own_call_err := module_bindings.call_insert_player(&connection, 201, "owned-view-row", 31)
	if own_call_err != .None do fail("owned view row insert call failed")
	await_reducer(&connection, &cache, own_insert)
	rows, decode_err := module_bindings.my_player_summary_rows(&cache)
	if decode_err != .None do fail("non-table view result decode failed")
	defer client.delete_rows(rows)
	expected_owner := host.Identity(host.U256(connection.identity))
	if len(rows) != 1 || rows[0].id != 201 || rows[0].owner != expected_owner || rows[0].score != 31 do fail("non-table view returned the wrong rows")
}

run_disconnect_sender_view_updates :: proc(server_url, database: string) {
	connection, connect_err := client.connect({host = server_url, database = database})
	if connect_err != .None do fail("sender-view client connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	subscription, subscribe_err := client.subscribe(&connection, 3, {"SELECT * FROM my_players"})
	if subscribe_err != .None do fail("sender-view subscription failed")
	await_subscription(&connection, &cache, subscription)
	own_insert, own_insert_err := module_bindings.call_insert_player(&connection, 301, "still-connected", 12)
	if own_insert_err != .None do fail("sender-view own insert failed")
	await_reducer(&connection, &cache, own_insert)
	peer, peer_err := client.connect({host = server_url, database = database})
	if peer_err != .None do fail("sender-view peer connection failed")
	peer_cache: client.Cache
	defer client.cache_destroy(&peer_cache)
	peer_subscription, peer_subscribe_err := client.subscribe(&peer, 4, {"SELECT * FROM my_players"})
	if peer_subscribe_err != .None do fail("sender-view peer subscription failed")
	await_subscription(&peer, &peer_cache, peer_subscription)
	peer_insert, peer_insert_err := module_bindings.call_insert_player(&peer, 302, "disconnecting", 13)
	if peer_insert_err != .None do fail("sender-view peer insert failed")
	await_reducer(&peer, &peer_cache, peer_insert)
	client.disconnect(&peer)
	delete_request, delete_err := module_bindings.call_delete_player(&connection, 301)
	if delete_err != .None do fail("sender-view delete call failed")
	await_reducer(&connection, &cache, delete_request)
	rows, decode_err := module_bindings.my_players_rows(&cache)
	if decode_err != .None do fail("sender-view final cache decode failed")
	defer client.delete_rows(rows)
	if len(rows) != 0 do fail("sender-view updates stopped after peer disconnect")
}

run_view_pk_join :: proc(server_url, database, mode: string) {
	connection, connect_err := client.connect({host = server_url, database = database})
	if connect_err != .None do fail("view-PK join connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	reverse := mode == "view-pk-right-semijoin"
	left_table := "my_players"
	left_alias := "p"
	join_table := "my_player_summary"
	join_alias := "s"
	left_key := "p.id"
	right_key := "s.id"
	projection := "p"
	if mode == "view-pk-join-query-builder" do projection = "s"
	if reverse {
		left_table, left_alias = "my_player_summary", "s"
		join_table, join_alias = "my_players", "p"
		left_key, right_key = "s.id", "p.id"
		projection = "s"
	}
	builder, builder_err := client.sql_query(left_table, left_alias)
	if builder_err != .None do fail("view-PK join query builder failed")
	defer client.sql_query_destroy(&builder)
	if client.sql_query_project_all(&builder, projection) != .None do fail("view-PK join projection failed")
	if client.sql_query_inner_join(&builder, join_table, join_alias, left_key, right_key) != .None do fail("view-PK join relation failed")
	query := client.sql_query_build(&builder)
	subscription, subscribe_err := client.subscribe(&connection, 5, {query})
	defer delete(query)
	if subscribe_err != .None do fail("view-PK join subscription failed")
	await_subscription(&connection, &cache, subscription)
	request, call_err := module_bindings.call_insert_player(&connection, 401, "view-pk-join", 26)
	if call_err != .None do fail("view-PK join source insert failed")
	await_reducer(&connection, &cache, request)
	request, call_err = module_bindings.call_update_player(&connection, 401, 30)
	if call_err != .None do fail("view-PK join update failed")
	await_reducer(&connection, &cache, request)
	if projection == "p" {
		rows, decode_err := module_bindings.my_players_rows(&cache)
		if decode_err != .None do fail("view-PK semijoin cache decode failed")
		defer client.delete_rows(rows)
		if len(rows) != 1 || rows[0].id != 401 || rows[0].score != 30 do fail("view-PK semijoin result mismatch")
	} else {
		rows, decode_err := module_bindings.my_player_summary_rows(&cache)
		if decode_err != .None do fail("view-PK join cache decode failed")
		defer client.delete_rows(rows)
		if len(rows) != 1 || rows[0].id != 401 || rows[0].score != 30 do fail("view-PK join result mismatch")
	}
}

await_subscription :: proc(connection: ^client.Connection, cache: ^client.Cache, request_id: u32) {
	for _ in 0 ..< 20 {
		message, err := client.poll(connection, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("view subscription poll failed")
		client.cache_apply(cache, message)
		if body, ok := message.body.(client.Subscribe_Applied); ok && body.request_id == request_id {
			client.message_destroy(&message)
			return
		}
		if _, failed := message.body.(client.Subscription_Error); failed do fail("view subscription rejected")
		client.message_destroy(&message)
	}
	fail("view subscription was not applied")
}

await_reducer :: proc(connection: ^client.Connection, cache: ^client.Cache, request_id: u32) {
	for _ in 0 ..< 20 {
		message, err := client.poll(connection, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("view reducer poll failed")
		client.cache_apply(cache, message)
		if body, ok := message.body.(client.Reducer_Result); ok && body.request_id == request_id {
			client.message_destroy(&message)
			if body.outcome != .Ok && body.outcome != .Ok_Empty do fail("view source reducer failed")
			return
		}
		client.message_destroy(&message)
	}
	fail("view source reducer result was not received")
}

main :: proc() {
	if len(os.args) != 2 do fail("expected one view test selector")
	selector := os.args[1]
	if selector != "view-anonymous-subscribe" && selector != "view-anonymous-subscribe-with-query-builder" && selector != "view-non-anonymous-subscribe" && selector != "view-subscription-update" && selector != "view-non-table-return" && selector != "view-non-table-query-builder-return" && selector != "view-disconnect-does-not-break-sender-updates" && selector != "view-pk-on-update" && selector != "view-pk-join-query-builder" && selector != "view-pk-semijoin-two-sender-views-query-builder" && selector != "sender-scoped-pk-view" && selector != "view-pk-left-semijoin" && selector != "view-pk-right-semijoin" do fail("unknown view selector")
	server_url, server_found := os.lookup_env("SPACETIME_SDK_TEST_SERVER_URL", context.allocator)
	database, database_found := os.lookup_env("SPACETIME_SDK_TEST_DB_NAME", context.allocator)
	if !server_found || !database_found do fail("missing SDK test server environment")
	if selector == "view-disconnect-does-not-break-sender-updates" {
		run_disconnect_sender_view_updates(server_url, database)
		return
	}
	if selector == "view-pk-join-query-builder" || selector == "view-pk-semijoin-two-sender-views-query-builder" || selector == "view-pk-left-semijoin" || selector == "view-pk-right-semijoin" {
		run_view_pk_join(server_url, database, selector)
		return
	}
	if selector == "view-non-table-return" || selector == "view-non-table-query-builder-return" {
		run_non_table_return(server_url, database, selector == "view-non-table-query-builder-return")
		return
	}
	connection, connect_err := client.connect({host = server_url, database = database})
	if connect_err != .None do fail("view client connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	query := "SELECT * FROM all_players"
	if selector == "view-anonymous-subscribe-with-query-builder" {
		builder, builder_err := client.sql_query("all_players")
		if builder_err != .None do fail("anonymous view query builder initialization failed")
		defer client.sql_query_destroy(&builder)
		query = client.sql_query_build(&builder)
	}
	if selector == "view-non-anonymous-subscribe" || selector == "view-pk-on-update" || selector == "sender-scoped-pk-view" do query = "SELECT * FROM my_players"
	if selector == "view-non-anonymous-subscribe" {
		request, call_err := module_bindings.call_insert_player(&connection, 101, "odin-view", 27)
		if call_err != .None do fail("view source reducer call failed")
		await_reducer(&connection, &cache, request)
	}
	subscription, subscribe_err := client.subscribe(&connection, 1, {query})
	if subscribe_err != .None do fail("anonymous view subscription failed")
	await_subscription(&connection, &cache, subscription)
	if selector == "view-anonymous-subscribe" || selector == "view-anonymous-subscribe-with-query-builder" || selector == "view-subscription-update" {
		request, call_err := module_bindings.call_insert_player(&connection, 101, "odin-view", 27)
		if call_err != .None do fail("view source reducer call failed")
		await_reducer(&connection, &cache, request)
	}
	if selector == "view-subscription-update" {
		request, call_err := module_bindings.call_update_player(&connection, 101, 29)
		if call_err != .None do fail("view update reducer call failed")
		await_reducer(&connection, &cache, request)
	}
	if selector == "view-pk-on-update" || selector == "sender-scoped-pk-view" {
		request, call_err := module_bindings.call_insert_player(&connection, 101, "odin-view", 27)
		if call_err != .None do fail("keyed view source insert failed")
		await_reducer(&connection, &cache, request)
		request, call_err = module_bindings.call_update_player(&connection, 101, 29)
		if call_err != .None do fail("keyed view update call failed")
		await_reducer(&connection, &cache, request)
		rows, decode_err := module_bindings.my_players_rows(&cache)
		if decode_err != .None do fail("keyed view cache decode failed")
		defer client.delete_rows(rows)
		if len(rows) != 1 || rows[0].id != 101 || rows[0].score != 29 do fail("keyed view update duplicated or lost the row")
		return
	}
	for _ in 0 ..< 20 {
		rows, decode_err := view_rows(&cache, selector)
		if decode_err != .None do fail("view cache decode failed")
		for row in rows {
			if row.id == 101 {
				expected_score := u64(27)
				if selector == "view-subscription-update" do expected_score = 29
				if row.name != "odin-view" || row.score != expected_score do fail("view update mismatch")
				client.delete_rows(rows)
				return
			}
		}
		client.delete_rows(rows)
		message, poll_err := client.poll(&connection, 3 * time.Second)
		if poll_err == .Timeout do continue
		if poll_err != .None do fail("view update poll failed")
		client.cache_apply(&cache, message)
		client.message_destroy(&message)
	}
	fail("view update was not received")
}
