//! Odin client bindings: row and argument types, reducer and procedure callers, and typed change dispatch.
//! The generated package builds on the `stdb:client` and `stdb:host` collections.

use crate::util::{
    collect_case, is_parameterized_view, iter_constraints, iter_indexes, iter_reducers, iter_table_names_and_types,
    iter_tables, iter_types, type_ref_name, CodegenVisibility,
};
use crate::{CodegenOptions, Lang, OutputFile};
use convert_case::{Case, Casing};
use spacetimedb_lib::sats::layout::PrimitiveType;
use spacetimedb_schema::def::{
    ConstraintData, FunctionKind, IndexAlgorithm, ModuleDef, ProcedureDef, ReducerDef, TableDef, TypeDef, ViewDef,
};
use spacetimedb_schema::schema::TableSchema;
use spacetimedb_schema::type_for_generate::{
    AlgebraicTypeDef, AlgebraicTypeUse, PlainEnumTypeDef, ProductTypeDef, SumTypeDef,
};
use std::collections::BTreeSet;
use std::fmt::Write;
use std::ops::Deref;

pub struct Odin;

pub(super) fn generate_module_bindings(module: &ModuleDef, _dependency_name: Option<&str>) -> Vec<OutputFile> {
    let mut output = generate_local_module_bindings(module);
    let mut children = Vec::new();
    collect_server_submodules(module, &mut children);
    for child in children {
        if iter_reducers(child, CodegenVisibility::OnlyPublic).next().is_some() {
            output.extend(
                generate_local_module_bindings(child)
                    .into_iter()
                    .map(|file| client_submodule_file(child, file)),
            );
        }
    }
    output
}

fn generate_local_module_bindings(module: &ModuleDef) -> Vec<OutputFile> {
    let mut pending = Vec::new();
    for reducer in iter_reducers(module, CodegenVisibility::OnlyPublic) {
        for (_, ty) in &reducer.params_for_generate.elements {
            ty.for_each_ref(|type_ref| pending.push(type_ref));
        }
    }

    let typespace = module.typespace_for_generate();
    let mut type_refs = BTreeSet::new();
    while let Some(type_ref) = pending.pop() {
        if !type_refs.insert(type_ref) {
            continue;
        }
        match &typespace[type_ref] {
            AlgebraicTypeDef::Product(product) => {
                for (_, ty) in &product.elements {
                    ty.for_each_ref(|type_ref| pending.push(type_ref));
                }
            }
            AlgebraicTypeDef::Sum(sum) => {
                for (_, ty) in &sum.variants {
                    ty.for_each_ref(|type_ref| pending.push(type_ref));
                }
            }
            AlgebraicTypeDef::PlainEnum(_) => {}
        }
    }

    let mut output = Vec::new();
    for typ in iter_types(module).filter(|typ| type_refs.contains(&typ.ty)) {
        output.extend(Odin.generate_type_files(module, typ));
    }

    let mut uses = Uses {
        host: true,
        runtime: true,
        ..Uses::default()
    };
    let mut body = String::new();
    for reducer in iter_reducers(module, CodegenVisibility::OnlyPublic) {
        let accessor = reducer.accessor_name.deref().to_string();
        let args_type = format!("{}_Args", ada_case(&accessor));
        let params = reducer
            .params_for_generate
            .elements
            .iter()
            .map(|(name, ty)| (field_name(name.deref()), odin_type(module, ty, &mut uses)))
            .collect::<Vec<_>>();
        write_struct(&mut body, &args_type, &params);
        writeln!(&mut body).unwrap();

        let signature_hash = spacetimedb_schema::def::reducer_signature_hash(
            &reducer.params(),
            &reducer.ok_return_type,
            &reducer.err_return_type,
            module.typespace(),
        );
        let hash_bytes = signature_hash
            .data
            .iter()
            .map(|byte| format!("0x{byte:02x}"))
            .collect::<Vec<_>>()
            .join(", ");
        let hash_name = format!("{}_SIGNATURE_HASH", accessor.to_uppercase());
        writeln!(&mut body, "{hash_name} :: [32]u8{{{hash_bytes}}}").unwrap();
        let reducer_name =
            serde_json::to_string(&reducer.name.deref()).unwrap_or_else(|_| format!("{:?}", reducer.name.deref()));
        writeln!(
            &mut body,
            "{accessor}_outbox :: proc($Row: typeid, table: ^host.Table_Definition, target_column: string, arg_column_buffer: []u16, outbox_row: Row, on_result_reducer: runtime.Maybe(string) = nil) -> host.Outbox_Error {{"
        )
        .unwrap();
        if !params.is_empty() {
            writeln!(&mut body, "\tif false {{").unwrap();
            writeln!(&mut body, "\t\t_ = outbox_row").unwrap();
            for ((remote_name, _), (field, ty)) in reducer.params_for_generate.elements.iter().zip(&params) {
                let check_name = format!("outbox_compile_{}", field);
                writeln!(&mut body, "\t\t{check_name}: {ty}").unwrap();
                writeln!(
                    &mut body,
                    "\t\t{check_name} = outbox_row.{}",
                    field_name(remote_name.deref())
                )
                .unwrap();
            }
            writeln!(&mut body, "\t}}").unwrap();
        }
        if params.is_empty() {
            writeln!(&mut body, "\tremote_args: []host.Reducer_Argument = nil").unwrap();
        } else {
            writeln!(&mut body, "\tremote_args := [?]host.Reducer_Argument{{").unwrap();
            for ((remote_name, _), (_, ty)) in reducer.params_for_generate.elements.iter().zip(&params) {
                writeln!(
                    &mut body,
                    "\t\t{{name = {:?}, info = type_info_of({ty})}},",
                    remote_name.deref()
                )
                .unwrap();
            }
            writeln!(&mut body, "\t}}\n").unwrap();
        }
        writeln!(
            &mut body,
            "\toutbox, err := host.make_outbox_definition(table^, {reducer_name}, target_column, remote_args[:], arg_column_buffer, {hash_name}, on_result_reducer)"
        )
        .unwrap();
        writeln!(&mut body, "\tif err != .None do return err").unwrap();
        writeln!(&mut body, "\ttable.outbox = outbox").unwrap();
        writeln!(&mut body, "\treturn .None").unwrap();
        writeln!(&mut body, "}}\n").unwrap();
    }
    output.push(generated_file("receiver_bindings.odin".into(), &uses, &body));
    output
}

