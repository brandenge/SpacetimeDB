# Odin Module ABI

This is an experimental low-level Odin binding for SpacetimeDB's WebAssembly module ABI.
It declares the versioned host imports and provides a descriptor writer for reducers and tables,
including primary keys, indexes, and unique constraints. BTree, Hash, and Direct index metadata
are supported. The host package provides raw and typed BSATN insert/update, scan, delete, clear,
and row-count wrappers.

The BSATN codec and schema writer support primitive values, UTF-8 strings, `I256`/`U256`, fixed
and dynamic arrays/slices, `Maybe(T)` options, `Result(Ok, Err)` sums, enums, and nested structs.
Results use `host.Result(Ok, Err)` with `host.Result_Ok(T)` and `host.Result_Err(E)` variant wrappers.
Table columns and reducer arguments may use any of these, nested arbitrarily. Structs and enums must
be named types: they are registered in the typespace by name and referenced by index. Enum variants
are encoded by declaration order. Enums with data are `union #no_nil` types: the union and every
variant must be a named type (wrap a primitive as `Radius :: distinct f32`), and each variant's
payload is that type's value; use an empty named struct for a variant with no data. Variants are
tagged by declaration order. Maps are not supported. `read_reducer_args` and typed scans return borrowed strings into
caller-owned buffers; those views must not outlive or survive reuse of their buffers.
`decode_row_from` returns owned string and array allocations; release them with
`delete_decoded_row`.

Run `spacetime generate --bindings module --lang odin` to generate receiver argument types and
`receiver_bindings.odin`. Each public reducer gets an `<Accessor>_Args` type, a canonical
`<ACCESSOR>_SIGNATURE_HASH`, and an `<accessor>_outbox` helper. For example, with a dependency named
`game_world`, import its package with `import game_world "remote_bindings:game_world"`; Odin module
builds automatically add `remote_bindings` as a collection when that directory exists.
Nested receiver reducers are generated in child packages under that directory, with package names
derived from the encoded accessor namespace.

To configure an outbox, call `game_world.add_outbox(Row, &table, "receiver", arg_column_buffer, Row{})`;
the row type is checked against receiver argument names and types when the helper is instantiated,
then the resolved indices are written in receiver parameter order. The table must have one
auto-increment `u64` primary key and an `Identity` target column. The buffer is caller-owned and must
remain alive through `write_module_def_all`. Call the helper while an allocator context is installed
(`host.scratch_context()` for a direct Wasm entrypoint), because descriptor validation uses temporary
schema buffers. `host.Outbox_Table(Row)` provides insert, insert-returning, update, delete, count and
scan helpers. Supply the table's unique index name to `host.outbox_table` when calling update.

Modules entered without a runtime start cannot use the default wasm allocator. Call
`context = host.scratch_context()` at the top of `__call_reducer__` to allocate from a static arena
(`-define:STDB_SCRATCH_BYTES=n` sets its size, 256 KiB by default); it is reset on every call.

Pass `Environment_Definition`s as the final argument to `write_module_def_full` or
`write_module_def_all` to declare string, string-literal, or string-union keys. Handler code reads them
through `host.environment_get(handler_context.env, key)`, which returns `(value, found, status, ok)`.
`found = false` means an optional key is absent; a present empty value has `found = true`. Check
`status` for host declaration/access errors and `ok` for source-read or UTF-8 errors. Release a
returned value with `host.environment_value_destroy`.

## Delivery Result Callbacks

Define a private reducer
with `host.Outbox_Result_Args(Row)` and use `host.outbox_result_arguments(Row, table_name)` in its
`Reducer_Definition`; the result is `host.Outbox_Result` (`Result<(), string>`). Set the outbox's
`on_result_reducer` to that reducer's name and set the matching `Reducer_Definition.handler` to a
module-local adapter. The adapter can use `host.outbox_result_dispatch(Row, args, buffer, callback,
user)` to decode and invoke the typed handler; decoded strings and slices borrow from the buffer.
Before the normal reducer switch in `__call_reducer__`, call
`host.dispatch_reducer_handler(id, reducer_definitions, args, error)` and return its status when
`handled` is true. The reducer-definition slice must be in the exact declaration order used by
`write_module_def_all`; registered handlers are routed by reducer ID without individual ID branches.
For example:

