#+build js
package client

Compression :: enum u8 {
	None = 0,
	Brotli = 1,
	Gzip = 2,
}

COMPRESSION_TAG_NONE :: u8(0)
COMPRESSION_TAG_BROTLI :: u8(1)
COMPRESSION_TAG_GZIP :: u8(2)

inflated_frame_count: int
inflated_brotli_frame_count: int

// Browser WebSocket imports decompress asynchronously and enqueue normalized frames.
inflate_gzip_frame :: proc(compressed: []u8) -> (frame: []u8, ok: bool) {
	_ = compressed
	return nil, false
}

inflate_brotli_frame :: proc(compressed: []u8) -> (frame: []u8, ok: bool) {
	_ = compressed
	return nil, false
}