/// Generate local-module schema definitions, ABI exports, and user-owned handler stubs.
pub fn generate_server_module_schema(module: &ModuleDef) -> anyhow::Result<Vec<OutputFile>> {
    let mut uses = Uses {
        host: true,
        runtime: true,
        ..Uses::default()
    };
    let mut body = String::new();
    write_server_module_types(&mut body, module, &mut uses)?;

    writeln!(
        body,
        "write_module_definition :: proc(description: host.Bytes_Sink) -> (host.Status, bool) {{"
    )
    .unwrap();
    writeln!(body, "\tcontext = host.scratch_context()").unwrap();
    writeln!(body, "\treducers: [dynamic]host.Reducer_Definition").unwrap();
    writeln!(body, "\tdefer for reducer in reducers do delete(reducer.args)").unwrap();
    for (reducer_index, reducer) in module.reducers().enumerate() {
        let accessor = reducer.accessor_name.deref().to_string();
        let args_type = server_wire_args_type(module, &accessor, &reducer.params_for_generate);
        let lifecycle = match reducer.lifecycle {
            None => ".None",
            Some(spacetimedb_lib::db::raw_def::v9::Lifecycle::Init) => ".Init",
            Some(spacetimedb_lib::db::raw_def::v9::Lifecycle::OnConnect) => ".On_Connect",
            Some(spacetimedb_lib::db::raw_def::v9::Lifecycle::OnDisconnect) => ".On_Disconnect",
            Some(_) => anyhow::bail!("Odin server schema generation encountered an unsupported reducer lifecycle"),
        };
        let row_table = module
            .tables()
            .find(|table| {
                table.schedule.as_ref().is_some_and(|schedule| {
                    schedule.function_kind == FunctionKind::Reducer && &schedule.function_name == reducer.name.local()
                })
            })
            .map(|table| serde_json::to_string(table.accessor_name.deref()).unwrap())
            .unwrap_or_else(|| "\"\"".to_string());
        let private = reducer.visibility.is_private();
        let reducer_name = serde_json::to_string(reducer.accessor_name.deref())?;
        writeln!(body, "\treducer_{reducer_index}, reducer_err_{reducer_index} := host.typed_reducer_definition({args_type}, {reducer_name}, {lifecycle}, private = {private}, row_table = {row_table})").unwrap();
        writeln!(
            body,
            "\tif reducer_err_{reducer_index} != .None do return host.Status(0), false"
        )
        .unwrap();
        for (index, parameter) in reducer.params.elements.iter().enumerate() {
            if let Some(name) = &parameter.name {
                let name = serde_json::to_string(name.deref())?;
                writeln!(body, "\treducer_{reducer_index}.args[{index}].name = {name}").unwrap();
            }
        }
        writeln!(body, "\tappend(&reducers, reducer_{reducer_index})").unwrap();
    }

    writeln!(body, "\ttables: [dynamic]host.Table_Definition").unwrap();
    writeln!(
        body,
        "\tdefer for table in tables do host.delete_table_definition(table)"
    )
    .unwrap();
    for (table_index, table) in iter_tables(module, CodegenVisibility::IncludePrivate).enumerate() {
        let row = type_name(module, table.product_type_ref);
        let access = match table.table_access {
            spacetimedb_lib::db::raw_def::v9::TableAccess::Public => ".Public",
            spacetimedb_lib::db::raw_def::v9::TableAccess::Private => ".Private",
        };
        let indexes = iter_indexes(table).collect::<Vec<_>>();
        for (index_position, index) in indexes.iter().enumerate() {
            let columns = index
                .algorithm
                .columns()
                .iter()
                .map(|column| format!("{}", column.idx()))
                .collect::<Vec<_>>()
                .join(", ");
            let algorithm = match &index.algorithm {
                IndexAlgorithm::BTree(_) => ".BTree",
                IndexAlgorithm::Hash(_) => ".Hash",
                IndexAlgorithm::Direct(_) => ".Direct",
                _ => anyhow::bail!("Odin server schema generation encountered an unsupported index algorithm"),
            };
            let source_name = serde_json::to_string(index.source_name.deref())?;
            let accessor_name = serde_json::to_string(
                index
                    .accessor_name
                    .as_ref()
                    .map(Deref::deref)
                    .unwrap_or(index.source_name.deref()),
            )?;
            writeln!(
                body,
                "\tindex_columns_{table_index}_{index_position} := [?]u16{{{columns}}}"
            )
            .unwrap();
            writeln!(body, "\tindex_{table_index}_{index_position} := host.Table_Index{{source_name = {source_name}, accessor_name = {accessor_name}, algorithm = {algorithm}, columns = index_columns_{table_index}_{index_position}[:]}}").unwrap();
        }
        if indexes.is_empty() {
            writeln!(body, "\tindexes_{table_index}: []host.Table_Index = nil").unwrap();
        } else {
            let entries = (0..indexes.len())
                .map(|index| format!("index_{table_index}_{index}"))
                .collect::<Vec<_>>()
                .join(", ");
            writeln!(body, "\tindexes_{table_index} := [?]host.Table_Index{{{entries}}}").unwrap();
        }

        let mut constraints = Vec::new();
        for constraint in iter_constraints(table) {
            match &constraint.data {
                ConstraintData::Unique(unique) => {
                    constraints.push(unique.columns.iter().map(|column| column.idx()).collect::<Vec<_>>());
                }
                _ => anyhow::bail!("Odin server schema generation encountered an unsupported table constraint"),
            }
        }
        for (constraint_index, columns) in constraints.iter().enumerate() {
            let columns = columns.iter().map(ToString::to_string).collect::<Vec<_>>().join(", ");
            writeln!(
                body,
                "\tunique_columns_{table_index}_{constraint_index} := [?]u16{{{columns}}}"
            )
            .unwrap();
            writeln!(body, "\tunique_{table_index}_{constraint_index} := host.Unique_Constraint{{columns = unique_columns_{table_index}_{constraint_index}[:]}}").unwrap();
        }
        if constraints.is_empty() {
            writeln!(
                body,
                "\tunique_constraints_{table_index}: []host.Unique_Constraint = nil"
            )
            .unwrap();
        } else {
            let entries = (0..constraints.len())
                .map(|index| format!("unique_{table_index}_{index}"))
                .collect::<Vec<_>>()
                .join(", ");
            writeln!(
                body,
                "\tunique_constraints_{table_index} := [?]host.Unique_Constraint{{{entries}}}"
            )
            .unwrap();
        }

        let primary_key = table
            .primary_key
            .map(|column| format!("[]u16{{{}}}", column.idx()))
            .unwrap_or_else(|| "nil".into());
        let table_name = serde_json::to_string(table.accessor_name.deref())?;
        writeln!(body, "\ttable_{table_index}, table_err_{table_index} := host.typed_table_definition({row}, {table_name}, {access}, {primary_key}, indexes_{table_index}[:], unique_constraints_{table_index}[:])").unwrap();
        writeln!(
            body,
            "\tif table_err_{table_index} != .None do return host.Status(0), false"
        )
        .unwrap();
        for (index, column) in table.columns.iter().enumerate() {
            let name = serde_json::to_string(column.accessor_name.deref())?;
            writeln!(body, "\ttable_{table_index}.columns[{index}].name = {name}").unwrap();
        }
        let defaults = table
            .columns
            .iter()
            .filter_map(|column| column.default_value.as_ref().map(|value| (column.col_id.idx(), value)))
            .collect::<Vec<_>>();
        for (default_index, (column, value)) in defaults.iter().enumerate() {
            let bytes = spacetimedb_lib::sats::bsatn::to_vec(value)?;
            let encoded = bytes
                .iter()
                .map(|byte| format!("0x{byte:02x}"))
                .collect::<Vec<_>>()
                .join(", ");
            writeln!(
                body,
                "\tdefault_bytes_{table_index}_{default_index} := [?]u8{{{encoded}}}"
            )
            .unwrap();
            writeln!(body, "\tdefault_{table_index}_{default_index} := host.Column_Default_Value{{column = {column}, bsatn = default_bytes_{table_index}_{default_index}[:]}}").unwrap();
        }
        if defaults.is_empty() {
            writeln!(body, "\ttable_{table_index}.default_values = nil").unwrap();
        } else {
            let entries = (0..defaults.len())
                .map(|index| format!("default_{table_index}_{index}"))
                .collect::<Vec<_>>()
                .join(", ");
            writeln!(
                body,
                "\tdefault_values_{table_index} := [?]host.Column_Default_Value{{{entries}}}"
            )
            .unwrap();
            writeln!(
                body,
                "\ttable_{table_index}.default_values = default_values_{table_index}[:]"
            )
            .unwrap();
        }
        let mut auto_columns = table
            .sequences
            .values()
            .map(|sequence| sequence.column.idx())
            .collect::<Vec<_>>();
        auto_columns.sort_unstable();
        let auto_columns = auto_columns
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(", ");
        if !auto_columns.is_empty() {
            writeln!(body, "\tauto_columns_{table_index} := [?]u16{{{auto_columns}}}").unwrap();
            writeln!(
                body,
                "\ttable_{table_index}.auto_increment_columns = auto_columns_{table_index}[:]"
            )
            .unwrap();
        }
        if table.is_event {
            writeln!(body, "\ttable_{table_index}.is_event = true").unwrap();
        }
        if let Some(schedule) = &table.schedule {
            let function = match schedule.function_kind {
                FunctionKind::Reducer => module
                    .reducers()
                    .find(|reducer| reducer.name.local() == &schedule.function_name)
                    .map(|reducer| reducer.accessor_name.deref()),
                FunctionKind::Procedure => module
                    .procedures()
                    .find(|procedure| procedure.name == schedule.function_name)
                    .map(|procedure| procedure.accessor_name.deref()),
                FunctionKind::Unknown => None,
            }
            .ok_or_else(|| anyhow::anyhow!("could not resolve scheduled function {}", schedule.function_name))?;
            let function = serde_json::to_string(function)?;
            writeln!(body, "\ttable_{table_index}.scheduled_function = {function}").unwrap();
            writeln!(
                body,
                "\ttable_{table_index}.schedule_at_column = {}",
                schedule.at_column.idx()
            )
            .unwrap();
        }
        if let Some(outbox) = &table.outbox {
            let remote_reducer = serde_json::to_string(outbox.remote_reducer.deref())?;
            let target_column = outbox.target_column.idx();
            let arg_columns = outbox
                .arg_columns
                .iter()
                .map(|col| col.idx().to_string())
                .collect::<Vec<_>>()
                .join(", ");
            let result_reducer = outbox
                .on_result_reducer
                .as_ref()
                .map(|name| {
                    let reducer = module
                        .reducers()
                        .find(|reducer| reducer.name.local() == name.local())
                        .ok_or_else(|| anyhow::anyhow!("could not resolve outbox callback {name}"))?;
                    Ok::<_, anyhow::Error>(serde_json::to_string(reducer.accessor_name.deref())?)
                })
                .transpose()?
                .unwrap_or_else(|| "nil".into());
            let signature = outbox
                .signature_hash
                .data
                .iter()
                .map(|byte| format!("0x{byte:02x}"))
                .collect::<Vec<_>>()
                .join(", ");
            writeln!(body, "\toutbox_args_{table_index} := [?]u16{{{arg_columns}}}").unwrap();
            writeln!(body, "\toutbox_{table_index} := host.Outbox_Definition{{remote_reducer = {remote_reducer}, target_column = {target_column}, arg_columns = outbox_args_{table_index}[:], on_result_reducer = runtime.Maybe(string)({result_reducer}), signature_hash = [32]u8{{{signature}}}}}").unwrap();
            writeln!(
                body,
                "\ttable_{table_index}.outbox = runtime.Maybe(host.Outbox_Definition)(outbox_{table_index})"
            )
            .unwrap();
        }
        writeln!(body, "\tappend(&tables, table_{table_index})").unwrap();
    }

    writeln!(body, "\tprocedures: [dynamic]host.Procedure_Definition").unwrap();
    writeln!(body, "\tdefer for procedure in procedures do delete(procedure.args)").unwrap();
    for (procedure_index, procedure) in module.procedures().enumerate() {
        let accessor = procedure.accessor_name.deref().to_string();
        let args_type = server_wire_args_type(module, &accessor, &procedure.params_for_generate);
        let name = serde_json::to_string(procedure.accessor_name.deref())?;
        let return_info = if matches!(
            procedure.return_type_for_generate,
            AlgebraicTypeUse::Unit | AlgebraicTypeUse::Never
        ) {
            "nil".to_string()
        } else {
            format!(
                "type_info_of({})",
                odin_type(module, &procedure.return_type_for_generate, &mut uses)
            )
        };
        let private = procedure.visibility.is_private();
        writeln!(body, "\tprocedure_{procedure_index}, procedure_err_{procedure_index} := host.typed_procedure_definition({args_type}, {name}, {return_info}, private = {private})").unwrap();
        writeln!(
            body,
            "\tif procedure_err_{procedure_index} != .None do return host.Status(0), false"
        )
        .unwrap();
        for (index, parameter) in procedure.params.elements.iter().enumerate() {
            if let Some(name) = &parameter.name {
                let name = serde_json::to_string(name.deref())?;
                writeln!(body, "\tprocedure_{procedure_index}.args[{index}].name = {name}").unwrap();
            }
        }
        if let Some(table) = module.tables().find(|table| {
            table.schedule.as_ref().is_some_and(|schedule| {
                schedule.function_kind == FunctionKind::Procedure && schedule.function_name == procedure.name
            })
        }) {
            let table_name = serde_json::to_string(table.accessor_name.deref())?;
            writeln!(body, "\tprocedure_{procedure_index}.args[0].table_ref = {table_name}").unwrap();
        }
        writeln!(body, "\tappend(&procedures, procedure_{procedure_index})").unwrap();
    }

    writeln!(body, "\tviews: [dynamic]host.View_Definition").unwrap();
    writeln!(body, "\tdefer for view in views do delete(view.args)").unwrap();
    for (view_index, view) in module.views().enumerate() {
        let accessor = view.accessor_name.deref().to_string();
        let args_type = server_wire_args_type(module, &accessor, &view.params_for_generate);
        let name = serde_json::to_string(view.accessor_name.deref())?;
        let row = type_name(module, view.product_type_ref);
        let key = view
            .primary_key
            .filter(|_| view.is_procedural())
            .and_then(|column| view.return_columns.get(column.idx()))
            .map(|column| serde_json::to_string(column.name.deref()))
            .transpose()?
            .unwrap_or_else(|| "\"\"".into());
        writeln!(body, "\tview_{view_index}, view_err_{view_index} := host.typed_view_definition({args_type}, {row}, {name}, is_anonymous = {}, primary_key = {key})", view.is_anonymous).unwrap();
        writeln!(
            body,
            "\tif view_err_{view_index} != .None do return host.Status(0), false"
        )
        .unwrap();
        let return_kind = if view.return_type.as_option().is_some() {
            ".Option"
        } else if view.return_type.as_array().is_some() {
            ".Array"
        } else {
            ".Query"
        };
        writeln!(body, "\tview_{view_index}.return_kind = {return_kind}").unwrap();
        for (index, parameter) in view.params.elements.iter().enumerate() {
            if let Some(name) = &parameter.name {
                let name = serde_json::to_string(name.deref())?;
                writeln!(body, "\tview_{view_index}.args[{index}].name = {name}").unwrap();
            }
        }
        writeln!(body, "\tview_{view_index}.fn_ptr = u32({})", view.fn_ptr.0).unwrap();
        writeln!(body, "\tappend(&views, view_{view_index})").unwrap();
    }

    let handlers = module
        .http_handlers()
        .map(|handler| serde_json::to_string(handler.accessor_name.deref()))
        .collect::<Result<Vec<_>, _>>()?;
    if handlers.is_empty() {
        writeln!(body, "\thandlers: []string = nil").unwrap();
    } else {
        writeln!(body, "\thandlers := [?]string{{{}}}", handlers.join(", ")).unwrap();
    }
    writeln!(body, "\troutes: [dynamic]host.Http_Route").unwrap();
    for route in module.http_routes() {
        let handler = module
            .http_handlers()
            .find(|handler| handler.name == route.handler_name)
            .ok_or_else(|| anyhow::anyhow!("could not resolve HTTP handler {}", route.handler_name))?;
        let handler = serde_json::to_string(handler.accessor_name.deref())?;
        let path = serde_json::to_string(route.path.as_ref())?;
        match &route.method {
            spacetimedb_lib::db::raw_def::v10::MethodOrAny::Any => {
                writeln!(
                    body,
                    "\tappend(&routes, host.Http_Route{{handler = {handler}, path = {path}, any_method = true}})"
                )
                .unwrap();
            }
            spacetimedb_lib::db::raw_def::v10::MethodOrAny::Method(method) => {
                let (method, extension) = match method {
                    spacetimedb_lib::http::Method::Get => (".Get", "\"\"".to_string()),
                    spacetimedb_lib::http::Method::Head => (".Head", "\"\"".to_string()),
                    spacetimedb_lib::http::Method::Post => (".Post", "\"\"".to_string()),
                    spacetimedb_lib::http::Method::Put => (".Put", "\"\"".to_string()),
                    spacetimedb_lib::http::Method::Delete => (".Delete", "\"\"".to_string()),
                    spacetimedb_lib::http::Method::Connect => (".Connect", "\"\"".to_string()),
                    spacetimedb_lib::http::Method::Options => (".Options", "\"\"".to_string()),
                    spacetimedb_lib::http::Method::Trace => (".Trace", "\"\"".to_string()),
                    spacetimedb_lib::http::Method::Patch => (".Patch", "\"\"".to_string()),
                    spacetimedb_lib::http::Method::Extension(name) => (".Extension", serde_json::to_string(name)?),
                };
                writeln!(body, "\tappend(&routes, host.Http_Route{{handler = {handler}, path = {path}, method = {method}, method_extension = {extension}}})").unwrap();
            }
            _ => anyhow::bail!("Odin server schema generation encountered an unsupported HTTP route method"),
        }
    }

    writeln!(body, "\tenvironment: [dynamic]host.Environment_Definition").unwrap();
    for (environment_index, declaration) in module.environment().declarations().enumerate() {
        let name = serde_json::to_string(&declaration.name)?;
        let optional = declaration.optional;
        let (ty, literal, values) = match &declaration.ty {
            spacetimedb_lib::environment::EnvVarType::String => (".String", "\"\"".to_string(), "nil".to_string()),
            spacetimedb_lib::environment::EnvVarType::StringLiteral(value) => {
                (".String_Literal", serde_json::to_string(value)?, "nil".to_string())
            }
            spacetimedb_lib::environment::EnvVarType::Union(items) => {
                let values = items
                    .iter()
                    .map(|item| serde_json::to_string(item))
                    .collect::<Result<Vec<_>, _>>()?
                    .join(", ");
                writeln!(body, "\tenv_values_{environment_index} := [?]string{{{values}}}").unwrap();
                (
                    ".Union",
                    "\"\"".to_string(),
                    format!("env_values_{environment_index}[:]"),
                )
            }
        };
        writeln!(body, "\tappend(&environment, host.Environment_Definition{{name = {name}, type = {ty}, literal = {literal}, values = {values}, optional = {optional}}})").unwrap();
    }
    let mut rls_policies = module
        .row_level_security()
        .map(|policy| serde_json::to_string(policy.sql.as_ref()))
        .collect::<Result<Vec<_>, _>>()?;
    rls_policies.sort();
    if rls_policies.is_empty() {
        writeln!(body, "\trls_policies: []host.Row_Level_Security_Definition = nil").unwrap();
    } else {
        let entries = rls_policies
            .iter()
            .map(|sql| format!("{{sql = {sql}}}"))
            .collect::<Vec<_>>()
            .join(", ");
        writeln!(
            body,
            "\trls_policies := [?]host.Row_Level_Security_Definition{{{entries}}}"
        )
        .unwrap();
    }
    let submodules = module.submodules().iter().collect::<Vec<_>>();
    if submodules.is_empty() {
        writeln!(body, "\tsubmodules: []host.Submodule_Definition = nil").unwrap();
    } else {
        for (index, (namespace, submodule)) in submodules.iter().enumerate() {
            let raw: spacetimedb_lib::db::raw_def::v10::RawModuleDefV10 = (*submodule).clone().into();
            let bytes = spacetimedb_lib::sats::bsatn::to_vec(&raw)?;
            let encoded = bytes
                .iter()
                .map(|byte| format!("0x{byte:02x}"))
                .collect::<Vec<_>>()
                .join(", ");
            let accessor = submodule.mount_accessor_name().unwrap_or(namespace);
            let accessor = serde_json::to_string(accessor.deref())?;
            writeln!(body, "\tsubmodule_bytes_{index} := [?]u8{{{encoded}}}").unwrap();
            writeln!(body, "\tsubmodule_{index} := host.Submodule_Definition{{namespace = {accessor}, module_bsatn = submodule_bytes_{index}[:]}}").unwrap();
        }
        let entries = (0..submodules.len())
            .map(|index| format!("submodule_{index}"))
            .collect::<Vec<_>>()
            .join(", ");
        writeln!(body, "\tsubmodules := [?]host.Submodule_Definition{{{entries}}}").unwrap();
    }
    let mut variants = Vec::new();
    let mut enum_variants = Vec::new();
    for typ in iter_types(module) {
        let Some(spacetimedb_lib::AlgebraicType::Sum(raw_sum)) = module.typespace().get(typ.ty) else {
            continue;
        };
        if let Some(AlgebraicTypeDef::Sum(sum)) = module.typespace_for_generate().get(typ.ty) {
            let name = type_name(module, typ.ty);
            for ((variant, _), raw_variant) in sum.variants.iter().zip(raw_sum.variants.iter()) {
                let wrapper = format!("{name}_{}", ada_case(variant.deref()));
                let variant_name = serde_json::to_string(raw_variant.name.as_deref().unwrap_or(variant.deref()))?;
                variants.push(format!("{{info = type_info_of({wrapper}), name = {variant_name}}}"));
            }
        } else if matches!(
            module.typespace_for_generate().get(typ.ty),
            Some(AlgebraicTypeDef::PlainEnum(_))
        ) {
            let names = raw_sum
                .variants
                .iter()
                .map(|variant| serde_json::to_string(variant.name.as_deref().unwrap_or("")))
                .collect::<Result<Vec<_>, _>>()?
                .join(", ");
            let index = enum_variants.len();
            writeln!(body, "\tenum_names_{index} := [?]string{{{names}}}").unwrap();
            enum_variants.push(format!(
                "{{info = type_info_of({}), names = enum_names_{index}[:]}}",
                type_name(module, typ.ty)
            ));
        }
    }
    if variants.is_empty() {
        writeln!(body, "\tsum_variants: []host.Sum_Variant_Definition = nil").unwrap();
    } else {
        writeln!(
            body,
            "\tsum_variants := [?]host.Sum_Variant_Definition{{{}}}",
            variants.join(", ")
        )
        .unwrap();
    }
    if enum_variants.is_empty() {
        writeln!(body, "\tenum_variants: []host.Enum_Variant_Definition = nil").unwrap();
    } else {
        writeln!(
            body,
            "\tenum_variants := [?]host.Enum_Variant_Definition{{{}}}",
            enum_variants.join(", ")
        )
        .unwrap();
    }
    let raw: spacetimedb_lib::db::raw_def::v10::RawModuleDefV10 = module.clone().into();
    let explicit_names = raw
        .sections
        .iter()
        .find(|section| {
            matches!(
                section,
                spacetimedb_lib::db::raw_def::v10::RawModuleDefV10Section::ExplicitNames(_)
            )
        })
        .expect("module conversion emits explicit names");
    let bytes = spacetimedb_lib::sats::bsatn::to_vec(explicit_names)?;
    let encoded = bytes
        .iter()
        .map(|byte| format!("0x{byte:02x}"))
        .collect::<Vec<_>>()
        .join(", ");
    writeln!(body, "\texplicit_names := [?]u8{{{encoded}}}").unwrap();
    let policy = server_case_conversion_policy(module)?;
    let policy = spacetimedb_lib::db::raw_def::v10::RawModuleDefV10Section::CaseConversionPolicy(policy);
    let bytes = spacetimedb_lib::sats::bsatn::to_vec(&policy)?;
    let encoded = bytes
        .iter()
        .map(|byte| format!("0x{byte:02x}"))
        .collect::<Vec<_>>()
        .join(", ");
    writeln!(body, "\tcase_policy := [?]u8{{{encoded}}}").unwrap();
    let mut exported_types = Vec::new();
    let mut type_fields = Vec::new();
    for (index, typ) in iter_types(module).enumerate() {
        let segments = typ.accessor_name.name_segments().collect::<Vec<_>>();
        let scope = segments[..segments.len() - 1]
            .iter()
            .map(|segment| serde_json::to_string(&segment.to_string()))
            .collect::<Result<Vec<_>, _>>()?
            .join(", ");
        if scope.is_empty() {
            writeln!(body, "\ttype_scope_{index}: []string = nil").unwrap();
        } else {
            writeln!(body, "\ttype_scope_{index} := [?]string{{{scope}}}").unwrap();
        }
        let name = serde_json::to_string(typ.accessor_name.name().deref())?;
        exported_types.push(format!(
            "{{info = type_info_of({}), scope = type_scope_{index}[:], name = {name}, custom_ordering = {}}}",
            type_name(module, typ.ty),
            typ.custom_ordering
        ));
        if let Some(AlgebraicTypeDef::Product(product)) = module.typespace_for_generate().get(typ.ty) {
            let names = product
                .elements
                .iter()
                .map(|(name, _)| serde_json::to_string(name.deref()))
                .collect::<Result<Vec<_>, _>>()?
                .join(", ");
            if names.is_empty() {
                writeln!(body, "\ttype_fields_{index}: []string = nil").unwrap();
            } else {
                writeln!(body, "\ttype_fields_{index} := [?]string{{{names}}}").unwrap();
            }
            type_fields.push(format!(
                "{{info = type_info_of({}), names = type_fields_{index}[:]}}",
                type_name(module, typ.ty)
            ));
        }
    }
    if exported_types.is_empty() {
        writeln!(body, "\texported_types: []host.Type_Export_Definition = nil").unwrap();
    } else {
        writeln!(
            body,
            "\texported_types := [?]host.Type_Export_Definition{{{}}}",
            exported_types.join(", ")
        )
        .unwrap();
    }
    let environment_declared = raw.sections.iter().any(|section| {
        matches!(
            section,
            spacetimedb_lib::db::raw_def::v10::RawModuleDefV10Section::Environment(_)
        )
    });
    if type_fields.is_empty() {
        writeln!(body, "\ttype_fields: []host.Type_Field_Definition = nil").unwrap();
    } else {
        writeln!(
            body,
            "\ttype_fields := [?]host.Type_Field_Definition{{{}}}",
            type_fields.join(", ")
        )
        .unwrap();
    }
    writeln!(body, "\treturn host.write_module_def_all(description, reducers[:], tables[:], views[:], procedures[:], handlers[:], routes[:], environment[:], rls_policies[:], submodules[:], sum_variants[:], enum_variants[:], explicit_names[:], case_policy[:], exported_types[:], {environment_declared}, type_fields[:])").unwrap();
    writeln!(body, "}}\n").unwrap();

    let mut code = String::from(
        "// THIS FILE IS AUTOMATICALLY GENERATED BY SPACETIMEDB. EDITS TO THIS FILE\n// WILL NOT BE SAVED. REGENERATE WITH `spacetime generate --bindings server --lang odin`.\n\npackage module_schema\n\n",
    );
    uses.write_imports(&mut code);
    code.push_str(&body);
    let mut files = vec![
        OutputFile {
            filename: "module_schema/module_schema.odin".into(),
            code,
        },
        generate_server_entrypoints(module)?,
        generate_server_handler_stubs(module, "module_schema", false)?,
        generate_server_handler_stubs(module, "module_schema", true)?,
    ];
    let mut owners = Vec::new();
    collect_server_submodules(module, &mut owners);
    for owner in owners {
        let package = server_submodule_package(owner);
        let mut uses = Uses {
            host: true,
            runtime: true,
            ..Uses::default()
        };
        let mut body = String::new();
        write_server_module_types(&mut body, owner, &mut uses)?;
        let mut code = format!(
            "// THIS FILE IS AUTOMATICALLY GENERATED BY SPACETIMEDB. EDITS TO THIS FILE\n// WILL NOT BE SAVED. REGENERATE WITH `spacetime generate --bindings server --lang odin`.\n\npackage {package}\n\n",
        );
        uses.write_imports(&mut code);
        code.push_str(&body);
        files.push(OutputFile {
            filename: format!("module_schema/{package}/module_types.odin"),
            code,
        });
        let mut handlers = generate_server_handler_stubs(owner, &package, false)?;
        handlers.filename = format!("module_schema/{package}/module_handlers.odin");
        files.push(handlers);
        let mut templates = generate_server_handler_stubs(owner, &package, true)?;
        templates.filename = format!("module_schema/{package}/module_handler_templates.odin.txt");
        files.push(templates);
    }
    Ok(files)
}