```odin
status, handled := host.dispatch_reducer_handler(id, reducers[:], args, error)
if handled do return status
```

## Index scans

`typed_scan_index_point` looks up rows by a full index key, and `typed_scan_index_range` bounds the
first indexed column with `bound_included`, `bound_excluded` or `bound_unbounded`.
`typed_scan_index_range_prefixed` first matches leading columns exactly. All return a `Typed_Scan`
that is read with `typed_scan_next` and closed with `typed_scan_close`. Close a scan before writing
to the same table. `typed_delete_index_point`, `typed_delete_index_range` and
`typed_delete_index_range_prefixed` delete by the same keys and return the number of rows removed.

## Auto-increment

List integer columns in `Table_Definition.auto_increment_columns`, insert them as `0`, and the host
fills in the generated values. `typed_insert_returning` returns the row with those values; set
`Typed_Table.auto_columns` to the same column indices in ascending order first.

## Scheduled functions

Set a table's `scheduled_function` (or legacy `scheduled_reducer`) and `schedule_at_column`; its
rows are timers. The table needs a
`u64` `scheduled_id` primary key listed in `auto_increment_columns` and a `host.Schedule_At` column
(`schedule_every(interval)` repeats, `schedule_at_time(timestamp)` fires once). A scheduled reducer
must be private and use `row_table = "<table>"`; a scheduled procedure declares the timer row as its
single argument. Deleting a row cancels its timer.

## Views

Pass `View_Definition`s (`name`, `args`, `row_info = type_info_of(Row)`, `is_anonymous`) to
`write_module_def_full`. The row type must be a named struct. Export `__call_view__` (caller-aware,
receives the sender limbs) and `__call_view_anon__`; an id indexes the views of that kind in
declaration order. Write the result with `write_view_rows` and return `VIEW_ABI_RESULT`. Views are
read-only and public; query them with SQL like tables. Set `primary_key` to a row field name to
declare it as the view's key.

Query views write their SQL with `host.write_view_query(result, sql)` and return `VIEW_ABI_RESULT`.

Generated bindings for parameterized views include a typed `<view>_query(args...)` helper for SQL
literal-compatible parameters. Pass its allocated result to `client.subscribe` or
`client.one_off_query`, then release it with `delete`.
Each generated table/view binding also exposes `<table>_query_rows(result)` to decode a matching
`One_Off_Query_Result`; release the returned rows with `client.delete_rows`.

## Procedures

Pass `Procedure_Definition`s (`name`, `args`, `return_info`, `private`) to `write_module_def_full`;
a nil `return_info` returns the unit type. Export `__call_procedure__`, write the BSATN result with
`write_procedure_result`, and return 0. Build `host.procedure_context(sender_0 ... timestamp)` from
the entrypoint arguments to access `sender`, `connection_id`, `timestamp`, and the declared
environment. `context_random_bytes`, `context_random_u64`, `context_new_uuid_v4`, and
`context_new_uuid_v7` use a deterministic ChaCha12 stream seeded from the invocation timestamp; this
is reproducible, not cryptographically secure. Procedures run outside a transaction: wrap datastore
access in `procedure_start_tx` and `procedure_commit_tx` (or `procedure_abort_tx`). The client calls
them with `client.call_procedure` and reads the `Procedure_Result` with `client.procedure_return_value`.
Use `host.typed_reducer_definition(Args, name)` and
`host.typed_procedure_definition(Args, name, return_info)` to derive argument descriptors from named
Odin structs. `host.typed_view_definition(Args, Row, name)` similarly derives view argument and row
types. These helpers return owned argument slices; keep them alive through `write_module_def_all`
and then free them. `host.typed_table_definition(Row, ...)` derives table columns from the row type.
HTTP requests: `host.http_request(Http_Request{method, uri, headers, timeout}, body)` returns an
`Http_Response` (status code, version, headers, body; free with `delete_http_response`). Use
`method = .Extension` with `method_extension = "NAME"` for non-standard methods, and `version` to
request an `Http_Version` (default HTTP/1.1; the host may negotiate a different one, which
`Http_Response.version` reports). Call it from a procedure or HTTP handler, but outside a transaction.
Any HTTP status counts as success; `Http_Error.Request_Failed`
means no response was produced. The host blocks loopback and private addresses.

