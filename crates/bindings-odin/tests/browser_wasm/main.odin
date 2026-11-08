package main

import "base:runtime"
import "stdb:client"

browser_connection: client.Connection

main :: proc() {}

@(export, link_name = "browser_connect")
browser_connect :: proc() -> i32 {
	context = runtime.default_context()
	options := client.Connect_Options{
		host = "db.example",
		port = 3000,
		database = "db",
		token = "signed-token",
		automatic_reconnect = true,
	}
	connection, err := client.connect(options)
	if err != .None do return i32(err)
	browser_connection = connection
	return 0
}

@(export, link_name = "browser_poll")
browser_poll :: proc() -> i32 {
	context = runtime.default_context()
	message, err := client.poll(&browser_connection)
	if err == .None do client.message_destroy(&message)
	return i32(err)
}

@(export, link_name = "browser_subscribe")
browser_subscribe :: proc() -> i32 {
	context = runtime.default_context()
	queries := [?]string{"SELECT * FROM items"}
	_, err := client.subscribe(&browser_connection, 7, queries[:])
	return i32(err)
}

@(export, link_name = "browser_disconnect")
browser_disconnect :: proc() {
	context = runtime.default_context()
	client.disconnect(&browser_connection)
}