fn write_server_module_types(body: &mut String, module: &ModuleDef, uses: &mut Uses) -> anyhow::Result<()> {
    let mut emitted_type_refs = BTreeSet::new();
    for typ in iter_types(module) {
        let name = type_name(module, typ.ty);
        match module.typespace_for_generate().get(typ.ty) {
            Some(AlgebraicTypeDef::Product(product)) => {
                write_struct(body, &name, &product_fields(module, product, uses));
            }
            Some(AlgebraicTypeDef::Sum(sum)) => write_sum(body, module, &name, sum, uses),
            Some(AlgebraicTypeDef::PlainEnum(plain)) => write_plain_enum(body, &name, plain),
            None => anyhow::bail!("could not resolve generated type {name:?}"),
        }
        emitted_type_refs.insert(typ.ty);
        writeln!(body).unwrap();
    }
    for (_, _, row_type_ref) in iter_table_names_and_types(module, CodegenVisibility::IncludePrivate) {
        if !emitted_type_refs.insert(row_type_ref) {
            continue;
        }
        let name = type_name(module, row_type_ref);
        let Some(AlgebraicTypeDef::Product(product)) = module.typespace_for_generate().get(row_type_ref) else {
            anyhow::bail!("row type {name:?} is not a product type");
        };
        write_struct(body, &name, &product_fields(module, product, uses));
        writeln!(body).unwrap();
    }
    for reducer in module.reducers() {
        let args_type = format!("{}_Args", ada_case(reducer.accessor_name.deref()));
        let fields = reducer
            .params_for_generate
            .elements
            .iter()
            .map(|(name, ty)| (field_name(name.deref()), odin_type(module, ty, uses)))
            .collect::<Vec<_>>();
        write_server_args(
            body,
            &args_type,
            fields,
            server_args_need_padding(module, &reducer.params_for_generate),
        );
        writeln!(body).unwrap();
    }
    for procedure in module.procedures() {
        let args_type = format!("{}_Args", ada_case(procedure.accessor_name.deref()));
        let fields = procedure
            .params_for_generate
            .elements
            .iter()
            .map(|(name, ty)| (field_name(name.deref()), odin_type(module, ty, uses)))
            .collect::<Vec<_>>();
        write_server_args(
            body,
            &args_type,
            fields,
            server_args_need_padding(module, &procedure.params_for_generate),
        );
        writeln!(body).unwrap();
    }
    for view in module.views() {
        let args_type = format!("{}_Args", ada_case(view.accessor_name.deref()));
        let fields = view
            .params_for_generate
            .elements
            .iter()
            .map(|(name, ty)| (field_name(name.deref()), odin_type(module, ty, uses)))
            .collect::<Vec<_>>();
        write_server_args(
            body,
            &args_type,
            fields,
            server_args_need_padding(module, &view.params_for_generate),
        );
        writeln!(body).unwrap();
    }
    Ok(())
}

fn server_case_conversion_policy(
    module: &ModuleDef,
) -> anyhow::Result<spacetimedb_lib::db::raw_def::v10::CaseConversionPolicy> {
    use spacetimedb_lib::db::raw_def::v10::CaseConversionPolicy;

    let mut needs_snake = false;
    let mut needs_none = false;
    let mut observe = |source: &str, canonical: &str| -> anyhow::Result<()> {
        let snake = source.to_case(Case::Snake);
        if source != canonical && snake == canonical {
            needs_snake = true;
        } else if source == canonical && snake != canonical {
            needs_none = true;
        } else if source != canonical {
            anyhow::bail!("cannot preserve field name {canonical}");
        }
        Ok(())
    };
    for column in module.tables().flat_map(|table| &table.columns) {
        observe(column.accessor_name.deref(), column.name.deref())?;
    }
    for typ in iter_types(module) {
        if let (Some(spacetimedb_lib::AlgebraicType::Product(raw)), Some(AlgebraicTypeDef::Product(generated))) = (
            module.typespace().get(typ.ty),
            module.typespace_for_generate().get(typ.ty),
        ) {
            for (field, (source, _)) in raw.elements.iter().zip(&generated.elements) {
                if let Some(canonical) = &field.name {
                    observe(source.deref(), canonical.deref())?;
                }
            }
        }
    }
    anyhow::ensure!(
        !(needs_snake && needs_none),
        "cannot preserve mixed column case policies"
    );
    Ok(if needs_snake {
        CaseConversionPolicy::SnakeCase
    } else {
        CaseConversionPolicy::None
    })
}

fn write_server_args(body: &mut String, name: &str, mut fields: Vec<(String, String)>, padded: bool) {
    if padded {
        write_struct(body, &format!("{name}_Wire"), &fields);
        writeln!(body).unwrap();
        fields.push(("__stdb_unit".into(), "u8".into()));
    }
    write_struct(body, name, &fields);
}

fn server_wire_args_type(module: &ModuleDef, accessor: &str, params: &ProductTypeDef) -> String {
    let name = format!("{}_Args", ada_case(accessor));
    if server_args_need_padding(module, params) {
        format!("{name}_Wire")
    } else {
        name
    }
}

fn server_args_need_padding(module: &ModuleDef, params: &ProductTypeDef) -> bool {
    fn zero_sized(
        module: &ModuleDef,
        ty: &AlgebraicTypeUse,
        visiting: &mut BTreeSet<spacetimedb_lib::sats::AlgebraicTypeRef>,
    ) -> bool {
        match ty {
            AlgebraicTypeUse::Unit | AlgebraicTypeUse::Never => true,
            AlgebraicTypeUse::Ref(type_ref) if visiting.insert(*type_ref) => {
                let result = match module.typespace_for_generate().get(*type_ref) {
                    Some(AlgebraicTypeDef::Product(product)) => product
                        .elements
                        .iter()
                        .all(|(_, field)| zero_sized(module, field, visiting)),
                    _ => false,
                };
                visiting.remove(type_ref);
                result
            }
            _ => false,
        }
    }
    params
        .elements
        .iter()
        .all(|(_, ty)| zero_sized(module, ty, &mut BTreeSet::new()))
}

fn server_submodule_package(module: &ModuleDef) -> String {
    let mut name = String::from("submodule");
    for segment in module.accessor_path().segments() {
        name.push('_');
        for byte in segment.deref().as_bytes() {
            write!(name, "{byte:02x}").unwrap();
        }
    }
    name
}

fn collect_server_submodules<'a>(module: &'a ModuleDef, submodules: &mut Vec<&'a ModuleDef>) {
    for submodule in module.submodules().values() {
        submodules.push(submodule);
        collect_server_submodules(submodule, submodules);
    }
}

