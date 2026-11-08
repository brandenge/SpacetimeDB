package host

import "base:runtime"
import "core:mem"

// The default wasm allocator is unavailable to modules entered without a runtime start,
// so reducer-scoped allocations come from this static arena.
SCRATCH_BYTES :: #config(STDB_SCRATCH_BYTES, 256 * 1024)

@(private)
scratch_storage: [SCRATCH_BYTES]u8
@(private)
scratch_arena: mem.Arena

// Returns a context whose allocator is a freshly reset scratch arena; call once per export.
scratch_context :: proc "contextless" () -> runtime.Context {
	ctx := runtime.default_context()
	context = ctx
	mem.arena_init(&scratch_arena, scratch_storage[:])
	ctx.allocator = mem.arena_allocator(&scratch_arena)
	return ctx
}
