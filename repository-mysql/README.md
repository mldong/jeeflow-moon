# jeeflow-repository-mysql

**The MySQL repository of jeeflow-moon — pure-MoonBit wire client, real transactions.**

Implements the full jeeflow SPI (process define / instance / task / actors / CC + design /
surrogate) over the upstream pure-MoonBit MySQL wire client (`moonbitstack/moonmysql/client`) — **no C, runs on wasm** — for
[jeeflow-moon](https://github.com/mldong/jeeflow-moon).

## Install

`moon add` without a version resolves the latest published generation. The repository sits on
the engine core's SPI, so both go in; `moonbitlang/async` is what an `async fn main` needs:

```bash
moon new my-mysql && cd my-mysql
moon add mldong/jeeflow-core             # engine + SPI this repository implements
moon add mldong/jeeflow-repository-mysql # this module
moon add moonbitlang/async
```

## Quickstart

Two files, copy-paste complete. Credentials come from `JEFFLOW_DB_HOST` / `JEFFLOW_DB_PORT` /
`JEFFLOW_DB_USER` / `JEFFLOW_DB_PWD` / `JEFFLOW_DB_NAME` — point them at a database that has
`schema/schema-mysql.sql` applied (a dedicated one; the write legs of the test suite create and
delete rows). `// @readme-check: needs-env JEFFLOW_DB_HOST` below is the CI marker that keeps
this block compile-only where no database is configured.

```moonbit
// cmd/main/moon.pkg
import {
  "mldong/jeeflow-core/model" @model,
  "mldong/jeeflow-core/spi" @spi,
  "mldong/jeeflow-repository-mysql/repo" @repo,
  "moonbitlang/async",
}

pkgtype(kind: "executable")

supported_targets = "+native+wasm"
```

```moonbit
// cmd/main/main.mbt
// @readme-check: needs-env JEFFLOW_DB_HOST
async fn main raise {
  // JEFFLOW_DB_HOST/PORT/USER/PWD/NAME ⇒ 一个先导过 schema/schema-mysql.sql 的库
  let repo = @repo.MysqlRepository::from_env()
  let page = @spi.ProcessRepository::page_instances(repo, @model.PageQuery::new(1L, 10L))
  println(
    "recordCount=\{page.record_count()} totalPage=\{page.total_page()} rows=\{page.rows().length()}",
  )
}
```

```
recordCount=0 totalPage=0 rows=0
```

Run it with `moon run cmd/main --target wasm`. The empty store still answers with the
federation's five-key pagination shape — same as the memory repository, which is the point of
the SPI: swapping the two changes nothing above this line.

To drive the engine instead of the repository directly, add `mldong/jeeflow-facade`
and `mldong/jeeflow-persist`, then hand the facade a context whose ext repository is the
no-op one (`MysqlRepository` covers the process SPI only — design/surrogate live in the
ext repo of the mldong stack):

```moonbit
let repo = @repo.MysqlRepository::from_env()
let ctx = @spi.Ctx::new(repo, @spi.NoExtRepository::new())
let facade = @facade.Facade::make(ctx) // flow(action, args) from here on
```

## What's here

- **All SPI methods** — 24 repository + 14 ext-repository methods, per-operation connections with
  statement-level autocommit (the federation status quo), NULL-safe readers, DATETIME text
  normalization, BLOB content decode.
- **`m_` filters** — three-segment request params (`m_LIKE_name`, `m_pd_EQ_state`) parsed and
  compiled into parameterized WHERE fragments across all page queries.
- **Transactions** — `repo.execute_in_tx(op)`, also reachable through `MysqlTxTemplate`: one
  checked-out connection, BEGIN → op → COMMIT, full ROLLBACK on error. The handle lives on the
  **repository instance**, not in a process-global slot: copies of an instance share
  the transaction, while `repo.new_request()` derives a fresh one per request — so sharing an
  instance across requests means sharing a transaction.
- **T1 smoke** — `smoke/` runs against a real MySQL (`SKIP_MYSQL=1` to skip on dev machines;
  **unreachable = fail, not skip** on release machines).

## Schema

`schema/schema-mysql.sql` mirrors the federation DDL (edit source lives in jeeflow-java; don't
hand-edit).

## License

Apache-2.0 — the full text ships next to this README (`./LICENSE`). Part of
[jeeflow-moon](https://github.com/mldong/jeeflow-moon).
