// issues/257 · 子流程主链（processName/version → 真子实例 → 自办 → 终态回父）。
// Java 参考：StartAndExecuteSupport / StartSubProcessHandler / EndProcessHandler。

///|
/// 子启动参数：复制父业务参数，剥除父提交/路由/分支控制键。
pub fn child_args(parent_args : @json.FlowData) -> @json.FlowData {
  let args = @json.FlowData::new()
  args.merge(parent_args)
  let _ = args.remove("submitType")
  let _ = args.remove("f_nextNodeOperator")
  let _ = args.remove("tf_nextNodeOperator")
  let _ = args.remove("_branchCtx")
  let _ = args.remove("_reapplyContext")
  for key in args.keys_with_prefix("tf_") {
    let _ = args.remove(key)
  }
  args
}

///|
/// 自动触发时回退父实例 operator；普通办理人原样保留。
pub fn real_operator(operator : String, parent : @model.ProcessInstance) -> String {
  let lower = operator.to_lower()
  if lower == "flow.auto" || lower == "flow.admin" {
    parent.operator
  } else {
    operator
  }
}

///|
/// 按 processName + version 查定义；null 取 version desc、id desc 最新一行。
/// 与顶层 startById 一致，不额外过滤 state；form 不参与查找。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::find_sub_process_define(
  self : Engine[R, E],
  node : @parser.NodeModel
) -> @model.ProcessDefine? raise @error.JeeflowError {
  let name = node.process_name()
  if name.trim(chars=" \t\r\n").is_empty() {
    return None
  }
  let query = @model.PageQuery::new(1L, 1L)
  query.add_filter(@model.QueryFilter::make("t", @model.Eq, "name", name))
  match node.sub_process_version() {
    Some(version) =>
      query.add_filter(
        @model.QueryFilter::make("t", @model.Eq, "version", version.to_string()),
      )
    None => ()
  }
  query.set_order_by("t.version desc,t.id desc")
  let page = (self.repo()).page_defines(query)
  if page.rows().is_empty() {
    return None
  }
  (self.repo()).find_define_by_id(page.rows()[0].id)
}

///|
fn[R, E] Engine::require_sub_process_define(
  self : Engine[R, E],
  node : @parser.NodeModel,
  define_info : @model.ProcessDefine?
) -> @model.ProcessDefine raise @error.JeeflowError {
  let _ = self
  match define_info {
    Some(d) => d
    None => raise @error.SubProcessDefineNotFound(node.process_name())
  }
}

///|
/// 当前任务直接出边的子流程目标预检（只读）。必须排在 complete_task 之前，
/// 内存仓没有事务可回滚，报错时任务/实例/事件都不能留下写入。
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::validate_sub_process_targets(
  self : Engine[R, E],
  model : @parser.ProcessModel,
  current : @parser.NodeModel?
) -> Unit raise @error.JeeflowError {
  let node = match current {
    Some(n) => n
    None => return
  }
  for edge in model.get_output_edges(node.id) {
    match model.get_target_node(edge) {
      Some(target) =>
        if target.node_type is @parser.SubProcess {
          let define_info = self.find_sub_process_define(target)
          let _ = self.require_sub_process_define(target, define_info)
        }
      None => ()
    }
  }
}

///|
/// 自办申请前再走一次只读预检：先于 add_task_actor，连参与者写入也保证为零。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::validate_task_sub_process_targets(
  self : Engine[R, E],
  task_id : Int64
) -> Unit raise @error.JeeflowError {
  let task = match (self.repo()).find_task_by_id(task_id) {
    Some(t) => t
    None => return
  }
  let instance = match (self.repo()).find_instance_by_id(task.process_instance_id) {
    Some(i) => i
    None => return
  }
  let define_info = match (self.repo()).find_define_by_id(instance.define_id) {
    Some(d) => d
    None => return
  }
  let model = @parser.parse_model(define_info.content)
  self.validate_sub_process_targets(model, model.get_node(task.task_name))
}

