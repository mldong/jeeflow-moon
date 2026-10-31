// 「退回修改、重提直返」—— 分支归属与直返上下文（引擎内部状态读写 ＋ 两条执行腿）
//
// 基准（逐条对照）：
//   · java  `jeeflow-core/.../core/ReapplySupport.java`（状态读写、静态分支分析）
//           `JeeflowEngineImpl#executeReapply` / `#createReturnToSourceApplication` /
//           `#executeAndJumpToFirstTaskNode` / `#validateReturnToSource`
//           `handler/impl/MergeBranchHandler.java`（汇合判据）、`CreateTaskHandler`（建单补归属）
//   · python `jeeflow-python/jeeflow/reapply.py`     · php `jeeflow-php/.../Support/ReapplySupport.php`
//
// 状态落点＝**零 DDL**：不新增表/列，全部寄存在任务变量 JSON 的保留键里
// （spec 04-engine-ops「退回修改、重提直返」）：
//   · `_branchCtx`     —— 分支归属栈（外层→内层数组，元素 `{fork,join,round,root}`）
//   · `_reapplyContext`—— 本次退回绑定（只出现在申请待办上）`{mode,sourceTaskId,sourceNode,branch}`
// 保留键由引擎写入，**对外办理入口必须先剥离客户端传入的同名键**（`strip_reserved`）。
//
// 并发口径（spec「同实例串行化」）：本栈引擎跑在 MoonBit async 的单任务队列上，引擎内
// 不 `spawn`、不加锁，同一实例的两次办理请求按事件循环次序串行进入 —— 与本仓既有形状一致，
// 故**不新增进程内锁**（python 的 `instance_lock` 是 asyncio 多协程并发的产物）。跨进程/多事件
// 循环部署时，同实例串行化必须由仓储侧（行锁）提供，不在本文件范围。

// ── 保留键与字段名 ──────────────────────────────────────────────────────────

///|
/// 任务变量保留键：分支归属栈（外层→内层）
pub let var_branch_ctx : String = "_branchCtx"

///|
/// 任务变量保留键：本次退回绑定（只出现在申请待办上）
pub let var_reapply_ctx : String = "_reapplyContext"

///|
pub let key_mode : String = "mode"

///|
pub let key_source_task : String = "sourceTaskId"

///|
pub let key_source_node : String = "sourceNode"

///|
pub let key_branch : String = "branch"

///|
pub let key_fork : String = "fork"

///|
pub let key_join : String = "join"

///|
pub let key_round : String = "round"

///|
pub let key_root : String = "root"

///|
/// 提交类型 `submitType` 的「重新提交」档（spec 与 java `ProcessSubmitTypeEnum.RE_APPLY` 同码）
pub let submit_type_re_apply : Int64 = 5L

///|
/// 一个分支范围（java `List<Map>` 里的一档；字段名与 JSON 键同形）
pub(all) struct BranchScope {
  fork : String
  join : String
  round : Int64
  root : Int64
} derive(Eq)

///|
/// 直返上下文（只挂在申请待办的任务变量 `_reapplyContext` 上）
pub(all) struct ReapplyContext {
  mode : String
  source_task_id : Int64
  source_node : String
  branch : Array[BranchScope]
} derive(Eq)

// ── 模型静态分析 ────────────────────────────────────────────────────────────

///|
fn outgoing_ids(model : @parser.ProcessModel, node_id : String) -> Array[String] {
  let out : Array[String] = []
  for e in model.get_output_edges(node_id) {
    out.push(e.target_node_id)
  }
  out
}

