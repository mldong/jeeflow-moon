# 引擎 API

## 单入口：`flow(action, args)`

40+ 个 action 全部经由一个门面入口，返回联邦统一信封：

```moonbit
let resp = facade.flow("processTask/execute", args)   // {code, msg, data}
```

- 成功 `code=0`；业务失败 `99999999`（仅此两值）；未知 action 在顶层拒绝。
- **出口契约层**（每个响应都过一遍）：snake→camel 键名、id 递归字符串化（含复数 id 数组——雪花超出 float64 精度）、时间 `yyyy-MM-dd HH:mm:ss`、分页五键 `pageNum/pageSize/recordCount/totalPage/rows`。

## 40+ action 分组

下表为语义分组速览，action 一律写 **wire 名**（即 `flow()` / `POST /wf/{action}` 的实参）；精确计数以 `scripts/action-manifest.json` 为准。

| 组 | 数量 | action（wire 名） |
|----|------|--------|
| processDefine | 8 | page / detail / startAndExecute / deploy / redeploy / remove / upAndDown / getLastByName |
| processInstance | 14（含 stats 3） | page / detail / startAndExecute / withdraw / bizData / highLight / approvalRecord / getAssigneeTextData / createCCInstance / updateCCStatus / ccList / stats/overview / stats/trend / stats/group |
| processTask | 10 | todoList / doneList / execute / detail / jumpAbleTaskNameList / candidatePage / surrogate / addCandidate / transfer / latest |
| processDesign | 9（需扩展仓储） | page / detail / save / update / updateDefine / remove / deploy / redeploy / listByType |
| processSurrogate | 5（需扩展仓储） | page / save / update / detail / remove |

契约源：`scripts/action-manifest.json`（与 java `JeeflowFacade` 实查双向无差集，精确计数以 manifest 为准）。

### 请求/响应示例：`processDefine/startAndExecute`

发起后引擎自动以 `submitType=0`（APPLY）完成申请节点（`assignee="applicant"` → 发起人），
下一节点的办理人即可在 `processTask/todoList` 里看到待办。demo 实测一对真实值：

请求（`POST /wf/processDefine/startAndExecute` 的 body）：

```json
{"processDefineId":1,"operator":"applicant"}
```

响应（出口契约生效：雪花 id 已字符串化，防 float64 精度丢失）：

```json
{"code":0,"msg":"成功","data":{"processInstanceId":"2105199812302348288"}}
```

## 引擎操作（核心语义）

- `start` / `execute` / `jump` / `jump_to_end` / `jump_to_first` / `withdraw`，聚合根从仓储水合是一等步骤。
- **submitType 全枚举** 0=APPLY / 1=AGREE / 2=REJECT / 3=ROLLBACK（血缘版退回上一步，见规范 04）/ 4=JUMP / 5=RE_APPLY / 6=ROLLBACK_TO_OPERATOR（首任务节点，与 3 不同实现） / 20=COUNTERSIGN_DISAGREE。
- 状态机：实例 10/20/30/40/45/50/99；任务 10/20/30/40/50/99（全集见 spec/03）。

## 会签门控

- 并行（全齐完成）、串行（一次一单，全名单存任务变量）、比例表达式（`#nrOfCompletedInstances==2`）、一票否决（`countersignCompletionCondition=ONE_VOTE_VETO`）。
- 软拒绝 `submitType=20`：置 `countersignDisagreeFlag` 并废弃合并遗留任务。

## 事件（三型）

| 事件 | 时机 |
|------|------|
| `TASK_CREATE` | 落库**后** fire（监听器可解析到任务行 时机对齐） |
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

`GET /api/stats`、`POST /api/reset`、`GET /health` 只存在于 demo 服务（stats 无查询串——wasm 路由不剥 `?`，operator 缺省 `user1`），mldong 集成栈没有——契约细节见 [演示站](./demo.md)。
