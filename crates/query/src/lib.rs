use anyhow::{bail, Result};
use spacetimedb_execution::{
    dml::{MutDatastore, MutExecutor},
    pipelined::ProjectListExecutor,
    Datastore, DeltaStore, ExecutionParams,
};
use spacetimedb_expr::{
    check::{parse_and_type_sub, SchemaView},
    expr::{ProjectList, SortKey},
    rls::{resolve_views_for_sql, resolve_views_for_sub},
    statement::{parse_and_type_sql, Statement, DML},
};
use spacetimedb_lib::{identity::AuthCtx, metrics::ExecutionMetrics, AlgebraicValue, ProductValue};
use spacetimedb_physical_plan::{
    compile::{compile_dml_plan, compile_select, compile_select_list},
    plan::{ProjectListPlan, ProjectPlan},
};
use spacetimedb_primitives::TableId;
use spacetimedb_schema::table_name::TableName;

/// DIRTY HACK ALERT: Maximum allowed length, in UTF-8 bytes, of SQL queries.
/// Any query longer than this will be rejected.
/// This prevents a stack overflow when compiling queries with deeply-nested `AND` and `OR` conditions.
const MAX_SQL_LENGTH: usize = 50_000;

pub fn compile_subscription(
    sql: &str,
    tx: &impl SchemaView,
    auth: &AuthCtx,
) -> Result<(Vec<ProjectPlan>, TableId, TableName, bool)> {
    if sql.len() > MAX_SQL_LENGTH {
        bail!("SQL query exceeds maximum allowed length: \"{sql:.120}...\"")
    }

    let (plan, mut has_param) = parse_and_type_sub(sql, tx, auth)?;

    let Some(return_id) = plan.return_table_id() else {
        bail!("Failed to determine TableId for query")
    };

    let Some(return_name) = tx.schema_for_table(return_id).map(|schema| schema.table_name.clone()) else {
        bail!("TableId `{return_id}` does not exist")
    };

    // Resolve any RLS filters
    let plan_fragments = resolve_views_for_sub(tx, plan, auth, &mut has_param)?
        .into_iter()
        .map(|mut fragment| {
            fragment.bind_view_arg_hashes(auth.caller());
            compile_select(fragment)
        })
        .collect::<Vec<_>>();

    // Does this subscription read from a client-specific view?
    // If so, it is as if the view is parameterized by `:sender`.
    // We must know this in order to generate the correct query hash.
    let reads_view = plan_fragments.iter().any(|plan| plan.reads_from_view(false));

    Ok((plan_fragments, return_id, return_name, has_param || reads_view))
}

/// A utility for parsing and type checking a sql statement
pub fn compile_sql_stmt(sql: &str, tx: &impl SchemaView, auth: &AuthCtx) -> Result<Statement> {
    if sql.len() > MAX_SQL_LENGTH {
        bail!("SQL query exceeds maximum allowed length: \"{sql:.120}...\"")
    }

    match parse_and_type_sql(sql, tx, auth)? {
        stmt @ Statement::DML(_) => Ok(stmt),
        Statement::Select(expr) => {
            let mut expr = resolve_views_for_sql(tx, expr, auth)?;
            expr.bind_view_arg_hashes(auth.caller());
            Ok(Statement::Select(expr))
        }
    }
}

/// A utility for executing a sql select statement
pub fn execute_select_stmt<Tx: Datastore + DeltaStore>(
    auth: &AuthCtx,
    stmt: ProjectList,
    tx: &Tx,
    metrics: &mut ExecutionMetrics,
    check_row_limit: impl Fn(ProjectListPlan) -> Result<ProjectListPlan>,
) -> Result<Vec<ProductValue>> {
    let (stmt, sort_keys, limit) = extract_order_by(stmt);
    let plan = compile_select_list(stmt).optimize()?;
    let plan = check_row_limit(plan)?;
    let plan = ProjectListExecutor::from(plan);
    let params = ExecutionParams::from_auth(auth);
    let mut rows = vec![];
    plan.execute(tx, &params, metrics, &mut |row| {
        rows.push(row);
        Ok(())
    })?;
    if !sort_keys.is_empty() {
        sort_query_rows(&mut rows, &sort_keys);
    }
    if let Some(limit) = limit {
        rows.truncate(usize::try_from(limit).unwrap_or(usize::MAX));
    }
    Ok(rows)
}

