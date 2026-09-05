<div align="center">

# jeeflow-facade

**Every jeeflow workflow capability behind one call — `flow(action, args)`.**

[![mooncakes](https://img.shields.io/badge/mooncakes-mldong%2Fjeeflow--facade-brightgreen)](https://mooncakes.io/docs/mldong/jeeflow-facade)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](../LICENSE)

</div>

The unified 45-action facade of [jeeflow-moon](https://github.com/mldong/jeeflow-moon): one
entry point, one federation envelope (`code=0` success / `99999999` failure), one outbound
contract layer that every response passes through.

## Quickstart

```moonbit
let facade = @facade.Facade::make(ctx)   // ctx wires engine + repositories + SPI closures

let resp = facade.flow("processDefine/startAndExecute", args)  // start + auto-apply
let _    = facade.flow("processTask/execute", args)            // submitType dispatch: 0/1/2/3/4/6/20
let page = facade.flow("processTask/todoList", args)           // five-key pagination
```

## The 45 actions

| group | actions |
|---|---|
| `processDefine` (8) | page · detail · startAndExecute · deploy · redeploy · remove · upAndDown · getLastByName |
| `processInstance` (14) | page · detail · startAndExecute · withdraw · highLight · approvalRecord · getAssigneeTextData · bizData · createCCInstance · updateCCStatus · ccList · stats/overview · stats/trend · stats/group |
| `processTask` (9) | todoList · doneList · execute · detail · jumpAbleTaskNameList · candidatePage · surrogate · addCandidate · latest |
| `processDesign` (9, ext repo) | page · detail · save · update · updateDefine · remove · deploy · redeploy · listByType |
| `processSurrogate` (5, ext repo) | page · save · update · detail · remove |

## Outbound contract layer (enforced, not optional)

- recursive **id stringification** — `id` / `*Id` / `*_id`, and plural `ids` / `*Ids` arrays
  element-wise (snowflakes exceed float64);
- **five-key pagination** — `pageNum/pageSize/recordCount/totalPage/rows`;
- **time normalization** — `yyyy-MM-dd HH:mm:ss`, ISO `T` folded to space;
- **stats as pure columns** — overview (13 keys), trend (hour/day/ISO-week/month buckets),
  group (9 dimensions incl. stuck-node/approver and 4 duration buckets), explicit errors on
  missing/invalid params.

## License

Apache-2.0 — part of [jeeflow-moon](https://github.com/mldong/jeeflow-moon).
