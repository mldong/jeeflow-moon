// issues/115 残留 · 门面第 **47** 个 action `processTask/removeTaskActor` —— MoonBit 腿用例。
// 契约逐字依据＝spec 06-facade.md §processTask/removeTaskActor（八条语义＋守卫次序）与 §2.11
// （归属值归一单点）；判据基准＝java `RemoveTaskActorActionTest`（17 格，本文件同等判据 +2 格）。
//
// 与三个兄弟 action 的分工是本文件的判据主线：surrogate/addCandidate＝只加；transfer＝摘 A 加 B
// ＋submitType=7 留痕＋fire 码 7；本 action＝**只摘不加、零留痕、一次事件都不发**。每条负向都
// 同时断"参与者一动不动"——摘人是删除操作，报错却删了一半比报错更糟。
//
// ── 本栈两处与 java 基准的形状差（不是判据缩水，判据本身逐条对齐）──
// ① 缺参数档按 spec 语义 8 收敛：**缺键/空串/纯空白/0/负数** ⇒ 逐字
//    `processTaskId/actorIds 缺失`（java 的 `toLong("")` 得 null，本来就落这一档）。
//    本栈旧形状是空串也被 `arg_i64` 的 `parse_int64` 折进"非法id: "信封（`task_surrogate`
//    即如此，i142b_actor_write_test.mbt:176 钉着那一档）⇒ 本 action 在调用 `arg_i64`
//    **之前**先把空值档截出来判，兄弟 action 不回改。
//    **不跨栈统一**的是另一档：主键给了但不是数字（"abc"）走本栈既有"非法id"信封——
//    spec 明文不作跨栈判据，伪装成"参数没传"会让调用方看不出自己传错了类型（i115-L 钉住）。
// ② 语义 6「DELETE 取行上的原值」在本栈**无法经两仓取证**：内存仓与 MySQL 仓的
//    `remove_task_actor` 都先把删除列表过一遍 `@model.normalize_actors`（issues/142 §9.2 立的
//    另一条尺子：入参带空格要删得掉库里 trim 后的行），而归一是幂等的 ⇒ 门面"喂原值"与
//    "喂归一值"在两仓给出**同一个答案**，未 trim 的历史脏行两形都删不掉。所以这一条只能由
//    一枚按 SQL `DELETE ... WHERE actor_id = ?` 逐字语义（原值精确命中、不再归一）的
//    test-only 仓储 `I115SpyRepo` 取证（java 基准腿的 DirtyRowSpyRepo 同策）。
//    ⚠️ 门面仍然照契约喂原值：第三方仓储/真库 NO PAD 排序规则下，喂归一值就是"判成同一人却
//    一条没删"的假成功（go 栈实测形状）。把实现退化成"按字面相等计数＋直接喂入参集合"
//    ⇒ N/P 两格当场红（变异对照 2 已实测：红的正是"脏行撑起下限"与"未 trim 历史行没删掉"）。
//
// 复用同包 helper：setup / listening_setup / doing_task_for / targs / code_of / msg_of / data_of /
// var_field / linear_flow_json / page_has_instance / todo_page（withdraw_transfer_test.mbt、
// events_leg_test.mbt）。本文件不改动任何既有断言。

///|
/// actorIds 数组形态（与逗号串两形同判据）
fn i115f_arr(items : Array[String]) -> Json {
  @json.array_of(items.map(fn(a) { @json.string_of(a) }))
}

///|
fn i115f_s(s : String) -> Json {
  @json.string_of(s)
}

///|
/// 摘人 action 调用（Json 形态自给：缺键档要能"就是不传"）
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] i115f_call(
  facade : @facade.Facade[R, E],
  entries : Array[(String, Json)]
) -> Json raise {
  let args : Map[String, Json] = Map([])
  for e in entries {
    let (k, v) = e
    args[k] = v
  }
  facade.flow("processTask/removeTaskActor", args)
}

///|
/// 造多参与者现场用兄弟 action（addCandidate 只追加），不直接塞仓储
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] i115f_add(
  facade : @facade.Facade[R, E],
  task_id : Int64,
  actor_ids : String
) -> Json raise {
  facade.flow(
    "processTask/addCandidate",
    targs([("processTaskId", task_id.to_string()), ("actorIds", actor_ids)]),
  )
}

