use predicates::prelude::*;
use spacetimedb_guard::ensure_binaries_built;
use spacetimedb_smoketests::{copy_module_fixture, odin_path, patch_module_cargo_to_local_bindings, workspace_root};
use std::process::Command;

fn cli_cmd() -> Command {
    Command::new(ensure_binaries_built())
}

#[test]
fn cli_generate_odin_client_bindings_compile() {
    let Some(odin) = odin_path() else {
        eprintln!("Skipping Odin codegen smoke test: Odin compiler not found");
        return;
    };

    let temp_dir = tempfile::tempdir().expect("failed to create temp dir");
    let workspace = workspace_root();
    let module_dir = workspace.join("crates/bindings-odin/examples/ping");
    let output_dir = temp_dir.path().join("generated");
    let output = cli_cmd()
        .args(["generate", "--lang", "odin", "--module-path"])
        .arg(&module_dir)
        .arg("--out-dir")
        .arg(&output_dir)
        .args(["--yes"])
        .current_dir(&workspace)
        .output()
        .expect("failed to execute Odin generate");
    assert!(
        output.status.success(),
        "Odin generate failed:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let table_bindings =
        std::fs::read_to_string(output_dir.join("items_table.odin")).expect("generated table bindings should exist");
    assert!(table_bindings.contains("Items_Handlers"));
    assert!(table_bindings.contains("client.dispatch_keyed_changes"));

    let collection = format!("-collection:stdb={}", workspace.join("crates/bindings-odin").display());
    let tests = Command::new(&odin)
        .args(["test", "crates/bindings-odin/tests"])
        .arg(&collection)
        .arg("-thread-count:1")
        .current_dir(&workspace)
        .output()
        .expect("failed to execute Odin SDK tests");
    assert!(
        tests.status.success(),
        "Odin SDK tests failed:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&tests.stdout),
        String::from_utf8_lossy(&tests.stderr)
    );

    let check = Command::new(&odin)
        .arg("check")
        .arg(&output_dir)
        .arg("-no-entry-point")
        .arg("-thread-count:1")
        .arg(&collection)
        .current_dir(&workspace)
        .output()
        .expect("failed to type-check generated Odin bindings");
    assert!(
        check.status.success(),
        "Generated Odin bindings did not type-check:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&check.stdout),
        String::from_utf8_lossy(&check.stderr)
    );

    let build = cli_cmd()
        .args(["build", "--module-path"])
        .arg(&module_dir)
        .args(["--debug", "--lint-dir", ""])
        .current_dir(&workspace)
        .output()
        .expect("failed to build Odin receiver module");
    assert!(
        build.status.success(),
        "Odin build failed:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&build.stdout),
        String::from_utf8_lossy(&build.stderr)
    );

    let receiver_dir = temp_dir.path().join("remote_bindings");
    let receiver_generate = cli_cmd()
        .args(["generate", "--lang", "odin", "--bindings", "module", "--bin-path"])
        .arg(module_dir.join("build/spacetimedb.wasm"))
        .arg("--out-dir")
        .arg(&receiver_dir)
        .args(["--yes"])
        .current_dir(&workspace)
        .output()
        .expect("failed to generate Odin receiver bindings");
    assert!(
        receiver_generate.status.success(),
        "Odin receiver generation failed:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&receiver_generate.stdout),
        String::from_utf8_lossy(&receiver_generate.stderr)
    );
    std::fs::write(
        receiver_dir.join("outbox_compile_check.odin"),
        r#"package module_bindings

import "stdb:host"

Outbox_Compile_Row :: struct {
	id: u32,
	name: string,
}

outbox_compile_check :: proc() {
	table: host.Table_Definition
	arg_column_buffer: [2]u16
    _ = set_score_outbox(Outbox_Compile_Row, &table, "receiver", arg_column_buffer[:], Outbox_Compile_Row{})
}
"#,
    )
    .expect("failed to add outbox compile-check fixture");
    let receiver_check = Command::new(&odin)
        .arg("check")
        .arg(&receiver_dir)
        .arg("-no-entry-point")
        .arg("-thread-count:1")
        .arg(&collection)
        .current_dir(&workspace)
        .output()
        .expect("failed to type-check generated Odin receiver bindings");
    assert!(
        receiver_check.status.success(),
        "Generated Odin receiver bindings did not type-check:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&receiver_check.stdout),
        String::from_utf8_lossy(&receiver_check.stderr)
    );

    let browser_dir = temp_dir.path().join("browser_client");
    std::fs::create_dir_all(&browser_dir).expect("failed to create browser client fixture");
    std::fs::write(
        browser_dir.join("main.odin"),
        r#"package browser_smoke

import "stdb:client"

connection: client.Connection

@(export, link_name="browser_connect")
browser_connect :: proc() -> i32 {
    created, err := client.connect({host = "wss://db.example", database = "test", token = "signed-token", automatic_reconnect = true})
	connection = created
	return i32(err)
}

@(export, link_name="browser_subscribe")
browser_subscribe :: proc() -> i32 {
    queries := [?]string{"SELECT * FROM test"}
    _, err := client.subscribe(&connection, 10, queries[:])
    return i32(err)
}

@(export, link_name="browser_poll")
browser_poll :: proc() -> i32 {
	message, err := client.poll(&connection)
	client.message_destroy(&message)
	return i32(err)
}

main :: proc() {}
"#,
    )
    .expect("failed to write browser client fixture");
    let browser_wasm = temp_dir.path().join("browser_client.wasm");
    let browser_build = Command::new(&odin)
        .arg("build")
        .arg(&browser_dir)
        .args(["-target:js_wasm32", &collection])
        .arg(format!("-out:{}", browser_wasm.display()))
        .current_dir(&workspace)
        .output()
        .expect("failed to build Odin browser client");
    assert!(
        browser_build.status.success(),
        "Odin browser client did not build:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&browser_build.stdout),
        String::from_utf8_lossy(&browser_build.stderr)
    );

    let browser_transport_test = Command::new("node")
        .args(["--test"])
        .arg(workspace.join("crates/bindings-odin/tests/browser_transport.test.mjs"))
        .env("STDB_ODIN_BROWSER_WASM", &browser_wasm)
        .current_dir(&workspace)
        .output()
        .expect("failed to run Odin browser transport test");
    assert!(
        browser_transport_test.status.success(),
        "Odin browser transport test failed:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&browser_transport_test.stdout),
        String::from_utf8_lossy(&browser_transport_test.stderr)
    );
}

/// Standalone-only: this builds a local module and generates bindings without contacting a server.
#[test]
fn cli_generate_with_config_but_no_match_uses_cli_args() {
    // Test that when config exists but doesn't match CLI args, we use CLI args
    let temp_dir = tempfile::tempdir().expect("failed to create temp dir");

    // Initialize a new project (creates <project-path>/spacetimedb/)
    let output = cli_cmd()
        .args([
            "init",
            "--non-interactive",
            "--lang",
            "rust",
            "--project-path",
            temp_dir.path().to_str().unwrap(),
            "test-project",
        ])
        .current_dir(temp_dir.path())
        .output()
        .expect("failed to execute");
    assert!(
        output.status.success(),
        "init failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let project_dir = temp_dir.path().to_path_buf();
    let module_dir = project_dir.join("spacetimedb");
    patch_module_cargo_to_local_bindings(&module_dir).expect("failed to patch module Cargo.toml");

    // Create a config with a different module-path filter
    let config_content = r#"{
  "generate": [
    {
      "language": "typescript",
      "out-dir": "./config-output",
      "module-path": "config-module-path"
    }
  ]
}"#;
    std::fs::write(module_dir.join("spacetime.json"), config_content).expect("failed to write config");

    // Build the module first
    let output = cli_cmd()
        .args(["build", "--module-path", module_dir.to_str().unwrap()])
        .output()
        .expect("failed to execute");
    assert!(
        output.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let output_dir = module_dir.join("cli-output");
    std::fs::create_dir(&output_dir).expect("failed to create output dir");

    // Generate with different module-path from CLI - should use CLI args, not config
    let output = cli_cmd()
        .args([
            "generate",
            "--lang",
            "rust",
            "--out-dir",
            output_dir.to_str().unwrap(),
            "--module-path",
            module_dir.to_str().unwrap(),
        ])
        .current_dir(&module_dir)
        .output()
        .expect("failed to execute");
    assert!(
        output.status.success(),
        "generate failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    // Verify files were generated in the CLI-specified output directory
    assert!(
        predicate::path::exists().eval(&output_dir.join("lib.rs"))
            || predicate::path::exists().eval(&output_dir.join("mod.rs")),
        "Generated files should exist in CLI-specified output directory"
    );
}

/// Standalone-only: receiver/module bindings are generated from a local Rust module without contacting a server.
#[test]
fn cli_generate_rust_module_bindings() {
    let temp_dir = tempfile::tempdir().expect("failed to create temp dir");

    let output = cli_cmd()
        .args([
            "init",
            "--non-interactive",
            "--lang",
            "rust",
            "--project-path",
            temp_dir.path().to_str().unwrap(),
            "test-project",
        ])
        .current_dir(temp_dir.path())
        .output()
        .expect("failed to execute");
    assert!(
        output.status.success(),
        "init failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let module_dir = temp_dir.path().join("spacetimedb");
    patch_module_cargo_to_local_bindings(&module_dir).expect("failed to patch module Cargo.toml");

    let output = cli_cmd()
        .args(["build", "--module-path", module_dir.to_str().unwrap()])
        .output()
        .expect("failed to execute");
    assert!(
        output.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let output_dir = module_dir.join("receiver-bindings");
    let output = cli_cmd()
        .args([
            "generate",
            "--lang",
            "rust",
            "--bindings",
            "module",
            "--out-dir",
            output_dir.to_str().unwrap(),
            "--module-path",
            module_dir.to_str().unwrap(),
        ])
        .current_dir(&module_dir)
        .output()
        .expect("failed to execute");
    assert!(
        output.status.success(),
        "generate failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    let root = std::fs::read_to_string(output_dir.join("lib.rs")).expect("generated lib.rs should exist");
    assert!(root.contains("pub struct Identity(pub spacetimedb::Identity);"));
    assert!(root.contains("impl spacetimedb::rt::RemoteReducer for add"));
    assert!(root.contains("const NAME: &'static str = \"add\";"));
    assert!(!root.contains("DbConnection"));
    assert!(!output_dir.join("add_reducer.rs").exists());
}

#[test]
fn cli_generate_two_scoped_receiver_types_compile_in_sender() {
    let temp_dir = tempfile::tempdir().expect("failed to create temp dir");
    for (name, fixture) in [
        ("world", "idc-receiver"),
        ("auth", "idc-receiver"),
        ("sender", "idc-two-dependencies-types"),
    ] {
        let module_dir = temp_dir.path().join(name);
        copy_module_fixture(fixture, &module_dir).expect("failed to copy module fixture");
        patch_module_cargo_to_local_bindings(&module_dir).expect("failed to patch module Cargo.toml");
    }
    std::fs::write(
        temp_dir.path().join("spacetime.json"),
        r#"{
  "server": "local",
  "children": [
    { "database": "world", "module-path": "./world" },
    { "database": "auth", "module-path": "./auth" },
    {
      "database": "sender",
      "module-path": "./sender",
      "dependencies": [
        { "name": "game_world", "database": "world" },
        { "name": "auth", "database": "auth" }
      ]
    }
  ]
}"#,
    )
    .expect("failed to write spacetime.json");

    let output = cli_cmd()
        .args(["generate", "sender"])
        .current_dir(temp_dir.path())
        .output()
        .expect("failed to execute generate");
    assert!(
        output.status.success(),
        "generate failed:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    for dependency in ["game_world", "auth"] {
        let path = temp_dir
            .path()
            .join("sender/src/remote_bindings")
            .join(dependency)
            .join("ping_details_type.rs");
        let source = std::fs::read_to_string(path).expect("generated receiver type is missing");
        assert!(source.contains(&format!("#[sats(name = \"{dependency}.PingDetails\")]")));
    }
    let sender_dir = temp_dir.path().join("sender");
    let output = cli_cmd()
        .args(["build", "--module-path", sender_dir.to_str().unwrap()])
        .output()
        .expect("failed to execute build");
    assert!(
        output.status.success(),
        "sender build failed:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
/// Standalone-only: a sender module can use generated receiver bindings from a spacetime.json dependency.
#[test]
fn cli_generate_receiver_bindings_from_dependency_compile_in_sender() {
    let temp_dir = tempfile::tempdir().expect("failed to create temp dir");
    let receiver_dir = temp_dir.path().join("receiver");
    let sender_dir = temp_dir.path().join("sender");

    copy_module_fixture("idc-receiver", &receiver_dir).expect("failed to copy receiver fixture");
    copy_module_fixture("idc-sender", &sender_dir).expect("failed to copy sender fixture");
    patch_module_cargo_to_local_bindings(&receiver_dir).expect("failed to patch receiver Cargo.toml");
    patch_module_cargo_to_local_bindings(&sender_dir).expect("failed to patch sender Cargo.toml");

    std::fs::write(
        temp_dir.path().join("spacetime.json"),
        r#"{
  "server": "local",
  "children": [
    {
      "database": "game-world",
      "module-path": "./receiver"
    },
    {
      "database": "lobby",
      "module-path": "./sender",
      "dependencies": [
        { "name": "game_world", "database": "game-world" }
      ]
    }
  ]
}
"#,
    )
    .expect("failed to write spacetime.json");

    let output = cli_cmd()
        .args(["generate", "lobby"])
        .current_dir(temp_dir.path())
        .output()
        .expect("failed to execute");
    assert!(
        output.status.success(),
        "generate failed:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let remote_bindings_mod = std::fs::read_to_string(sender_dir.join("src/remote_bindings/mod.rs"))
        .expect("generated remote_bindings mod.rs should exist");
    assert!(remote_bindings_mod.contains("pub mod game_world;"));

    let generated = sender_dir.join("src/remote_bindings/game_world/mod.rs");
    let root = std::fs::read_to_string(&generated).expect("generated receiver binding should exist");
    assert!(root.contains("pub struct Identity(pub spacetimedb::Identity);"));
    assert!(root.contains("impl spacetimedb::rt::RemoteReducer for receive_ping"));
    assert!(root.contains("receive_ping"));

    let output = cli_cmd()
        .args(["build", "--module-path", sender_dir.to_str().unwrap()])
        .output()
        .expect("failed to execute");
    assert!(
        output.status.success(),
        "sender build failed:\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}