///|
/// 从节点沿入边回溯到指定 fork 之间的**任务节点**名集合；可穿过嵌套的内层 fork，遇到 stop_fork 即止。
fn backward_task_names(
  model : @parser.ProcessModel,
  node_id : String,
  stop_fork : String
) -> Array[String] {
  let names : Array[String] = []
  let stack : Array[String] = []
  for e in model.get_input_edges(node_id) {
    stack.push(e.source_node_id)
  }
  let visited : Array[String] = []
  while !stack.is_empty() {
    let cur_id = stack.pop().unwrap()
    let cur = match model.get_node(cur_id) {
      None => continue
      Some(n) => n
    }
    if visited.contains(cur_id) {
      continue
    }
    visited.push(cur_id)
    if cur.node_type is @parser.Fork {
      if cur_id == stop_fork {
        continue
      }
    } else if cur.node_type is @parser.Task {
      if !names.contains(cur_id) {
        names.push(cur_id)
      }
    }
    for e in model.get_input_edges(cur_id) {
      stack.push(e.source_node_id)
    }
  }
  names
}

///|
/// 屏蔽该汇合点后，fork 的任一分支仍能走到末端即返回 false。
fn post_dominates(model : @parser.ProcessModel, fork_id : String, join_id : String) -> Bool {
  let stack = outgoing_ids(model, fork_id)
  let visited : Array[String] = []
  let mut reaches_end = false
  while !stack.is_empty() && !reaches_end {
    let cur = stack.pop().unwrap()
    if cur == join_id || visited.contains(cur) {
      continue
    }
    visited.push(cur)
    let outs = outgoing_ids(model, cur)
    if outs.is_empty() {
      reaches_end = true
    } else {
      for t in outs {
        stack.push(t)
      }
    }
  }
  !reaches_end
}

///|
/// 分支走到汇合点的最大跳数（外层程度）；不可达返回 -1。
fn max_distance_to_join(model : @parser.ProcessModel, fork_id : String, join_id : String) -> Int {
  let mut frontier = outgoing_ids(model, fork_id)
  let visited : Array[String] = []
  for t in frontier {
    if !visited.contains(t) {
      visited.push(t)
    }
  }
  let mut d = 1
  let mut found = -1
  while !frontier.is_empty() {
    let next : Array[String] = []
    for id in frontier {
      if id == join_id {
        found = d
      }
      for t in outgoing_ids(model, id) {
        if !visited.contains(t) {
          visited.push(t)
          next.push(t)
        }
      }
    }
    frontier = next
    d = d + 1
  }
  found
}

///|
fn nearest_post_dominating_join(model : @parser.ProcessModel, fork_id : String) -> String? {
  let mut best : String? = None
  let mut best_max = -1
  for join in model.get_nodes_by_type(@parser.Join) {
    if !post_dominates(model, fork_id, join.id) {
      continue
    }
    let d = max_distance_to_join(model, fork_id, join.id)
    if d >= 0 && (best_max < 0 || d < best_max) {
      best_max = d
      best = Some(join.id)
    }
  }
  best
}

///|
/// 汇合点对应的分叉：取「最近后支配汇合点 == 本 join」的 fork，多候选取最外层。
/// 不能取"回溯遇到的第一个 fork"——嵌套并行时外层汇合点沿内层分支回溯会先撞到内层 fork。
fn fork_for_join(model : @parser.ProcessModel, join_id : String) -> String? {
  let mut best : String? = None
  let mut best_depth = -1
  for fork in model.get_nodes_by_type(@parser.Fork) {
    let nearest = nearest_post_dominating_join(model, fork.id)
    let hit = match nearest {
      Some(j) => j == join_id
      None => false
    }
    if !hit {
      continue
    }
    let d = max_distance_to_join(model, fork.id, join_id)
    if d > best_depth {
      best_depth = d
      best = Some(fork.id)
    }
  }
  best
}

///|
/// 节点所在的全部分支范围（外层→内层）。含该节点的汇合点按集合大小**降序**排列即为外→内。
/// round/root 静态档恒 0，由 `build_scopes` 在建单时填。
pub fn static_scopes(model : @parser.ProcessModel, node_name : String) -> Array[BranchScope] {
  let matched : Array[(Int, BranchScope)] = []
  for join in model.get_nodes_by_type(@parser.Join) {
    let fork = match fork_for_join(model, join.id) {
      Some(f) => f
      None => continue
    }
    let inside = backward_task_names(model, join.id, fork)
    if !inside.contains(node_name) {
      continue
    }
    matched.push((inside.length(), { fork, join: join.id, round: 0L, root: 0L }))
  }
  matched.sort_by(fn(a, b) { b.0.compare(a.0) })
  let out : Array[BranchScope] = []
  for pair in matched {
    out.push(pair.1)
  }
  out
}

