#+build windows
package client

import "core:c"
import win32 "core:sys/windows"

foreign import crypt32 "system:crypt32.lib"

Cert_Context :: struct {
	encoding_type: u32,
	encoded: [^]u8,
	encoded_length: u32,
	cert_info: rawptr,
	store: rawptr,
}

@(default_calling_convention = "system")
foreign crypt32 {
	CertOpenSystemStoreW :: proc(provider: rawptr, name: win32.LPCWSTR) -> rawptr ---
	CertEnumCertificatesInStore :: proc(store: rawptr, previous: ^Cert_Context) -> ^Cert_Context ---
	CertCloseStore :: proc(store: rawptr, flags: u32) -> win32.BOOL ---
}

// OpenSSL does not read the Windows certificate store, so copy the trusted roots into its store.
tls_load_system_roots :: proc(ssl_ctx: rawptr) {
	when STDB_TLS {
		store := CertOpenSystemStoreW(nil, win32.L("ROOT"))
		if store == nil do return
		defer CertCloseStore(store, 0)
		trusted := SSL_CTX_get_cert_store(ssl_ctx)
		for cert := CertEnumCertificatesInStore(store, nil); cert != nil; cert = CertEnumCertificatesInStore(store, cert) {
			data := cert.encoded
			parsed := d2i_X509(nil, &data, c.long(cert.encoded_length))
			if parsed == nil do continue
			_ = X509_STORE_add_cert(trusted, parsed)
			X509_free(parsed)
		}
	}
}

tls_read_timed_out :: proc() -> bool {
	error := int(win32.WSAGetLastError())
	return error == int(win32.WSAETIMEDOUT) || error == int(win32.WSAEWOULDBLOCK) || error == int(win32.WSAEINTR)
}