fn generate_server_entrypoints(module: &ModuleDef) -> anyhow::Result<OutputFile> {
    let mut body = String::new();
    let reducers = module.all_reducers_with_prefix();
    let procedures = module.all_procedures_with_prefix();
    let views = module.all_views_with_prefix();
    writeln!(body, "@(export, link_name = \"__describe_module__\")").unwrap();
    writeln!(body, "describe_module :: proc \"c\" (description: host.Bytes_Sink) {{").unwrap();
    writeln!(body, "\tcontext = host.scratch_context()").unwrap();
    writeln!(body, "\t_, _ = write_module_definition(description)").unwrap();
    writeln!(body, "}}\n").unwrap();

    {
        writeln!(body, "@(export, link_name = \"__call_reducer__\")").unwrap();
        writeln!(body, "call_reducer :: proc \"c\" (").unwrap();
        writeln!(body, "\tid: uint,").unwrap();
        writeln!(body, "\tsender_0, sender_1, sender_2, sender_3: u64,").unwrap();
        writeln!(body, "\tconn_id_0, conn_id_1: u64,").unwrap();
        writeln!(body, "\ttimestamp: u64,").unwrap();
        writeln!(body, "\targs: host.Bytes_Source,").unwrap();
        writeln!(body, "\terror: host.Bytes_Sink,").unwrap();
        writeln!(body, ") -> i16 {{").unwrap();
        writeln!(body, "\tcontext = host.scratch_context()").unwrap();
        if !reducers.is_empty() {
            writeln!(
                body,
                "\tcaller := host.reducer_context(sender_0, sender_1, sender_2, sender_3, conn_id_0, conn_id_1, timestamp)"
            )
            .unwrap();
        }
        for (index, (path, owner, reducer)) in reducers.iter().enumerate() {
            let accessor = reducer.accessor_name.deref().to_string();
            let prefix = if path.is_empty() {
                String::new()
            } else {
                format!("{}.", server_submodule_package(owner))
            };
            let args_type = format!("{prefix}{}_Args", ada_case(&accessor));
            writeln!(body, "\tif id == {index} {{").unwrap();
            write_read_typed_args(
                &mut body,
                &args_type,
                index,
                "error",
                true,
                server_args_need_padding(owner, &reducer.params_for_generate),
            );
            writeln!(
                body,
                "\t\treturn {prefix}handle_{accessor}_reducer(caller, decoded_args_{index}, error)"
            )
            .unwrap();
            writeln!(body, "\t}}").unwrap();
        }
        writeln!(body, "\treturn host.reducer_fail(error, \"unknown reducer id\")").unwrap();
        writeln!(body, "}}\n").unwrap();
    }

    if !procedures.is_empty() {
        writeln!(body, "@(export, link_name = \"__call_procedure__\")").unwrap();
        writeln!(body, "call_procedure :: proc \"c\" (").unwrap();
        writeln!(body, "\tid: uint,").unwrap();
        writeln!(body, "\tsender_0, sender_1, sender_2, sender_3: u64,").unwrap();
        writeln!(body, "\tconn_id_0, conn_id_1: u64,").unwrap();
        writeln!(body, "\ttimestamp: u64,").unwrap();
        writeln!(body, "\targs: host.Bytes_Source,").unwrap();
        writeln!(body, "\tresult: host.Bytes_Sink,").unwrap();
        writeln!(body, ") -> i16 {{").unwrap();
        writeln!(body, "\tcontext = host.scratch_context()").unwrap();
        writeln!(body, "\tcaller := host.procedure_context(sender_0, sender_1, sender_2, sender_3, conn_id_0, conn_id_1, timestamp)").unwrap();
        for (index, (path, owner, procedure)) in procedures.iter().enumerate() {
            let accessor = procedure.accessor_name.deref();
            let prefix = if path.is_empty() {
                String::new()
            } else {
                format!("{}.", server_submodule_package(owner))
            };
            let args_type = format!("{prefix}{}_Args", ada_case(accessor));
            writeln!(body, "\tif id == {index} {{").unwrap();
            write_read_typed_args(
                &mut body,
                &args_type,
                index,
                "result",
                false,
                server_args_need_padding(owner, &procedure.params_for_generate),
            );
            writeln!(
                body,
                "\t\treturn {prefix}handle_{accessor}_procedure(caller, decoded_args_{index}, result)"
            )
            .unwrap();
            writeln!(body, "\t}}").unwrap();
        }
        writeln!(body, "\treturn -1").unwrap();
        writeln!(body, "}}\n").unwrap();
    }

    let caller_views = views
        .iter()
        .filter(|(_, _, view)| !view.is_anonymous)
        .collect::<Vec<_>>();
    if !caller_views.is_empty() {
        writeln!(body, "@(export, link_name = \"__call_view__\")").unwrap();
        writeln!(body, "call_view :: proc \"c\" (id: uint, sender_0, sender_1, sender_2, sender_3: u64, args: host.Bytes_Source, result: host.Bytes_Sink) -> i16 {{").unwrap();
        writeln!(body, "\tcontext = host.scratch_context()").unwrap();
        writeln!(
            body,
            "\tsender := host.reducer_context(sender_0, sender_1, sender_2, sender_3, 0, 0, 0).sender"
        )
        .unwrap();
        for (path, owner, view) in caller_views {
            let name = path.join(view.name.clone());
            let (index, _, _) = module
                .view_by_name_with_global_fn_ptr(&name)
                .ok_or_else(|| anyhow::anyhow!("could not resolve view {name}"))?;
            let index = index.0;
            let prefix = if path.is_empty() {
                String::new()
            } else {
                format!("{}.", server_submodule_package(owner))
            };
            let accessor = view.accessor_name.deref();
            writeln!(
                body,
                "\tif id == {index} do return {prefix}handle_{accessor}_view(sender, args, result)"
            )
            .unwrap();
        }
        writeln!(body, "\treturn -1").unwrap();
        writeln!(body, "}}\n").unwrap();
    }

    let anonymous_views = views
        .iter()
        .filter(|(_, _, view)| view.is_anonymous)
        .collect::<Vec<_>>();
    if !anonymous_views.is_empty() {
        writeln!(body, "@(export, link_name = \"__call_view_anon__\")").unwrap();
        writeln!(
            body,
            "call_view_anon :: proc \"c\" (id: uint, args: host.Bytes_Source, result: host.Bytes_Sink) -> i16 {{"
        )
        .unwrap();
        writeln!(body, "\tcontext = host.scratch_context()").unwrap();
        for (path, owner, view) in anonymous_views {
            let name = path.join(view.name.clone());
            let (index, _, _) = module
                .view_by_name_with_global_fn_ptr(&name)
                .ok_or_else(|| anyhow::anyhow!("could not resolve view {name}"))?;
            let index = index.0;
            let prefix = if path.is_empty() {
                String::new()
            } else {
                format!("{}.", server_submodule_package(owner))
            };
            let accessor = view.accessor_name.deref();
            writeln!(
                body,
                "\tif id == {index} do return {prefix}handle_{accessor}_view_anon(args, result)"
            )
            .unwrap();
        }
        writeln!(body, "\treturn -1").unwrap();
        writeln!(body, "}}\n").unwrap();
    }

    let handlers = module.http_handlers().collect::<Vec<_>>();
    if !handlers.is_empty() {
        writeln!(body, "@(export, link_name = \"__call_http_handler__\")").unwrap();
        writeln!(body, "call_http_handler :: proc \"c\" (id: uint, sender_0, sender_1, sender_2, sender_3: u64, sender_jwt: host.Bytes_Source, timestamp: u64, request: host.Bytes_Source, request_body: host.Bytes_Source, response_sink, response_body_sink: host.Bytes_Sink) -> i16 {{").unwrap();
        writeln!(body, "\tcontext = host.scratch_context()").unwrap();
        writeln!(body, "\tjwt_payload, jwt_ok := host.read_bytes_source(sender_jwt)").unwrap();
        writeln!(body, "\tif !jwt_ok do return -1").unwrap();
        writeln!(body, "\tdefer delete(jwt_payload)").unwrap();
        writeln!(body, "\thandler_context := host.http_handler_context(sender_0, sender_1, sender_2, sender_3, jwt_payload, timestamp)").unwrap();
        for (index, handler) in handlers.iter().enumerate() {
            let accessor = handler.accessor_name.deref();
            writeln!(body, "\tif id == {index} do return handle_{accessor}_http(handler_context, request, request_body, response_sink, response_body_sink)").unwrap();
        }
        writeln!(body, "\t_ = host.write_http_response(response_sink, response_body_sink, 404, nil, transmute([]u8)string(\"no such handler\"))").unwrap();
        writeln!(body, "\treturn host.HTTP_HANDLER_OK").unwrap();
        writeln!(body, "}}\n").unwrap();
    }

    let mut code = String::from(
        "// THIS FILE IS AUTOMATICALLY GENERATED BY SPACETIMEDB. EDITS TO THIS FILE\n// WILL NOT BE SAVED. REGENERATE WITH `spacetime generate --bindings server --lang odin`.\n\npackage module_schema\n\nimport \"stdb:host\"\n",
    );
    let mut imported_packages = BTreeSet::new();
    let owners = reducers
        .iter()
        .map(|(path, owner, _)| (path, owner))
        .chain(procedures.iter().map(|(path, owner, _)| (path, owner)))
        .chain(views.iter().map(|(path, owner, _)| (path, owner)));
    for (path, owner) in owners {
        if !path.is_empty() {
            let package = server_submodule_package(owner);
            if imported_packages.insert(package.clone()) {
                writeln!(code, "import {package} \"{package}\"").unwrap();
            }
        }
    }
    writeln!(code).unwrap();
    code.push_str(&body);
    Ok(OutputFile {
        filename: "module_schema/module_entrypoints.odin".into(),
        code,
    })
}

fn write_read_typed_args(
    body: &mut String,
    args_type: &str,
    index: usize,
    error_sink: &str,
    reducer: bool,
    empty: bool,
) {
    writeln!(body, "\t\targs_length_{index}: u32").unwrap();
    writeln!(
        body,
        "\t\tif args != host.INVALID_BYTES_SOURCE && host.bytes_source_remaining_length(args, &args_length_{index}) != 0 {{"
    )
    .unwrap();
    if reducer {
        writeln!(
            body,
            "\t\t\treturn host.reducer_fail({error_sink}, \"failed to read reducer arguments\")"
        )
        .unwrap();
    } else {
        writeln!(body, "\t\t\treturn -1").unwrap();
    }
    writeln!(body, "\t\t}}").unwrap();
    if empty {
        writeln!(body, "\t\tif args_length_{index} != 0 {{").unwrap();
        if reducer {
            writeln!(
                body,
                "\t\t\treturn host.reducer_fail({error_sink}, \"invalid reducer arguments\")"
            )
            .unwrap();
        } else {
            writeln!(body, "\t\t\treturn -1").unwrap();
        }
        writeln!(body, "\t\t}}").unwrap();
        writeln!(body, "\t\tdecoded_args_{index}: {args_type}").unwrap();
        return;
    }
    writeln!(body, "\t\targ_buffer_{index} := make([]u8, int(args_length_{index}))").unwrap();
    writeln!(body, "\t\tdefer delete(arg_buffer_{index})").unwrap();
    writeln!(
        body,
        "\t\tdecoded_args_{index}, decode_err_{index} := host.read_reducer_args({args_type}, args, arg_buffer_{index})"
    )
    .unwrap();
    writeln!(body, "\t\tif decode_err_{index} != .None {{").unwrap();
    if reducer {
        writeln!(
            body,
            "\t\t\treturn host.reducer_fail({error_sink}, \"invalid reducer arguments\")"
        )
        .unwrap();
    } else {
        writeln!(body, "\t\t\treturn -1").unwrap();
    }
    writeln!(body, "\t\t}}").unwrap();
}

fn generate_server_handler_stubs(module: &ModuleDef, package: &str, template: bool) -> anyhow::Result<OutputFile> {
    let header = if template {
        "// THIS FILE IS AUTOMATICALLY GENERATED BY SPACETIMEDB. EDITS TO THIS FILE\n// WILL NOT BE SAVED. REGENERATE WITH `spacetime generate --bindings server --lang odin`."
    } else {
        "// USER-OWNED FILE: edit these handlers; server schema generation preserves this file."
    };
    let mut body = format!("{header}\n\npackage {package}\n\nimport \"stdb:host\"\n\n");
    for reducer in module.reducers() {
        let accessor = reducer.accessor_name.deref();
        let args_type = format!("{}_Args", ada_case(accessor));
        writeln!(body, "handle_{accessor}_reducer :: proc(ctx: host.Reducer_Context, args: {args_type}, error: host.Bytes_Sink) -> i16 {{").unwrap();
        writeln!(body, "\t_ = ctx").unwrap();
        writeln!(body, "\t_ = args").unwrap();
        writeln!(
            body,
            "\treturn host.reducer_fail(error, \"implement reducer {accessor}\")"
        )
        .unwrap();
        writeln!(body, "}}\n").unwrap();
    }
    for procedure in module.procedures() {
        let accessor = procedure.accessor_name.deref();
        let args_type = format!("{}_Args", ada_case(accessor));
        writeln!(body, "handle_{accessor}_procedure :: proc(ctx: host.Procedure_Context, args: {args_type}, result: host.Bytes_Sink) -> i16 {{").unwrap();
        writeln!(body, "\t_ = ctx").unwrap();
        writeln!(body, "\t_ = args").unwrap();
        writeln!(body, "\t_ = result").unwrap();
        writeln!(body, "\treturn -1 // implement this procedure").unwrap();
        writeln!(body, "}}\n").unwrap();
    }
    for view in module.views() {
        let accessor = view.accessor_name.deref();
        if view.is_anonymous {
            writeln!(
                body,
                "handle_{accessor}_view_anon :: proc(args: host.Bytes_Source, result: host.Bytes_Sink) -> i16 {{"
            )
            .unwrap();
        } else {
            writeln!(body, "handle_{accessor}_view :: proc(sender: host.Identity, args: host.Bytes_Source, result: host.Bytes_Sink) -> i16 {{").unwrap();
            writeln!(body, "\t_ = sender").unwrap();
        }
        writeln!(body, "\t_ = args").unwrap();
        writeln!(body, "\t_ = result").unwrap();
        writeln!(body, "\treturn -1 // implement this view").unwrap();
        writeln!(body, "}}\n").unwrap();
    }
    for handler in module.http_handlers() {
        let accessor = handler.accessor_name.deref();
        writeln!(body, "handle_{accessor}_http :: proc(ctx: host.Http_Handler_Context, request, request_body: host.Bytes_Source, response_sink, response_body_sink: host.Bytes_Sink) -> i16 {{").unwrap();
        writeln!(body, "\t_ = ctx").unwrap();
        writeln!(body, "\t_ = request").unwrap();
        writeln!(body, "\t_ = request_body").unwrap();
        writeln!(body, "\t_ = host.write_http_response(response_sink, response_body_sink, 501, nil, transmute([]u8)string(\"implement handler {accessor}\"))").unwrap();
        writeln!(body, "\treturn host.HTTP_HANDLER_OK").unwrap();
        writeln!(body, "}}\n").unwrap();
    }
    Ok(OutputFile {
        filename: if template {
            "module_schema/module_handler_templates.odin.txt".into()
        } else {
            "module_schema/module_handlers.odin".into()
        },
        code: body,
    })
}

