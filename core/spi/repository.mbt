// SPI —— 移植自 rust spi.rs + context.rs（方案 §2.3 全异步 / §3.2 闭包字段 / §3.4.3 泛型约束）
// 大 SPI（两仓储）= trait 泛型参数；小 SPI = 闭包字段/闭包组。
// ITransactionTemplate 口径（D-M1-1）：Unit 形态——回调内写外部可变单元带回结果。

///|
/// IProcessRepository（spec/05，24 方法，全 async）
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
  async fn update_cc_status(Self, Int64, String) -> Unit raise @error.JeeflowError
  async fn page_todo_tasks(Self, @model.PageQuery) -> @model.PageResult[@model.TaskRow] raise @error.JeeflowError
  async fn page_done_tasks(Self, @model.PageQuery) -> @model.PageResult[@model.TaskRow] raise @error.JeeflowError
  async fn page_instances(Self, @model.PageQuery) -> @model.PageResult[@model.InstanceRow] raise @error.JeeflowError
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
