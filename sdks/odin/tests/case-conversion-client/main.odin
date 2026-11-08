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
		if err != .None do fail("case-conversion subscription poll failed")
		client.cache_apply(cache, message)
		if applied, ok := message.body.(client.Subscribe_Applied); ok && applied.request_id == request_id {
			client.message_destroy(&message)
			return
		}
		if _, failed := message.body.(client.Subscription_Error); failed do fail("case-conversion subscription rejected")
		client.message_destroy(&message)
	}
	fail("case-conversion subscription was not applied")
}

await_reducer :: proc(connection: ^client.Connection, cache: ^client.Cache, request_id: u32) {
	for _ in 0 ..< 20 {
		message, err := client.poll(connection, 3 * time.Second)
		if err == .Timeout do continue
		if err != .None do fail("case-conversion reducer poll failed")
		client.cache_apply(cache, message)
		if result, ok := message.body.(client.Reducer_Result); ok && result.request_id == request_id {
			client.message_destroy(&message)
			if result.outcome != .Ok && result.outcome != .Ok_Empty do fail("case-conversion reducer failed")
			return
		}
		client.message_destroy(&message)
	}
	fail("case-conversion reducer result was not received")
}

run_insert_player :: proc(connection: ^client.Connection, cache: ^client.Cache) {
	subscription, subscribe_err := client.subscribe(connection, 1, {"SELECT * FROM Player1Canonical"})
	if subscribe_err != .None do fail("player insert subscription failed")
	await_subscription(connection, cache, subscription)
	request, call_err := module_bindings.call_CreatePlayer1(connection, "Alice", 5)
	if call_err != .None do fail("mixed-case reducer call failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.player1_rows(cache)
	if decode_err != .None do fail("mixed-case player cache decode failed")
	defer client.delete_rows(rows)
	if len(rows) != 1 || rows[0].player_name != "Alice" || rows[0].currentLevel2 != 5 do fail("digit-boundary player fields were not converted")
	_, active := rows[0].status3Field.(module_bindings.Player2Status_Active_1)
	if !active do fail("simple enum variant was not converted")
}

run_insert_person :: proc(connection: ^client.Connection, cache: ^client.Cache) {
	subscription, subscribe_err := client.subscribe(connection, 2, {"SELECT * FROM Player1Canonical", "SELECT * FROM person_2"})
	if subscribe_err != .None do fail("person insert subscription failed")
	await_subscription(connection, cache, subscription)
	request, call_err := module_bindings.call_CreatePlayer1(connection, "PlayerForPerson", 1)
	if call_err != .None do fail("player setup reducer call failed")
	await_reducer(connection, cache, request)
	players, player_err := module_bindings.player1_rows(cache)
	if player_err != .None || len(players) != 1 do fail("case-conversion player setup mismatch")
	defer client.delete_rows(players)
	request, call_err = module_bindings.call_AddPerson2(connection, "Bob", players[0].Player1Id, 25, 1000)
	if call_err != .None do fail("nested person reducer call failed")
	await_reducer(connection, cache, request)
	people, person_err := module_bindings.person2_rows(cache)
	if person_err != .None do fail("nested person cache decode failed")
	defer client.delete_rows(people)
	if len(people) != 1 || people[0].FirstName != "Bob" || people[0].personInfo.AgeValue1 != 25 || people[0].personInfo.ScoreTotal != 1000 do fail("nested digit-boundary fields were not converted")
}

run_ban_player :: proc(connection: ^client.Connection, cache: ^client.Cache) {
	subscription, subscribe_err := client.subscribe(connection, 3, {"SELECT * FROM Player1Canonical"})
	if subscribe_err != .None do fail("player ban subscription failed")
	await_subscription(connection, cache, subscription)
	request, call_err := module_bindings.call_CreatePlayer1(connection, "BanTarget", 1)
	if call_err != .None do fail("ban target reducer call failed")
	await_reducer(connection, cache, request)
	request, call_err = module_bindings.call_BanPlayer1(connection, 1, 150)
	if call_err != .None do fail("explicitly named reducer call failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.player1_rows(cache)
	if decode_err != .None do fail("banned player cache decode failed")
	defer client.delete_rows(rows)
	if len(rows) != 1 do fail("banned player row is missing")
	banned, is_banned := rows[0].status3Field.(module_bindings.Player2Status_Banned_Until)
	if !is_banned || banned.value != 150 do fail("payload enum variant was not converted")
}

run_query_filter :: proc(connection: ^client.Connection, cache: ^client.Cache) {
	query, query_err := client.sql_query("Player1Canonical", "p")
	if query_err != .None do fail("case-conversion filter builder failed")
	defer client.sql_query_destroy(&query)
	if client.sql_query_where(u32, &query, "p.currentLevel2", .Equal, 5) != .None do fail("case-conversion filter predicate failed")
	sql := client.sql_query_build(&query)
	defer delete(sql)
	subscription, subscribe_err := client.subscribe(connection, 4, {sql})
	if subscribe_err != .None do fail("case-conversion filter subscription failed")
	await_subscription(connection, cache, subscription)
	request, call_err := module_bindings.call_CreatePlayer1(connection, "NoMatch", 3)
	if call_err != .None do fail("nonmatching player insert failed")
	await_reducer(connection, cache, request)
	request, call_err = module_bindings.call_CreatePlayer1(connection, "FilterMatch", 5)
	if call_err != .None do fail("matching player insert failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.player1_rows(cache)
	if decode_err != .None do fail("filtered player cache decode failed")
	defer client.delete_rows(rows)
	if len(rows) != 1 || rows[0].player_name != "FilterMatch" || rows[0].currentLevel2 != 5 do fail("case-converted query filter mismatch")
}

run_query_join :: proc(connection: ^client.Connection, cache: ^client.Cache) {
	query, query_err := client.sql_query("Player1Canonical", "p")
	if query_err != .None do fail("case-conversion join builder failed")
	defer client.sql_query_destroy(&query)
	if client.sql_query_project_all(&query, "p2") != .None do fail("case-conversion join projection failed")
	if client.sql_query_inner_join(&query, "person_2", "p2", "p.Player1Id", "p2.playerRef") != .None do fail("case-conversion join relation failed")
	sql := client.sql_query_build(&query)
	defer delete(sql)
	subscription, subscribe_err := client.subscribe(connection, 5, {sql, "SELECT * FROM Player1Canonical"})
	if subscribe_err != .None do fail("case-conversion join subscription failed")
	await_subscription(connection, cache, subscription)
	request, call_err := module_bindings.call_CreatePlayer1(connection, "JoinedPlayer", 7)
	if call_err != .None do fail("joined player reducer call failed")
	await_reducer(connection, cache, request)
	players, player_err := module_bindings.player1_rows(cache)
	if player_err != .None || len(players) != 1 do fail("joined player cache mismatch")
	defer client.delete_rows(players)
	request, call_err = module_bindings.call_AddPerson2(connection, "JoinPerson", players[0].Player1Id, 30, 500)
	if call_err != .None do fail("joined person reducer call failed")
	await_reducer(connection, cache, request)
	people, person_err := module_bindings.person2_rows(cache)
	if person_err != .None do fail("joined person cache decode failed")
	defer client.delete_rows(people)
	if len(people) != 1 || people[0].FirstName != "JoinPerson" || people[0].personInfo.AgeValue1 != 30 || people[0].personInfo.ScoreTotal != 500 do fail("case-converted join result mismatch")
}

run_view :: proc(connection: ^client.Connection, cache: ^client.Cache) {
	subscription, subscribe_err := client.subscribe(connection, 6, {"SELECT * FROM Level2Person"})
	if subscribe_err != .None do fail("case-conversion view subscription failed")
	await_subscription(connection, cache, subscription)
	request, call_err := module_bindings.call_CreatePlayer1(connection, "Level2Player", 2)
	if call_err != .None do fail("view player reducer call failed")
	await_reducer(connection, cache, request)
	request, call_err = module_bindings.call_AddPerson2(connection, "ViewPerson", 1, 20, 200)
	if call_err != .None do fail("view person reducer call failed")
	await_reducer(connection, cache, request)
	rows, decode_err := module_bindings.person_at_level_2_rows(cache)
	if decode_err != .None do fail("case-conversion view cache decode failed")
	defer client.delete_rows(rows)
	if len(rows) != 1 || rows[0].FirstName != "ViewPerson" || rows[0].personInfo.AgeValue1 != 20 || rows[0].personInfo.ScoreTotal != 200 do fail("case-converted view result mismatch")
}

main :: proc() {
	if len(os.args) != 2 do fail("expected one case-conversion selector")
	server_url, server_found := os.lookup_env("SPACETIME_SDK_TEST_SERVER_URL", context.allocator)
	database, database_found := os.lookup_env("SPACETIME_SDK_TEST_DB_NAME", context.allocator)
	if !server_found || !database_found do fail("missing SDK test server environment")
	connection, connect_err := client.connect({host = server_url, database = database})
	if connect_err != .None do fail("case-conversion connection failed")
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	switch os.args[1] {
	case "insert-player": run_insert_player(&connection, &cache)
	case "insert-person": run_insert_person(&connection, &cache)
	case "ban-player": run_ban_player(&connection, &cache)
	case "query-builder-filter": run_query_filter(&connection, &cache)
	case "query-builder-join": run_query_join(&connection, &cache)
	case "view": run_view(&connection, &cache)
	case: fail("unknown case-conversion selector")
	}
}