const HEADER: &str = "// THIS FILE IS AUTOMATICALLY GENERATED BY SPACETIMEDB. EDITS TO THIS FILE\n// WILL NOT BE SAVED. MODIFY TABLES IN YOUR MODULE SOURCE CODE INSTEAD.\n\npackage module_bindings\n\n";

const KEYWORDS: &[&str] = &[
    "asm",
    "auto_cast",
    "bit_field",
    "bit_set",
    "break",
    "case",
    "cast",
    "context",
    "continue",
    "defer",
    "distinct",
    "do",
    "dynamic",
    "else",
    "enum",
    "fallthrough",
    "false",
    "for",
    "foreign",
    "if",
    "import",
    "in",
    "map",
    "matrix",
    "nil",
    "not_in",
    "or_break",
    "or_continue",
    "or_else",
    "or_return",
    "package",
    "proc",
    "return",
    "struct",
    "switch",
    "transmute",
    "true",
    "typeid",
    "union",
    "using",
    "when",
    "where",
];

/// Which imports a generated file needs, so unused imports are not emitted.
#[derive(Default)]
struct Uses {
    runtime: bool,
    host: bool,
    client: bool,
}

impl Uses {
    fn write_imports(&self, out: &mut String) {
        if self.runtime {
            out.push_str("import \"base:runtime\"\n");
        }
        if self.client {
            out.push_str("import \"stdb:client\"\n");
        }
        if self.host {
            out.push_str("import \"stdb:host\"\n");
        }
        if self.runtime || self.client || self.host {
            out.push('\n');
        }
    }
}

fn field_name(name: &str) -> String {
    if KEYWORDS.contains(&name.trim_end_matches('_')) {
        format!("{name}_")
    } else {
        name.to_string()
    }
}

/// Odin type and variant names are Ada_Case, e.g. `shape_kind` becomes `Shape_Kind`.
fn ada_case(name: &str) -> String {
    name.to_case(Case::Snake)
        .split('_')
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            chars
                .next()
                .map(|c| c.to_uppercase().collect::<String>() + chars.as_str())
                .unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join("_")
}

fn type_name(module: &ModuleDef, type_ref: spacetimedb_lib::sats::AlgebraicTypeRef) -> String {
    type_ref_name(module, type_ref)
}

/// `ShapeKind` becomes `shape_kind` and `P0` becomes `p0`.
fn snake_file(name: &str) -> String {
    let mut out = String::new();
    let mut previous_lower = false;
    for c in name.chars() {
        if c.is_uppercase() && previous_lower {
            out.push('_');
        }
        previous_lower = c.is_lowercase() || c.is_ascii_digit();
        out.extend(c.to_lowercase());
    }
    out
}

fn odin_type(module: &ModuleDef, ty: &AlgebraicTypeUse, uses: &mut Uses) -> String {
    match ty {
        AlgebraicTypeUse::Primitive(p) => match p {
            PrimitiveType::Bool => "bool".into(),
            PrimitiveType::I8 => "i8".into(),
            PrimitiveType::U8 => "u8".into(),
            PrimitiveType::I16 => "i16".into(),
            PrimitiveType::U16 => "u16".into(),
            PrimitiveType::I32 => "i32".into(),
            PrimitiveType::U32 => "u32".into(),
            PrimitiveType::I64 => "i64".into(),
            PrimitiveType::U64 => "u64".into(),
            PrimitiveType::I128 => "i128".into(),
            PrimitiveType::U128 => "u128".into(),
            PrimitiveType::I256 => {
                uses.host = true;
                "host.I256".into()
            }
            PrimitiveType::U256 => {
                uses.host = true;
                "host.U256".into()
            }
            PrimitiveType::F32 => "f32".into(),
            PrimitiveType::F64 => "f64".into(),
        },
        AlgebraicTypeUse::Array(elem) => format!("[]{}", odin_type(module, elem, uses)),
        AlgebraicTypeUse::Option(inner) => {
            uses.runtime = true;
            format!("runtime.Maybe({})", odin_type(module, inner, uses))
        }
        AlgebraicTypeUse::Result { ok_ty, err_ty } => {
            uses.host = true;
            let ok = odin_type(module, ok_ty, uses);
            let err = odin_type(module, err_ty, uses);
            format!("host.Result({ok}, {err})")
        }
        AlgebraicTypeUse::String => "string".into(),
        AlgebraicTypeUse::Identity => {
            uses.host = true;
            "host.Identity".into()
        }
        AlgebraicTypeUse::ConnectionId => {
            uses.host = true;
            "host.Connection_Id".into()
        }
        AlgebraicTypeUse::Timestamp => {
            uses.host = true;
            "host.Timestamp".into()
        }
        AlgebraicTypeUse::TimeDuration => {
            uses.host = true;
            "host.Time_Duration".into()
        }
        AlgebraicTypeUse::ScheduleAt => {
            uses.host = true;
            "host.Schedule_At".into()
        }
        AlgebraicTypeUse::Uuid => "u128".into(),
        AlgebraicTypeUse::Unit | AlgebraicTypeUse::Never => "struct {}".into(),
        AlgebraicTypeUse::Ref(type_ref) => type_name(module, *type_ref),
    }
}

fn write_struct(out: &mut String, name: &str, fields: &[(String, String)]) {
    if fields.is_empty() {
        writeln!(out, "{name} :: struct {{}}").unwrap();
        return;
    }
    writeln!(out, "{name} :: struct {{").unwrap();
    for (field, ty) in fields {
        writeln!(out, "\t{field}: {ty},").unwrap();
    }
    writeln!(out, "}}").unwrap();
}

fn product_fields(module: &ModuleDef, product: &ProductTypeDef, uses: &mut Uses) -> Vec<(String, String)> {
    product
        .elements
        .iter()
        .map(|(name, ty)| (field_name(name.deref()), odin_type(module, ty, uses)))
        .collect()
}

fn write_plain_enum(out: &mut String, name: &str, plain: &PlainEnumTypeDef) {
    writeln!(out, "{name} :: enum u8 {{").unwrap();
    for variant in plain.variants.iter() {
        writeln!(out, "\t{},", ada_case(variant.deref())).unwrap();
    }
    writeln!(out, "}}").unwrap();
}

/// Odin unions hold types, so each variant gets a wrapper struct whose single field is the payload.
fn write_sum(out: &mut String, module: &ModuleDef, name: &str, sum: &SumTypeDef, uses: &mut Uses) {
    let mut variant_types = Vec::new();
    for (variant, ty) in sum.variants.iter() {
        let wrapper = format!("{name}_{}", ada_case(variant.deref()));
        let fields = match ty {
            AlgebraicTypeUse::Unit | AlgebraicTypeUse::Never => Vec::new(),
            _ => vec![("value".to_string(), odin_type(module, ty, uses))],
        };
        write_struct(out, &wrapper, &fields);
        writeln!(out).unwrap();
        variant_types.push(wrapper);
    }
    writeln!(out, "{name} :: union #no_nil {{").unwrap();
    for wrapper in variant_types {
        writeln!(out, "\t{wrapper},").unwrap();
    }
    writeln!(out, "}}").unwrap();
}

fn generated_file(filename: String, uses: &Uses, body: &str) -> OutputFile {
    let mut code = String::from(HEADER);
    uses.write_imports(&mut code);
    code.push_str(body);
    OutputFile { filename, code }
}

fn client_submodule_file(module: &ModuleDef, mut file: OutputFile) -> OutputFile {
    let package = server_submodule_package(module);
    file.filename = format!("{package}/{}", file.filename);
    file.code = file
        .code
        .replacen("package module_bindings\n", &format!("package {package}\n"), 1);
    file
}

fn table_const(accessor: &str) -> String {
    format!("{}_TABLE", accessor.to_uppercase())
}

impl Lang for Odin {
    fn generate_table_file_from_schema(
        &self,
        module: &ModuleDef,
        table: &TableDef,
        _schema: TableSchema,
    ) -> OutputFile {
        let accessor = table.accessor_name.deref().to_string();
        let row = type_name(module, table.product_type_ref);
        let handlers = format!("{}_Handlers", ada_case(&accessor));
        let constant = table_const(&accessor);
        let wire_name = module.path().join(table.name.clone()).to_string();
        let mut uses = Uses {
            client: true,
            host: true,
            ..Uses::default()
        };
        let mut body = String::new();

        writeln!(body, "{constant} :: {wire_name:?}").unwrap();
        if !is_parameterized_view(module, &table.name) {
            writeln!(
                body,
                "{}_SUBSCRIPTION :: \"SELECT * FROM {}\"",
                accessor.to_uppercase(),
                wire_name
            )
            .unwrap();
        }
        writeln!(body).unwrap();
        writeln!(
            body,
            "// Rows currently visible in the cache; release them with client.delete_rows."
        )
        .unwrap();
        writeln!(
            body,
            "{accessor}_rows :: proc(cache: ^client.Cache) -> ([]{row}, host.Codec_Error) {{"
        )
        .unwrap();
        writeln!(body, "\treturn client.cache_rows(cache, {constant}, {row})").unwrap();
        writeln!(body, "}}").unwrap();
        writeln!(body).unwrap();
        writeln!(body, "{accessor}_filter :: proc(cache: ^client.Cache, predicate: proc(row: ^{row}, user: rawptr) -> bool, user: rawptr = nil) -> ([]{row}, host.Codec_Error) {{").unwrap();
        writeln!(
            body,
            "\treturn client.cache_filter_rows(cache, {constant}, {row}, predicate, user)"
        )
        .unwrap();
        writeln!(body, "}}").unwrap();
        writeln!(body).unwrap();
        writeln!(
            body,
            "{accessor}_query_rows :: proc(result: client.One_Off_Query_Result) -> ([]{row}, host.Codec_Error) {{"
        )
        .unwrap();
        writeln!(
            body,
            "\treturn client.one_off_query_result_rows(result, {constant}, {row})"
        )
        .unwrap();
        writeln!(body, "}}\n").unwrap();
        writeln!(body, "{handlers} :: client.Table_Handlers({row})").unwrap();
        writeln!(body).unwrap();

        if let Some(view) = module.view(&table.name) {
            let params = &view.params_for_generate.elements;
            if !params.is_empty() && params.iter().all(|(_, ty)| is_odin_sql_literal_type(ty)) {
                let query_params = params
                    .iter()
                    .map(|(name, ty)| (field_name(name.deref()), odin_type(module, ty, &mut uses)))
                    .collect::<Vec<_>>();
                let signature = query_params
                    .iter()
                    .map(|(name, ty)| format!("{name}: {ty}"))
                    .collect::<Vec<_>>()
                    .join(", ");
                let literals = params
                    .iter()
                    .zip(&query_params)
                    .map(|((_, ty), (name, odin_ty))| match ty {
                        AlgebraicTypeUse::String => format!("client.sql_string_literal({name})"),
                        AlgebraicTypeUse::Uuid => format!("client.sql_uuid_literal({name})"),
                        AlgebraicTypeUse::Array(elem)
                            if matches!(**elem, AlgebraicTypeUse::Primitive(PrimitiveType::U8)) =>
                        {
                            format!("client.sql_bytes_literal({name})")
                        }
                        _ => format!("client.sql_literal({odin_ty}, {name})"),
                    })
                    .collect::<Vec<_>>()
                    .join(", ");
                writeln!(body, "{accessor}_query :: proc({signature}) -> string {{").unwrap();
                writeln!(body, "\targuments := [?]string{{{literals}}}").unwrap();
                writeln!(body, "\treturn client.sql_view_query({:?}, arguments[:])", wire_name).unwrap();
                writeln!(body, "}}\n").unwrap();
            }
        }

        if !is_parameterized_view(module, &table.name) {
            if let Some(AlgebraicTypeDef::Product(product)) =
                module.typespace_for_generate().get(table.product_type_ref)
            {
                for (column_name, column_type) in &product.elements {
                    if is_odin_cache_equality_type(column_type) {
                        let value_type = odin_type(module, column_type, &mut uses);
                        let column_accessor = snake_file(column_name.deref());
                        write_cache_equality_lookup(
                            &mut body,
                            &accessor,
                            &wire_name,
                            &constant,
                            &row,
                            column_name.deref(),
                            &column_accessor,
                            &value_type,
                        );
                    }
                    if is_odin_cache_range_type(column_type) {
                        let value_type = odin_type(module, column_type, &mut uses);
                        let column_accessor = snake_file(column_name.deref());
                        write_cache_range_lookup(
                            &mut body,
                            &accessor,
                            &wire_name,
                            &constant,
                            &row,
                            column_name.deref(),
                            &column_accessor,
                            &value_type,
                            column_type,
                        );
                    }
                    if !is_odin_sql_literal_type(column_type) {
                        continue;
                    }
                    let value_type = odin_type(module, column_type, &mut uses);
                    let column_accessor = snake_file(column_name.deref());
                    for (suffix, operator) in [
                        ("eq", "Equal"),
                        ("ne", "Not_Equal"),
                        ("lt", "Less"),
                        ("le", "Less_Or_Equal"),
                        ("gt", "Greater"),
                        ("ge", "Greater_Or_Equal"),
                    ] {
                        writeln!(
                            body,
                            "{accessor}_where_{column_accessor}_{suffix} :: proc(query: ^client.Sql_Query_Builder, value: {value_type}) -> client.Sql_Query_Error {{"
                        )
                        .unwrap();
                        writeln!(
                            body,
                            "\treturn client.sql_query_where({value_type}, query, {:?}, .{operator}, value)",
                            column_name.deref()
                        )
                        .unwrap();
                        writeln!(body, "}}\n").unwrap();
                    }
                }
            }
        }

        if let Some(AlgebraicTypeDef::Product(product)) = module.typespace_for_generate().get(table.product_type_ref) {
            for index in iter_indexes(table) {
                let IndexAlgorithm::BTree(_) = &index.algorithm else {
                    continue;
                };
                let Some(index_accessor) = index.accessor_name.as_ref() else {
                    continue;
                };
                let fields = index
                    .algorithm
                    .columns()
                    .iter()
                    .map(|column| product.elements.get(column.idx()))
                    .collect::<Option<Vec<_>>>();
                let Some(fields) = fields else { continue };
                if fields.len() < 2 || !fields.iter().all(|(_, ty)| is_odin_cache_equality_type(ty)) {
                    continue;
                }
                write_cache_composite_index_helpers(
                    &mut body,
                    module,
                    &accessor,
                    &wire_name,
                    &row,
                    index.name.deref(),
                    index_accessor.deref(),
                    &fields,
                    &mut uses,
                );
            }
        }

        let key = table.primary_key.and_then(|col| {
            let typespace = module.typespace_for_generate();
            match typespace.get(table.product_type_ref) {
                Some(AlgebraicTypeDef::Product(product)) => product.elements.get(col.idx()).cloned(),
                _ => None,
            }
        });
        if let Some((key_name, key_type_def)) = &key {
            if is_odin_cache_equality_type(key_type_def) {
                let key_type = odin_type(module, key_type_def, &mut uses);
                let key_field = field_name(key_name.deref());
                let column_accessor = snake_file(key_name.deref());
                let index_name = format!("{}.{}", wire_name, key_name.deref());
                writeln!(
                    body,
                    "{accessor}_cache_by_{column_accessor} :: proc(cache: ^client.Cache, key: {key_type}) -> ({row}, bool, host.Codec_Error) {{"
                )
                .unwrap();
                writeln!(
                    body,
                    "\textract_key := proc(encoded_row: []u8, user: rawptr) -> ([]u8, host.Codec_Error) {{"
                )
                .unwrap();
                writeln!(body, "\t\t_ = user").unwrap();
                writeln!(
                    body,
                    "\t\tdecoded, consumed, decode_err := host.decode_row_from({row}, encoded_row)"
                )
                .unwrap();
                writeln!(body, "\t\tif decode_err != .None do return nil, decode_err").unwrap();
                writeln!(body, "\t\tif consumed != len(encoded_row) {{").unwrap();
                writeln!(body, "\t\t\thost.delete_decoded_row({row}, &decoded)").unwrap();
                writeln!(body, "\t\t\treturn nil, .Trailing_Bytes").unwrap();
                writeln!(body, "\t\t}}").unwrap();
                writeln!(
                    body,
                    "\t\tkey_bytes, encode_err := client.encode_value({key_type}, decoded.{key_field})"
                )
                .unwrap();
                writeln!(body, "\t\thost.delete_decoded_row({row}, &decoded)").unwrap();
                writeln!(body, "\t\treturn key_bytes, encode_err").unwrap();
                writeln!(body, "\t}}").unwrap();
                writeln!(
                    body,
                    "\tindex_err := client.cache_index_register(cache, {:?}, {:?}, extract_key)",
                    index_name, wire_name
                )
                .unwrap();
                writeln!(body, "\tif index_err != .None do return {{}}, false, index_err").unwrap();
                writeln!(body, "\tkey_bytes, encode_err := client.encode_value({key_type}, key)").unwrap();
                writeln!(body, "\tif encode_err != .None do return {{}}, false, encode_err").unwrap();
                writeln!(body, "\tdefer delete(key_bytes)").unwrap();
                writeln!(
                    body,
                    "\tmatches, indexed := client.cache_index_lookup(cache, {:?}, key_bytes)",
                    index_name
                )
                .unwrap();
                writeln!(body, "\tif !indexed do return {{}}, false, .Malformed_Data").unwrap();
                writeln!(body, "\tif len(matches) == 0 do return {{}}, false, .None").unwrap();
                writeln!(body, "\tif len(matches) != 1 do return {{}}, false, .Malformed_Data").unwrap();
                writeln!(
                    body,
                    "\tdecoded, consumed, decode_err := host.decode_row_from({row}, matches[0])"
                )
                .unwrap();
                writeln!(
                    body,
                    "\tif decode_err == .None && consumed != len(matches[0]) do decode_err = .Trailing_Bytes"
                )
                .unwrap();
                writeln!(body, "\tif decode_err != .None {{").unwrap();
                writeln!(body, "\t\thost.delete_decoded_row({row}, &decoded)").unwrap();
                writeln!(body, "\t\treturn {{}}, false, decode_err").unwrap();
                writeln!(body, "\t}}").unwrap();
                writeln!(body, "\treturn decoded, true, .None").unwrap();
                writeln!(body, "}}\n").unwrap();
            }
        }
        writeln!(
            body,
            "{accessor}_dispatch :: proc(changes: []client.Row_Change, handlers: {handlers}, user: rawptr = nil) {{"
        )
        .unwrap();
        match key {
            Some((key_name, key_ty)) => {
                let key_type = odin_type(module, &key_ty, &mut uses);
                writeln!(
                    body,
                    "\tclient.dispatch_keyed_changes(changes, {constant}, handlers, user, proc(row: ^{row}) -> {key_type} {{ return row.{} }})",
                    field_name(key_name.deref())
                )
                .unwrap();
            }
            None => writeln!(body, "\tclient.dispatch_changes(changes, {constant}, handlers, user)").unwrap(),
        }
        writeln!(body, "}}").unwrap();

        // Views reuse this generator; their row type lives in the same package.
        generated_file(format!("{accessor}_table.odin"), &uses, &body)
    }

