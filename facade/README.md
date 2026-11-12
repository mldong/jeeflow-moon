# jeeflow-facade

**Every jeeflow workflow capability behind one call — `flow(action, args)`.**

The unified action facade of [jeeflow-moon](https://github.com/mldong/jeeflow-moon): one
entry point, one federation envelope (`code=0` success / `99999999` failure), one outbound
contract layer that every response passes through.

## Install

`moon add` without a version resolves the latest published generation and pins the exact
number into `moon.mod`. The facade needs its own module plus the engine core it dispatches
into, and an async runtime for `async fn main`:

```bash
moon new my-flow && cd my-flow
moon add mldong/jeeflow-core      # engine heart + SPI (zero registry dependencies)
moon add mldong/jeeflow-facade    # this module: flow(action, args)
moon add moonbitlang/async        # flow is async; async main needs it
```

## Quickstart

Two files, copy-paste complete. On a factory-fresh `MemoryRepository` nothing is seeded, so
the very first call already proves the envelope:

```moonbit
// cmd/main/moon.pkg
import {
  "mldong/jeeflow-core/spi" @spi,
  "mldong/jeeflow-core/memory" @memory,
  "mldong/jeeflow-core/json" @json,
  "mldong/jeeflow-facade" @facade,
  "moonbitlang/async",
}

pkgtype(kind: "executable")
```

```moonbit
// cmd/main/main.mbt — the repository is a generic parameter, small SPIs are closure fields
async fn main raise {
  let repo = @memory.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let facade = @facade.Facade::make(ctx)
  let args : Map[String, Json] = { "processDefineId": 1, "operator": "applicant" }
  println(@json.stringify(facade.flow("processDefine/startAndExecute", args)))
}
```

```
{"code":99999999,"msg":"流程定义不存在: 1"}
```

Run it with `moon run cmd/main --target wasm`. To drive a real flow, put a process definition in
the store first (`processDefine/deploy`, or `processDefine/startAndExecute` against
`mldong/jeeflow-repository-mysql` pointed at a database holding `schema/schema-mysql.sql`).

For the positive counterpart — a full leave flow (start, todo, execute, end) on the same
in-memory wiring — see the `mldong/jeeflow-core` page's Quickstart. It drives the engine
directly; `flow(action, args)` wraps those same engine steps behind one call.

The response of any action is the same three-key envelope, so `flow` can sit behind one
HTTP route in your framework of choice — that is exactly how the mldong MoonBit stack
(`github.com/mldong/mldong-moon`, `plugins/jeeflow`) wires it.

## The action surface

| group | actions |
|---|---|
| `processDefine` | page · detail · startAndExecute · deploy · redeploy · remove · upAndDown · getLastByName |
| `processInstance` | page · detail · startAndExecute · withdraw · bizData · highLight · approvalRecord · getAssigneeTextData · createCCInstance · updateCCStatus · ccList · stats/overview · stats/trend · stats/group |
| `processTask` | todoList · doneList · execute · detail · jumpAbleTaskNameList · candidatePage · surrogate · addCandidate · transfer · removeTaskActor · recall · revokeDynamicCountersign · latest |
| `processDesign` (ext repository) | page · detail · save · update · updateDefine · remove · deploy · redeploy · listByType |
| `processSurrogate` (ext repository) | page · save · update · detail · remove |

Every accepted name is a dispatch arm in `./facade.mbt`, which ships inside this package: that
file, not this table, is the authority. In the source repository the same list is also kept as
`scripts/action-manifest.json` and diffed against the Java reference implementation in both
directions (`node scripts/check-action-manifest.mjs`). This page lists the names, not a number,
so it cannot silently fall behind.

## Outbound contract layer (enforced, not optional)

- recursive **id stringification** — `id` / `*Id` / `*_id`, and plural `ids` / `*Ids` arrays
  element-wise (snowflakes exceed float64);
- **five-key pagination** — `pageNum/pageSize/recordCount/totalPage/rows`;
- **time normalization** — `yyyy-MM-dd HH:mm:ss`, ISO `T` folded to space;
- **stats as pure columns** — overview, trend (hour/day/ISO-week/month buckets), group
  (dimensions incl. stuck-node/approver and duration buckets), explicit errors on
  missing/invalid params;
- an unknown action is not a crash: `{code:99999999, msg:"未知 action: <action>"}`.

## License

Apache-2.0 — the full text ships next to this README (`./LICENSE`). Part of
[jeeflow-moon](https://github.com/mldong/jeeflow-moon).
