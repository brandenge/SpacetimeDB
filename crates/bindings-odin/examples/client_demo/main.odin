package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"
import "stdb:client"
import "stdb:host"

Point :: struct {
	x: i32,
	y: i32,
}

Kind :: enum u8 {
	Small,
	Large,
}

Shape :: struct {
	origin: Point,
	corners: []Point,
	label: runtime.Maybe(string),
	kind: Kind,
	weight: host.U256,
}

Session :: struct {
	identity: host.Identity,
	connected_at: host.Timestamp,
}

// The caller's own reducer updates arrive inside Reducer_Result rather than as a Transaction_Update.
print_inserts :: proc(update: client.Transaction_Update) -> (count: int) {
	for set in update.query_sets {
		for table in set.tables {
			for group in table.groups {
				rows, decode_err := client.decode_rows(group.inserts, Shape)
				if decode_err != .None {
					fmt.eprintln("decode failed:", decode_err)
					os.exit(1)
				}
				defer client.delete_rows(rows)
				for row in rows {
					fmt.println(table.table, "insert:", row)
					count += 1
				}
			}
		}
	}
	return
}

// Usage: client_demo <host> <port> <database>; the database must be the examples/ping module.
main :: proc() {
	if len(os.args) != 4 {
		fmt.eprintln("usage: client_demo <host> <port> <database>")
		os.exit(2)
	}
	port := 0
	for char in os.args[2] {
		if char < '0' || char > '9' do os.exit(2)
		port = port * 10 + int(char - '0')
	}

	connection, err := client.connect({host = os.args[1], port = port, database = os.args[3]})
	if err != .None {
		fmt.eprintln("connect failed:", err)
		os.exit(1)
	}
	defer client.disconnect(&connection)
	cache: client.Cache
	defer client.cache_destroy(&cache)
	fmt.printf("connected, identity %x\n", connection.identity)

	subscribe_id, subscribe_err := client.subscribe(&connection, 1, {"SELECT * FROM shapes"})
	if subscribe_err != .None {
		fmt.eprintln("subscribe failed:", subscribe_err)
		os.exit(1)
	}

	// Wait for the subscription before calling the reducer so its update reaches this query set.
	for applied := false; !applied; {
		message, poll_err := client.poll(&connection, 5 * time.Second)
		if poll_err != .None {
			fmt.eprintln("poll failed:", poll_err)
			os.exit(1)
		}
		defer client.message_destroy(&message)
		client.cache_apply(&cache, message)
		if body, is_applied := message.body.(client.Subscribe_Applied); is_applied && body.request_id == subscribe_id {
			applied = true
			for table in body.rows.tables {
				rows, decode_err := client.decode_rows(table.rows, Shape)
				if decode_err != .None {
					fmt.eprintln("decode failed:", decode_err)
					os.exit(1)
				}
				defer client.delete_rows(rows)
				fmt.println(table.table, "initial rows:", len(rows))
			}
		}
	}

	shape := Shape{
		origin = {i32(time.to_unix_seconds(time.now())), 8}, // distinct rows: the table has no key, so duplicates are no-ops
		corners = []Point{{1, 2}, {3, 4}},
		label = "from odin client",
		kind = .Large,
	}
	reducer_id, call_err := client.call_reducer(&connection, "add_shape", shape)
	if call_err != .None {
		fmt.eprintln("call failed:", call_err)
		os.exit(1)
	}

	reducer_done, inserted := false, 0
	for !(reducer_done && inserted > 0) {
		message, poll_err := client.poll(&connection, 5 * time.Second)
		if poll_err != .None {
			fmt.eprintln("poll failed:", poll_err)
			os.exit(1)
		}
		defer client.message_destroy(&message)
		client.cache_apply(&cache, message)
		switch body in message.body {
		case client.Reducer_Result:
			if body.request_id == reducer_id {
				reducer_done = true
				fmt.println("reducer outcome:", body.outcome, body.message)
				inserted += print_inserts(body.update)
			}
		case client.Transaction_Update:
			inserted += print_inserts(body)
		case client.Subscription_Error:
			fmt.eprintln("subscription error:", body.error)
			os.exit(1)
		case client.Initial_Connection, client.Subscribe_Applied, client.Subscribe_Batch_Applied, client.Unsubscribe_Applied, client.One_Off_Query_Result, client.Procedure_Result:
		}
	}

	fmt.println("cached shapes:", client.cache_row_count(&cache, "shapes"))

	// on_connect inserted this connection's session row.
	query_id, query_err := client.one_off_query(&connection, "SELECT * FROM sessions")
	if query_err != .None {
		fmt.eprintln("query failed:", query_err)
		os.exit(1)
	}
	for answered := false; !answered; {
		message, poll_err := client.poll(&connection, 5 * time.Second)
		if poll_err != .None {
			fmt.eprintln("poll failed:", poll_err)
			os.exit(1)
		}
		defer client.message_destroy(&message)
		result, is_result := message.body.(client.One_Off_Query_Result)
		if !is_result || result.request_id != query_id do continue
		answered = true
		for table in result.rows.tables {
			sessions, decode_err := client.decode_rows(table.rows, Session)
			if decode_err != .None {
				fmt.eprintln("decode failed:", decode_err)
				os.exit(1)
			}
			defer client.delete_rows(sessions)
			for session in sessions do fmt.println("session:", session.identity == host.Identity(connection.identity), session.connected_at)
		}
	}
	fmt.println("done")
}