    fn generate_type_files(&self, module: &ModuleDef, typ: &TypeDef) -> Vec<OutputFile> {
        let name = collect_case(Case::Pascal, typ.accessor_name.name_segments());
        let mut uses = Uses::default();
        let mut body = String::new();
        match module.typespace_for_generate().get(typ.ty) {
            Some(AlgebraicTypeDef::Product(product)) => {
                write_struct(&mut body, &name, &product_fields(module, product, &mut uses));
            }
            Some(AlgebraicTypeDef::Sum(sum)) => write_sum(&mut body, module, &name, sum, &mut uses),
            Some(AlgebraicTypeDef::PlainEnum(plain)) => write_plain_enum(&mut body, &name, plain),
            None => writeln!(body, "// Could not resolve the definition of {name}.").unwrap(),
        }
        vec![generated_file(format!("{}_type.odin", snake_file(&name)), &uses, &body)]
    }

    fn generate_submodule_table_file(&self, module: &ModuleDef, table: &TableDef) -> OutputFile {
        client_submodule_file(module, self.generate_table_file(module, table))
    }

    fn generate_submodule_view_file(&self, module: &ModuleDef, view: &ViewDef) -> OutputFile {
        client_submodule_file(module, self.generate_view_file(module, view))
    }

    fn generate_submodule_reducer_file(&self, module: &ModuleDef, reducer: &ReducerDef) -> OutputFile {
        client_submodule_file(module, self.generate_reducer_file(module, reducer))
    }

    fn generate_submodule_procedure_file(&self, module: &ModuleDef, procedure: &ProcedureDef) -> OutputFile {
        client_submodule_file(module, self.generate_procedure_file(module, procedure))
    }

    fn generate_reducer_file(&self, module: &ModuleDef, reducer: &ReducerDef) -> OutputFile {
        let accessor = reducer.accessor_name.deref().to_string();
        let mut uses = Uses {
            client: true,
            ..Uses::default()
        };
        let params: Vec<(String, String)> = reducer
            .params_for_generate
            .elements
            .iter()
            .map(|(name, ty)| (field_name(name.deref()), odin_type(module, ty, &mut uses)))
            .collect();
        let mut body = String::new();
        write_caller(&mut body, &accessor, reducer.name.deref(), "call_reducer", &params);
        generated_file(format!("{accessor}_reducer.odin"), &uses, &body)
    }

    fn generate_procedure_file(&self, module: &ModuleDef, procedure: &ProcedureDef) -> OutputFile {
        let accessor = procedure.accessor_name.deref().to_string();
        let mut uses = Uses {
            client: true,
            ..Uses::default()
        };
        let params: Vec<(String, String)> = procedure
            .params_for_generate
            .elements
            .iter()
            .map(|(name, ty)| (field_name(name.deref()), odin_type(module, ty, &mut uses)))
            .collect();
        let mut body = String::new();
        let wire_name = module.path().join(procedure.name.clone()).to_string();
        write_caller(&mut body, &accessor, &wire_name, "call_procedure", &params);
        if !matches!(procedure.return_type_for_generate, AlgebraicTypeUse::Unit) {
            uses.host = true;
            let ret = odin_type(module, &procedure.return_type_for_generate, &mut uses);
            writeln!(body).unwrap();
            writeln!(
                body,
                "// Decodes the value a {accessor} call returned; free it with host.delete_decoded_row."
            )
            .unwrap();
            writeln!(
                body,
                "{accessor}_result :: proc(result: client.Procedure_Result) -> ({ret}, host.Codec_Error) {{"
            )
            .unwrap();
            writeln!(body, "\treturn client.procedure_return_value(result, {ret})").unwrap();
            writeln!(body, "}}").unwrap();
        }
        generated_file(format!("{accessor}_procedure.odin"), &uses, &body)
    }

    fn generate_global_files(&self, module: &ModuleDef, options: &CodegenOptions) -> Vec<OutputFile> {
        let entries: Vec<_> = iter_table_names_and_types(module, options.visibility).collect();
        let mut children = Vec::new();
        if module.path().is_empty() {
            collect_server_submodules(module, &mut children);
            children.retain(|child| iter_table_names_and_types(child, options.visibility).next().is_some());
        }
        let mut body = String::new();
        writeln!(body, "// Queries that subscribe to every generated table and view.").unwrap();
        writeln!(body, "SUBSCRIBE_ALL_QUERIES := [?]string{{").unwrap();
        for (name, _accessor, _) in &entries {
            if !is_parameterized_view(module, name) {
                let wire_name = module.path().join((*name).clone());
                writeln!(body, "\t\"SELECT * FROM {wire_name}\",").unwrap();
            }
        }
        for child in &children {
            for (name, _, _) in iter_table_names_and_types(child, options.visibility) {
                if !is_parameterized_view(child, name) {
                    let wire_name = child.path().join(name.clone());
                    writeln!(body, "\t\"SELECT * FROM {wire_name}\",").unwrap();
                }
            }
        }
        writeln!(body, "}}").unwrap();
        writeln!(body).unwrap();
        writeln!(
            body,
            "subscribe_all :: proc(connection: ^client.Connection, query_set_id: u32, callback: client.Response_Callback, user: rawptr = nil) -> (request_id: u32, err: client.Error) {{"
        )
        .unwrap();
        writeln!(body, "\treturn client.subscribe_with_callback(connection, query_set_id, SUBSCRIBE_ALL_QUERIES[:], callback, user)").unwrap();
        writeln!(body, "}}\n").unwrap();
        writeln!(body, "subscribe_all_managed :: proc(connection: ^client.Connection, handle: ^client.Subscription_Handle, callback: client.Subscription_Event_Callback = nil, user: rawptr = nil) -> (request_id: u32, err: client.Error) {{").unwrap();
        writeln!(
            body,
            "\treturn client.subscribe_managed_auto(connection, handle, SUBSCRIBE_ALL_QUERIES[:], callback, user)"
        )
        .unwrap();
        writeln!(body, "}}\n").unwrap();
        writeln!(body, "Table_Callbacks :: struct {{").unwrap();
        for (_, accessor, _) in &entries {
            writeln!(body, "\t{}: {}_Handlers,", field_name(accessor), ada_case(accessor)).unwrap();
        }
        for child in &children {
            let package = server_submodule_package(child);
            writeln!(body, "\t{package}: {package}.Table_Callbacks,").unwrap();
        }
        writeln!(body, "}}").unwrap();
        writeln!(body).unwrap();
        writeln!(
            body,
            "// Routes the changes from client.cache_apply to each table's handlers."
        )
        .unwrap();
        writeln!(
            body,
            "dispatch_all :: proc(changes: []client.Row_Change, callbacks: Table_Callbacks, user: rawptr = nil) {{"
        )
        .unwrap();
        for (_, accessor, _) in &entries {
            writeln!(
                body,
                "\t{accessor}_dispatch(changes, callbacks.{}, user)",
                field_name(accessor)
            )
            .unwrap();
        }
        for child in &children {
            let package = server_submodule_package(child);
            writeln!(body, "\t{package}.dispatch_all(changes, callbacks.{package}, user)").unwrap();
        }
        writeln!(body, "}}").unwrap();
        for (name, accessor, row_ref) in &entries {
            let row = type_name(module, *row_ref);
            for (event, kind) in [("insert", "Insert"), ("delete", "Delete")] {
                let callback_type = format!("{}_{}_Callback", ada_case(accessor), ada_case(event));
                let state_type = format!("{accessor}_{event}_Listener_State");
                let dispatch = format!("{accessor}_dispatch_on_{event}");
                let destroy = format!("{accessor}_destroy_on_{event}");
                writeln!(body, "{callback_type} :: proc(row: ^{row}, user: rawptr)").unwrap();
                writeln!(
                    body,
                    "{state_type} :: struct {{ callback: {callback_type}, user: rawptr }}"
                )
                .unwrap();
                writeln!(body, "{dispatch} :: proc(change: client.Row_Change, user: rawptr) {{").unwrap();
                writeln!(body, "\tstate := cast(^{state_type})user").unwrap();
                writeln!(body, "\trow, consumed, err := host.decode_row_from({row}, change.row)").unwrap();
                writeln!(body, "\tif err != .None || consumed != len(change.row) {{").unwrap();
                writeln!(body, "\t\thost.delete_decoded_row({row}, &row)").unwrap();
                writeln!(body, "\t\treturn").unwrap();
                writeln!(body, "\t}}").unwrap();
                writeln!(body, "\tdefer host.delete_decoded_row({row}, &row)").unwrap();
                writeln!(body, "\tstate.callback(&row, state.user)").unwrap();
                writeln!(body, "}}\n").unwrap();
                writeln!(
                    body,
                    "{destroy} :: proc(user: rawptr) {{ free(cast(^{state_type})user) }}\n"
                )
                .unwrap();
                writeln!(body, "{accessor}_on_{event} :: proc(registry: ^client.Row_Change_Listener_Registry, callback: {callback_type}, user: rawptr = nil) -> (client.Row_Change_Listener_Id, client.Error) {{").unwrap();
                writeln!(
                    body,
                    "\tif registry == nil || callback == nil do return 0, .Invalid_Argument"
                )
                .unwrap();
                writeln!(body, "\twhen ODIN_OS == .JS do context = runtime.default_context()").unwrap();
                writeln!(body, "\tstate := new({state_type})").unwrap();
                writeln!(body, "\tstate^ = {state_type}{{callback = callback, user = user}}").unwrap();
                let wire_name = module.path().join((*name).clone()).to_string();
                writeln!(body, "\tid, err := client.row_change_event_listener_add(registry, {:?}, .{kind}, {dispatch}, state, {destroy})", wire_name).unwrap();
                writeln!(body, "\tif err != .None do free(state)").unwrap();
                writeln!(body, "\treturn id, err").unwrap();
                writeln!(body, "}}\n").unwrap();
                writeln!(body, "{accessor}_remove_on_{event} :: proc(registry: ^client.Row_Change_Listener_Registry, id: client.Row_Change_Listener_Id) -> bool {{").unwrap();
                writeln!(body, "\treturn client.row_change_listener_remove(registry, id)").unwrap();
                writeln!(body, "}}\n").unwrap();
            }
        }
        writeln!(body, "Row_Change_Dispatcher :: struct {{").unwrap();
        writeln!(body, "\ttables: Table_Callbacks,").unwrap();
        writeln!(body, "\tuser: rawptr,").unwrap();
        writeln!(body, "}}\n").unwrap();
        writeln!(
            body,
            "// Use as Connect_Options.on_row_changes with a stable Row_Change_Dispatcher user pointer."
        )
        .unwrap();
        writeln!(
            body,
            "dispatch_connection_row_changes :: proc(changes: []client.Row_Change, user: rawptr) {{"
        )
        .unwrap();
        writeln!(body, "\tdispatcher := cast(^Row_Change_Dispatcher)user").unwrap();
        writeln!(body, "\tdispatch_all(changes, dispatcher.tables, dispatcher.user)").unwrap();
        writeln!(body, "}}\n").unwrap();
        writeln!(body, "register_row_change_dispatcher :: proc(registry: ^client.Row_Change_Listener_Registry, dispatcher: ^Row_Change_Dispatcher) -> (client.Row_Change_Listener_Id, client.Error) {{").unwrap();
        writeln!(
            body,
            "\treturn client.row_change_listener_add(registry, dispatch_connection_row_changes, dispatcher)"
        )
        .unwrap();
        writeln!(body, "}}\n").unwrap();
        writeln!(body, "unregister_row_change_dispatcher :: proc(registry: ^client.Row_Change_Listener_Registry, id: client.Row_Change_Listener_Id) -> bool {{").unwrap();
        writeln!(body, "\treturn client.row_change_listener_remove(registry, id)").unwrap();
        writeln!(body, "}}\n").unwrap();
        let uses = Uses {
            client: true,
            host: true,
            runtime: true,
            ..Uses::default()
        };
        let mut code = String::from(HEADER);
        uses.write_imports(&mut code);
        for child in &children {
            let package = server_submodule_package(child);
            writeln!(code, "import {package} \"{package}\"").unwrap();
        }
        if !children.is_empty() {
            writeln!(code).unwrap();
        }
        code.push_str(&body);
        let mut files = vec![OutputFile {
            filename: "module_bindings.odin".into(),
            code,
        }];
        if module.path().is_empty() {
            let mut owners = Vec::new();
            collect_server_submodules(module, &mut owners);
            for owner in owners {
                for typ in iter_types(owner) {
                    files.extend(
                        self.generate_type_files(owner, typ)
                            .into_iter()
                            .map(|file| client_submodule_file(owner, file)),
                    );
                }
                if iter_table_names_and_types(owner, options.visibility).next().is_some() {
                    files.extend(
                        self.generate_global_files(owner, options)
                            .into_iter()
                            .map(|file| client_submodule_file(owner, file)),
                    );
                }
            }
        }
        files
    }
}

