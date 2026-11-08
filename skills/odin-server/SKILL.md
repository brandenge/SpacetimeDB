---
name: odin-server
description: Experimental SpacetimeDB Odin server module ABI guidance.
metadata:
  author: clockworklabs
  version: "0.1"
  role: server
  language: odin
  cursor_globs: "**/*.odin"
  cursor_always_apply: true
---

# SpacetimeDB Odin Module ABI

The current Odin module support is experimental. `spacetime init --lang odin` starts from a minimal
counter module whose schema comes from `spacetime generate --bindings server --lang odin`; the
fuller `crates/bindings-odin/examples/ping` module exposes insert, update, delete, count, scan,
clear, schedule, view, procedure, HTTP, and lifecycle examples. Column and reducer argument types
may be bool, 8/16/32/64/128-bit integers,
`host.I256`/`host.U256`, f32/f64, UTF-8 strings, fixed arrays, slices, dynamic arrays,
`runtime.Maybe(T)` options, named enums, and named structs, nested to any supported depth. Structs
and enums must be named types; they are registered in the typespace by name.

Generated schema packages provide ABI exports. Handwritten exports must use
`@(export, link_name=...)`; do not rely on Odin startup initializers because SpacetimeDB calls
`__describe_module__` and `__call_reducer__` directly.
Use the `stdb:host` collection for the versioned host imports and V10 descriptor helper. Generated
local schema metadata preserves supported tables, indexes, constraints, reducers, procedures, views,
HTTP routes, environment declarations, reducer and procedure schedules, outboxes, RLS policies, and
column defaults. Nested modules use separate generated packages with reducer, procedure, and view
ABI dispatch. Child HTTP routes are ignored by the server; only root routes are served. Regeneration
preserves user-owned handler files, adds missing stubs in separate files, and updates
`module_handler_templates.odin.txt`. If existing source cannot be parsed, use the templates after
correcting it. Runtime argument decoding uses the typed BSATN product decoder. Use `typed_insert`,
`typed_update`, `typed_delete`, `typed_count`, and the `typed_scan_*` functions for typed rows.
For handwritten exports, set `context = host.scratch_context()` at the top of both
`__describe_module__` and `__call_reducer__`; generated exports do this automatically. Reducer
argument and scan string fields borrow from caller buffers and must not outlive their reuse;
`decode_row_from` instead returns owned strings that must be released with `delete_decoded_row`.
The default wasm allocator is unavailable to modules; the scratch arena is reset on every export.

Use `host.reducer_context(...)` for the sender, connection ID and timestamp, and set
`lifecycle = .Init/.On_Connect/.On_Disconnect` on no-argument reducers for lifecycle hooks.
`host.Identity`, `Connection_Id`, `Timestamp` and `Time_Duration` are supported column types.

The native and browser client SDK lives in `stdb:client` (see `examples/client_demo`): it supports
V3 with V2 fallback, subscriptions, procedures, reconnect, typed cache/index access, response
callbacks, native TLS, and browser transport.