///|
/// 常用三参形状（主键给真实值时的快捷臂；缺键档走 i115f_call）
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] i115f_remove(
  facade : @facade.Facade[R, E],
  task_id : Int64,
  actor_ids : Json,
  operator : String
) -> Json raise {
  i115f_call(
    facade,
    [
      ("processTaskId", i115f_s(task_id.to_string())),
      ("actorIds", actor_ids),
      ("operator", i115f_s(operator)),
    ],
  )
}

// ══════════════ test-only 仓储：语义 6 删除腿的取证面 ══════════════

///|
/// 复刻"库里已存在的历史脏行"＋ `DELETE ... WHERE process_task_id = ? AND actor_id = ?` 的逐字
/// 语义：**按行上的原值精确命中**、不再对删除列表做归一（两仓都会归一，见文件头栈差 ②）。
/// 脏行只能从外部塞进来——两仓写侧都过 @model.normalize_actors，正常路径建不出
/// actor_id=''／未 trim 的行。除 find_task_actors / remove_task_actor 两条腿外全部转发内存仓，
/// 让现场（发起、加签、办结）仍走真实通道。
pub(all) struct I115SpyRepo {
  base : @mem.MemoryRepository
  dirty : Map[Int64, Array[String]]
  remove_calls : Array[Array[String]]
}

///|
pub fn I115SpyRepo::seed_dirty(self : I115SpyRepo, task_id : Int64, actor_id : String) -> Unit {
  match self.dirty.get(task_id) {
    Some(rows) => rows.push(actor_id)
    None => self.dirty[task_id] = [actor_id]
  }
}

///|
/// 只取"真人"那一半（内存仓写侧归一后的行）
pub async fn I115SpyRepo::spy_real(self : I115SpyRepo, task_id : Int64) -> Array[String] raise {
  self.base.find_task_actors(task_id)
}

///|
/// 脏行存活读数
pub fn I115SpyRepo::dirty_remaining(self : I115SpyRepo, task_id : Int64) -> Array[String] {
  match self.dirty.get(task_id) {
    Some(rows) => rows.copy()
    None => []
  }
}