///|
/// 新任务的分支归属：静态范围逐档继承**父任务同档**（同 fork+join）的 round/root；
/// 父任务不在该档（本任务就是该分叉的分支根）时 round=父任务 ID、root=本任务 ID。
/// ⚠️ 建单此刻本任务 ID 尚未分配（本仓 id 在 `persist_tasks` 落库时才给），故 root=0，
/// 由 `fill_root_self` 在 id 落定后回填（java 同款两步：`buildScopes(..., task.getTaskId())`
/// 拿到的也是 null/0，`fillRootSelf` 在 save 后补）。
pub fn build_scopes(
  parent : @model.ProcessTask?,
  model : @parser.ProcessModel,
  node_name : String,
  self_task_id : Int64
) -> Array[BranchScope] {
  let statics = static_scopes(model, node_name)
  if statics.is_empty() {
    return statics
  }
  let parent_scopes = match parent {
    Some(p) => scopes_of(p.variables)
    None => []
  }
  let parent_id = match parent {
    Some(p) => p.task_id
    None => 0L
  }
  let out : Array[BranchScope] = []
  for s in statics {
    let mut inherited : BranchScope? = None
    for p in parent_scopes {
      if p.fork == s.fork && p.join == s.join {
        inherited = Some(p)
        break
      }
    }
    match inherited {
      Some(p) => out.push({ fork: s.fork, join: s.join, round: p.round, root: p.root })
      None => out.push({ fork: s.fork, join: s.join, round: parent_id, root: self_task_id })
    }
  }
  out
}

///|
/// 分支根任务拿到真实 ID 后回填自身 root（建单时 ID 尚未生成）；返回是否发生回填。
pub fn fill_root_self(task : @model.ProcessTask) -> Bool {
  if task.task_id == 0L {
    return false
  }
  let scopes = scopes_of(task.variables)
  let mut changed = false
  let out : Array[BranchScope] = []
  for s in scopes {
    if s.root == 0L {
      out.push({ ..s, root: task.task_id })
      changed = true
    } else {
      out.push(s)
    }
  }
  if changed {
    put_scopes(task, out)
  }
  changed
}

///|
/// 建单钩子（java `CreateTaskHandler` 尾段同一刀）：给本次新建的任务补分支归属。
/// 父任务＝本 execution 刚办结的那个任务（`exec.process_task`；发起 execution 为 None）。
/// ⚠️ 只有走 `create_task_with_assignment` 的建单腿带归属；串行会签"推进出的下一位成员"
/// （`execute_task_async` 直建那一支）与 java `CountersignHandler` 同形**不补**——那一位
/// 到汇合点时无归属 ⇒ 按 legacy 判据走，两栈同答案（会签节点本身也不许配 `reapplyMode`）。
fn attach_branch_scopes(
  exec : @exec.Execution,
  node : @parser.NodeModel,
  tasks : Array[@model.ProcessTask]
) -> Unit {
  for t in tasks {
    put_scopes(t, build_scopes(exec.process_task, exec.process_model, node.id, t.task_id))
  }
}

// ── 任务变量的读写（JSON ↔ 结构体） ─────────────────────────────────────────

///|
fn i64_of(v : Json?) -> Int64 {
  match v {
    Some(x) =>
      match @json.as_i64(x) {
        Some(n) => n
        None => 0L
      }
    None => 0L
  }
}

///|
fn str_of(v : Json?) -> String {
  match v {
    Some(x) =>
      match @json.as_str(x) {
        Some(s) => s
        None => ""
      }
    None => ""
  }
}

///|
fn scope_of_json(v : Json) -> BranchScope? {
  match v {
    Json::Object(_) =>
      Some({
        fork: str_of(@json.get(v, key_fork)),
        join: str_of(@json.get(v, key_join)),
        round: i64_of(@json.get(v, key_round)),
        root: i64_of(@json.get(v, key_root)),
      })
    _ => None
  }
}

