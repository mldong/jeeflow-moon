<div align="center">

# jeeflow-persist

**Workflow → business-table persistence for jeeflow — ARCHIVE / SYNC with field permissions.**

[![mooncakes](https://img.shields.io/badge/mooncakes-mldong%2Fjeeflow--persist-brightgreen)](https://mooncakes.io/docs/mldong/jeeflow-persist)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](../LICENSE)

</div>

`PersistPostInterceptor` copies form data out of running workflow instances into your own
business tables, driven entirely by the process definition — the role jeeflow-persist plays for
the MoonBit build of [jeeflow-moon](https://github.com/mldong/jeeflow-moon).

## Quickstart

```moonbit
let provider = @persist.InMemoryMetaProvider::new()
let meta = @persist.TableMeta::make("expense", "报销")
// ⚠ 元数据是**白名单**：`filter_editable` 只放行登记过且 permission=2（可编辑）的列。
// 只登记业务列 `note` 而漏掉 `process_instance_id`，归档行就带着空幂等键落库 ⇒
// 每次办结都插一行，幂等（C16）静默失效。要写的列请登记全（issues/151 普查 X7 的实话）。
meta.add_field(@persist.FieldMeta::make("process_instance_id", "BIGINT", "流程实例ID"))
meta.add_field(@persist.FieldMeta::make("apply_user_id", "VARCHAR(64)", "申请人"))
meta.add_field(@persist.FieldMeta::make("note", "VARCHAR(200)", "备注"))
provider.register(meta)

let interceptor = @persist.PersistPostInterceptor::make(provider, my_writer)
ctx.register_interceptor(interceptor.as_interceptor())   // order = 100 (post)
```

两个装配口按集成方的元数据来源选：自备元数据（框架 `dev_schema` / 库内省）用
`PersistPostInterceptor::make_from_provider`；另有 `with_system_fields`（系统列名与缺省用户值，
见下）与 `with_strict_columns`（列匹配档位）。

Process definition drives everything:

```json
{"persistMode": "ARCHIVE", "relTableName": "expense"}
```

- **ARCHIVE** — at the end node, on `FINISHED` + agree (`submitType=1`), insert the full `f_*`
  form once; idempotent by the `process_instance_id` key.
- **SYNC** — insert at start → update at each task (business fields filtered by the target
  node's `field.PERMISSION_*`: readonly/hidden never write through) → final-state update at the
  end; a `{nodeId}_{state}` status column is probed automatically.
- **Safety** — dynamic table names are validated (alnum+underscore, `wf_`/`sys_`/… prefixes
  refused) and failures are loud, never silent.
- **Column matching** — loose by default: a camelCase form key (`merchantName`) lands on the
  snake_case table column (`merchant_name`), case-insensitively, and the SQL always emits the
  **real** column name. Two data keys normalising onto one column resolve deterministically —
  the first one in insertion order wins. Exact matching is one switch away
  (`MysqlTableWriter::with_strict(true)` and `PersistPostInterceptor::with_strict_columns(true)`
  are the same ruler's two consumers: the table-structure filter and the metadata whitelist —
  set both, or the two layers measure with different sticks).
- **System columns** — `create_time` / `create_user` / `update_time` / `update_user` /
  `is_deleted`, all renameable and individually disableable (`None`) via
  `PersistPostInterceptor::with_system_fields`. Insert fills them with *putIfAbsent* semantics
  (a business-supplied `create_time` survives); the update leg overwrites `update_time` only.
  User columns read `apply_user_id` first (= the flow's operator), then the current operator,
  then the configured fallback (default `"system"`) — spec/09 §3, matching the Java reference.

## License

Apache-2.0 — part of [jeeflow-moon](https://github.com/mldong/jeeflow-moon).