///|
/// 每一次喂进 DELETE 的实参快照（判据打在"落库的值"上，不是返回值）
pub fn I115SpyRepo::remove_calls_snapshot(self : I115SpyRepo) -> Array[Array[String]] {
  self.remove_calls.copy()
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn find_define_by_id(self, id) {
  self.base.find_define_by_id(id)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn save_define(self, define_info) {
  self.base.save_define(define_info)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn update_define(self, define_info) {
  self.base.update_define(define_info)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn update_define_state(self, id, state) {
  self.base.update_define_state(id, state)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn remove_define(self, id) {
  self.base.remove_define(id)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn find_instance_by_id(self, id) {
  self.base.find_instance_by_id(id)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn save_instance(self, instance) {
  self.base.save_instance(instance)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn update_instance(self, instance) {
  self.base.update_instance(instance)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn find_task_by_id(self, id) {
  self.base.find_task_by_id(id)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn save_task(self, task) {
  self.base.save_task(task)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn update_task(self, task) {
  self.base.update_task(task)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn find_doing_tasks(self, iid, names) {
  self.base.find_doing_tasks(iid, names)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn find_done_tasks(self, iid, names) {
  self.base.find_done_tasks(iid, names)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn find_history_tasks(self, iid) {
  self.base.find_history_tasks(iid)
}

///|
/// 一条裸 SELECT 的形状：真人行＋历史脏行并起来（脏行本来就会被读出来；内存仓的
/// find_task_actors 只看得见归一后的真人行）
pub impl @spi.ProcessRepository for I115SpyRepo with fn find_task_actors(self, task_id) {
  let out = self.base.find_task_actors(task_id)
  match self.dirty.get(task_id) {
    Some(rows) => for r in rows {
      out.push(r)
    }
    None => ()
  }
  out
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn add_task_actor(self, task_id, actors) {
  self.base.add_task_actor(task_id, actors)
}

///|
/// 记录每一次删除实参 + 按原值精确命中删脏行（真人行交给内存仓；两仓那层归一不在本格判据面）
pub impl @spi.ProcessRepository for I115SpyRepo with fn remove_task_actor(self, task_id, actors) {
  self.remove_calls.push(actors.copy())
  match self.dirty.get(task_id) {
    Some(rows) => {
      let kept : Array[String] = []
      for r in rows {
        // DELETE 的实参是门面喂进来的**行上原值** ⇒ 这里按字面相等命中，与 SQL 同判据
        if !actors.contains(r) {
          kept.push(r)
        }
      }
      self.dirty[task_id] = kept
    }
    None => ()
  }
  self.base.remove_task_actor(task_id, actors)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn create_cc_instance(self, iid, creator, ids) {
  self.base.create_cc_instance(iid, creator, ids)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn find_cc_actors(self, iid) {
  self.base.find_cc_actors(iid)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn create_cc_instance_if_absent(self, iid, creator, ids) {
  self.base.create_cc_instance_if_absent(iid, creator, ids)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn update_cc_status(self, iid, state) {
  self.base.update_cc_status(iid, state)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn page_todo_tasks(self, query) {
  self.base.page_todo_tasks(query)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn page_done_tasks(self, query) {
  self.base.page_done_tasks(query)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn page_instances(self, query) {
  self.base.page_instances(query)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn page_cc_instances(self, query) {
  self.base.page_cc_instances(query)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn page_defines(self, query) {
  self.base.page_defines(query)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn count_todo_tasks(self, actor) {
  self.base.count_todo_tasks(actor)
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn get_all_instances(self) {
  self.base.get_all_instances()
}

///|
pub impl @spi.ProcessRepository for I115SpyRepo with fn get_all_tasks(self) {
  self.base.get_all_tasks()
}

///|
/// 扩展仓储仍用内存仓（同一对象）；门面主仓储走 spy ⇒ 现场照由真实发起通道造
async fn i115f_spy_setup(
  content : String
) -> (@facade.Facade[I115SpyRepo, @mem.MemoryRepository], I115SpyRepo, @mem.MemoryRepository, Int64) raise {
  let base = @mem.MemoryRepository::new()
  let spy : I115SpyRepo = { base, dirty: Map([]), remove_calls: [] }
  let ctx = @spi.Ctx::new(spy, base)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i115-spy",
    display_name: "摘除参与人脏行流程",
    define_type: "approval",
    state: 1,
    content,
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  base.save_define(define_info)
  let env = facade.flow(
    "processInstance/startAndExecute",
    targs([("processDefineId", define_info.id.to_string()), ("operator", "applicant")]),
  )
  assert_eq(msg_of(env), "成功")
  let iid = @json.get_str(data_of(env), "processInstanceId").unwrap_or("0")
  (facade, spy, base, parse_iid(iid))
}

// ══════════════ 语义 1「只摘不加」＋正向核心 ══════════════

///|
/// A 只删点名的那一个人，其余参与人原样保留（含顺序）；data 出 null（前端消费面不读 data）
async test "i115-A 只摘点名的人，其余参与人原样保留 + data=null" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(msg_of(i115f_add(facade, tid, "9001,9002")), "成功")
  assert_true(repo.find_task_actors(tid) == ["leader", "9001", "9002"])
  let env = i115f_remove(facade, tid, i115f_arr(["9001"]), "flow.admin")
  assert_eq(code_of(env), 0L)
  assert_eq(msg_of(env), "成功")
  assert_true(@json.get(env, "data") is Some(Json::Null))
  assert_true(repo.find_task_actors(tid) == ["leader", "9002"])
}

///|
/// B 一次摘多人（集合语义，不是"一次只能摘一个人"）
async test "i115-B 一次摘多人" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(msg_of(i115f_add(facade, tid, "9001,9002,9003")), "成功")
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["9001", "9002"]), "flow.admin")), "成功")
  assert_true(repo.find_task_actors(tid) == ["leader", "9003"])
}

///|
/// C 逗号串腿与数组腿同判据（§2.11 第 1 行"两形一把尺子"，摘人腿不得另抄一份）
async test "i115-C actorIds 逗号串形态同判据（带空格元素照命中）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(msg_of(i115f_add(facade, tid, "9001,9002")), "成功")
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_s("9001, 9002 "), "flow.admin")), "成功")
  assert_true(repo.find_task_actors(tid) == ["leader"])
}

///|
/// R 摘除必须真的作用在待办面上：被摘的人不再是参与人（"假成功"的反面），其余人照旧可办
async test "i115-R 被摘的人待办消失，其余人待办不受影响（门面出口取证）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(msg_of(i115f_add(facade, tid, "9001")), "成功")
  assert_true(page_has_instance(todo_page(facade, "9001"), iid))
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["9001"]), "flow.admin")), "成功")
  assert_true(!page_has_instance(todo_page(facade, "9001"), iid))
  assert_true(page_has_instance(todo_page(facade, "leader"), iid))
}

// ══════════════ 语义 3「归属判据同 transfer」 ══════════════

///|
/// D 本人摘自己的那一票：无需特权
async test "i115-D 本人摘自己无需特权" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(msg_of(i115f_add(facade, tid, "9001")), "成功")
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["9001"]), "9001")), "成功")
  assert_true(repo.find_task_actors(tid) == ["leader"])
}

///|
/// E 借道摘他人必须拦下（transfer 能"摘 A 加 B"是因为 A＝操作人本人，本 action 同理），
///    且报错后参与者一动不动
async test "i115-E 借道摘他人被拦，参与者一动不动" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(msg_of(i115f_add(facade, tid, "9001")), "成功")
  let env = i115f_remove(facade, tid, i115f_arr(["9001"]), "leader")
  assert_eq(code_of(env), 99999999L)
  assert_eq(msg_of(env), "无权限摘除该任务参与人")
  assert_true(repo.find_task_actors(tid) == ["leader", "9001"])
}

///|
/// F flow.auto / flow.admin 同档放行；大小写不敏感沿用本栈既有写法
///    （is_privileged_operator 走 to_lower，与 java 同口径）
async test "i115-F flow.auto 与 flow.admin（含大小写变体）放行" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(msg_of(i115f_add(facade, tid, "9001,9002,9003")), "成功")
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["9001"]), "flow.auto")), "成功")
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["9002"]), "FLOW.ADMIN")), "成功")
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["9003"]), "Flow.Auto")), "成功")
  assert_true(repo.find_task_actors(tid) == ["leader"])
}

