#+build !windows
#+build !js
package client

import "core:sys/posix"

// OpenSSL's default verify paths already cover the system trust store here.
tls_load_system_roots :: proc(ssl_ctx: rawptr) {}

tls_read_timed_out :: proc() -> bool {
	errno := posix.errno()
	return errno == .EAGAIN || errno == .EWOULDBLOCK || errno == .EINTR
}
