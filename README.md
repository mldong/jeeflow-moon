<div align="center">

# jeeflow-moon

**The jeeflow workflow engine in MoonBit — the federation's 7th language.**

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)
[![mooncakes](https://img.shields.io/badge/mooncakes-mldong%2Fjeeflow--core-brightgreen)](https://mooncakes.io/docs/mldong/jeeflow-core)
[![mooncakes](https://img.shields.io/badge/mooncakes-mldong%2Fjeeflow--facade-brightgreen)](https://mooncakes.io/docs/mldong/jeeflow-facade)
[![T0](https://img.shields.io/badge/T0-116%20tests%20green-brightgreen)](./docs/testing.md)

</div>

`jeeflow-moon` is a full workflow (BPM) engine — process definitions, instances, tasks,
countersign gates, CC notifications, stats — behind a **single 45-action facade**:
`flow(action, args) → {code, msg, data}`. It is the MoonBit port of the
jeeflow federation (Java reference implementation), API-compatible with the Go / Python / Node /
PHP / Rust builds: same 15 shared LogicFlow fixtures, same `99999999` error envelope, same
five-key pagination, same state machine.

```mermaid
flowchart LR
  ui["jeeflow-ui (?lang=moon)"] -->|"/moon-api → POST /wf/{action}"| demo["demo :8092<br/>run_forever"]
  demo --> f["**Facade** flow(action, args)<br/>45 actions · outbound contract layer"]
  f --> e["**Engine** (async)<br/>start · execute · jump · countersign gates"]
  e -->|"`async fn` SPI"| spi["ProcessRepository · SPI methods"]
  spi --> mem["Memory repo<br/>(T0)"]
  spi --> my[("MySQL<br/>tx template · m_ filters")]
  f --> p["**Persist**<br/>ARCHIVE / SYNC · field permissions"]
```

## Quickstart

```bash
git clone git@github.com:mldong/jeeflow-moon.git && cd jeeflow-moon
export MOON_HOME=<your-moon-home> PATH=$MOON_HOME/bin:$PATH

moon test --target wasm                                   # T0: 116 tests, all green
moon run --target wasm demo/cmd/main                      # demo on :8092 (memory store)
bash scripts/smoke_t2.sh                                  # start → todo → approve → highlight
```

Consume from your own module (`moon.mod`):

```toml
import {
  "mldong/jeeflow-core@0.1.0",     # engine core — zero runtime registry deps
  "mldong/jeeflow-facade@0.1.0",   # 45-action unified facade
}
```

```moonbit
// Wire once at startup: repositories are generic parameters, small SPIs are closure fields.
let repo    = @memory.MemoryRepository::new()
let ctx     = @spi.Ctx::new(repo, repo)
              .with_user_provider(my_user_provider)       // (String) -> UserInfo? raise
let facade  = @facade.Facade::make(ctx)

// Every workflow capability is one call:
let resp = facade.flow("processDefine/startAndExecute", args)   // {code:0, msg, data}
```

## What's here

- **45-action facade** — every engine capability routes through `flow(action, args)` with the
  federation envelope: success `code=0`, business failure `99999999` (and nothing else), unknown
  action rejected at the top level. Groups: `processDefine` (8), `processInstance` (14, incl. 3
  stats), `processTask` (9), `processDesign` (9), `processSurrogate` (5). An outbound contract
  layer runs on every response: snake→camel keys, recursive id stringification (including plural
  id arrays — snowflakes exceed float64), `yyyy-MM-dd HH:mm:ss` times, five-key pagination
  (`pageNum/pageSize/recordCount/totalPage/rows`).
- **Fully async engine** — repository SPI, engine and facade are `async fn` end to end, one event
  loop, zero nested runtimes (MoonBit has no `block_on`; the sync-SPI + bridge shape used
  elsewhere is not portable here). Engine operations: `start`, `execute`, `jump`, `jump_to_end`,
  `jump_to_first`, withdraw — with hydrate-from-repository as a first-class step.
- **Countersign gates** — parallel (all-finish), sequential (one task at a time, full roster kept
  in task variables), ratio expressions (`#nrOfCompletedInstances==2`), and one-vote veto
  (`countersignCompletionCondition=ONE_VOTE_VETO`); soft reject via `submitType=20` sets
  `countersignDisagreeFlag` and abandons merged leftovers.
- **Events** — `TASK_CREATE` (fired after persistence, so listeners can resolve the task),
  `INSTANCE_END` (both finish and reject paths), `CC_CREATE` (per actor, id passed in the event);
  per-listener fault isolation — one bad listener never breaks the flow.
- **Metadata & handlers** — 7 built-in assignment handlers registered under their Java FQCNs
  (applicant / dept leaders / form-field / role), `EnumDictRegistry` with the 7 `wf_*` dicts,
  `HandlerRegistry`.
- **Persist** (separate module) — `PersistPostInterceptor` drives business-table writes off
  `persistMode`: **ARCHIVE** (one idempotent INSERT at end+agree, keyed by `process_instance_id`)
  or **SYNC** (INSERT at start → per-task UPDATE filtered by the target node's
  `PERMISSION_*` field rights → final-state UPDATE), with table-name safety checks.
- **MySQL repository** (separate module) — all SPI methods over a vendored pure-MoonBit
  MySQL wire client (works on wasm), `m_` three-segment filters, NULL-safe row hydration,
  DATETIME text normalization, and a real `BEGIN/COMMIT/ROLLBACK` transaction template
  (connection-bound via ambient single-thread context).
- **Memory repository** (in core) — the T0 store: same behavior, no I/O; row listing is
  id-ordered for deterministic tests.
- **Clock SPI** — core has no wall clock; time is injected (`set_clock`), so stats snapshots and
  `autoGenTitle` are fully deterministic under test (fixed clock = byte-stable consistency runs).
- **Zero-registry-dependency core** — `jeeflow-core` runs on the MoonBit standard library only;
  JSON, expressions, users and transactions are all SPI. Demo wiring shows a full assembly in
  ~40 lines.

## Modules

| module | mooncakes | role |
|---|---|---|
| [`core`](./core) | [`mldong/jeeflow-core`](https://mooncakes.io/docs/mldong/jeeflow-core) | model / async SPI / engine / parser / events / metadata / memory repo |
| [`facade`](./facade) | [`mldong/jeeflow-facade`](https://mooncakes.io/docs/mldong/jeeflow-facade) | 45-action `flow(action, args)` + outbound contract layer + stats |
| [`persist`](./persist) | [`mldong/jeeflow-persist`](https://mooncakes.io/docs/mldong/jeeflow-persist) | business-table persist: ARCHIVE / SYNC + field permissions |
| [`repository-mysql`](./repository-mysql) | [`mldong/jeeflow-repository-mysql`](https://mooncakes.io/docs/mldong/jeeflow-repository-mysql) | MySQL SPI over a pure-MoonBit wire client + tx template |
| `demo` | not published | `:8092` HTTP demo + jeeflow-ui `?lang=moon` |

## Test matrix

| Tier | Command | Scope |
|---|---|---|
| T0 | `moon test --target wasm` | 116 tests: 22 compliance scenarios over the 15 shared flows, submitType matrix, event timing, outbound contracts, persist idempotency/permissions (mutation-verified) |
| T1 | `JEFFLOW_DB_*=… moon run --target wasm repository-mysql/smoke` | real MySQL: five-key pages, hydrate, `m_` filters over SQL, tx rollback leaves no half instance, double-execute is rejected |
| T2 | `bash scripts/smoke_t2.sh` | demo HTTP: start → todo → approve → state 20 → highlight → 99999999 negative |

## Design notes

Two MoonBit realities shaped the code, both documented in `docs/decisions-log.md`:

- **JSON numbers are doubles.** Snowflake ids exceed 2⁵³, so row VOs stringify ids at
  construction time and the outbound `stringify_ids` pass is a recursive safety net, not the
  first line of defense.
- **`Array::sort` on `String` mis-sorts on wasm** (calling `compare` directly is correct). The repo
  ships its own insertion sorts (`sort_strings` / `sort_i64` / `sort_int`) and uses them everywhere;
  when the toolchain is fixed the swaps are one-line.

See also `docs/contract-notes.md` (contract → implementation map), `docs/integration.md`
(embedding guide), `docs/testing.md` (T0/T1/T2) and `docs/PUBLISH.md` (mooncakes release runbook).

## License

Apache-2.0.