fn is_odin_sql_literal_type(ty: &AlgebraicTypeUse) -> bool {
    match ty {
        AlgebraicTypeUse::Primitive(primitive) => !matches!(
            primitive,
            PrimitiveType::I256 | PrimitiveType::U256 | PrimitiveType::F32 | PrimitiveType::F64
        ),
        AlgebraicTypeUse::String
        | AlgebraicTypeUse::Identity
        | AlgebraicTypeUse::ConnectionId
        | AlgebraicTypeUse::Timestamp
        | AlgebraicTypeUse::Uuid => true,
        AlgebraicTypeUse::Array(elem) => matches!(**elem, AlgebraicTypeUse::Primitive(PrimitiveType::U8)),
        _ => false,
    }
}

fn is_odin_cache_equality_type(ty: &AlgebraicTypeUse) -> bool {
    match ty {
        AlgebraicTypeUse::Primitive(_) => true,
        AlgebraicTypeUse::String
        | AlgebraicTypeUse::Identity
        | AlgebraicTypeUse::ConnectionId
        | AlgebraicTypeUse::Timestamp
        | AlgebraicTypeUse::Uuid => true,
        _ => false,
    }
}

fn is_odin_cache_range_type(ty: &AlgebraicTypeUse) -> bool {
    match ty {
        AlgebraicTypeUse::Primitive(primitive) => !matches!(primitive, PrimitiveType::Bool),
        AlgebraicTypeUse::String
        | AlgebraicTypeUse::Identity
        | AlgebraicTypeUse::ConnectionId
        | AlgebraicTypeUse::Timestamp
        | AlgebraicTypeUse::TimeDuration
        | AlgebraicTypeUse::Uuid => true,
        _ => false,
    }
}

fn write_cache_value_less_function(body: &mut String, function_name: &str, value_type: &str, ty: &AlgebraicTypeUse) {
    writeln!(body, "{function_name} :: proc(left, right: {value_type}) -> bool {{").unwrap();
    match ty {
        AlgebraicTypeUse::Primitive(PrimitiveType::F32) => {
            writeln!(body, "\tleft_bits := transmute(u32)left").unwrap();
            writeln!(body, "\tright_bits := transmute(u32)right").unwrap();
            writeln!(
                body,
                "\tleft_key := left_bits ~ (u32(0x7fff_ffff) if left_bits & 0x8000_0000 != 0 else u32(0x8000_0000))"
            )
            .unwrap();
            writeln!(
                body,
                "\tright_key := right_bits ~ (u32(0x7fff_ffff) if right_bits & 0x8000_0000 != 0 else u32(0x8000_0000))"
            )
            .unwrap();
            writeln!(body, "\treturn left_key < right_key").unwrap();
        }
        AlgebraicTypeUse::Primitive(PrimitiveType::F64) => {
            writeln!(body, "\tleft_bits := transmute(u64)left").unwrap();
            writeln!(body, "\tright_bits := transmute(u64)right").unwrap();
            writeln!(body, "\tleft_key := left_bits ~ (u64(0x7fff_ffff_ffff_ffff) if left_bits & 0x8000_0000_0000_0000 != 0 else u64(0x8000_0000_0000_0000))").unwrap();
            writeln!(body, "\tright_key := right_bits ~ (u64(0x7fff_ffff_ffff_ffff) if right_bits & 0x8000_0000_0000_0000 != 0 else u64(0x8000_0000_0000_0000))").unwrap();
            writeln!(body, "\treturn left_key < right_key").unwrap();
        }
        AlgebraicTypeUse::Primitive(PrimitiveType::I256) => {
            write_i256_less_body(body, true);
        }
        AlgebraicTypeUse::Primitive(PrimitiveType::U256) | AlgebraicTypeUse::Identity => {
            write_i256_less_body(body, false);
        }
        _ => writeln!(body, "\treturn left < right").unwrap(),
    }
    writeln!(body, "}}\n").unwrap();
}

fn write_i256_less_body(body: &mut String, signed: bool) {
    writeln!(body, "\tleft_bytes := transmute([32]u8)left").unwrap();
    writeln!(body, "\tright_bytes := transmute([32]u8)right").unwrap();
    if signed {
        writeln!(body, "\tleft_negative := left_bytes[31] & 0x80 != 0").unwrap();
        writeln!(body, "\tright_negative := right_bytes[31] & 0x80 != 0").unwrap();
        writeln!(body, "\tif left_negative != right_negative do return left_negative").unwrap();
    }
    writeln!(body, "\tfor offset in 0 ..< 32 {{").unwrap();
    writeln!(body, "\t\tindex := 31 - offset").unwrap();
    writeln!(
        body,
        "\t\tif left_bytes[index] != right_bytes[index] do return left_bytes[index] < right_bytes[index]"
    )
    .unwrap();
    writeln!(body, "\t}}\n\treturn false").unwrap();
}

fn write_cache_composite_index_helpers<I: Deref<Target = str>>(
    body: &mut String,
    module: &ModuleDef,
    accessor: &str,
    table: &str,
    row: &str,
    index_name: &str,
    index_accessor: &str,
    fields: &[&(I, AlgebraicTypeUse)],
    uses: &mut Uses,
) {
    let key_type = format!("{accessor}_{index_accessor}_Key");
    let normalized_fields = fields
        .iter()
        .map(|field| {
            let (name, ty) = *field;
            (field_name(name.deref()), ty)
        })
        .collect::<Vec<_>>();
    let typed_fields = normalized_fields
        .iter()
        .map(|(name, ty)| (name.clone(), odin_type(module, ty, uses)))
        .collect::<Vec<_>>();
    let runtime_index_name = format!("{table}.{index_name}");
    let extractor_name = format!("{accessor}_{index_accessor}_extract_key");

    write_struct(body, &key_type, &typed_fields);
    writeln!(body).unwrap();
    writeln!(
        body,
        "{extractor_name} :: proc(encoded_row: []u8, user: rawptr) -> ([]u8, host.Codec_Error) {{"
    )
    .unwrap();
    writeln!(body, "\t_ = user").unwrap();
    writeln!(
        body,
        "\tdecoded, consumed, decode_err := host.decode_row_from({row}, encoded_row)"
    )
    .unwrap();
    writeln!(body, "\tif decode_err != .None do return nil, decode_err").unwrap();
    writeln!(body, "\tif consumed != len(encoded_row) {{").unwrap();
    writeln!(body, "\t\thost.delete_decoded_row({row}, &decoded)").unwrap();
    writeln!(body, "\t\treturn nil, .Trailing_Bytes").unwrap();
    writeln!(body, "\t}}").unwrap();
    let key_fields = normalized_fields
        .iter()
        .map(|(name, _)| format!("{name} = decoded.{name}"))
        .collect::<Vec<_>>()
        .join(", ");
    writeln!(body, "\tkey := {key_type}{{{key_fields}}}").unwrap();
    writeln!(body, "\tkey_bytes, encode_err := client.encode_value({key_type}, key)").unwrap();
    writeln!(body, "\thost.delete_decoded_row({row}, &decoded)").unwrap();
    writeln!(body, "\treturn key_bytes, encode_err").unwrap();
    writeln!(body, "}}\n").unwrap();

    writeln!(body, "{accessor}_cache_{index_accessor} :: proc(cache: ^client.Cache, key: {key_type}) -> ([]{row}, host.Codec_Error) {{").unwrap();
    writeln!(
        body,
        "\tindex_err := client.cache_index_register(cache, {:?}, {:?}, {extractor_name})",
        runtime_index_name, table
    )
    .unwrap();
    writeln!(body, "\tif index_err != .None do return nil, index_err").unwrap();
    writeln!(body, "\tkey_bytes, encode_err := client.encode_value({key_type}, key)").unwrap();
    writeln!(body, "\tif encode_err != .None do return nil, encode_err").unwrap();
    writeln!(body, "\tdefer delete(key_bytes)").unwrap();
    writeln!(
        body,
        "\treturn client.cache_index_decode_rows(cache, {:?}, key_bytes, {row})",
        runtime_index_name
    )
    .unwrap();
    writeln!(body, "}}\n").unwrap();

    for prefix_len in 1..fields.len() {
        let prefix_type = format!("{accessor}_{index_accessor}_Prefix_{prefix_len}");
        write_struct(body, &prefix_type, &typed_fields[..prefix_len]);
        writeln!(body).unwrap();
        let prefix_index_name = format!("{runtime_index_name}.prefix.{prefix_len}");
        let matcher = format!("{accessor}_{index_accessor}_prefix_{prefix_len}_matches");
        writeln!(
            body,
            "{matcher} :: proc(key_bytes, prefix_bytes: []u8, user: rawptr) -> (bool, host.Codec_Error) {{"
        )
        .unwrap();
        writeln!(body, "\t_ = user").unwrap();
        writeln!(
            body,
            "\tkey, key_consumed, key_err := host.decode_row_from({key_type}, key_bytes)"
        )
        .unwrap();
        writeln!(body, "\tif key_err != .None do return false, key_err").unwrap();
        writeln!(body, "\tdefer host.delete_decoded_row({key_type}, &key)").unwrap();
        writeln!(
            body,
            "\tif key_consumed != len(key_bytes) do return false, .Trailing_Bytes"
        )
        .unwrap();
        writeln!(
            body,
            "\tprefix, prefix_consumed, prefix_err := host.decode_row_from({prefix_type}, prefix_bytes)"
        )
        .unwrap();
        writeln!(body, "\tif prefix_err != .None do return false, prefix_err").unwrap();
        writeln!(body, "\tdefer host.delete_decoded_row({prefix_type}, &prefix)").unwrap();
        writeln!(
            body,
            "\tif prefix_consumed != len(prefix_bytes) do return false, .Trailing_Bytes"
        )
        .unwrap();
        let equality = normalized_fields[..prefix_len]
            .iter()
            .map(|(name, _)| format!("key.{name} == prefix.{name}"))
            .collect::<Vec<_>>()
            .join(" && ");
        writeln!(body, "\treturn {equality}, .None").unwrap();
        writeln!(body, "}}\n").unwrap();
        writeln!(body, "{accessor}_cache_prefix_{index_accessor}_{prefix_len} :: proc(cache: ^client.Cache, prefix: {prefix_type}) -> ([]{row}, host.Codec_Error) {{").unwrap();
        writeln!(
            body,
            "\tindex_err := client.cache_index_register(cache, {:?}, {:?}, {extractor_name}, nil, nil, {matcher})",
            prefix_index_name, table
        )
        .unwrap();
        writeln!(body, "\tif index_err != .None do return nil, index_err").unwrap();
        writeln!(
            body,
            "\tprefix_bytes, encode_err := client.encode_value({prefix_type}, prefix)"
        )
        .unwrap();
        writeln!(body, "\tif encode_err != .None do return nil, encode_err").unwrap();
        writeln!(body, "\tdefer delete(prefix_bytes)").unwrap();
        writeln!(
            body,
            "\treturn client.cache_index_decode_prefix_rows(cache, {:?}, prefix_bytes, {row})",
            prefix_index_name
        )
        .unwrap();
        writeln!(body, "}}\n").unwrap();
    }

    if normalized_fields.iter().all(|(_, ty)| is_odin_cache_range_type(ty)) {
        let less = format!("{accessor}_{index_accessor}_less");
        for (field_index, (field, ty)) in normalized_fields.iter().enumerate() {
            let field_less = format!("{accessor}_{index_accessor}_{field}_less");
            write_cache_value_less_function(body, &field_less, &typed_fields[field_index].1, ty);
        }
        writeln!(
            body,
            "{less} :: proc(left_bytes, right_bytes: []u8, user: rawptr) -> (bool, host.Codec_Error) {{"
        )
        .unwrap();
        writeln!(body, "\t_ = user").unwrap();
        writeln!(
            body,
            "\tleft, left_consumed, left_err := host.decode_row_from({key_type}, left_bytes)"
        )
        .unwrap();
        writeln!(body, "\tif left_err != .None do return false, left_err").unwrap();
        writeln!(body, "\tdefer host.delete_decoded_row({key_type}, &left)").unwrap();
        writeln!(
            body,
            "\tif left_consumed != len(left_bytes) do return false, .Trailing_Bytes"
        )
        .unwrap();
        writeln!(
            body,
            "\tright, right_consumed, right_err := host.decode_row_from({key_type}, right_bytes)"
        )
        .unwrap();
        writeln!(body, "\tif right_err != .None do return false, right_err").unwrap();
        writeln!(body, "\tdefer host.delete_decoded_row({key_type}, &right)").unwrap();
        writeln!(
            body,
            "\tif right_consumed != len(right_bytes) do return false, .Trailing_Bytes"
        )
        .unwrap();
        for (field, _) in &normalized_fields {
            let field_less = format!("{accessor}_{index_accessor}_{field}_less");
            writeln!(
                body,
                "\tif {field_less}(left.{field}, right.{field}) do return true, .None"
            )
            .unwrap();
            writeln!(
                body,
                "\tif {field_less}(right.{field}, left.{field}) do return false, .None"
            )
            .unwrap();
        }
        writeln!(body, "\treturn false, .None").unwrap();
        writeln!(body, "}}\n").unwrap();
        writeln!(body, "{accessor}_cache_range_{index_accessor} :: proc(cache: ^client.Cache, lower: {key_type}, lower_mode: client.Cache_Index_Bound_Mode, upper: {key_type}, upper_mode: client.Cache_Index_Bound_Mode) -> ([]{row}, host.Codec_Error) {{").unwrap();
        writeln!(
            body,
            "\tindex_err := client.cache_index_register(cache, {:?}, {:?}, {extractor_name}, nil, {less})",
            runtime_index_name, table
        )
        .unwrap();
        writeln!(body, "\tif index_err != .None do return nil, index_err").unwrap();
        writeln!(
            body,
            "\tlower_bytes, lower_err := client.encode_value({key_type}, lower)"
        )
        .unwrap();
        writeln!(body, "\tif lower_err != .None do return nil, lower_err").unwrap();
        writeln!(body, "\tdefer delete(lower_bytes)").unwrap();
        writeln!(
            body,
            "\tupper_bytes, upper_err := client.encode_value({key_type}, upper)"
        )
        .unwrap();
        writeln!(body, "\tif upper_err != .None do return nil, upper_err").unwrap();
        writeln!(body, "\tdefer delete(upper_bytes)").unwrap();
        writeln!(body, "\treturn client.cache_index_decode_range_rows(cache, {:?}, lower_bytes, lower_mode, upper_bytes, upper_mode, {row})", runtime_index_name).unwrap();
        writeln!(body, "}}\n").unwrap();
    }
}

