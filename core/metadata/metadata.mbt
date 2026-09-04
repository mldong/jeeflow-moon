// 元数据注册表 —— 移植自 rust metadata.rs（7 字典 + HandlerRegistry，spec/07 v1.4.0）

///|
pub(all) struct DictItem {
  value : String
  label : String
} derive(Eq, Show)

///|
pub fn DictItem::value(self : DictItem) -> String {
  self.value
}

///|
pub fn DictItem::label(self : DictItem) -> String {
  self.label
}

///|
/// 引擎枚举字典注册表（7 键，C24：键=wf_+枚举下划线）
pub(all) struct EnumDictRegistry {
  dicts : Map[String, Array[DictItem]]
}

///|
pub fn EnumDictRegistry::new() -> EnumDictRegistry {
  let dicts : Map[String, Array[DictItem]] = Map::new()
  dicts["wf_process_define_state"] = [
    { value: "0", label: "禁用" },
    { value: "1", label: "启用" },
  ]
  dicts["wf_process_instance_state"] = [
    { value: "10", label: "进行中" },
    { value: "20", label: "已完成" },
    { value: "30", label: "已撤回" },
    { value: "40", label: "强行终止" },
    { value: "45", label: "已拒绝" },
    { value: "50", label: "挂起" },
    { value: "99", label: "已废弃" },
  ]
  dicts["wf_process_submit_type"] = [
    { value: "0", label: "发起申请" },
    { value: "1", label: "同意申请" },
    { value: "2", label: "拒绝申请" },
    { value: "3", label: "退回上一步" },
    { value: "4", label: "跳转" },
    { value: "5", label: "重新提交" },
    { value: "6", label: "退回发起人" },
    { value: "20", label: "拒绝申请(会签)" },
  ]
  dicts["wf_process_task_state"] = [
    { value: "10", label: "进行中" },
    { value: "20", label: "已完成" },
    { value: "30", label: "已撤回" },
    { value: "40", label: "强行终止" },
    { value: "50", label: "挂起" },
    { value: "99", label: "已废弃" },
  ]
  dicts["wf_process_task_type"] = [
    { value: "0", label: "主办" },
    { value: "1", label: "协办" },
    { value: "2", label: "记录" },
  ]
  dicts["wf_process_task_perform_type"] = [
    { value: "0", label: "普通参与" },
    { value: "1", label: "会签参与" },
  ]
  dicts["wf_countersign_type"] = [
    { value: "0", label: "并行会签" },
    { value: "1", label: "串行会签" },
  ]
  { dicts }
}

///|
pub fn EnumDictRegistry::list_dict_keys(self : EnumDictRegistry) -> Array[String] {
  let keys : Array[String] = []
  for k, _ in self.dicts {
    keys.push(k)
  }
  keys.sort_by(fn(a, b) { a.compare(b) })
  keys
}

///|
pub fn EnumDictRegistry::get_dict(self : EnumDictRegistry, key : String) -> Array[DictItem]? {
  self.dicts.get(key)
}

///|
pub(all) struct HandlerMeta {
  handler_type : String // 如 "AssignmentHandler"
  class_name : String // Java FQCN
  display_name : String
  order : Int
  group : String
} derive(Eq, Show)

///|
pub fn HandlerMeta::make(
  handler_type : String,
  class_name : String,
  display_name : String,
  order : Int,
  group : String
) -> HandlerMeta {
  { handler_type, class_name, display_name, order, group }
}

///|
pub fn HandlerMeta::class_name(self : HandlerMeta) -> String {
  self.class_name
}

///|
pub fn HandlerMeta::display_name(self : HandlerMeta) -> String {
  self.display_name
}

///|
pub fn HandlerMeta::order(self : HandlerMeta) -> Int {
  self.order
}

///|
pub fn HandlerMeta::handler_type(self : HandlerMeta) -> String {
  self.handler_type
}

///|
pub fn HandlerMeta::group(self : HandlerMeta) -> String {
  self.group
}