// ══════════════ 语义 5「不得摘空」：判据是集合差，不是入参条数 ══════════════

///|
/// G 摘空会造出无人可办又无法重派的死单 ⇒ 拦下且一个人都不删
async test "i115-G 不得摘空" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_true(repo.find_task_actors(tid) == ["leader"])
  let env = i115f_remove(facade, tid, i115f_arr(["leader"]), "leader")
  assert_eq(code_of(env), 99999999L)
  assert_eq(msg_of(env), "至少需保留一名参与人")
  assert_true(repo.find_task_actors(tid) == ["leader"])
}

///|
/// H 混入非参与者 id 绕不过下限（spec 语义 5 第二句：判据是集合差，不是入参条数）
async test "i115-H 混入非参与者 id 绕不过「至少留一人」" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(msg_of(i115f_add(facade, tid, "9001")), "成功")
  let env = i115f_remove(facade, tid, i115f_arr(["leader", "9001", "ghost"]), "leader")
  assert_eq(msg_of(env), "至少需保留一名参与人")
  assert_true(repo.find_task_actors(tid) == ["leader", "9001"])
}

// ══════════════ 语义 4「只作用于进行中任务」 ══════════════

///|
/// I 历史参与人行是审批链的取证依据 ⇒ 非 DOING 一律拦下，历史行不动
async test "i115-I 已办结任务不可摘人，历史行不动" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/execute",
        targs([("processTaskId", tid.to_string()), ("operator", "leader"), ("submitType", "1")]),
      ),
    ),
    "成功",
  )
  let env = i115f_remove(facade, tid, i115f_arr(["leader"]), "flow.admin")
  assert_eq(code_of(env), 99999999L)
  assert_eq(msg_of(env), "任务非进行中，不可摘除参与人")
  assert_true(repo.find_task_actors(tid) == ["leader"])
}

// ══════════════ 语义 2「不留痕、不 fire 事件」 ══════════════