///|
/// 子节点只负责启动；父出边由子实例终态续跑，子任务绝不并入父 execution.new_tasks。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::start_sub_process(
  self : Engine[R, E],
  exec : @exec.Execution,
  node : @parser.NodeModel
) -> Unit raise @error.JeeflowError {
  let define_info = self.find_sub_process_define(node)
  let define_info = self.require_sub_process_define(node, define_info)
  let parent = exec.process_instance
  let operator = real_operator(exec.operator, parent)
  let args = child_args(exec.args)
  let (child, pending) = self.start_with_parent_async_inner(
    define_info.id,
    operator,
    args,
    parent.instance_id,
    node.id,
    true,
    true,
  )
  // child 已由子 start/自办腿各自持久化并 fire；这里只转交终态续跑项。
  let _ = child
  for item in pending {
    exec.pending_parent_ends.push(item)
  }
}

///|
/// 父 execution 的自身写入全部完成后统一回父；每个子终态只消费一次。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::flush_parent_ends(
  self : Engine[R, E],
  exec : @exec.Execution
) -> Unit raise @error.JeeflowError {
  let pending = exec.pending_parent_ends
  exec.pending_parent_ends = []
  for item in pending {
    self.continue_parent_after_end(item.child_instance, item.args, item.operator)
  }
}

///|
/// 回父后把父实例新增任务拼回本次动作产出；子任务仍由各自执行链持久化。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::flush_parent_ends_collect(
  self : Engine[R, E],
  exec : @exec.Execution
) -> Array[@model.ProcessTask] raise @error.JeeflowError {
  let parent_ids : Array[Int64] = []
  for item in exec.pending_parent_ends {
    match item.child_instance.parent_id {
      Some(parent_id) =>
        if !parent_ids.contains(parent_id) {
          parent_ids.push(parent_id)
        }
      None => ()
    }
  }
  let before : Array[(Int64, Array[Int64])] = []
  for parent_id in parent_ids {
    let ids : Array[Int64] = []
    for task in (self.repo()).find_doing_tasks(parent_id, []) {
      ids.push(task.task_id)
    }
    before.push((parent_id, ids))
  }
  self.flush_parent_ends(exec)
  let created : Array[@model.ProcessTask] = []
  for entry in before {
    let (parent_id, ids) = entry
    for task in (self.repo()).find_doing_tasks(parent_id, []) {
      let mut exists = false
      for current in created {
        if current.task_id == task.task_id {
          exists = true
          break
        }
      }
      if !ids.contains(task.task_id) && !exists {
        created.push(task)
      }
    }
  }
  created
}

///|
/// 子实例终态事件已落库并播出后，按 parentId/parentNodeName 回父执行 SubProcessModel 的出边一次。
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::continue_parent_after_end(
  self : Engine[R, E],
  child : @model.ProcessInstance,
  args : @json.FlowData,
  operator : String
) -> Unit raise @error.JeeflowError {
  if child.state != @model.InstanceState::Finished.code() &&
    child.state != @model.InstanceState::Reject.code() {
    return
  }
  let parent_id = match child.parent_id {
    Some(id) => id
    None => return
  }
  let parent_node_name = match child.parent_node_name {
    Some(name) => name
    None => return
  }
  let parent = match (self.repo()).find_instance_by_id(parent_id) {
    Some(i) => i
    None => return
  }
  let define_info = match (self.repo()).find_define_by_id(parent.define_id) {
    Some(d) => d
    None => return
  }
  let model = @parser.parse_model(define_info.content)
  let parent_node = match model.get_node(parent_node_name) {
    Some(n) => n
    None => return
  }
  if !(parent_node.node_type is @parser.SubProcess) {
    return
  }
  let parent_operator = real_operator(operator, child)
  let parent_exec = @exec.Execution::make(parent, model, define_info, parent_operator, args)
  parent_exec.current_node = Some(parent_node)
  self.fire_pre_interceptors(parent_exec)
  // 与 Java SubProcessModel.exec 相同：只跑父出边，绝不再次启动本 SubProcess 节点。
  for edge in model.get_output_edges(parent_node.id) {
    match model.get_target_node(edge) {
      Some(next) => self.execute_node(parent_exec, next)
      None => println(unknown_edge_warning(parent_node.id, edge.target_node_id))
    }
  }
  self.fire_post_interceptors(parent_exec)
  // 父任务必须用父 model/父 instance id 持久化；父子变量不互相覆盖。
  self.persist_tasks(parent_exec)
  (self.repo()).update_instance(parent_exec.process_instance)
  self.flush_parent_ends(parent_exec)
}
