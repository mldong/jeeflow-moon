# 引擎 API

## 单入口：`flow(action, args)`

45 个 action 全部经由一个门面入口，返回联邦统一信封：

```moonbit
let resp = facade.flow("processTask/execute", args)   // {code, msg, data}
```

- 成功 `code=0`；业务失败 `99999999`（仅此两值）；未知 action 在顶层拒绝。
- **出口契约层**（每个响应都过一遍）：snake→camel 键名、id 递归字符串化（含复数 id 数组——雪花超出 float64 精度）、时间 `yyyy-MM-dd HH:mm:ss`、分页五键 `pageNum/pageSize/recordCount/totalPage/rows`。

## 45 action 分组

| 组 | 数量 | action |
|----|------|--------|
| processDefine | 8 | page / detail / start_and_execute / deploy / redeploy / remove / up_and_down / get_last_by_name |
| processInstance | 14（含 stats 3） | page / detail / start_and_execute / withdraw / bizData / highLight / approvalRecord / getAssigneeTextData / createCCInstance / updateCCStatus / ccList / stats/overview / stats/trend / stats/group |
| processTask | 9 | todoList / doneList / execute / taskDetail / jumpAbleTaskNameList / candidatePage / surrogate / addCandidate / latest |
| processDesign | 9（需扩展仓储） | page / detail / save / update / updateDefine / remove / deploy / redeploy / listByType |
| processSurrogate | 5（需扩展仓储） | page / save / update / detail / remove |

契约源：`docs/action-manifest.json`（与 java `JeeflowFacade` 实查 45/45 无差集）。

## 引擎操作（核心语义）

- `start` / `execute` / `jump` / `jump_to_end` / `jump_to_first` / `withdraw`，聚合根从仓储水合是一等步骤。
- **submitType 全枚举** 0=APPLY / 1=AGREE / 2=REJECT / 3=ROLLBACK / 4=JUMP / 5=RE_APPLY / 6=ROLLBACK_TO_OPERATOR / 20=COUNTERSIGN_DISAGREE。
- 状态机：实例 10/20/30/40/45/50/99；任务 10/20/30/40/50/99（全集见 spec/03）。

## 会签门控

- 并行（全齐完成）、串行（一次一单，全名单存任务变量）、比例表达式（`#nrOfCompletedInstances==2`）、一票否决（`countersignCompletionCondition=ONE_VOTE_VETO`）。
- 软拒绝 `submitType=20`：置 `countersignDisagreeFlag` 并废弃合并遗留任务。

## 事件（三型）

| 事件 | 时机 |
|------|------|
| `TASK_CREATE` | 落库**后** fire（监听器可解析到任务行，issues/13 时机对齐） |
| `INSTANCE_END` | 办结与拒绝双路都 fire |
| `CC_CREATE` | 逐人 fire，事件携带 cc 记录 id |

监听器逐个兜底：单个监听器异常不打断其余、不打断流程。

## stats（纯列聚合）

- `processInstance/stats/overview`：13 字段（total/inProgress/completed/rejected/withdrawn/suspended/todayNew/avgDurationSeconds/rejectRate/pendingTaskCount/overdueTaskCount/countersignRate/onTimeRate）；`stateIn` 入参作用于六状态计数（缺省 [10,20,30,40,45,50]，todayNew 不受影响）。
- `processInstance/stats/trend`：start/end/granularity 均必填（缺任一报错），hour/day/week/month 连续桶，裸数组出参。
- `processInstance/stats/group`：dimension ∈ state/define/category/approver/node/stuckNode/stuckApprover/durationBucket，count DESC + key ASC 确定序，durationBucket 固定 4 桶全枚举。

与 java 参考实现的一致性由固定数据集快照保证（`consistency/moon.json`，15 action 逐字段一致，
驱动 `demo/cmd/consistency`）。

## stats / reset（仅 demo）

`GET /api/stats?operator=`、`POST /api/reset`、`GET /health` 只存在于 demo 服务，mldong 集成栈没有——契约细节见 [演示站](./demo.md)。
