<div align="center">

# jeeflow-repository-mysql

**The MySQL repository of jeeflow-moon — pure-MoonBit wire client, real transactions.**

[![mooncakes](https://img.shields.io/badge/mooncakes-mldong%2Fjeeflow--repository--mysql-brightgreen)](https://mooncakes.io/docs/mldong/jeeflow-repository-mysql)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](../LICENSE)

</div>

Implements the full jeeflow SPI (process define / instance / task / actors / CC + design /
surrogate) over the upstream pure-MoonBit MySQL wire client (`moonbitstack/moonmysql/client`) — **no C, runs on wasm** — for
[jeeflow-moon](https://github.com/mldong/jeeflow-moon).

## Quickstart

```moonbit
let repo = @repo.MysqlRepository::from_env()   // JEFFLOW_DB_HOST/PORT/USER/PWD/NAME
let facade = @facade.Facade::make(@spi.Ctx::new(repo, @spi.NoExtRepository::new()))
```

## What's here

- **All SPI methods** — 24 repository + 14 ext-repository methods, per-operation connections with
  statement-level autocommit (the federation status quo), NULL-safe readers, DATETIME text
  normalization, BLOB content decode.
- **`m_` filters** — three-segment request params (`m_LIKE_name`, `m_pd_EQ_state`) parsed and
  compiled into parameterized WHERE fragments across all page queries.
- **Transactions** — `repo.execute_in_tx(op)`, also reachable through `MysqlTxTemplate`: one
  checked-out connection, BEGIN → op → COMMIT, full ROLLBACK on error. The handle lives on the
  **repository instance**, not in a process-global slot (issues/144): copies of an instance share
  the transaction, while `repo.new_request()` derives a fresh one per request — so sharing an
  instance across requests means sharing a transaction.
- **T1 smoke** — `smoke/` runs against a real MySQL (`SKIP_MYSQL=1` to skip on dev machines;
  **unreachable = fail, not skip** on release machines).

## Schema

`schema/schema-mysql.sql` mirrors the federation DDL (edit source lives in jeeflow-java; don't
hand-edit).

## License

Apache-2.0 — part of [jeeflow-moon](https://github.com/mldong/jeeflow-moon).
