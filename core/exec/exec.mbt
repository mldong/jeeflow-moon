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
}

///|
pub fn Execution::make(
  instance : @model.ProcessInstance,
  model : @parser.ProcessModel,
  define : @model.ProcessDefine,
  operator : String,
  args : @json.FlowData
) -> Execution {
  {
    process_instance: instance,
    process_model: model,
    process_define: define,
    current_node: None,
    process_task: None,
    process_task_list: [],
    args,
    operator,
    is_merged: false,
    new_tasks: [],
    instance_finished: false,
    gate_vars: @json.FlowData::new(),
  }
}
