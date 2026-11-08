use anyhow::Context;
use std::path::{Path, PathBuf};

pub(crate) fn build_odin(project_path: &Path, build_debug: bool) -> anyhow::Result<PathBuf> {
    let project_path = std::fs::canonicalize(project_path).context("Failed to resolve Odin project directory")?;
    let build_dir = project_path.join("build");
    std::fs::create_dir_all(&build_dir).context("Failed to create Odin build directory")?;
    let wasm_path = build_dir.join("spacetimedb.wasm");

    let mut args = vec![
        "build".to_string(),
        ".".to_string(),
        "-target:freestanding_wasm32".to_string(),
        "-no-entry-point".to_string(),
        format!("-out:{}", wasm_path.display()),
        format!(
            "-collection:stdb={}",
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../bindings-odin").display()
        ),
    ];
    let remote_bindings = project_path.join("remote_bindings");
    if remote_bindings.is_dir() {
        args.push(format!("-collection:remote_bindings={}", remote_bindings.display()));
    }
    let module_schema = project_path.join("module_schema");
    if module_schema.is_dir() {
        args.push(format!("-collection:module_schema={}", project_path.display()));
    }
    args.push(if build_debug { "-debug" } else { "-o:speed" }.to_string());

    duct::cmd("odin", &args)
        .dir(&project_path)
        .run()
        .context("Failed to build Odin module; ensure Odin is installed and available in PATH")?;

    if !wasm_path.is_file() {
        anyhow::bail!("Odin build succeeded but did not produce {}", wasm_path.display());
    }

    Ok(wasm_path)
}