## HTTP handlers

Pass handler names and `Http_Route`s (`handler`, `path`, and either `any_method = true` or a
`method`, with `method_extension` for custom methods) to `write_module_def_all`. Export
`__call_http_handler__`; the id indexes the handler names. Inside it, call `read_http_request` for the
method, URI, headers and body, answer with `write_http_response(sink, body_sink, code, headers, body)`,
and return `HTTP_HANDLER_OK`. Call `read_bytes_source(sender_jwt)` and pass the payload along with the
sender limbs and timestamp to `http_handler_context` to construct an `Http_Handler_Context`. It exposes
`sender`, `timestamp`, and `sender_auth.has_jwt` / `sender_auth.jwt_payload`; the latter is the validated
JWT claims JSON payload, not the signed token. The payload and request data are valid for the current
export call. Use `host.http_jwt_claims(sender_auth)` to extract typed `subject`, `issuer` and `audience`
values, then release them with `host.http_jwt_claims_destroy`. `http_header_value` looks headers up case-insensitively. Routes are served at
`/v1/database/<name>/route/<path>`, and each request runs as a fresh identity with no token.
Use `host.http_handler_with_tx(handler_context, callback, user)` for transactional datastore work.
The callback receives a `Http_Transaction_Context` with the request sender/auth and transaction
timestamp; return `Status(0)` to commit or a nonzero status to abort.
`host.new_uuid_v4(&handler_context)` and `host.new_uuid_v7(&handler_context)` use the Rust 0.8
`StdRng`-compatible ChaCha12 stream seeded from the invocation timestamp. UUIDs are reproducible for
identical seeds and are not cryptographically secure; UUIDv7 values also use a per-context monotonic
counter.
If commit fails, the callback is retried once in a fresh transaction, so keep external side effects
idempotent. `host.database_identity()` returns the identity of the current module.

## Reducer errors

Return `host.reducer_fail(error_sink, "message")` from `__call_reducer__` to abort and roll back the
transaction. The client sees `Reducer_Outcome.Err`; read the text with `client.reducer_error_message`.

## Reducer context and lifecycle

`host.reducer_context(sender_0 ... timestamp)` rebuilds a `Reducer_Context` (`sender`, `connection_id`,
`has_connection_id`, `timestamp`, `env`) from the `__call_reducer__` arguments. Reducer and procedure
contexts also expose deterministic random bytes, `u64`s, and UUIDv4/v7 helpers seeded from the
invocation timestamp; these are reproducible, not cryptographically secure. Set
`lifecycle = .Init`, `.On_Connect` or `.On_Disconnect` on a `Reducer_Definition` to register a
lifecycle reducer; these are private and must take no arguments. `host.Identity`, `Connection_Id`,
`Timestamp` and `Time_Duration` are encoded as the server's reserved single-field products, so they
work as table columns and reducer arguments (the type names are matched, so do not reuse them).

## Client SDK

`stdb:client` supports native and browser WebSocket transports and negotiates v3 BSATN with v2 fallback.
`Connect_Options.host` accepts `ws://`, `wss://`, `http://` and `https://` URIs (the last two map to
the first two) or a bare host meaning `ws://`, as in the Rust and C# SDKs. The port comes from the
URI, then `Connect_Options.port`, then 80 (443 for `wss`). Set `compression = .Gzip` or `.Brotli` for
server frame decompression. Native Brotli requires `brotlidec` (`libbrotli-dev` on Debian/Ubuntu,
`brotli` on Homebrew, or `brotlidec.lib` from vcpkg on Windows); browser Brotli uses
`DecompressionStream` support from the browser.