///|
fn scope_to_json(s : BranchScope) -> Json {
  @json.object_of([
    (key_fork, @json.string_of(s.fork)),
    (key_join, @json.string_of(s.join)),
    (key_round, @json.number_of(s.round)),
    (key_root, @json.number_of(s.root)),
  ])
}

///|
fn scopes_json(scopes : Array[BranchScope]) -> Json {
  let arr = @json.empty_array()
  for s in scopes {
    @json.arr_push(arr, scope_to_json(s))
  }
  arr
}

///|
/// 读 `_branchCtx`：缺键/非数组/元素非对象一律**跳过该元素**（不炸流程，与 java 逐条同形）。
pub fn scopes_of(vars : @json.FlowData) -> Array[BranchScope] {
  let out : Array[BranchScope] = []
  match vars.get(var_branch_ctx) {
    Some(v) =>
      match @json.as_array(v) {
        Some(items) =>
          for it in items {
            match scope_of_json(it) {
              Some(s) => out.push(s)
              None => ()
            }
          }
        None => ()
      }
    None => ()
  }
  out
}

///|
pub fn put_scopes(task : @model.ProcessTask, scopes : Array[BranchScope]) -> Unit {
  task.variables.insert(var_branch_ctx, scopes_json(scopes))
}

///|
/// 读 `_reapplyContext`：缺键/非对象 ⇒ None；**空对象**也当"没标记"（java `isEmpty()` 判否），
/// 免得客户端塞一个 `{}` 就能把普通申请待办拐进直返腿。
pub fn reapply_of(task : @model.ProcessTask) -> ReapplyContext? {
  match task.variables.get(var_reapply_ctx) {
    Some(v) =>
      match v {
        Json::Object(m) =>
          if m.length() == 0 {
            None
          } else {
            Some({
              mode: str_of(m.get(key_mode)),
              source_task_id: i64_of(m.get(key_source_task)),
              source_node: str_of(m.get(key_source_node)),
              branch: branch_of_json(m.get(key_branch)),
            })
          }
        _ => None
      }
    None => None
  }
}

///|
/// `branch` 字段是"外层→内层"的分支范围数组（形状与 `_branchCtx` 同）。
fn branch_of_json(raw : Json?) -> Array[BranchScope] {
  let out : Array[BranchScope] = []
  match raw {
    Some(v) =>
      match @json.as_array(v) {
        Some(items) =>
          for it in items {
            match scope_of_json(it) {
              Some(s) => out.push(s)
              None => ()
            }
          }
        None => ()
      }
    None => ()
  }
  out
}

///|
pub fn put_reapply(task : @model.ProcessTask, ctx : ReapplyContext) -> Unit {
  let obj = @json.object_of([
    (key_mode, @json.string_of(ctx.mode)),
    // sourceTaskId 写成字符串：java/php/python 三栈同为 `String.valueOf` 形状，
    // 读侧走 @json.as_i64（字符串/数字双收）⇒ 存量与别栈写的两种形态都认。
    (key_source_task, @json.string_of(ctx.source_task_id.to_string())),
    (key_source_node, @json.string_of(ctx.source_node)),
    (key_branch, scopes_json(ctx.branch)),
  ])
  task.variables.insert(var_reapply_ctx, obj)
}

///|
pub fn new_reapply_context(
  mode : String,
  source_task_id : Int64,
  source_node : String,
  branch : Array[BranchScope]
) -> ReapplyContext {
  { mode, source_task_id, source_node, branch }
}

// ── 工具 ────────────────────────────────────────────────────────────────────

///|
/// 客户端不得伪造/覆盖引擎控制键：办理入口第一件事就是剥掉这两个键。
pub fn strip_reserved(args : @json.FlowData) -> Unit {
  args.remove(var_branch_ctx) |> ignore
  args.remove(var_reapply_ctx) |> ignore
}

///|
/// 结构损坏的直返上下文明确失败，不按"无标记"处理（静默降级会让申请人以为直返了、
/// 实际重新走完整个流程）。
pub fn require_source_task_id(ctx : ReapplyContext) -> Int64 raise @error.JeeflowError {
  if ctx.source_task_id <= 0L {
    raise @error.Business("重提直返上下文缺少有效来源任务")
  }
  ctx.source_task_id
}

