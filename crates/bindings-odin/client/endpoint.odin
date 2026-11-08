package client

import "core:strconv"
import "core:strings"

// Mirrors the Rust and C# SDKs: ws/wss pass through, http/https map to ws/wss, and a bare host means ws.
Endpoint :: struct {
	secure: bool,
	host: string, // borrowed from the input
	port: int,
	path_prefix: string, // always starts and ends with '/'; borrowed or a constant
}

parse_endpoint :: proc(address: string, default_port := 0) -> (endpoint: Endpoint, ok: bool) {
	rest := address
	endpoint.secure = false
	for scheme in ([?]struct{prefix: string, secure: bool}{
		{"wss://", true}, {"ws://", false}, {"https://", true}, {"http://", false},
	}) {
		if strings.has_prefix(rest, scheme.prefix) {
			rest = rest[len(scheme.prefix):]
			endpoint.secure = scheme.secure
			break
		}
	}
	if strings.contains(rest, "://") || strings.contains_any(rest, "?#@ ") do return endpoint, false

	authority := rest
	endpoint.path_prefix = "/"
	if slash := strings.index_byte(rest, '/'); slash >= 0 {
		authority = rest[:slash]
		path := rest[slash:]
		endpoint.path_prefix = path if strings.has_suffix(path, "/") else strings.concatenate({path, "/"}, context.temp_allocator)
	}
	if len(authority) == 0 do return endpoint, false

	port_text := ""
	if authority[0] == '[' {
		close := strings.index_byte(authority, ']')
		if close < 0 do return endpoint, false
		endpoint.host = authority[1:close]
		tail := authority[close + 1:]
		if len(tail) > 0 {
			if tail[0] != ':' do return endpoint, false
			port_text = tail[1:]
		}
	} else if colon := strings.last_index_byte(authority, ':'); colon >= 0 {
		endpoint.host = authority[:colon]
		port_text = authority[colon + 1:]
	} else {
		endpoint.host = authority
	}
	if len(endpoint.host) == 0 do return endpoint, false

	endpoint.port = default_port
	if len(port_text) > 0 {
		value, parsed := strconv.parse_int(port_text, 10)
		if !parsed || value <= 0 || value > 65535 do return endpoint, false
		endpoint.port = value
	}
	if endpoint.port == 0 do endpoint.port = 443 if endpoint.secure else 80
	return endpoint, true
}