Start a SQL query with `client.sql_query(table_name, alias)`, choose `*` or `alias.*` using
`sql_query_project_all`, or add named columns with `sql_query_project_column`. The builder supports
`COUNT(*) AS alias` and integer `SUM(column) AS alias` via `sql_query_sum`, typed predicates with
`sql_query_where(T, ...)` / `sql_query_or_where(T, ...)`,
and `sql_query_inner_join` / `sql_query_cross_join` relations. Generated bindings add
`<table>_where_<column>_<op>` helpers for SQL-literal-compatible column types. Identifiers are
validated and quoted. `sql_query_limit` is only for one-off SQL queries; subscription SQL rejects
limits. `sql_query_order_by` is also one-off-only and is restricted to projected columns; subscription
SQL rejects ordering. SUM is limited to one integer column over a single source relation and returns
`Option<T>` (`None` when no rows match). The SQL parser rejects `GROUP BY` and aggregates other than
`COUNT` and restricted `SUM`; nested relation expressions are not exposed by this builder.
Set `light_mode = true` to reduce network payloads. Set `confirmed_reads` to `true` or `false` to
override the server's confirmed-read default; leave it unset to use the server default.

Native `connect` and `poll` are blocking. On `js_wasm32`, `connect` returns a connection with a
pending handshake; call `poll` from the browser event loop until it returns `Initial_Connection`.
When no frame is ready, `poll` returns `.Timeout` immediately. A v3 frame may contain several
messages; `poll` returns them one at a time in frame order. Automatic reconnect and subscription
replay also proceed through later polls without sleeping. The JS build imports `odin_env` and
`stdb_browser`; wire them using `client/browser_transport.js`:

```js
const browser = createBrowserTransport();
const { instance } = await WebAssembly.instantiate(wasmBytes, browser.imports);
browser.attach(instance);
instance.exports._start();
```

The host must call the module's exported wrapper around `client.connect` and poll it while the page is
active. It provides `connect`, `subscribe`, `unsubscribe`, `one_off_query`, `call_reducer`, `poll`,
and typed `decode_rows`. `poll` automatically updates `connection.cache`; read it with
`cache_row_count`, generated `<table>_rows` helpers, `<table>_filter` for typed local filtering, or
`<table>_cache_eq_<column>` helpers for common scalar/string equality filters. These lazily register
persistent client-side indexes; arbitrary `<table>_filter` predicates still scan the cached table.
Generated `<table>_cache_by_<primary_key>` accessors use the same index mechanism and return one
owned row plus a found flag. Integer and string columns also generate `<table>_cache_range_<column>`
helpers that accept `.Unbounded`, `.Inclusive`, or `.Exclusive` bounds and return owned rows.
Declared scalar/string-compatible multi-column B-tree indexes also generate a typed key struct,
`<table>_cache_<index_accessor>` full-key lookup, `<table>_cache_prefix_<index_accessor>_<n>`
helpers for each leading-column prefix, and `<table>_cache_range_<index_accessor>` over ordered
composite keys.
For composite indexes, register an extractor that encodes a named key struct with
`cache_index_register`; use `cache_index_lookup` for full-key equality and provide a
`Cache_Index_Prefix_Match` callback to support `cache_index_prefix_lookup` and
`cache_index_decode_prefix_rows`. An optional `Cache_Index_Less` callback enables ordered range
queries, while `cache_rows` and `cache_filter_rows` provide a full local-table scan and predicate
interface. Returned decoded rows own their strings and arrays; release them with `client.delete_rows`.
Set `Connect_Options.on_row_changes` to receive
visible row inserts and deletes as they are applied, then use generated `<table>_dispatch` procedures
and `<Table>_Handlers` for typed row callbacks. The callback runs during `poll`; its row bytes borrow
the message and must not be retained. The standalone `Cache` / `cache_apply` APIs remain available for
custom message-processing flows. Tables with
a primary key can pair a delete and insert for the same key into `on_update`; other tables report
them separately. Callback row pointers are valid only during the callback. Messages from `poll` and
the change rows borrow from their payload and must be used before `message_destroy`.
To route changes automatically, set `on_row_changes` to generated `dispatch_connection_row_changes`
and `callback_user` to a stable `Row_Change_Dispatcher` containing `Table_Callbacks` and the handler
user pointer. For runtime add/remove, set `on_row_changes` to
`client.dispatch_row_change_listeners` and `callback_user` to a stable
`client.Row_Change_Listener_Registry`; register each generated dispatcher with
`register_row_change_dispatcher` and remove it with `unregister_row_change_dispatcher`. The registry,
dispatcher, and user pointers must stay alive while registered.
For independent event listeners, generated `<table>_on_insert` and `<table>_on_delete` helpers
register a typed row callback for one table and event; pair them with `<table>_remove_on_insert` or
`<table>_remove_on_delete`. The decoded row pointer is valid only during the callback. Listener
context is owned by the registry and released on removal; use `row_change_listener_registry_destroy`
when the registry is no longer needed.
Updates caused by your own reducer calls arrive inside `Reducer_Result.update`. The client imports
the codec from `stdb:host`; native builds never reference the host imports.