///|
/// 在范围内找指定汇合点的那一档
pub fn find_scope(scopes : Array[BranchScope], join_name : String) -> BranchScope? {
  for s in scopes {
    if s.join == join_name {
      return Some(s)
    }
  }
  None
}

///|
/// `submitType` 双收（数字/字符串，C3 同源）——引擎五个办理入口共用同一枚判据
pub fn submit_type_value(args : @json.FlowData) -> Int64? {
  match args.get_i64("submitType") {
    Some(v) => Some(v)
    None =>
      match args.get_str("submitType") {
        Some(s) =>
          try {
            Some(@string.parse_int64(s))
          } catch {
            _ => None
          }
        None => None
      }
  }
}

// ── 汇合判据（java MergeBranchHandler.computeMerged 的移植） ────────────────

///|
/// 汇合是否可放行。
///
/// 判据分两档（逐条照 java `MergeBranchHandler`）：
/// · **有分支归属**（到达任务带 `_branchCtx` 里本汇合点那一档）：取它的 `(fork,round)`，
///   把实例内同档任务按 `root` 分组——任一根下还有 DOING 任务 ⇒ 阻塞；任一根有 DOING 申请
///   待办的 `_reapplyContext.branch` 命中同 `(join,fork,round)` ⇒ 也阻塞（申请人回到分叉之外
///   修改时，那条申请任务不叫任何分支节点名，靠等待关系仍算「该分支未完成」——旧的按节点名
///   扫描做不到这一格）。
/// · **无分支归属**（存量任务 / 到达任务不在任何分支里）：回落本栈**原有**判据
///   ——实例无进行中任务即放行。刻意不改成 java 的"按输入源节点名扫"：
///   那是本栈建栈以来就不同的形状，改它等于顺手改既有流程的汇合语义。
///
/// 一次性放行（只建一份下游待办）由调用方在同一 execution 的 `is_merged` 上兜住。
pub fn join_ready(
  instance : @model.ProcessInstance,
  arriving : @model.ProcessTask?,
  join_id : String
) -> Bool {
  let scope = match arriving {
    Some(t) => find_scope(scopes_of(t.variables), join_id)
    None => None
  }
  let s = match scope {
    None => return legacy_merged(instance)
    Some(s) => s
  }
  let roots : Map[Int64, Bool] = Map([])
  for t in instance.tasks {
    let ts = find_scope(scopes_of(t.variables), join_id)
    let in_round = match ts {
      Some(x) => x.fork == s.fork && x.round == s.round
      None => false
    }
    let mut root = 0L
    if in_round {
      root = ts.unwrap().root
      match roots.get(root) {
        Some(_) => ()
        None => roots[root] = false
      }
    }
    if !t.is_doing() {
      continue
    }
    if in_round {
      roots[root] = true
    }
    match reapply_of(t) {
      Some(rc) =>
        for b in rc.branch {
          if b.join == join_id && b.fork == s.fork && b.round == s.round {
            roots[b.root] = true
          }
        }
      None => ()
    }
  }
  if roots.length() == 0 {
    return legacy_merged(instance)
  }
  let mut blocked = false
  for _root, v in roots {
    if v {
      blocked = true
    }
  }
  !blocked
}

///|
/// 存量/无归属任务的旧判据（＝本栈汇合支改造前的判据，一个字不改）
fn legacy_merged(instance : @model.ProcessInstance) -> Bool {
  instance.get_doing_tasks().is_empty()
}

// ── 执行腿：submitType=6 退回发起人（来源节点配 RETURN_TO_SOURCE） ──────────

