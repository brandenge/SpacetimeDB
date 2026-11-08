package main

import "core:fmt"
import "core:net"
import "core:time"
import "stdb:client"

main :: proc() {
	socket, dial_err := net.dial_tcp_from_hostname_with_port_override("github.com", 443)
	if dial_err != nil do panic(fmt.tprintf("TLS smoke TCP connect failed: %v", dial_err))
	defer net.close(socket)

	if net.set_option(socket, .Receive_Timeout, 10 * time.Second) != nil {
		panic("TLS smoke socket timeout setup failed")
	}

	session, tls_err := client.tls_connect(socket, "github.com")
	if tls_err != .None do panic(fmt.tprintf("TLS smoke handshake failed: %v", tls_err))
	client.tls_close(session)

	invalid_socket, invalid_dial_err := net.dial_tcp_from_hostname_with_port_override("github.com", 443)
	if invalid_dial_err != nil do panic(fmt.tprintf("TLS negative-test TCP connect failed: %v", invalid_dial_err))
	defer net.close(invalid_socket)
	if net.set_option(invalid_socket, .Receive_Timeout, 10 * time.Second) != nil {
		panic("TLS negative-test socket timeout setup failed")
	}
	invalid_session, invalid_tls_err := client.tls_connect(invalid_socket, "invalid.example")
	if invalid_tls_err == .None {
		client.tls_close(invalid_session)
		panic("TLS smoke accepted a hostname mismatch")
	}
	if invalid_tls_err != .Tls_Failed {
		panic(fmt.tprintf("TLS hostname mismatch returned unexpected error: %v", invalid_tls_err))
	}
	fmt.println("Windows TLS handshake and certificate verification succeeded")
}