For managed subscription lifecycle state, use `client.subscribe_managed_auto` with a caller-owned,
stable-address `Subscription_Handle`, or generated `subscribe_all_managed`; both allocate a query-set
ID and store it on the handle. The handle must remain at a stable address until it ends or the
connection is disconnected. Its state moves from
`.Pending` to `.Active` on application and `.Ended` on subscription error or unsubscribe; call
`client.unsubscribe_managed` to unsubscribe. The lower-level query-set ID APIs remain available.

Ordinary V3 reducer, procedure, and one-off query requests are queued and coalesced into frames of up
to 256 KiB immediately before the next `poll`; check `poll`'s error for send failures. V2 sends
ordinary requests immediately. To control a batch explicitly on either protocol, call
`begin_message_batch`, issue requests, then call `end_message_batch` and check its error. A manual
batch flushes earlier automatic V3 requests first. Subscription and unsubscription requests are not
accepted inside a manual batch because they change replay state. Do not call `poll` while a manual
batch is open; use `cancel_message_batch` to discard it. Pending request callbacks receive
`.Cancelled` when a manual batch is discarded.

For callback-style response handling, use generated `call_<name>_with_callback` wrappers or
`call_reducer_with_callback`, `call_procedure_with_callback`, and `one_off_query_with_callback`;
callbacks receive a borrowed `Message` and an `Error`, and are invoked by `poll` before it returns
that message. Generated `call_<name>_with_result_callback` wrappers instead deliver a typed
`Reducer_Result` or `Procedure_Result`; result pointers and their payload slices are borrowed only
until the callback returns. Their `Response_Context` exposes the connection, cache, identity, and
connection ID during the callback. Procedure results have generated typed decoders, and reducer
failures can be read with `client.reducer_error_message`. Managed subscription callbacks receive a
`Subscription_Event_Context` with the connection, query-set ID, and updated state. Generated
`subscribe_all` and `subscribe_with_callback` handle subscribe, replay,
unsubscribe, and subscription-error messages for a query-set ID. One-shot request callbacks are
completed with `.Unknown_Result` if the connection drops before a response arrives, since
reducer/procedure/query outcomes are not replayed. Set `Connect_Options.on_connect_error` to receive
initial native or browser handshake failures; reconnect failures use `on_disconnect`.

Set `Connect_Options.automatic_reconnect` to replay active subscriptions after a dropped socket.
`poll` uses exponential backoff up to 30 seconds, reconnects with the retained server token, verifies
the identity, and returns the new `Initial_Connection` before replayed subscription results arrive.
Active query sets are replayed in one `SubscribeBatch`; each set independently becomes active or
ends with its server-reported subscription error.
Reducer, procedure, and one-off query requests are not replayed because their outcome may be unknown;
if a reconnect attempt fails, `poll` returns its error and the next call can try again.
Set `Connect_Options.token_provider` to synchronously obtain a refreshed token before a reconnect;
return `(token, true)` on success or `(empty, false)` to stop that attempt. `on_reconnect` runs after
identity verification and token replacement but before subscriptions are replayed. `on_connect` runs
after the initial handshake; `on_disconnect` receives the socket error or `.Closed` for explicit
disconnect. Connect and reconnect callbacks receive identity, connection id, token, and `callback_user`.