fn extract_order_by(project: ProjectList) -> (ProjectList, Vec<SortKey>, Option<u64>) {
    match project {
        ProjectList::OrderBy(input, mut sort_keys) => {
            let (input, mut inner_sort_keys, limit) = extract_order_by(*input);
            sort_keys.append(&mut inner_sort_keys);
            (input, sort_keys, limit)
        }
        ProjectList::Limit(input, limit) => {
            let (input, sort_keys, inner_limit) = extract_order_by(*input);
            if sort_keys.is_empty() {
                (ProjectList::Limit(Box::new(input), limit), sort_keys, inner_limit)
            } else {
                (input, sort_keys, Some(limit))
            }
        }
        other => (other, Vec::new(), None),
    }
}

fn compare_query_rows(left: &ProductValue, right: &ProductValue, sort_keys: &[SortKey]) -> std::cmp::Ordering {
    for key in sort_keys {
        let index = key.field_index as usize;
        let Some(left_value) = left.elements.get(index) else {
            continue;
        };
        let Some(right_value) = right.elements.get(index) else {
            continue;
        };
        if key.nullable {
            let left_null = matches!(left_value, AlgebraicValue::Sum(sum) if sum.tag == 1);
            let right_null = matches!(right_value, AlgebraicValue::Sum(sum) if sum.tag == 1);
            if left_null != right_null {
                return if left_null == key.nulls_first {
                    std::cmp::Ordering::Less
                } else {
                    std::cmp::Ordering::Greater
                };
            }
        }
        let ordering = left_value.cmp(right_value);
        if ordering != std::cmp::Ordering::Equal {
            return if key.ascending { ordering } else { ordering.reverse() };
        }
    }
    std::cmp::Ordering::Equal
}

fn sort_query_rows(rows: &mut [ProductValue], sort_keys: &[SortKey]) {
    rows.sort_by(|left, right| compare_query_rows(left, right, sort_keys));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sorts_projected_rows_by_multiple_keys_and_direction() {
        let mut rows = vec![
            ProductValue::from(vec![AlgebraicValue::U32(2), AlgebraicValue::U32(1)]),
            ProductValue::from(vec![AlgebraicValue::U32(1), AlgebraicValue::U32(3)]),
            ProductValue::from(vec![AlgebraicValue::U32(1), AlgebraicValue::U32(2)]),
        ];
        sort_query_rows(
            &mut rows,
            &[
                SortKey {
                    field_index: 0,
                    ascending: true,
                    nulls_first: false,
                    nullable: false,
                },
                SortKey {
                    field_index: 1,
                    ascending: false,
                    nulls_first: true,
                    nullable: false,
                },
            ],
        );
        assert_eq!(rows[0].elements[0], AlgebraicValue::U32(1));
        assert_eq!(rows[0].elements[1], AlgebraicValue::U32(3));
        assert_eq!(rows[1].elements[0], AlgebraicValue::U32(1));
        assert_eq!(rows[1].elements[1], AlgebraicValue::U32(2));
        assert_eq!(rows[2].elements[0], AlgebraicValue::U32(2));
    }

    #[test]
    fn honors_explicit_null_ordering() {
        let mut rows = vec![
            ProductValue::from(vec![AlgebraicValue::enum_simple(0)]),
            ProductValue::from(vec![AlgebraicValue::enum_simple(1)]),
        ];
        sort_query_rows(
            &mut rows,
            &[SortKey {
                field_index: 0,
                ascending: true,
                nulls_first: true,
                nullable: true,
            }],
        );
        assert!(matches!(rows[0].elements[0], AlgebraicValue::Sum(ref sum) if sum.tag == 1));
    }
}

/// A utility for executing a sql dml statement
pub fn execute_dml_stmt<Tx: MutDatastore>(
    auth: &AuthCtx,
    stmt: DML,
    tx: &mut Tx,
    metrics: &mut ExecutionMetrics,
) -> Result<()> {
    let plan = compile_dml_plan(stmt).optimize()?;
    let plan = MutExecutor::from(plan);
    plan.execute(tx, &ExecutionParams::from_auth(auth), metrics)
}