///|
/// J 零留痕（不置 submitType、不写 tf_* 变量、不覆写 actor_id/update_* 列）＋零事件
///    （摘人不在 132 定稿事件集里；码 7 的语义是"参与者被替换"）
async test "i115-J 零留痕 + 零事件" {
  let (facade, repo, iid, events) = listening_setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(msg_of(i115f_add(facade, tid, "9001")), "成功")
  // 留痕列的"改前读数"：建单路径本来就会写 update_user（不是摘人写的），
  // 判据只能是"摘人这一步没动它"，不能假定它是 null。
  let snapshot = repo.find_task_by_id(tid).unwrap()
  let user_before = snapshot.update_user
  let time_before = snapshot.update_time
  let actor_id_before = snapshot.actor_id
  let events_before = events.length()
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["9001"]), "flow.admin")), "成功")
  // 零事件：这次调用一条都不发（不是"少发一条"）
  assert_eq(events.length(), events_before)
  assert_eq(events.filter(fn(e) { e.event_type().name() == "TASK_TRANSFER" }).length(), 0)
  let back = repo.find_task_by_id(tid).unwrap()
  assert_eq(var_field(back, "submitType"), "<missing>")
  assert_eq(var_field(back, "tf_transferHistory"), "<missing>")
  assert_eq(var_field(back, "tf_transferTo"), "<missing>")
  assert_eq(var_field(back, "tf_transferReason"), "<missing>")
  assert_eq(var_field(back, "tf_approvalComment"), "<missing>")
  assert_eq(back.update_user, user_before)
  assert_eq(back.update_time, time_before)
  assert_eq(back.actor_id, actor_id_before)
  assert_true(repo.find_task_actors(tid) == ["leader"])
}

// ══════════════ 语义 7「幂等（非参与者静默忽略）」 ══════════════

///|
/// K 重放第二次仍成功；一个都没命中 ⇒ 空操作、照常成功信封
async test "i115-K 幂等重放 + 未命中静默空操作" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(msg_of(i115f_add(facade, tid, "9001")), "成功")
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["9001"]), "flow.admin")), "成功")
  assert_true(repo.find_task_actors(tid) == ["leader"])
  assert_eq(code_of(i115f_remove(facade, tid, i115f_arr(["9001"]), "flow.admin")), 0L)
  assert_true(repo.find_task_actors(tid) == ["leader"])
  assert_eq(code_of(i115f_remove(facade, tid, i115f_arr(["ghost"]), "flow.admin")), 0L)
  assert_true(repo.find_task_actors(tid) == ["leader"])
}

// ══════════════ 必填档与守卫次序（spec 同节钉死，八栈不接受自行排序） ══════════════

