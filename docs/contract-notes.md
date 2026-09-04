# 契约对照（moon ↔ java ↔ 六语言）

> 契约源：`docs/action-manifest.json`（M0 与 java `JeeflowFacade` 实查 45/45 无差集）。
> 本文件记录 MoonBit 实现的关键契约落点与语言特有注意点。

## 45 action（5 组）

| 组 | 数量 | 入口方法 |
|---|---|---|
| processDefine | 8 | define_page/detail/start_and_execute/deploy/redeploy/remove/up_and_down/get_last_by_name |
| processInstance | 14（含 stats 3） | instance_page/detail/start_and_execute/withdraw/bizData/highLight/approvalRecord/getAssigneeTextData/createCCInstance/updateCCStatus/ccList/stats_overview/stats_trend/stats_group |
| processTask | 9 | todo_list/done_list/execute/task_detail/jump_able_task_name_list/candidate_page/surrogate/add_candidate/latest |
| processDesign | 9（需扩展仓储） | design_page/detail/save/update/updateDefine/remove/deploy/redeploy/listByType |
| processSurrogate | 5（需扩展仓储） | page/save/update/detail/remove |

## 契约要点（方案 §4 C 条目 → moon 落点）

| 契约 | 落点 |
|---|---|
| C1 id 字符串化递归含复数数组 | `facade/outbound.mbt stringify_ids`（行 VO 构造期即字符串化，雪花 >2^53 免 Double 精度丢失） |
| C2/C3 id 双收（数字/字符串；非法→非法id） | `facade/args.mbt arg_i64` |
| C4/C5 performType 容错入口+数字出口 | `core/parser` perform_type / `facade` 数字 code 输出 |
| C7 时间 yyyy-MM-dd HH:mm:ss | Clock 注入（model.current_time_str）+ 出口 T→空格 + mysql DATETIME 文本归一 19 位 |
| C8–C10 会签 | `core/engine` 门控（串行逐个/并行全齐/比例表达式/一票否决）+ `core/handler check_merge` |
| C11 抄送双路径（f_ccActors/tf_ccActors） | `engine start_async` / `execute_task_async` + CC_CREATE 逐人 fire |
| C12/C13 事件三型 + per-listener 兜底 | `core/event`（TASK_CREATE 落库后 fire，issues/13 时机） |
| C14 action 全齐/加签去重追加/决策 true 边 | manifest + `engine collect_path` + `repo add_task_actor` |
| C15 ids/id 双收、空显式报错 | `facade arg_ids` |
| C16–C20 persist | `persist/interceptor.mbt`（幂等键/权限双格式键/状态列探测/表名安全） |
| C22 分页五键 | `facade finalize_page`（仅 m_ 过滤时后过滤+重分页，D-M3-1） |
| C23 stats 纯列/显式错误 | `facade/stats.mbt` |
| C25 autoGenTitle 先注入 u_* 再生成 | `engine add_user_info + gen_auto_title` |
| C26 surrogate 双格式时间/enabled=0 不折叠 | `facade actions_ext` |
| C28 withdraw 30/30 | `model withdraw` + `facade withdraw` 级联持久化 |

## MoonBit 特有注意点

- **ids 必须 Int64**：wasm Int=32 位，雪花越界（全模型 id 用 Int64）。
- **builtin Json Number 是 Double**：行 VO 的 id 在构造期即字符串化；`Int64::to_json()` 输出字符串（core 惯例），勿直接用于数字契约键（`@json.number_of` 已绕行）。
- **String::compare/Array::sort wasm 怪异**：排序一律用 `@model.sort_strings/sort_i64/sort_int`（D-M3-2）。
- **async 无 await 关键字**：async 调用自动挂起；`moon test` 的 wasm 运行器 Windows 下 socket/fs 挂死 → IO 测试走 `moon run` 可执行（D-M2-2）。
- **records 引用语义**：mut 字段原地共享，克隆点显式 `clone()`（rust Clone 语义的显式化）。
