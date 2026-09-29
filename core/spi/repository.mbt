// SPI —— 移植自 rust spi.rs + context.rs（方案 §2.3 全异步 / §3.2 闭包字段 / §3.4.3 泛型约束）
// 大 SPI（两仓储）= trait 泛型参数；小 SPI = 闭包字段/闭包组。
// ITransactionTemplate 口径（D-M1-1）：Unit 形态——回调内写外部可变单元带回结果。

///|
/// IProcessRepository（spec/05，26 方法，全 async）
///
/// 抄送两条义务（issues/141 · spec 06-facade §2.5 / §4）——两仓储（内存 / MySQL）必须同判据同答案：
/// · **G1 分页归属必填**：`page_cc_instances` 的归属列 `cc.actor_id`（本栈取值通道＝`PageQuery.operator`）
///   无有效条件（缺键 / 空串 / 全空白）时返回**空页**，严禁退化成"这条不加"而放出全部实例；
///   判据单点在 `@model.cc_ownership_operator`。非归属列的空值放行维持既有通用放行。
/// · **G2 写侧判重＝幂等空操作**：同一 `(instance_id, actor_id)` 已有 cc 行时跳过——不新增行、
///   不重置未读 state、不更新原行时间，并且**不 fire CC_CREATE（码 4）**；建 cc 的三条入口一律改调
///   `create_cc_instance_if_absent` 并拿它返回的**实际新建子集**去 fire，子集为空整支不发。
///   查询侧不引入去重、历史重复行不清理（owner 2026-09-29 拍）。
/// · **G10 空抄送人不建 cc 行**（spec 06-facade §2.10，owner 2026-09-29 拍「空不创建行」；基准＝java
///   `5fbd5ac`）：`create_cc_instance` 与 `create_cc_instance_if_absent` 的入参里**空串、纯空白一律丢弃**，
///   落库与比较值取 **trim 后的串**（`" 123 "` 与 `"123"` 是同一个人 ⇒ 与上面的 G2 判重咬合，
///   不 trim 就会让同一人落两行）；判据单点在 `@model.normalize_cc_actors`。
///   ⚠️ **写侧这一层必须实现方自己挡**：引擎漏斗（`parse_cc_actors`）与门面手动腿都归一，但绕过它们
///   直连仓储的调用方（集成层、第三方仓储消费者）照样能把空归属值灌进 `actor_id` —— 那正是 issues/129
///   那族"空 operator 读全库"的病根。丢完为空 ⇒ 一行不建、也不 fire CC_CREATE（码 4）。
///   反向哨兵：`"0"` 这类"看起来像空"的正常 id 是有效值，**不得**被当空值丢掉。
pub(open) trait ProcessRepository {
  async fn find_define_by_id(Self, Int64) -> @model.ProcessDefine? raise @error.JeeflowError
  async fn save_define(Self, @model.ProcessDefine) -> Unit raise @error.JeeflowError
  async fn update_define(Self, @model.ProcessDefine) -> Unit raise @error.JeeflowError
  async fn update_define_state(Self, Int64, Int) -> Unit raise @error.JeeflowError
  async fn remove_define(Self, Int64) -> Unit raise @error.JeeflowError
  async fn find_instance_by_id(Self, Int64) -> @model.ProcessInstance? raise @error.JeeflowError
  async fn save_instance(Self, @model.ProcessInstance) -> Unit raise @error.JeeflowError
  async fn update_instance(Self, @model.ProcessInstance) -> Unit raise @error.JeeflowError
  async fn find_task_by_id(Self, Int64) -> @model.ProcessTask? raise @error.JeeflowError
  async fn save_task(Self, @model.ProcessTask) -> Unit raise @error.JeeflowError
  async fn update_task(Self, @model.ProcessTask) -> Unit raise @error.JeeflowError
  async fn find_doing_tasks(Self, Int64, Array[String]) -> Array[@model.ProcessTask] raise @error.JeeflowError
  async fn find_done_tasks(Self, Int64, Array[String]) -> Array[@model.ProcessTask] raise @error.JeeflowError
  async fn find_history_tasks(Self, Int64) -> Array[@model.ProcessTask] raise @error.JeeflowError
  async fn find_task_actors(Self, Int64) -> Array[String] raise @error.JeeflowError
  async fn add_task_actor(Self, Int64, Array[String]) -> Unit raise @error.JeeflowError
  async fn remove_task_actor(Self, Int64, Array[String]) -> Unit raise @error.JeeflowError
  async fn create_cc_instance(Self, Int64, String, Array[String]) -> Unit raise @error.JeeflowError
  // issues/141 G2：写侧判重的读侧（某实例已有 cc 行的 actor id）与幂等建行的入口（返回实际新建子集）。
  // java 侧这两件是 IProcessRepository 的 default 方法（不覆写＝维持旧行为）；MoonBit trait 无默认实现，
  // 故进 trait 本体＝SPI 破坏性新增，自带两仓都必须覆写，第三方仓储照此实现即可（0.x 线允许）。
  async fn find_cc_actors(Self, Int64) -> Array[String] raise @error.JeeflowError
  async fn create_cc_instance_if_absent(Self, Int64, String, Array[String]) -> Array[String] raise @error.JeeflowError
  async fn update_cc_status(Self, Int64, String) -> Unit raise @error.JeeflowError
  async fn page_todo_tasks(Self, @model.PageQuery) -> @model.PageResult[@model.TaskRow] raise @error.JeeflowError
  async fn page_done_tasks(Self, @model.PageQuery) -> @model.PageResult[@model.TaskRow] raise @error.JeeflowError
  async fn page_instances(Self, @model.PageQuery) -> @model.PageResult[@model.InstanceRow] raise @error.JeeflowError
  // issues/141 G1 归属条件必填（spec 06-facade §2.5）：cc.actor_id 无有效条件 ⇒ 空页，
  // 不得退化成"这条不加"放出全部实例；两仓储同判据（@model.cc_ownership_operator）。
  async fn page_cc_instances(Self, @model.PageQuery) -> @model.PageResult[@model.InstanceRow] raise @error.JeeflowError
  async fn page_defines(Self, @model.PageQuery) -> @model.PageResult[@model.DefineRow] raise @error.JeeflowError
  async fn count_todo_tasks(Self, String) -> Int64 raise @error.JeeflowError
  async fn get_all_instances(Self) -> Array[@model.ProcessInstance] raise @error.JeeflowError
  async fn get_all_tasks(Self) -> Array[@model.ProcessTask] raise @error.JeeflowError
}