///|
/// L 报错档逐字文案：operator 两形 / 缺参数六形（含空串与纯空白）/ 非数字主键仍走"非法id" /
///    任务不存在，且一条都不许删
async test "i115-L 必填档与缺参数档逐字文案 + 零删除" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  let before = repo.find_task_actors(tid)
  // operator：缺键与纯空白同判"必填"档（严禁回落 user1 —— operator_arg 那支会回落，本 action 不用它）
  assert_eq(
    msg_of(i115f_call(facade, [("processTaskId", i115f_s(tid.to_string())), ("actorIds", i115f_arr(["leader"]))])),
    "operator 必填",
  )
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["leader"]), "   ")), "operator 必填")
  // 缺参数：主键缺键 / 主键 0 / 主键负数 / actorIds 缺键 / actorIds 归一后为空
  //          ⇒ 与兄弟 action surrogate 同一逐字文案（不另造）
  assert_eq(
    msg_of(i115f_call(facade, [("actorIds", i115f_arr(["9001"])), ("operator", i115f_s("flow.admin"))])),
    "processTaskId/actorIds 缺失",
  )
  assert_eq(msg_of(i115f_remove(facade, 0L, i115f_arr(["9001"]), "flow.admin")), "processTaskId/actorIds 缺失")
  assert_eq(msg_of(i115f_remove(facade, -1L, i115f_arr(["9001"]), "flow.admin")), "processTaskId/actorIds 缺失")
  assert_eq(
    msg_of(i115f_call(facade, [("processTaskId", i115f_s(tid.to_string())), ("operator", i115f_s("flow.admin"))])),
    "processTaskId/actorIds 缺失",
  )
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["", "  ", "   "]), "flow.admin")), "processTaskId/actorIds 缺失")
  // 主键空串/纯空白 ⇒ 缺参数档（spec 语义 8：空值与缺键同判，java `toLong("")` 也落这一档）
  assert_eq(
    msg_of(i115f_call(
      facade,
      [
        ("processTaskId", i115f_s("")),
        ("actorIds", i115f_arr(["9001"])),
        ("operator", i115f_s("flow.admin")),
      ],
    )),
    "processTaskId/actorIds 缺失",
  )
  assert_eq(
    msg_of(i115f_call(
      facade,
      [
        ("processTaskId", i115f_s("   ")),
        ("actorIds", i115f_arr(["9001"])),
        ("operator", i115f_s("flow.admin")),
      ],
    )),
    "processTaskId/actorIds 缺失",
  )
  // 主键"给了但不是数字" ⇒ 本栈既有"非法id"信封原样透出（spec 明文**不**统一这一档）
  let e_bad_pk = i115f_call(
    facade,
    [
      ("processTaskId", i115f_s("abc")),
      ("actorIds", i115f_arr(["9001"])),
      ("operator", i115f_s("flow.admin")),
    ],
  )
  assert_eq(code_of(e_bad_pk), 99999999L)
  assert_true(msg_of(e_bad_pk).contains("非法id"))
  // 任务不存在（本 action 的逐字判据，不带 id 尾巴）
  assert_eq(msg_of(i115f_remove(facade, 424242L, i115f_arr(["9001"]), "flow.admin")), "任务不存在")
  assert_true(repo.find_task_actors(tid) == before)
}

///|
/// M 守卫次序两支：operator 必填 排在缺参数之前（否则鉴权缺口被参数报错藏起来）；
///    权限档排在非进行中之前（否则外人可借"任务已完成"探别人的任务状态）
async test "i115-M 守卫次序（operator 先于缺参数、权限先于非进行中）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(
    msg_of(i115f_call(facade, [("processTaskId", i115f_s("")), ("actorIds", i115f_arr(["leader"]))])),
    "operator 必填",
  )
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/execute",
        targs([("processTaskId", tid.to_string()), ("operator", "leader"), ("submitType", "1")]),
      ),
    ),
    "成功",
  )
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["leader"]), "outsider")), "无权限摘除该任务参与人")
  assert_true(repo.find_task_actors(tid) == ["leader"])
}

// ══════════════ 语义 5/6 的脏行腿（test-only 仓储取证，栈差 ②见文件头） ══════════════

///|
/// N 带空格入参删得掉真人 ∧ 空值不误删 actor_id='' 脏行 ∧ 喂进 DELETE 的实参永不含空值
async test "i115-N 带空格入参删得掉真人，空值不误删脏行，DELETE 实参不含空值" {
  let (facade, spy, base, iid) = i115f_spy_setup(linear_flow_json())
  let tid = doing_task_for(base, iid, "leader").task_id
  assert_eq(msg_of(i115f_add(facade, tid, "9001,9002")), "成功")
  spy.seed_dirty(tid, "")
  spy.seed_dirty(tid, "   ")
  assert_eq(
    msg_of(i115f_remove(facade, tid, i115f_arr([" 9001 ", "", "   ", "9002"]), "flow.admin")),
    "成功",
  )
  assert_true(spy.spy_real(tid) == ["leader"])
  assert_true(spy.dirty_remaining(tid) == ["", "   "])
  for call in spy.remove_calls_snapshot() {
    for a in call {
      assert_true(!a.trim(chars=" \t\r\n").is_empty())
    }
  }
}

///|
/// O 匹配取归一值、DELETE 取**行上的原值**：库里是修复前落下的 " 9101 "，入参 "9101" 必须
///    判成同一人**并真删掉它**，且喂给仓储的实参是那一行的原值（喂归一值＝判成同一人却一条
///    没删的假成功）。反面形状由变异对照 2 实测：退化实现 ⇒ 本格当场红。
async test "i115-O 未 trim 历史行被归一命中并按行上原值删除" {
  let (facade, spy, base, iid) = i115f_spy_setup(linear_flow_json())
  let tid = doing_task_for(base, iid, "leader").task_id
  spy.seed_dirty(tid, " 9101 ")
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["9101"]), "flow.admin")), "成功")
  assert_true(spy.spy_real(tid) == ["leader"])
  assert_true(spy.dirty_remaining(tid) == [])
  let calls = spy.remove_calls_snapshot()
  assert_eq(calls.length(), 1)
  assert_true(calls[calls.length() - 1] == [" 9101 "])
}

