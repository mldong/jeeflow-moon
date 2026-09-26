// 委托代理自动生效（issues/116 批次 D / spec 06 §4.5 运行期语义）——引擎内置、默认开启、可显式关闭。
// 参考实现：Java `03474fe`（SurrogateInterceptor 提升为内置）/ Python `ccb4667`（surrogate.py）/
// Go `engine/surrogate.go`（saveNewTask 收口）。
//
// 本栈挂点落位（issues/116 §3 记的两个结构缺口，逐条）：
//
// ① 「建任务点显式不触发拦截器」——Task/Custom 节点不 fire **后置**节点拦截器是刻意与
//    Java CreateTaskHandler / Go executeNode 对齐的，本轮不改它；委托改挂在
//    **新任务落库唯一收口** `Engine::persist_tasks`（`engine.mbt`）的 `save_task` **之前**。
//    本栈 7 处 `persist_tasks` 调用点覆盖了全部建任务路径（发起 / 带父实例发起 /
//    办理推进 / 串行会签每一步推进 / 会签未合并提前返回 / 表达式会签 / 跳转含回退与退回发起人），
//    漏斗唯一 ⇒ 结构上漏不掉，不存在"只挂在发起一处"。
//
// ② 「fire_pre_interceptors 是空实现」——现为真派发：按 order 遍历独立注册通道
//    `Ctx::register_pre_interceptor` 里的前置拦截器（不与后置数组共用，否则 persist 的
//    PostInterceptor 会被双触发），并在 Task/Custom 节点的建单处调用 ⇒ 第三方自写拦截器
//    从此"有地方挂"。内置委托**不走**这条通道：委托要的是"参与者已解析、taskId 已分配、
//    尚未落库"这一刻，节点 pre 的时机对不上（Task 节点的参与者集合在 create_task 才成形），
//    故落在 ① 的收口里。pre 体系的整体 canonical 形态仍归 issues/104 §P1，本轮不扩。
//
// 条款 2 ⚠️：并入的是**参与者集合本身**（`task.actor_ids`），随后由 `save_task` 之后的
// `add_task_actor(task_id, task.actor_ids)` 随任务一起落 `wf_process_task_actor`；
// **不走**"事后再补写一次 add_task_actor"——Java 首版正是那条路，且它在 taskId 分配前触发，
// 补写打在空 id 上静默无效（"看起来实现了、实际一单都没代理出去"）。
//
// 条款 3/4：默认开启；`Ctx::with_surrogate_auto_apply(false)` 显式关闭后回到"仅台账"。
// 本栈"未配置扩展仓储"的形状是 `E = @spi.NoExtRepository`（其 `get_surrogate` 恒 None）
// ⇒ 天然静默跳过；仓储自身报错也吞成 None，绝不打断建单。

///|
/// 对任务的**原始参与者快照**逐个查一次生效委托，命中的被委托人并入 `task.actor_ids`
/// （授权人保留、任一可办——委托不是转办，不摘原人）。返回是否并入了人（供测试/断言）。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::apply_surrogate(
  self : Engine[R, E],
  task : @model.ProcessTask,
  process_name : String
) -> Bool raise @error.JeeflowError {
  // 条款 3：显式关闭 ⇒ 完全跳过（行为回退到"仅台账 CRUD"）
  if !self.ctx.surrogate_auto_apply {
    return false
  }
  if task.actor_ids.is_empty() {
    return false
  }
  let now = @model.current_time_str()
  // 条款 1.2：先取快照再遍历——代理人自身的委托不再展开（A→B 且 B→C 不会把 C 也拉进来），
  // 边遍历边往同一集合追加会级联，故这里显式 copy。
  let snapshot = task.actor_ids.copy()
  let mut added = false
  for actor in snapshot {
    match (self.find_effective_surrogate(actor, process_name, now)) {
      Some(sg) => {
        let agent = sg.surrogate
        // 判据兜底（条款 5③ 的引擎侧一道）：空代理人 / 自己委托给自己不并入；
        // 去重读**实时集合**——两个授权人委托给同一人时只并一次
        if !agent.is_empty() && agent != actor && !task.actor_ids.contains(agent) {
          task.actor_ids.push(agent)
          added = true
        }
      }
      None => ()
    }
  }
  added
}

///|
/// 查一条生效委托；**仓储报错一律吞成 None**（条款 4：委托是增强能力，不得因它丢任务或
/// 打断建单）。四判据（空 processName 兜底 / 时间窗 NULL 不限 / 自委托过滤 / enabled 只认 1）
/// 收口成**单条裁决** `@model.ProcessSurrogate::is_effective`，取数顺序是条款 1.4
/// 「各作用域先按 id 取最新一条、再交裁决」（issues/123）——两个仓储各自实现且必须同答案
/// （条款 5/6）：内存仓 `core/memory/memory_ext.mbt`、SQL 仓 `repository-mysql/repo/repository_ext.mbt`。
/// 判定全在**读回侧**，引擎这里只负责"并入、原人保留"。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::find_effective_surrogate(
  self : Engine[R, E],
  actor : String,
  process_name : String,
  now : String
) -> @model.ProcessSurrogate? raise @error.JeeflowError {
  let ext = self.ctx.ext_repository()
  let outcome : Result[@model.ProcessSurrogate?, @error.JeeflowError] = (ext).get_surrogate(
    actor,
    process_name,
    now,
  )
  match outcome {
    Ok(sg) => sg
    Err(_) => None
  }
}

///|
/// 条款 1.1：委托查询用**流程模型 `name`**（迁移基线 = 内置版 `execution.getProcessModel().getName()`，
/// 用户从内置线迁过来的委托必须命中同一条）；模型未带 name 时回落 `wf_process_define.name`。
/// 本栈 `Execution` 同时持有 `process_model` 与 `process_define`，无需查库、也无需缓存。
/// ⚠️ 本栈解析器对"JSON 里没有 name 键"给的是哨兵值 `"unknown"`（`core/parser/parser.mbt`
/// 的 `parse_model`），不是空串——故"未带"判据要同时认空串与该哨兵，否则回落分支恒不成立。
///
/// 「未带」= 键缺失/哨兵/空串/**仅空白**，一律**先 trim 再判空**，且传给委托查询的必须是
/// trim 后的值（规范 06 §4.5 条款 1.1，与 Java `isNotBlank`+`trim` 同语义）。
/// 不 trim 的后果不是显示差异而是**功能分叉**：`name=" 请假 "` 时拿带空白的串去
/// `wf_process_surrogate.process_name` 做精确匹配必失配，只剩"全流程兜底"行能命中 ⇒
/// 用户在该流程自己配的委托静默失效；而 name 仅空白时也不会回落定义行。
fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::surrogate_process_name(
  self : Engine[R, E],
  exec : @exec.Execution
) -> String {
  let _ = self
  let model_name = exec.process_model.name.trim(chars=" \t\r\n").to_string()
  if !model_name.is_empty() && model_name != "unknown" {
    model_name
  } else {
    exec.process_define.name.trim(chars=" \t\r\n").to_string()
  }
}