///|
/// handler 元数据注册表
pub(all) struct HandlerRegistry {
  handlers : Array[HandlerMeta]
}

///|
pub fn HandlerRegistry::new() -> HandlerRegistry {
  let handlers : Array[HandlerMeta] = []
  let ah = "AssignmentHandler"
  handlers.push({
    handler_type: ah,
    class_name: "com.mldong.jeeflow.interceptor.impl.OperatorAssignmentHandler",
    display_name: "流程发起人",
    order: -9999,
    group: "built-in",
  })
  handlers.push({
    handler_type: ah,
    class_name: "com.mldong.jeeflow.interceptor.impl.OrgUserAssignmentHandlers$ApplicantDeptLeaderAssignmentHandler",
    display_name: "发起人所属部门经理",
    order: 10,
    group: "built-in",
  })
  handlers.push({
    handler_type: ah,
    class_name: "com.mldong.jeeflow.interceptor.impl.OrgUserAssignmentHandlers$ApplicantDeptMainLeaderAssignmentHandler",
    display_name: "发起人所属部门分管领导",
    order: 20,
    group: "built-in",
  })
  handlers.push({
    handler_type: ah,
    class_name: "com.mldong.jeeflow.interceptor.impl.OrgUserAssignmentHandlers$DeptLeaderAssignmentHandler",
    display_name: "当前用户所属部门经理",
    order: 30,
    group: "built-in",
  })
  handlers.push({
    handler_type: ah,
    class_name: "com.mldong.jeeflow.interceptor.impl.OrgUserAssignmentHandlers$DeptMainLeaderAssignmentHandler",
    display_name: "当前用户所属部门分管领导",
    order: 40,
    group: "built-in",
  })
  handlers.push({
    handler_type: ah,
    class_name: "com.mldong.jeeflow.interceptor.impl.FormFieldAssigneeHandler",
    display_name: "根据表单字段值分配参与者",
    order: 50,
    group: "built-in",
  })
  handlers.push({
    handler_type: ah,
    class_name: "com.mldong.jeeflow.interceptor.impl.OrgUserAssignmentHandlers$TaskRoleAssigneeHandler",
    display_name: "根据任务节点唯一编码关联角色分配参与者",
    order: 60,
    group: "built-in",
  })
  // Default ActionPermissionProvider
  handlers.push({
    handler_type: "ActionPermissionProvider",
    class_name: "com.mldong.jeeflow.spi.impl.DefaultActionPermissionProvider",
    display_name: "默认权限码提供者",
    order: 0,
    group: "built-in",
  })
  { handlers }
}

///|
pub fn HandlerRegistry::register(self : HandlerRegistry, meta : HandlerMeta) -> Unit {
  self.handlers.push(meta)
}

///|
pub fn HandlerRegistry::list_handlers(self : HandlerRegistry, handler_type : String) -> Array[HandlerMeta] {
  let out : Array[HandlerMeta] = []
  for h in self.handlers {
    if h.handler_type == handler_type {
      out.push(h)
    }
  }
  out.sort_by(fn(a, b) { a.order.compare(b.order) })
  out
}

///|
pub fn HandlerRegistry::list_handlers_group(
  self : HandlerRegistry,
  handler_type : String,
  group : String
) -> Array[HandlerMeta] {
  let out : Array[HandlerMeta] = []
  for h in self.handlers {
    if h.handler_type == handler_type && h.group == group {
      out.push(h)
    }
  }
  out.sort_by(fn(a, b) { a.order.compare(b.order) })
  out
}

///|
pub fn HandlerRegistry::list_handler_types(self : HandlerRegistry) -> Array[String] {
  let seen : Map[String, Unit] = Map::new()
  for h in self.handlers {
    seen[h.handler_type] = ()
  }
  let types : Array[String] = []
  for t, _ in seen {
    types.push(t)
  }
  types.sort_by(fn(a, b) { a.compare(b) })
  types
}

///|
pub fn HandlerRegistry::all_handlers(self : HandlerRegistry) -> Array[HandlerMeta] {
  self.handlers
}
