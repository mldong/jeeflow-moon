<div align="center">

# jeeflow-core

**The zero-dependency workflow engine core of jeeflow — in MoonBit.**

[![mooncakes](https://img.shields.io/badge/mooncakes-mldong%2Fjeeflow--core-brightgreen)](https://mooncakes.io/docs/mldong/jeeflow-core)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](./LICENSE)

</div>

The engine heart of [jeeflow-moon](https://github.com/mldong/jeeflow-moon) (the federation's
7th language): DDD aggregates, a fully `async` engine, the LogicFlow parser, countersign gates,
events, metadata registries and an in-memory repository — **zero registry dependencies**, JSON /
expressions / users / transactions are all SPI.

## Install

`moon add` without a version resolves the latest published generation:

```bash
moon new my-flow && cd my-flow
moon add mldong/jeeflow-core      # this module: engine + SPI + memory repository
moon add moonbitlang/async        # engine methods are async; async main needs it
```

If you want the one-call action surface (`flow(action, args)`) instead of driving the engine
directly, add `mldong/jeeflow-facade` too — see that module's page.

## Quickstart

Two files, copy-paste complete. The repository is a generic parameter and the small SPIs are
closure fields, so this is what "wiring" actually costs:

```moonbit
// cmd/main/moon.pkg
import {
  "mldong/jeeflow-core/spi" @spi,
  "mldong/jeeflow-core/memory" @memory,
  "mldong/jeeflow-core/model" @model,
  "mldong/jeeflow-core/json" @json,
  "mldong/jeeflow-core/engine" @engine,
  "mldong/jeeflow-core/id_gen" @id_gen,
  "mldong/jeeflow-core/metadata" @metadata,
  "moonbitlang/async",
}

pkgtype(kind: "executable")
```

```moonbit
// cmd/main/main.mbt
async fn main raise {
  // the repository is a generic parameter and the small SPIs are closure fields
  let repo = @memory.MemoryRepository::new()
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, repo) // (process repository, ext repository)
    .with_id_generator(fn() { gen.next_id() })
  let engine = @engine.Engine::make(ctx)

  // a process definition is the LogicFlow document the designer produces
  let flow = $|{
$|  "name": "leave", "displayName": "请假", "type": "approval",
$|  "nodes": [
$|    { "id": "start", "type": "snaker:start", "text": { "value": "开始" } },
$|    { "id": "apply", "type": "snaker:task", "text": { "value": "申请" },
$|      "properties": { "assignee": "applicant" } },
$|    { "id": "end", "type": "snaker:end", "text": { "value": "结束" } }
$|  ],
$|  "edges": [
$|    { "id": "e1", "sourceNodeId": "start", "targetNodeId": "apply" },
$|    { "id": "e2", "sourceNodeId": "apply", "targetNodeId": "end" }
$|  ]}
$|
  let draft : @model.ProcessDefine = {
    id: 0L, // 0 ⇒ the store assigns the id
    name: "leave",
    display_name: "请假",
    define_type: "approval",
    state: 1,
    version: 1,
    content: flow,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(draft)

  let instance = engine.start_async(draft.id, "u1", @json.FlowData::new())
  println("start   instance=\{instance.instance_id} state=\{instance.state}")
  let todos = repo.find_doing_tasks(instance.instance_id, [])
  println("todo    \{todos.length()} task at node '\{todos[0].task_name}'")
  let next = engine.execute_task_async(todos[0].task_id, "u1", @json.FlowData::new())
  let handled = repo.find_task_by_id(todos[0].task_id).unwrap()
  println("execute task=\{handled.task_id} state=\{handled.task_state} next=\{next.length()}")
  let ended = repo.find_instance_by_id(instance.instance_id).unwrap()
  println("end     instance=\{ended.instance_id} state=\{ended.state}")

  // the shipped dictionaries, so submitType / state codes never get hardcoded by hand
  let dicts = @metadata.EnumDictRegistry::new()
  println("dicts   \{dicts.list_dict_keys().join(" ")}")
}
```

```
start   instance=1 state=10
todo    1 task at node 'apply'
execute task=2 state=20 next=0
end     instance=1 state=20
dicts   wf_countersign_type wf_process_define_state wf_process_instance_state wf_process_submit_type wf_process_task_perform_type wf_process_task_state wf_process_task_type
```

`state` here is the federation code, not a MoonBit-only invention: instance 10 = running, 20 =
finished (task 10 = running, 20 = handled), and the `wf_*` dictionaries printed above are the
same tables an admin page reads, so nobody has to memorize them.

Run it with `moon run cmd/main --target wasm`. Swap `MemoryRepository` for
`mldong/jeeflow-repository-mysql` and the same wiring drives a real database.

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
- **Metadata** — `EnumDictRegistry` (the `wf_*` dictionaries above) + `HandlerRegistry`
  (built-in assignment handlers under Java FQCNs).
- **Memory repository** — the T0 store; rows listed in id order for determinism.
- **Clock SPI** — no wall clock in core; inject `set_clock` for fully deterministic tests.

## License

Apache-2.0 — the full text ships next to this README (`./LICENSE`). Part of
[jeeflow-moon](https://github.com/mldong/jeeflow-moon).
