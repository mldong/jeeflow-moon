// issues/142 A/B 批同族缺口：内存仓**列表读路**不做参与者水合 ⇒ 只写 task_actors 的参与人
// （发起腿门面 addTaskActor、processTask/surrogate 追加，java 同款只写表）在待办/已办列表里
// 整行不可见，find_doing_tasks / find_done_tasks 投影出的 actor_ids 也仍是建单时旧集合。
// 权威判据：java JdbcProcessRepository.mapTasks:571 对每行无条件 setActorIds(findTaskActors)
// （actor 表是参与者唯一事实源），本栈 mysql 仓 hydrate_tasks 同构；8bb6a2d 只补了两条守卫
// 读路（find_task_by_id / find_history_tasks），本文件把剩下四条列表读路一起钉住。
//
// ⚠️ 夹具刻意**非对称**：同一实例里放三种行——A 只写表（缺口本体，改前对 zhang 不可见）、
//    B 表与聚合一至（对照组，改前后都该绿，防"水合=把所有行放行"的假绿）、
//    C 两处都空（真空对照，任何人都不该看到）。三行等值会让 B/C 自等假绿。

///|
fn lh_task(
  tid : Int64, name : String, state : Int, actor_ids : Array[String], actor : String
) -> @model.ProcessTask {
  {
    task_id: tid,
    process_instance_id: 7001L,
    task_name: name,
    display_name: name,
    task_type: 0,
    perform_type: 0,
    task_state: state,
    actor_id: if state == 10 { None } else { Some(actor) },
    actor_ids: actor_ids,
    finish_time: if state == 10 { None } else { Some("2026-09-30 10:00:00") },
    expire_time: None,
    form_key: None,
    parent_task_id: None,
    variables: @json.FlowData::new(),
    create_time: Some("2026-09-30 09:00:00"),
    create_user: Some("boss"),
    update_time: None,
    update_user: None,
  }
}

///|
/// 三行待办 + 一行已办：A(9001) 归属只在表里；B(9002) 表与聚合一至；C(9003) 两处都空；
/// D(9004) 已办且归属只在表里。
async fn lh_repo() -> @mem.MemoryRepository raise {
  let repo = @mem.MemoryRepository::new()
  repo.save_task(lh_task(9001L, "taskA", 10, [], "zhang"))
  repo.save_task(lh_task(9002L, "taskB", 10, ["lisi"], "lisi"))
  repo.save_task(lh_task(9003L, "taskC", 10, [], "nobody"))
  repo.save_task(lh_task(9004L, "taskD", 20, [], "zhang"))
  repo.add_task_actor(9001L, ["zhang"])
  repo.add_task_actor(9002L, ["lisi"])
  repo.add_task_actor(9004L, ["zhang"])
  repo
}

fn lh_q(op : String) -> @model.PageQuery {
  let q = @model.PageQuery::new(1L, 50L)
  q.set_operator(Some(op))
  q
}

///|
/// 缺口本体：只写表的参与人必须能在待办列表里看到自己那一行（改前红：0 行）。
async test "page_todo_tasks 水合后才不漏发起腿参与人（改前 zhang=0 红）" {
  let repo = lh_repo()
  assert_eq(repo.page_todo_tasks(lh_q("zhang")).record_count(), 1L)
  // 对照组：表与聚合一至的行改前后都该是 1，证明上面那 1 行来自水合而非过滤被放宽
  assert_eq(repo.page_todo_tasks(lh_q("lisi")).record_count(), 1L)
  // 负向：无关人仍 0 行——水合只补归属值，不得把别人的行放进来
  assert_eq(repo.page_todo_tasks(lh_q("wangwu")).record_count(), 0L)
  // 真空对照：C 两处都空 ⇒ 谁都不该看到 taskC
  let mut saw_c = false
  for row in repo.page_todo_tasks(lh_q("zhang")).rows {
    if row.task_name == "taskC" { saw_c = true }
  }
  assert_true(!saw_c)
}

///|
/// 投影一致：三条列表读路（find_doing_tasks / find_done_tasks / find_history_tasks）与
/// 单行读路 find_task_by_id 对同一行必须给出**同一个**参与人集合（防"补一条漏三条"）。
async test "四条任务读路对同一行给出同一参与者集合" {
  let repo = lh_repo()
  let mut doing_a : Array[String] = []
  for t in repo.find_doing_tasks(7001L, []) {
    if t.task_id == 9001L { doing_a = t.actor_ids.copy() }
  }
  assert_true(doing_a == ["zhang"])
  let mut done_d : Array[String] = []
  for t in repo.find_done_tasks(7001L, []) {
    if t.task_id == 9004L { done_d = t.actor_ids.copy() }
  }
  assert_true(done_d == ["zhang"])
  let mut hist_a : Array[String] = []
  for t in repo.find_history_tasks(7001L) {
    if t.task_id == 9001L { hist_a = t.actor_ids.copy() }
  }
  assert_true(hist_a == ["zhang"])
  let by_id = match repo.find_task_by_id(9001L) {
    Some(t) => t.actor_ids.copy()
    None => abort("9001 行缺失")
  }
  assert_true(by_id == ["zhang"])
  // 真空行不受影响：C 没有表记录，水合后仍是空（不得凭空造出参与人）
  let mut c_actors : Array[String] = ["dirty"]
  for t in repo.find_doing_tasks(7001L, []) {
    if t.task_id == 9003L { c_actors = t.actor_ids.copy() }
  }
  assert_true(c_actors.is_empty())
}

///|
/// 已办列表：过滤判据是 actor_id（办理人，finish 写入），水合不得改变命中集合；
/// 但投影行的 actor_ids 要与表一致（java mapTasks 同款）。
async test "page_done_tasks 过滤口径不变、投影行归属与表一致" {
  let repo = lh_repo()
  assert_eq(repo.page_done_tasks(lh_q("zhang")).record_count(), 1L)
  assert_eq(repo.page_done_tasks(lh_q("lisi")).record_count(), 0L)
  let mut d_actors : Array[String] = []
  for row in repo.page_done_tasks(lh_q("zhang")).rows {
    if row.task_name == "taskD" {
      match repo.find_task_by_id(9004L) {
        Some(t) => d_actors = t.actor_ids.copy()
        None => ()
      }
    }
  }
  assert_true(d_actors == ["zhang"])
}
