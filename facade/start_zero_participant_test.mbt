// 发起腿零参与者申请节点回归（demo 种子 define=14 同形）——issues/142 A 批「任务类零参与者
// 照样建单」（spec/02 §6.1）落地后暴露的内存仓读侧缺口：门面 start_and_execute 自动办申请前
// 只写 task_actors（java JeeflowFacade.startAndExecute 的 addTaskActor([operator]) 同款），而
// 内存仓 find_task_by_id / find_history_tasks 不做参与者水合 ⇒ 办理守卫 is_allowed 读聚合根
// 建单时的空集合，99999999「权限不足: Operator … not allowed on task …」。
//
// 权威判据：java JdbcProcessRepository 的 findTaskById / mapTasks 无条件
// setActorIds(findTaskActors)——actor 表是参与者唯一事实源；本栈 mysql 仓 hydrate_tasks 同构
// （其注释即「is_allowed 依赖 actor_ids」）。改前两格红（实测见 demo 种子 15/16），改后绿。

///|
/// 首任务节点零参与者（无 assignee / 无 candidateUsers，与 define=14 的
/// FormFieldAssigneeHandler 解析落空同形）：apply 照样建单但无参与人，task1(leader) 在下一跳
fn zero_apply_flow_json() -> String {
  let s = $|{"name": "z-apply", "displayName": "零参与者申请流程", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|   {"id": "apply", "type": "snaker:task", "text": {"value": "申请"},
  $|    "properties": {"taskType": 0, "performType": 0}},
  $|   {"id": "task1", "type": "snaker:task", "text": {"value": "审批"},
  $|    "properties": {"assignee": "leader", "taskType": 0, "performType": 0}},
  $|   {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $| ],
  $| "edges": [
  $|   {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|   {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "task1"},
  $|   {"id": "e3", "sourceNodeId": "task1", "targetNodeId": "end"}
  $| ]}
$|
  s
}

///|
/// 夹具：内存仓 + 门面 + 已部署零参与者申请流程（define id 以部署回读为准）
async fn zero_apply_facade() -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], @mem.MemoryRepository, Int64) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let facade = @facade.Facade::make(ctx.with_id_generator(fn() { gen.next_id() }))
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "z-apply",
    display_name: "零参与者申请流程",
    define_type: "approval",
    state: 1,
    content: zero_apply_flow_json(),
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let define_id = define_info.id
  (facade, repo, define_id)
}

///|
/// 改前红：99999999「权限不足: Operator user1 not allowed on task …」——门面塞进
/// task_actors 的发起人进不了守卫判据。改后：办理守卫与办结 finish() 两道 is_allowed
/// 都读水合值 ⇒ 发起成功。
async test "发起腿零参与者申请节点 startAndExecute 成功（seed define=14 同形）" {
  let (facade, _repo, define_id) = zero_apply_facade()
  let env = facade.flow(
    "processDefine/startAndExecute",
    targs([("processDefineId", define_id.to_string()), ("operator", "user1")]),
  )
  assert_eq(code_of(env), 0L)
  assert_eq(msg_of(env), "成功")
}

///|
/// 读侧钉：门面只写 task_actors 的参与人必须从两个读路读得回——
/// find_history_tasks（apply 行 actor_ids==["user1"]，改前红：[]）与
/// find_task_by_id（下一跳 leader 待办 actor_ids==["leader"]）。
async test "内存仓读侧水合：task_actors 是参与者唯一事实源（java findTaskById/mapTasks 同构）" {
  let (facade, repo, define_id) = zero_apply_facade()
  let env = facade.flow(
    "processDefine/startAndExecute",
    targs([("processDefineId", define_id.to_string()), ("operator", "user1")]),
  )
  assert_eq(code_of(env), 0L)
  let iid = parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0"))
  let mut apply_actors : Array[String] = []
  let mut doing_task1_tid : Int64 = 0L
  for t in repo.find_history_tasks(iid) {
    if t.task_name == "apply" {
      apply_actors = t.actor_ids.copy()
    }
    if t.task_name == "task1" && t.is_doing() {
      doing_task1_tid = t.task_id
    }
  }
  assert_true(apply_actors == ["user1"])
  let leader_task = match repo.find_task_by_id(doing_task1_tid) {
    Some(t) => t
    None => abort("task1 行缺失")
  }
  assert_true(leader_task.actor_ids == ["leader"])
}