TLS uses OpenSSL (or LibreSSL) through `-lssl -lcrypto`, so those libraries must be installed to build
the client; on Windows it links `libssl.lib` and `libcrypto.lib` (for example from vcpkg or an OpenSSL
installer) and copies the trusted roots from the Windows `ROOT` certificate store into OpenSSL.
Certificates and hostnames are verified against the system trust store, which OpenSSL
reads from its default paths and from `SSL_CERT_FILE` and `SSL_CERT_DIR`; there is no option to skip
verification. Failures report `.Tls_Failed`. Build with `-define:STDB_TLS=false` to drop the OpenSSL
dependency (then `wss://` fails). Windows CI builds and runs
`tests/tls_windows_smoke`, which performs a verified TLS handshake with `github.com:443` to exercise
the Windows `ROOT` certificate-store import and hostname validation, then confirms a mismatched
hostname is rejected.

```sh
odin build crates/bindings-odin/examples/client_demo -collection:stdb=crates/bindings-odin -out:client_demo
./client_demo 127.0.0.1 3000 <database running examples/ping>
```

Run the native unit tests with:

```sh
odin test crates/bindings-odin/tests -collection:stdb=crates/bindings-odin
```

Run the browser transport tests, including the self-building `js_wasm32` connection and reconnect
integration test, with:

```sh
node --test crates/bindings-odin/tests/browser_transport.test.mjs
```

The browser-WASM integration case skips only when the Odin compiler is unavailable.

The opt-in live SDK smoke test runs an Odin client against the Rust, TypeScript, and C# module
fixtures. Build the CLI and standalone server first, then run:

```sh
CARGO_BUILD_PROFILE=debug cargo test -p spacetimedb-codegen test_codegen_odin_client_live_cross_language -- --ignored
```

On macOS, set `SPACETIME_SDK_TEST_MODULE_DIR` to a directory containing `module-test.wasm`,
`module-test-ts.js`, and a prebuilt `module-test-cs.wasm`.

The `examples/ping` module exposes typed insert, update, delete, count, scan, and clear reducers
for a public `items` table. Build it from the repository root with:

```sh
cargo run -p spacetimedb-cli -- build \
  --module-path crates/bindings-odin/examples/ping \
  --debug --lint-dir ''
```

The CLI adds this directory as the `stdb` Odin collection. Odin module entry points are exported
by the application using `@(export, link_name=...)`; they must not depend on Odin startup
initializers, since SpacetimeDB invokes the exports directly.

`spacetime generate --bindings server --lang odin --module-path spacetimedb` builds the current
module and emits the `spacetimedb/module_schema` package. Import it as
`import module_schema "module_schema:module_schema"`; it supplies the ABI exports and derives the
table, reducer, procedure, view, index, constraint, schedule, outbox, route, and environment
descriptors from the compiled module definition. Handler bodies remain user-owned. Odin builds
automatically add the generated `module_schema` collection when that
directory exists. Nested types, reducers, procedures, and views use separate generated packages and
depth-first ABI dispatch. Child HTTP handler stubs are generated, but the server serves routes only
from the root module. Row-level security policies and column defaults are preserved.
Handler files remain user-owned. Regeneration adds missing stubs in separate user-owned files and
updates `module_handler_templates.odin.txt`; existing handler signatures are not rewritten. If existing
Odin source cannot be parsed, no stubs are added automatically; use the templates after correcting
the source.

`spacetime init --lang odin` starts from `crates/bindings-odin/examples/basic`, a minimal public
counter module using the generated schema package. The fuller `ping` example remains available for
index, view, procedure, HTTP, and lifecycle patterns.
