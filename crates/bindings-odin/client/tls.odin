#+build !js
package client

import "core:c"
import "core:net"
import "core:strings"

// Set -define:STDB_TLS=false to build without OpenSSL; wss:// connections then fail with .Tls_Failed.
STDB_TLS :: #config(STDB_TLS, ODIN_OS == .Darwin || ODIN_OS == .Linux || ODIN_OS == .Windows)

SSL_VERIFY_PEER :: 1
SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55
TLSEXT_NAMETYPE_host_name :: 0
SSL_ERROR_WANT_READ :: 2
SSL_ERROR_WANT_WRITE :: 3
SSL_ERROR_SYSCALL :: 5
SSL_ERROR_ZERO_RETURN :: 6

when STDB_TLS {
	when ODIN_OS == .Windows {
		foreign import tls_lib {"system:libssl.lib", "system:libcrypto.lib"}
	} else {
		foreign import tls_lib {"system:ssl", "system:crypto"}
	}

	@(private, default_calling_convention = "c")
	foreign tls_lib {
		TLS_client_method :: proc() -> rawptr ---
		SSL_CTX_new :: proc(method: rawptr) -> rawptr ---
		SSL_CTX_free :: proc(ctx: rawptr) ---
		SSL_CTX_set_default_verify_paths :: proc(ctx: rawptr) -> c.int ---
		SSL_CTX_get_cert_store :: proc(ctx: rawptr) -> rawptr ---
		X509_STORE_add_cert :: proc(store: rawptr, cert: rawptr) -> c.int ---
		d2i_X509 :: proc(out: ^rawptr, data: ^[^]u8, length: c.long) -> rawptr ---
		X509_free :: proc(cert: rawptr) ---
		SSL_CTX_set_verify :: proc(ctx: rawptr, mode: c.int, callback: rawptr) ---
		SSL_new :: proc(ctx: rawptr) -> rawptr ---
		SSL_free :: proc(ssl: rawptr) ---
		SSL_set_fd :: proc(ssl: rawptr, fd: c.int) -> c.int ---
		SSL_ctrl :: proc(ssl: rawptr, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
		SSL_set1_host :: proc(ssl: rawptr, hostname: cstring) -> c.int ---
		SSL_get0_param :: proc(ssl: rawptr) -> rawptr ---
		X509_VERIFY_PARAM_set1_ip_asc :: proc(param: rawptr, ipasc: cstring) -> c.int ---
		SSL_connect :: proc(ssl: rawptr) -> c.int ---
		SSL_get_error :: proc(ssl: rawptr, result: c.int) -> c.int ---
		SSL_read :: proc(ssl: rawptr, buffer: rawptr, length: c.int) -> c.int ---
		SSL_write :: proc(ssl: rawptr, buffer: rawptr, length: c.int) -> c.int ---
		SSL_shutdown :: proc(ssl: rawptr) -> c.int ---
	}
}

// Certificates are verified against the system trust store (OpenSSL honors SSL_CERT_FILE and SSL_CERT_DIR).
Tls_Session :: struct {
	context_handle: rawptr,
	ssl: rawptr,
}

tls_connect :: proc(socket: net.TCP_Socket, host: string) -> (session: ^Tls_Session, err: Error) {
	when !STDB_TLS {
		return nil, .Tls_Failed
	} else {
		method := TLS_client_method()
		if method == nil do return nil, .Tls_Failed
		session = new(Tls_Session)
		session.context_handle = SSL_CTX_new(method)
		if session.context_handle == nil {
			free(session)
			return nil, .Tls_Failed
		}
		// Failure returns set the named result to nil, so cleanup must go through a separate pointer.
		owned := session
		defer if err != .None do tls_close(owned, graceful = false)
		if SSL_CTX_set_default_verify_paths(owned.context_handle) != 1 do return nil, .Tls_Failed
		tls_load_system_roots(owned.context_handle)
		SSL_CTX_set_verify(owned.context_handle, SSL_VERIFY_PEER, nil)
		owned.ssl = SSL_new(owned.context_handle)
		if owned.ssl == nil do return nil, .Tls_Failed
		if SSL_set_fd(owned.ssl, c.int(uintptr(socket))) != 1 do return nil, .Tls_Failed

		host_c := strings.clone_to_cstring(host, context.temp_allocator)
		// IP literals are matched against certificate IP SANs; names are sent as SNI and matched against DNS SANs.
		if net.parse_address(host) != nil {
			if X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(owned.ssl), host_c) != 1 do return nil, .Tls_Failed
		} else {
			SSL_ctrl(owned.ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, rawptr(host_c))
			if SSL_set1_host(owned.ssl, host_c) != 1 do return nil, .Tls_Failed
		}
		if SSL_connect(owned.ssl) != 1 do return nil, .Tls_Failed
		return owned, .None
	}
}

// A graceful close sends close_notify; skip it for sessions whose handshake never completed.
tls_close :: proc(session: ^Tls_Session, graceful := true) {
	if session == nil do return
	when STDB_TLS {
		if session.ssl != nil {
			if graceful do _ = SSL_shutdown(session.ssl)
			SSL_free(session.ssl)
		}
		if session.context_handle != nil do SSL_CTX_free(session.context_handle)
	}
	free(session)
}

// Returns the bytes read; a receive timeout reports .Timeout and a closed stream .Closed.
tls_recv :: proc(session: ^Tls_Session, buffer: []u8) -> (count: int, err: Error) {
	when !STDB_TLS {
		return 0, .Receive_Failed
	} else {
		result := SSL_read(session.ssl, raw_data(buffer), c.int(len(buffer)))
		if result > 0 do return int(result), .None
		switch SSL_get_error(session.ssl, result) {
		case SSL_ERROR_ZERO_RETURN:
			return 0, .Closed
		case SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE:
			return 0, .Timeout
		case SSL_ERROR_SYSCALL:
			if result == 0 do return 0, .Closed
			if tls_read_timed_out() do return 0, .Timeout
		}
		return 0, .Receive_Failed
	}
}

tls_send :: proc(session: ^Tls_Session, bytes: []u8) -> Error {
	when !STDB_TLS {
		return .Send_Failed
	} else {
		sent := 0
		for sent < len(bytes) {
			result := SSL_write(session.ssl, raw_data(bytes[sent:]), c.int(len(bytes) - sent))
			if result <= 0 do return .Send_Failed
			sent += int(result)
		}
		return .None
	}
}