fn write_cache_equality_lookup(
    body: &mut String,
    accessor: &str,
    table: &str,
    constant: &str,
    row: &str,
    column: &str,
    column_accessor: &str,
    value_type: &str,
) {
    let index_name = format!("{table}.{column}");
    writeln!(
        body,
        "{accessor}_cache_eq_{column_accessor} :: proc(cache: ^client.Cache, value: {value_type}) -> ([]{row}, host.Codec_Error) {{"
    )
    .unwrap();
    writeln!(
        body,
        "\textract_key := proc(encoded_row: []u8, user: rawptr) -> ([]u8, host.Codec_Error) {{"
    )
    .unwrap();
    writeln!(body, "\t\t_ = user").unwrap();
    writeln!(
        body,
        "\t\tdecoded, consumed, decode_err := host.decode_row_from({row}, encoded_row)"
    )
    .unwrap();
    writeln!(body, "\t\tif decode_err != .None do return nil, decode_err").unwrap();
    writeln!(body, "\t\tif consumed != len(encoded_row) {{").unwrap();
    writeln!(body, "\t\t\thost.delete_decoded_row({row}, &decoded)").unwrap();
    writeln!(body, "\t\t\treturn nil, .Trailing_Bytes").unwrap();
    writeln!(body, "\t\t}}").unwrap();
    writeln!(
        body,
        "\t\tkey_bytes, encode_err := client.encode_value({value_type}, decoded.{})",
        field_name(column)
    )
    .unwrap();
    writeln!(body, "\t\thost.delete_decoded_row({row}, &decoded)").unwrap();
    writeln!(body, "\t\treturn key_bytes, encode_err").unwrap();
    writeln!(body, "\t}}").unwrap();
    writeln!(
        body,
        "\tindex_err := client.cache_index_register(cache, {:?}, {constant}, extract_key)",
        index_name
    )
    .unwrap();
    writeln!(body, "\tif index_err != .None do return nil, index_err").unwrap();
    writeln!(
        body,
        "\tkey_bytes, encode_err := client.encode_value({value_type}, value)"
    )
    .unwrap();
    writeln!(body, "\tif encode_err != .None do return nil, encode_err").unwrap();
    writeln!(body, "\tdefer delete(key_bytes)").unwrap();
    writeln!(
        body,
        "\treturn client.cache_index_decode_rows(cache, {:?}, key_bytes, {row})",
        index_name
    )
    .unwrap();
    writeln!(body, "}}\n").unwrap();
}

fn write_cache_range_lookup(
    body: &mut String,
    accessor: &str,
    table: &str,
    constant: &str,
    row: &str,
    column: &str,
    column_accessor: &str,
    value_type: &str,
    value_type_use: &AlgebraicTypeUse,
) {
    let index_name = format!("{table}.{column}");
    let less_value = format!("{accessor}_{column_accessor}_less_value");
    write_cache_value_less_function(body, &less_value, value_type, value_type_use);
    writeln!(
        body,
        "{accessor}_cache_range_{column_accessor} :: proc(cache: ^client.Cache, lower: {value_type}, lower_mode: client.Cache_Index_Bound_Mode, upper: {value_type}, upper_mode: client.Cache_Index_Bound_Mode) -> ([]{row}, host.Codec_Error) {{"
    )
    .unwrap();
    writeln!(
        body,
        "\textract_key := proc(encoded_row: []u8, user: rawptr) -> ([]u8, host.Codec_Error) {{"
    )
    .unwrap();
    writeln!(body, "\t\t_ = user").unwrap();
    writeln!(
        body,
        "\t\tdecoded, consumed, decode_err := host.decode_row_from({row}, encoded_row)"
    )
    .unwrap();
    writeln!(body, "\t\tif decode_err != .None do return nil, decode_err").unwrap();
    writeln!(body, "\t\tif consumed != len(encoded_row) {{").unwrap();
    writeln!(body, "\t\t\thost.delete_decoded_row({row}, &decoded)").unwrap();
    writeln!(body, "\t\t\treturn nil, .Trailing_Bytes").unwrap();
    writeln!(body, "\t\t}}").unwrap();
    writeln!(
        body,
        "\t\tkey_bytes, encode_err := client.encode_value({value_type}, decoded.{})",
        field_name(column)
    )
    .unwrap();
    writeln!(body, "\t\thost.delete_decoded_row({row}, &decoded)").unwrap();
    writeln!(body, "\t\treturn key_bytes, encode_err").unwrap();
    writeln!(body, "\t}}").unwrap();
    writeln!(
        body,
        "\tless_keys := proc(left, right: []u8, user: rawptr) -> (bool, host.Codec_Error) {{"
    )
    .unwrap();
    writeln!(body, "\t\t_ = user").unwrap();
    writeln!(
        body,
        "\t\tleft_value, left_consumed, left_err := host.decode_row_from({value_type}, left)"
    )
    .unwrap();
    writeln!(body, "\t\tif left_err != .None do return false, left_err").unwrap();
    writeln!(body, "\t\tdefer host.delete_decoded_row({value_type}, &left_value)").unwrap();
    writeln!(
        body,
        "\t\tif left_consumed != len(left) do return false, .Trailing_Bytes"
    )
    .unwrap();
    writeln!(
        body,
        "\t\tright_value, right_consumed, right_err := host.decode_row_from({value_type}, right)"
    )
    .unwrap();
    writeln!(body, "\t\tif right_err != .None do return false, right_err").unwrap();
    writeln!(body, "\t\tdefer host.delete_decoded_row({value_type}, &right_value)").unwrap();
    writeln!(
        body,
        "\t\tif right_consumed != len(right) do return false, .Trailing_Bytes"
    )
    .unwrap();
    writeln!(body, "\t\treturn {less_value}(left_value, right_value), .None").unwrap();
    writeln!(body, "\t}}").unwrap();
    writeln!(
        body,
        "\tindex_err := client.cache_index_register(cache, {:?}, {constant}, extract_key, nil, less_keys)",
        index_name
    )
    .unwrap();
    writeln!(body, "\tif index_err != .None do return nil, index_err").unwrap();
    writeln!(body, "\tlower_key: []u8").unwrap();
    writeln!(body, "\tif lower_mode != .Unbounded {{").unwrap();
    writeln!(
        body,
        "\t\tencoded_lower, encode_err := client.encode_value({value_type}, lower)"
    )
    .unwrap();
    writeln!(body, "\t\tif encode_err != .None do return nil, encode_err").unwrap();
    writeln!(body, "\t\tlower_key = encoded_lower").unwrap();
    writeln!(body, "\t}}").unwrap();
    writeln!(body, "\tdefer delete(lower_key)").unwrap();
    writeln!(body, "\tupper_key: []u8").unwrap();
    writeln!(body, "\tif upper_mode != .Unbounded {{").unwrap();
    writeln!(
        body,
        "\t\tencoded_upper, encode_err := client.encode_value({value_type}, upper)"
    )
    .unwrap();
    writeln!(body, "\t\tif encode_err != .None do return nil, encode_err").unwrap();
    writeln!(body, "\t\tupper_key = encoded_upper").unwrap();
    writeln!(body, "\t}}").unwrap();
    writeln!(body, "\tdefer delete(upper_key)").unwrap();
    writeln!(body, "\treturn client.cache_index_decode_range_rows(cache, {:?}, lower_key, lower_mode, upper_key, upper_mode, {row})", index_name).unwrap();
    writeln!(body, "}}\n").unwrap();
}

fn write_caller(body: &mut String, accessor: &str, wire_name: &str, call: &str, params: &[(String, String)]) {
    let (typed_callback, typed_call) = if call == "call_reducer" {
        ("client.Reducer_Result_Callback", "call_reducer_with_result_callback")
    } else {
        (
            "client.Procedure_Result_Callback",
            "call_procedure_with_result_callback",
        )
    };
    if params.is_empty() {
        let args_type = format!("{}_Args", ada_case(accessor));
        write_struct(body, &args_type, params);
        writeln!(body).unwrap();
        writeln!(
            body,
            "call_{accessor} :: proc(connection: ^client.Connection) -> (request_id: u32, err: client.Error) {{"
        )
        .unwrap();
        writeln!(body, "\treturn client.{call}_raw(connection, \"{wire_name}\", nil)").unwrap();
        writeln!(body, "}}").unwrap();
        writeln!(
            body,
            "call_{accessor}_with_callback :: proc(connection: ^client.Connection, callback: client.Response_Callback, user: rawptr = nil) -> (request_id: u32, err: client.Error) {{"
        )
        .unwrap();
        writeln!(
            body,
            "\treturn client.{call}_with_callback(connection, \"{wire_name}\", {args_type}{{}}, callback, user)"
        )
        .unwrap();
        writeln!(body, "}}").unwrap();
        writeln!(body, "call_{accessor}_with_result_callback :: proc(connection: ^client.Connection, callback: {typed_callback}, user: rawptr = nil) -> (request_id: u32, err: client.Error) {{").unwrap();
        writeln!(
            body,
            "\treturn client.{typed_call}(connection, \"{wire_name}\", {args_type}{{}}, callback, user)"
        )
        .unwrap();
        writeln!(body, "}}\n").unwrap();
        return;
    }
    let args_type = format!("{}_Args", ada_case(accessor));
    write_struct(body, &args_type, params);
    writeln!(body).unwrap();
    let signature = params
        .iter()
        .map(|(name, ty)| format!("{name}: {ty}"))
        .collect::<Vec<_>>()
        .join(", ");
    let values = params
        .iter()
        .map(|(name, _)| name.clone())
        .collect::<Vec<_>>()
        .join(", ");
    writeln!(
        body,
        "call_{accessor} :: proc(connection: ^client.Connection, {signature}) -> (request_id: u32, err: client.Error) {{"
    )
    .unwrap();
    writeln!(
        body,
        "\treturn client.{call}(connection, \"{wire_name}\", {args_type}{{{values}}})"
    )
    .unwrap();
    writeln!(body, "}}").unwrap();
    writeln!(
        body,
        "call_{accessor}_with_callback :: proc(connection: ^client.Connection, {signature}, callback: client.Response_Callback, user: rawptr = nil) -> (request_id: u32, err: client.Error) {{"
    )
    .unwrap();
    writeln!(
        body,
        "\treturn client.{call}_with_callback(connection, \"{wire_name}\", {args_type}{{{values}}}, callback, user)"
    )
    .unwrap();
    writeln!(body, "}}").unwrap();
    writeln!(body, "call_{accessor}_with_result_callback :: proc(connection: ^client.Connection, {signature}, callback: {typed_callback}, user: rawptr = nil) -> (request_id: u32, err: client.Error) {{").unwrap();
    writeln!(
        body,
        "\treturn client.{typed_call}(connection, \"{wire_name}\", {args_type}{{{values}}}, callback, user)"
    )
    .unwrap();
    writeln!(body, "}}\n").unwrap();
}
