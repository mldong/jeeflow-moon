// 执行上下文 Execution —— 移植自 rust engine.rs L21-L57
// 独立小包：engine / handler / interceptor / spi 共同依赖，避免包循环。

///|
pub(all) struct Execution {
  mut process_instance : @model.ProcessInstance
  mut process_model : @parser.ProcessModel
  mut process_define : @model.ProcessDefine
  mut current_node : @parser.NodeModel?
  mut process_task : @model.ProcessTask?
  mut process_task_list : Array[@model.ProcessTask]
  mut args : @json.FlowData
  mut operator : String
  mut is_merged : Bool
  /// 本步新创建的任务
  mut new_tasks : Array[@model.ProcessTask]
  /// 本步实例是否终结（finish/reject）
  mut instance_finished : Bool
  /// 会签门控表达式变量（nrOfInstances 等）
  mut gate_vars : @json.FlowData
  /// 后加签：本次**请求**点名的本节点后继办理人（＝java `Execution#addSignOperators`）。
  /// 为什么不从 `args` 读：`args` 是"实例变量 ← 任务变量 ← 本次参数"的合并结果，
  /// 上一轮提交的 `tf_addSignOperators` 会随它复活，凭空多建一条本节点待办
  /// （`tf_nextNodeOperator` 同病，直返腿为此在 `execute_reapply_async` 里显式剥键）。
  /// 控制类参数一律只认当次请求，这里用字段承载而不是靠剥键。判据见 `core/engine/add_sign.mbt`。
  mut add_sign_operators : Array[String]
}

///|
pub fn Execution::make(
  instance : @model.ProcessInstance,
  model : @parser.ProcessModel,
  define_info : @model.ProcessDefine,
  operator : String,
  args : @json.FlowData
) -> Execution {
  {
    process_instance: instance,
    process_model: model,
    process_define: define_info,
    current_node: None,
    process_task: None,
    process_task_list: [],
    args,
    operator,
    is_merged: false,
    new_tasks: [],
    instance_finished: false,
    gate_vars: @json.FlowData::new(),
    // 后加签人一律由办理入口按**当次请求**显式带入（`load_exec_for_task`），缺省空表
    add_sign_operators: [],
  }
}