///|
/// 来源节点配置 `RETURN_TO_SOURCE` 时的准入校验（**不改任何状态**）。
/// 文案逐字取 java `JeeflowEngineImpl#validateReturnToSource`。
fn[R, E] Engine::validate_return_to_source(
  self : Engine[R, E],
  model : @parser.ProcessModel,
  node : @parser.NodeModel
) -> Unit raise @error.JeeflowError {
  let _ = self
  if node.perform_type() == 1 {
    raise @error.Business("会签节点[\{node.id}]不支持退回修改直返")
  }
  if model.is_first_task_node(node.id) {
    raise @error.Business("申请节点[\{node.id}]不能配置重提直返")
  }
  match model.get_first_task_node() {
    Some(_) => ()
    None => raise @error.Business("流程定义缺少申请节点，无法退回发起人")
  }
}

///|
/// submitType=6 且来源节点配了 `RETURN_TO_SOURCE`：完成来源任务（`load_exec_for_task` 已做）后
/// 在原实例里给发起人建一条申请待办，并把本次退回绑定写进任务变量；
/// **不重放来源出边、不重触发分叉、不建来源之后的节点**。
///
/// 校验顺序照 java：先只读地判"来源节点是不是直返档 + 准入三条"，再走公共序言完成来源任务。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::execute_return_to_source_async(
  self : Engine[R, E],
  task_id : Int64,
  operator : String,
  args : @json.FlowData
) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  // 1. 只读判定（不碰任何状态）：任务 → 实例 → 定义 → 模型 → 来源节点
  let mut direct : @parser.NodeModel? = None
  let mut direct_model : @parser.ProcessModel? = None
  match (self.repo()).find_task_by_id(task_id) {
    Some(pre) =>
      if pre.is_doing() {
        match (self.repo()).find_instance_by_id(pre.process_instance_id) {
          Some(inst) =>
            match (self.repo()).find_define_by_id(inst.define_id) {
              Some(def) => {
                let m = @parser.parse_model(def.content)
                match m.get_node(pre.task_name) {
                  Some(n) =>
                    if n.node_type is @parser.Task && n.is_return_to_source() {
                      direct = Some(n)
                      direct_model = Some(m)
                    }
                  None => ()
                }
              }
              None => ()
            }
          None => ()
        }
      }
    None => ()
  }
  let node = match direct {
    None =>
      // 未配直返 ⇒ 原路（首任务节点重执行给发起人），一行行为不变
      return self.execute_jump_mode_async(task_id, operator, args, FirstNode)
    Some(n) => n
  }
  // 2. 准入校验（任何状态变更之前；配错/不支持的形状不得先完成任务、先发通知）
  self.validate_return_to_source(direct_model.unwrap(), node)
  // 3. 完成来源任务（含落库与码 5/6 事件）
  let (src_task, instance, _define, _model, exec, _st) = self.load_exec_for_task(task_id, operator, args)
  // 4. 建申请待办：参与者＝实例发起人，parent＝本次来源任务，带直返上下文
  let apply_node = match exec.process_model.get_first_task_node() {
    Some(n) => n
    None => raise @error.Business("流程定义缺少申请节点，无法退回发起人")
  }
  let app = instance.create_task(
    apply_node.id,
    apply_node.display_name,
    [instance.operator],
    instance.operator,
    @model.TaskType::from_code(apply_node.task_type()),
    @model.PerformType::from_code(apply_node.perform_type()),
    apply_node.form_key(),
    Some(src_task.task_id),
  )
  apply_node_expire_time(exec, apply_node, [app])
  // 申请待办本身不在任何分支里（java `putScopes(appTask, emptyScopes())`）
  put_scopes(app, [])
  put_reapply(
    app,
    new_reapply_context(
      @parser.reapply_mode_return_to_source,
      src_task.task_id,
      node.id,
      scopes_of(src_task.variables),
    ),
  )
  exec.new_tasks.push(app)
  self.persist_tasks(exec)
  (self.repo()).update_instance(exec.process_instance)
  exec.new_tasks
}

// ── 执行腿：submitType=5 重提（申请待办带 _reapplyContext） ─────────────────

