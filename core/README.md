<div align="center">

# jeeflow-core

**The zero-dependency workflow engine core of jeeflow — in MoonBit.**

[![mooncakes](https://img.shields.io/badge/mooncakes-mldong%2Fjeeflow--core-brightgreen)](https://mooncakes.io/docs/mldong/jeeflow-core)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](../LICENSE)

</div>

The engine heart of [jeeflow-moon](https://github.com/mldong/jeeflow-moon) (the federation's
7th language): DDD aggregates, a fully `async` engine, the LogicFlow parser, countersign gates,
events, metadata registries and an in-memory repository — **zero registry dependencies**, JSON /
expressions / users / transactions are all SPI.

## Quickstart

```moonbit
// Wire once: repositories are generic parameters, small SPIs are closure fields.
let repo = @memory.MemoryRepository::new()
let ctx  = @spi.Ctx::new(repo, repo)
           .with_user_provider(my_user_provider)     // (String) -> UserInfo? raise
let facade = @facade.Facade::make(ctx)               // 45-action facade on top
```

## What's here

- **Model** — `ProcessInstance` / `ProcessTask` aggregates with the federation state machine
  (instance 10/20/30/40/45/50/99, task 10/20/30/40/50/99); ids are `Int64` and leave the engine
  as strings.
- **Async engine** — `start` / `execute` / `jump` / `jump_to_end` / `jump_to_first` / withdraw as
  `async fn` end to end (one event loop, no `block_on`), hydrate-from-repository built in.
- **Countersign gates** — parallel, sequential (one task at a time + roster in task variables),
  ratio expressions, one-vote veto; soft reject (`submitType=20`) with `countersignDisagreeFlag`.
- **Parser** — LogicFlow JSON → 8 node types; tolerant `performType` (number, `"1"`, `"ALL"`,
  `"COUNTERSIGN"`).
- **Events** — `TASK_CREATE` after persistence, `INSTANCE_END` on finish **and** reject,
  `CC_CREATE` per actor; per-listener fault isolation.
- **SPI** — `ProcessRepository` / `ProcessExtRepository` as generic parameters; user, org,
  search, json, expression, permission, clock, id-generator and biz-data-reader as closure
  fields.
- **Metadata** — `EnumDictRegistry` (7 `wf_*` dicts) + `HandlerRegistry` (7 built-in assignment
  handlers under Java FQCNs).
- **Memory repository** — the T0 store; rows listed in id order for determinism.
- **Clock SPI** — no wall clock in core; inject `set_clock` for fully deterministic tests.

## License

Apache-2.0 — part of [jeeflow-moon](https://github.com/mldong/jeeflow-moon).