///|
/// IProcessExtRepository（spec/05，14 方法：design/his/surrogate）
pub(open) trait ProcessExtRepository {
  async fn find_design_by_id(Self, Int64) -> @model.ProcessDesign? raise @error.JeeflowError
  async fn save_design(Self, @model.ProcessDesign) -> Unit raise @error.JeeflowError
  async fn update_design(Self, @model.ProcessDesign) -> Unit raise @error.JeeflowError
  async fn remove_design(Self, Int64) -> Unit raise @error.JeeflowError
  async fn page_designs(Self, @model.PageQuery) -> @model.PageResult[@model.ProcessDesign] raise @error.JeeflowError
  async fn save_design_his(Self, @model.ProcessDesignHis) -> Unit raise @error.JeeflowError
  async fn list_design_his(Self, Int64) -> Array[@model.ProcessDesignHis] raise @error.JeeflowError
  async fn find_surrogate_by_id(Self, Int64) -> @model.ProcessSurrogate? raise @error.JeeflowError
  async fn save_surrogate(Self, @model.ProcessSurrogate) -> Unit raise @error.JeeflowError
  async fn update_surrogate(Self, @model.ProcessSurrogate) -> Unit raise @error.JeeflowError
  async fn remove_surrogate(Self, Int64) -> Unit raise @error.JeeflowError
  async fn page_surrogates(Self, @model.PageQuery) -> @model.PageResult[@model.ProcessSurrogate] raise @error.JeeflowError
  async fn get_surrogate(Self, String, String, String) -> @model.ProcessSurrogate? raise @error.JeeflowError
}

///|
/// 引擎不需要扩展仓储时的空实现
pub(all) struct NoExtRepository {}

///|
pub fn NoExtRepository::new() -> NoExtRepository {
  NoExtRepository::{}
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn find_design_by_id(_self, _id) {
  None
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn save_design(_self, _d) {
  ()
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn update_design(_self, _d) {
  ()
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn remove_design(_self, _id) {
  ()
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn page_designs(_self, _q) {
  @model.PageResult::new(1L, 20L, 0L, [])
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn save_design_his(_self, _h) {
  ()
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn list_design_his(_self, _id) {
  []
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn find_surrogate_by_id(_self, _id) {
  None
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn save_surrogate(_self, _s) {
  ()
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn update_surrogate(_self, _s) {
  ()
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn remove_surrogate(_self, _id) {
  ()
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn page_surrogates(_self, _q) {
  @model.PageResult::new(1L, 20L, 0L, [])
}

///|
pub impl ProcessExtRepository for NoExtRepository with fn get_surrogate(_self, _op, _name, _time) {
  None
}


// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。
pub extend NoExtRepository with ProcessExtRepository::{find_design_by_id, find_surrogate_by_id, get_surrogate, list_design_his, page_designs, page_surrogates, remove_design, remove_surrogate, save_design, save_design_his, save_surrogate, update_design, update_surrogate}