///|
/// submitType=5 且申请待办带直返上下文：校验来源后，在**来源节点**直接建新待办。
/// 不执行申请节点出边（不重算来源前条件、不重触发分叉），也不执行来源节点出边。
///
/// 校验全在 `load_exec_for_task`（＝完成申请任务那一步）**之前**做：任何一条不过都不许
/// 留下"申请任务已办结、来源任务却没回来"的半截事实。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::execute_reapply_async(
  self : Engine[R, E],
  task_id : Int64,
  operator : String,
  args : @json.FlowData
) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  // 1. submitType 判档：缺省＝5（重新提交），其余一律拒——直返申请待办不得用普通
  //    "同意/拒绝"绕过（绕过就等于把来源分支按普通出边重放）。
  let submit_type = match submit_type_value(args) {
    Some(v) => v
    None => submit_type_re_apply
  }
  if submit_type != submit_type_re_apply {
    raise @error.Business("带重提直返标记的申请待办只接受重新提交(submitType=5)")
  }
  // 2. 只读校验
  let apply_task = match (self.repo()).find_task_by_id(task_id) {
    Some(t) => t
    None => raise @error.TaskNotFound(task_id)
  }
  let instance = match (self.repo()).find_instance_by_id(apply_task.process_instance_id) {
    Some(i) => i
    None => raise @error.Business("流程实例不存在")
  }
  let dfn = match (self.repo()).find_define_by_id(instance.define_id) {
    Some(d) => d
    None => raise @error.Business("流程定义不存在: \{instance.define_id}")
  }
  let model = @parser.parse_model(dfn.content)
  let ctx = match reapply_of(apply_task) {
    Some(c) => c
    None => raise @error.Business("重提直返上下文缺失，拒绝执行")
  }
  let source_id = require_source_task_id(ctx)
  // 来源必须**同实例**且已办结：本栈按聚合内 tasks 取行（仓储已按 instance_id 过滤），
  // 仍显式再判一次 instanceId —— 判据写在读点上，不靠"取数范围"这种隐含前提（python/php 同款）。
  let mut source : @model.ProcessTask? = None
  for t in instance.tasks {
    if t.task_id == source_id {
      source = Some(t)
    }
  }
  let source = match source {
    Some(t) => t
    None => raise @error.Business("重提直返来源任务无效或未完成")
  }
  if !source.is_finished() || source.process_instance_id != instance.instance_id {
    raise @error.Business("重提直返来源任务无效或未完成")
  }
  match model.get_node(source.task_name) {
    Some(n) =>
      if !(n.node_type is @parser.Task) || !n.is_return_to_source() {
        raise @error.Business("重提直返来源节点配置已变更，拒绝执行")
      }
    None => raise @error.Business("重提直返来源节点配置已变更，拒绝执行")
  }
  if !model.is_first_task_node(apply_task.task_name) {
    raise @error.Business("重提直返必须从申请待办发起")
  }
  // 3. 完成申请任务（公共序言：权限、字段权限过滤、办结落库、码 5/6 事件、后置拦截器）
  let (apply_done, instance2, _dfn, _model2, exec, _st2) = self.load_exec_for_task(task_id, operator, args)
  // 遗留的下一节点指定人参数不得影响本次建单（历史记录不删）
  exec.args.remove("tf_nextNodeOperator") |> ignore
  let target = match exec.process_model.get_node(source.task_name) {
    Some(n) => n
    None => raise @error.Business("重提直返来源节点配置已变更，拒绝执行")
  }
  let actors = self.resolve_assignee(exec, target)
  // 4. 在来源节点建新待办：parent＝本轮申请任务，分支归属＝上下文里那份（原样搬，不重算）
  let nt = instance2.create_task(
    target.id,
    target.display_name,
    actors,
    operator,
    @model.TaskType::from_code(target.task_type()),
    @model.PerformType::from_code(target.perform_type()),
    target.form_key(),
    Some(apply_done.task_id),
  )
  apply_node_expire_time(exec, target, [nt])
  put_scopes(nt, ctx.branch)
  exec.new_tasks.push(nt)
  self.persist_tasks(exec)
  (self.repo()).update_instance(exec.process_instance)
  exec.new_tasks
}

// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
pub extend BranchScope with Eq::{equal, not_equal}
pub extend ReapplyContext with Eq::{equal, not_equal}