///|
/// P 「至少剩一人」的下限按**能办单的人数**算：只剩 actor_id=''／纯空白脏行时，摘走最后一个
///    真人必须报错——脏行谁也办不了，拿它撑住下限等于让"摘空"伪装成成功
async test "i115-P 脏行撑不起「至少留一人」的下限" {
  let (facade, spy, base, iid) = i115f_spy_setup(linear_flow_json())
  let tid = doing_task_for(base, iid, "leader").task_id
  spy.seed_dirty(tid, "")
  spy.seed_dirty(tid, "   ")
  let env = i115f_remove(facade, tid, i115f_arr(["leader"]), "flow.admin")
  assert_eq(msg_of(env), "至少需保留一名参与人")
  assert_true(spy.spy_real(tid) == ["leader"])
  assert_true(spy.dirty_remaining(tid) == ["", "   "])
  assert_true(spy.remove_calls_snapshot().is_empty())
}

///|
/// Q 报错档 ⇒ 仓储的删除腿一次都没被调用（比"读数没变"更硬的零副作用判据；摘人报错却删了一半
///    比报错更糟）
async test "i115-Q 五个报错档零删除调用（spy 取证）" {
  let (facade, spy, base, iid) = i115f_spy_setup(linear_flow_json())
  let tid = doing_task_for(base, iid, "leader").task_id
  spy.seed_dirty(tid, "")
  let before = spy.spy_real(tid)
  let cases : Array[(Json, String)] = [
    (
      i115f_call(facade, [("processTaskId", i115f_s(tid.to_string())), ("actorIds", i115f_arr(["leader"]))]),
      "operator 必填",
    ),
    (
      i115f_call(facade, [("actorIds", i115f_arr(["leader"])), ("operator", i115f_s("flow.admin"))]),
      "processTaskId/actorIds 缺失",
    ),
    (i115f_remove(facade, tid, i115f_arr(["  "]), "flow.admin"), "processTaskId/actorIds 缺失"),
    (i115f_remove(facade, tid, i115f_arr(["leader"]), "outsider"), "无权限摘除该任务参与人"),
    (i115f_remove(facade, 424242L, i115f_arr(["leader"]), "flow.admin"), "任务不存在"),
  ]
  for c in cases {
    let (env, want) = c
    assert_eq(msg_of(env), want)
    assert_eq(code_of(env), 99999999L)
  }
  assert_true(spy.remove_calls_snapshot().is_empty())
  assert_true(spy.spy_real(tid) == before)
  assert_true(spy.dirty_remaining(tid) == [""])
}

// ══════════════ 兄弟 action 回归（三条混用不得发生） ══════════════

///|
/// S surrogate 仍只加、本 action 只摘不加、transfer 仍换人＋submitType=7 留痕
async test "i115-S 兄弟 action 各自语义不破（只加 / 只摘 / 换人留痕）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/surrogate",
        targs([("processTaskId", tid.to_string()), ("actorIds", "9101")]),
      ),
    ),
    "成功",
  )
  assert_true(repo.find_task_actors(tid) == ["leader", "9101"])
  assert_eq(msg_of(i115f_remove(facade, tid, i115f_arr(["9101"]), "flow.admin")), "成功")
  assert_true(repo.find_task_actors(tid) == ["leader"])
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/transfer",
        targs([
          ("processTaskId", tid.to_string()),
          ("operator", "leader"),
          ("fromActor", "leader"),
          ("toActor", "lisi"),
        ]),
      ),
    ),
    "成功",
  )
  assert_true(repo.find_task_actors(tid) == ["lisi"])
  let back = repo.find_task_by_id(tid).unwrap()
  assert_eq(var_field(back, "submitType"), "7")
  assert_eq(var_field(back, "tf_transferTo"), "lisi")
}
