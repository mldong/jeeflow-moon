<div align="center">

# jeeflow-persist

**Workflow → business-table persistence for jeeflow — ARCHIVE / SYNC with field permissions.**

[![mooncakes](https://img.shields.io/badge/mooncakes-mldong%2Fjeeflow--persist-brightgreen)](https://mooncakes.io/docs/mldong/jeeflow-persist)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)

</div>

`PersistPostInterceptor` copies form data out of running workflow instances into your own
business tables, driven entirely by the process definition — the role jeeflow-persist plays for
the MoonBit build of [jeeflow-moon](https://github.com/mldong/jeeflow-moon).

## Install

`moon add` without a version resolves the latest published generation. This module rides on the
engine core (its metadata, writer and interceptor types are all in terms of `Ctx` / `Json`):

```bash
moon new my-persist && cd my-persist
moon add mldong/jeeflow-core      # engine + SPI + memory repository
moon add mldong/jeeflow-persist   # this module: metadata-driven persist
moon add moonbitlang/async        # async methods need it for async main
```

## Quickstart

Two files, copy-paste complete. The in-memory writer is the no-database shape of the write leg —
swap it for `MysqlTableWriter` and the same metadata drives a real table:

```moonbit
// cmd/main/moon.pkg
import {
  "mldong/jeeflow-core/json" @json,
  "mldong/jeeflow-core/memory" @memory,
  "mldong/jeeflow-core/spi" @spi,
  "mldong/jeeflow-persist" @persist,
  "moonbitlang/async",
}

pkgtype(kind: "executable")
```

```moonbit
// cmd/main/main.mbt
fn as_json(row : Map[String, Json]) -> Json {
  let obj = @json.empty_object()
  for k, v in row {
    @json.obj_set(obj, k, v)
  }
  obj
}

async fn main raise {
  // 元数据＝这张表怎么写库的唯一来源：一列一档
  let provider = @persist.InMemoryMetaProvider::new()
  let meta = @persist.TableMeta::make("expense", "报销", primary_key="expense_id")
  meta.add_field(@persist.FieldMeta::make("process_instance_id", "BIGINT", "流程实例ID"))
  // JSON 档：一个表单字段（对象/数组）收成主表的一列
  meta.add_field(@persist.FieldMeta::make(
    "detail_json", "TEXT", "明细", name="detail", storage_type=@persist.StorageType::Json,
  ))
  // ONE2MANY 档：一个数组字段递归插子表，外键回落主表主键
  meta.add_field(@persist.FieldMeta::make(
    "items", "", "子项",
    storage_type=@persist.StorageType::One2Many, target_table="expense_item",
  ))
  provider.register(meta)

  // 装饰器套在任意 DynamicTableWriter 外面：内存档验形状，真库档换 MysqlTableWriter
  let sink = @persist.InMemoryTableWriter::new()
  let writer = @persist.MetaTableWriter::make(sink, provider.as_provider())
  let pk = writer.insert("expense", {
    "process_instance_id": 7,
    "detail": [ "上海", "北京" ],
    "items": [ { "city": "上海" }, { "city": "北京" } ],
  })
  println("main pk=\{pk} row=\{@json.stringify(as_json(sink.get_row("expense", pk).unwrap()))}")
  for _, row in sink.get_table_rows("expense_item") {
    println("sub row=\{@json.stringify(as_json(row))}")
  }

  // 引擎侧装配：后置拦截器（order=100）；节点级声明档下按类名挂
  let repo = @memory.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let itc = @persist.PersistPostInterceptor::make(provider, writer)
  ctx.register_interceptor(itc.as_interceptor())
  ctx.register_named_interceptor(@persist.PERSIST_CLASS_NAME, itc.as_interceptor())
  println("interceptor wired")
}
```

```
main pk=1 row={"process_instance_id":7,"detail_json":"[\"上海\",\"北京\"]","id":1}
sub row={"city":"上海","expense_id":1,"id":2}
sub row={"city":"北京","expense_id":1,"id":3}
interceptor wired
```

Run it with `moon run cmd/main --target wasm`. `expense_id:1` on both sub-rows is the
ONE2MANY foreign key inheriting the parent's primary key; `detail_json` is the collapsed
`detail` field — that is the storage-type dispatch of the cross-language persist spec
(spec/10 at [jeeflow-doc](https://jeeflow-doc.mldong.com/)), observable without a database.

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
- **Storage types (spec/10)** — a field's `storageType` (name or code 1-5) drives how it lands:
  `NORMAL` straight to a column, `EXPAND` one object → several columns (`expandFields` maps
  sub-field → column), `JSON` object/array → a JSON string column, `ONE2ONE`/`ONE2MANY` → a
  recursive sub-table insert/update keyed by the parent's primary key (inheriting the parent's
  `apply_user_id`). Sub-tables never participate in mid-flow updates. Wrap any writer with
  `MetaTableWriter::make(base, provider)`; read the same shape back with
  `MetaTableReader::make(provider, reader_fns)` whose `as_biz_data_reader()` slots straight into
  `Ctx::with_biz_data_reader`.
- **Auto-increment / pk generation** — a missing `id` is filled by the configured
  `with_pk_generator` (or this stack's snowflake by default); `AUTO_INCREMENT` columns are left
  to the database and read back via `LAST_INSERT_ID()` on the same connection.

> **一句实话**：`PersistPostInterceptor` 的两个字段都是必填，所以 Java 参考实现里
> 「未注入 writer ⇒ 从服务容器兜底、再找不到就静默跳过」那一档在本栈**结构上不存在**。
> 这不是免检：哪天把它改成可选字段或可选注册，spec/09 §4.6 的「未注入静默跳过 vs 显性报错」
> 判据必须连着补回来。

## License

Apache-2.0 — the full text ships next to this README (`./LICENSE`). Part of
[jeeflow-moon](https://github.com/mldong/jeeflow-moon).
