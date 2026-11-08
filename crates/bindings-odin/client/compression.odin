#+build !js
package client

import "core:c"
import "core:bytes"
import "core:compress/gzip"

Compression :: enum u8 {
	None = 0,
	Brotli = 1,
	Gzip = 2,
}

COMPRESSION_TAG_NONE :: u8(0)
COMPRESSION_TAG_BROTLI :: u8(1)
COMPRESSION_TAG_GZIP :: u8(2)

// Number of gzip frames inflated so far, for confirming that compression is in effect.
inflated_frame_count: int
inflated_brotli_frame_count: int

when ODIN_ARCH != .wasm32 && ODIN_ARCH != .wasm64p32 {
	when ODIN_OS == .Windows {
		foreign import brotli_lib {"system:brotlidec.lib"}
	} else {
		foreign import brotli_lib {"system:brotlidec"}
	}

	@(private, default_calling_convention = "c")
	foreign brotli_lib {
		BrotliDecoderCreateInstance :: proc(alloc_func, free_func, opaque: rawptr) -> rawptr ---
		BrotliDecoderDestroyInstance :: proc(state: rawptr) ---
		BrotliDecoderDecompressStream :: proc(
			state: rawptr,
			available_in: ^uintptr,
			next_in: ^[^]u8,
			available_out: ^uintptr,
			next_out: ^[^]u8,
			total_out: ^uintptr,
		) -> c.int ---
	}
}

BROTLI_DECODER_ERROR :: c.int(0)
BROTLI_DECODER_SUCCESS :: c.int(1)
BROTLI_DECODER_NEEDS_MORE_INPUT :: c.int(2)
BROTLI_DECODER_NEEDS_MORE_OUTPUT :: c.int(3)

// Returns a frame with the uncompressed tag in front, so parse_server_frame can read it unchanged.
inflate_gzip_frame :: proc(compressed: []u8) -> (frame: []u8, ok: bool) {
	buffer: bytes.Buffer
	defer bytes.buffer_destroy(&buffer)
	if gzip.load_from_bytes(compressed, &buffer) != nil do return nil, false
	inflated := bytes.buffer_to_bytes(&buffer)
	if len(inflated) > MAX_MESSAGE_BYTES do return nil, false
	frame = make([]u8, len(inflated) + 1)
	frame[0] = COMPRESSION_TAG_NONE
	copy(frame[1:], inflated)
	inflated_frame_count += 1
	return frame, true
}

// Returns a frame with the uncompressed tag prefixed for parse_server_frame.
inflate_brotli_frame :: proc(compressed: []u8) -> (frame: []u8, ok: bool) {
	when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 {
		return nil, false
	} else {
		state := BrotliDecoderCreateInstance(nil, nil, nil)
		if state == nil do return nil, false
		defer BrotliDecoderDestroyInstance(state)

		capacity := min(16 * 1024, MAX_MESSAGE_BYTES)
		output := make([]u8, capacity)
		available_in := uintptr(len(compressed))
		next_in := raw_data(compressed)
		total_out: uintptr
		for {
			if total_out > uintptr(MAX_MESSAGE_BYTES) {
				delete(output)
				return nil, false
			}
			available_out := uintptr(capacity) - total_out
			next_out := raw_data(output[int(total_out):])
			result := BrotliDecoderDecompressStream(state, &available_in, &next_in, &available_out, &next_out, &total_out)
			switch result {
			case BROTLI_DECODER_SUCCESS:
				if available_in != 0 || total_out > uintptr(MAX_MESSAGE_BYTES) {
					delete(output)
					return nil, false
				}
				break
			case BROTLI_DECODER_NEEDS_MORE_OUTPUT:
				if capacity >= MAX_MESSAGE_BYTES {
					delete(output)
					return nil, false
				}
				new_capacity := min(capacity * 2, MAX_MESSAGE_BYTES)
				replacement := make([]u8, new_capacity)
				copy(replacement, output[:int(total_out)])
				delete(output)
				output = replacement
				capacity = new_capacity
			case BROTLI_DECODER_NEEDS_MORE_INPUT, BROTLI_DECODER_ERROR:
				delete(output)
				return nil, false
			}
			if result == BROTLI_DECODER_SUCCESS do break
		}

		frame = make([]u8, int(total_out) + 1)
		frame[0] = COMPRESSION_TAG_NONE
		copy(frame[1:], output[:int(total_out)])
		delete(output)
		inflated_brotli_frame_count += 1
		return frame, true
	}
}
