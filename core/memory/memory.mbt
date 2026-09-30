// 内存仓储（T0）—— 移植自 rust memory.rs
// ProcessRepository + ProcessExtRepository 双实现；MoonBit 单线程事件循环无锁（方案 §3.4.2）。
// 方法签名 async 内部零 await。行收集按 id 升序排序（rust 为 HashMap 无序；排序使契约测试确定化，
// 不改变单元素断言语义，属测试确定性增强，见 docs/m1-progress.md）。

///|
/// operator 过滤：todo 按 actor_ids；done/instance 按 actor_id/create_user（rust 同款宽匹配由各方法自定）
fn query_match(q : @model.PageQuery, actor_ids : Array[String]) -> Bool {
  match q.operator() {
    Some(op) => actor_ids.contains(op)
    None => true
  }
}

///|
/// 已办 operator 过滤：t.operator = 我（对齐 java doneList query.add("t.operator","EQ",userId)）。
/// moon memory 语义 = 任务办理人 actor_id（finish(operator) 写入），非发起人 create_user。
/// issues/117 §3.2：operator 缺失/空串 → **不匹配任何行**（原 `None => true` 等于"没传就给我
/// 全库已办"，是旁路型缺口）；SQL 仓同口径见 repository_page.mbt 的空 operator 短路。
fn done_operator_match(q : @model.PageQuery, t : @model.ProcessTask) -> Bool {
  match q.operator() {
    Some(op) => {
      let want = op.trim(chars=" \t\r\n").to_owned()
      if want.is_empty() {
        false
      } else {
        match t.actor_id {
          Some(a) => a == want
          None => false
        }
      }
    }
    None => false
  }
}

///|
/// 实例/抄送行 operator 过滤（String 列版）：传 operator 时列值须相等，不传全量。
/// java 口径：instancePage `t.operator EQ`（实例 operator 即发起人，memory `i.operator`
/// 与 java t.operator 列同源）、ccList `cc.actor_id EQ`（spec 06-facade §2.5，issues/108）。
fn operator_eq(q : @model.PageQuery, col : String) -> Bool {
  match q.operator() {
    Some(op) => col == op
    None => true
  }
}

///|
fn flow_data_json_string(fd : @json.FlowData) -> String? {
  Some(fd.to_object_json().stringify())
}

///|
pub(all) struct MemoryRepository {
  mut id_counter : Int64
  defines : Map[Int64, @model.ProcessDefine]
  instances : Map[Int64, @model.ProcessInstance]
  tasks : Map[Int64, @model.ProcessTask]
  task_actors : Map[Int64, Array[String]]
  cc_instances : Array[@model.CcInstance]
  designs : Map[Int64, @model.ProcessDesign]
  design_his : Array[@model.ProcessDesignHis]
  surrogates : Map[Int64, @model.ProcessSurrogate]
}

///|
pub fn MemoryRepository::new() -> MemoryRepository {
  {
    id_counter: 100000L,
    defines: Map([]),
    instances: Map([]),
    tasks: Map([]),
    task_actors: Map([]),
    cc_instances: [],
    designs: Map([]),
    design_his: [],
    surrogates: Map([]),
  }
}

///|
fn MemoryRepository::next_id(self : MemoryRepository) -> Int64 {
  let v = self.id_counter
  self.id_counter = v + 1L
  v
}

///|
fn[V] sorted_ids(map : Map[Int64, V]) -> Array[Int64] {
  let ids : Array[Int64] = []
  for k, _ in map {
    ids.push(k)
  }
  @model.sort_i64(ids)
  ids
}

///|
pub fn MemoryRepository::put_define_direct(self : MemoryRepository, d : @model.ProcessDefine) -> Unit {
  self.defines[d.id] = d
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn find_define_by_id(self, define_id) {
  match self.defines.get(define_id) {
    Some(d) => Some(d.clone())
    None => None
  }
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn save_define(self, define_info) {
  if define_info.id == 0L {
    define_info.id = self.next_id()
  }
  self.defines[define_info.id] = define_info.clone()
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn update_define(self, define_info) {
  self.defines[define_info.id] = define_info.clone()
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn update_define_state(self, define_id, state) {
  match self.defines.get(define_id) {
    Some(d) => d.state = state
    None => ()
  }
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn remove_define(self, define_id) {
  self.defines.remove(define_id)
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn find_instance_by_id(self, instance_id) {
  // 任务落在独立 map；聚合内 tasks 可能仍是 task_id=0 的草稿——读侧用仓储真相回填
  match self.instances.get(instance_id) {
    Some(i) => {
      let inst = i.clone()
      let ts : Array[@model.ProcessTask] = []
      for tid in sorted_ids(self.tasks) {
        let t = self.tasks[tid]
        if t.process_instance_id == instance_id {
          ts.push(t.clone())
        }
      }
      inst.tasks = ts
      Some(inst)
    }
    None => None
  }
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn save_instance(self, instance) {
  if instance.instance_id == 0L {
    instance.instance_id = self.next_id()
  }
  self.instances[instance.instance_id] = instance.clone()
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn update_instance(self, instance) {
  self.instances[instance.instance_id] = instance.clone()
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn find_task_by_id(self, task_id) {
  match self.tasks.get(task_id) {
    Some(t) => Some(t.clone())
    None => None
  }
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn save_task(self, task) {
  if task.task_id == 0L {
    task.task_id = self.next_id()
  }
  self.tasks[task.task_id] = task.clone()
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn update_task(self, task) {
  self.tasks[task.task_id] = task.clone()
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn find_doing_tasks(self, instance_id, task_names) {
  let out : Array[@model.ProcessTask] = []
  for tid in sorted_ids(self.tasks) {
    let t = self.tasks[tid]
    if t.process_instance_id == instance_id && t.task_state == @model.TaskState::Doing.code() && (task_names.is_empty() || task_names.contains(t.task_name)) {
      out.push(t.clone())
    }
  }
  out
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn find_done_tasks(self, instance_id, task_names) {
  let out : Array[@model.ProcessTask] = []
  for tid in sorted_ids(self.tasks) {
    let t = self.tasks[tid]
    if t.process_instance_id == instance_id && t.task_state == @model.TaskState::Finished.code() && (task_names.is_empty() || task_names.contains(t.task_name)) {
      out.push(t.clone())
    }
  }
  out
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn find_history_tasks(self, instance_id) {
  let out : Array[@model.ProcessTask] = []
  for tid in sorted_ids(self.tasks) {
    let t = self.tasks[tid]
    if t.process_instance_id == instance_id {
      out.push(t.clone())
    }
  }
  out
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn find_task_actors(self, task_id) {
  match self.task_actors.get(task_id) {
    Some(actors) => actors.copy()
    None => []
  }
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn add_task_actor(self, task_id, new_actors) {
  // issues/142 B 批（spec 06-facade §2.11「两仓 addTaskActor 写侧兜底」，owner 拍「八栈一起收：
  // 两形同判据＋写侧兜底＋trim＋哨兵」）：判据复用 @model.normalize_actors 那一枚单点（逐元素
  // trim、空串/纯空白丢弃、同一次调用折叠），落库与判重读的都是 trim 后的值 —— 与 MySQL 仓
  // 同一把尺子，"同一栈两个仓储两个答案"由构造堵死（issues/117 场景 27）。
  // 改前本仓只 `!entry.contains(a)` 判重**不判空** ⇒ 绕过门面/引擎直连仓储的调用方照样能把
  // ""／纯空白灌进归属列 actor_id，那正是 issues/129 那族"空归属值读全库"的进水口。
  // 反向哨兵："0" 与 "00" 是两个人，都得落（判空是 trim()==""，不是 falsy）。
  let entry = match self.task_actors.get(task_id) {
    Some(v) => v
    None => {
      let v : Array[String] = []
      self.task_actors[task_id] = v
      v
    }
  }
  for a in @model.normalize_actors(new_actors) {
    if !entry.contains(a) {
      entry.push(a)
    }
  }
}

///|
/// issues/142 §9.2 第二批（spec 06 §2.11 删除位与写侧同一条尺子）：删除列表先过
/// `@model.normalize_actors`——不 trim 则「 8601 」删不掉库里 trim 后的 8601（静默 no-op 报成功）；
/// 归一后为空 ⇒ 什么都不删（早退），空串入参在历史 actor_id='' 脏行上会批量误删
/// （issues/129 的删除位对偶）。与 MySQL 仓同一条判据、同一个答案。
pub impl @spi.ProcessRepository for MemoryRepository with fn remove_task_actor(self, task_id, remove_actors) {
  let remove = @model.normalize_actors(remove_actors)
  if remove.is_empty() {
    return
  }
  match self.task_actors.get(task_id) {
    Some(entry) => {
      let kept : Array[String] = []
      for a in entry {
        if !remove.contains(a) {
          kept.push(a)
        }
      }
      self.task_actors[task_id] = kept
    }
    None => ()
  }
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn create_cc_instance(self, instance_id, creator, actor_ids) {
  // issues/141 G2 写侧判重＝幂等空操作（spec 06 §4），与 MySQL 仓同一条判据（共用 @model.cc_fresh_subset）：
  // 同一 (实例, 被抄送人) 已有 cc 行 ⇒ 跳过——①不新增行 ②不重置未读 state ③不更新原行时间，
  // 重复抄送同一个人**不是**"再提醒一次"（owner 2026-09-29 明确「不需要重置」）。判重在写侧，
  // 查询侧不去重、历史重复行不清理。
  let existing = self.find_cc_actors(instance_id)
  // issues/141 G10（spec 06 §2.10「空抄送人不建 cc 行」）第二层兜底：绕过引擎漏斗/门面**直连仓储**的
  // 调用方同样建不出空值行 —— 空串/纯空白先由 @model.normalize_cc_actors 丢弃，落库值取 trim 后的串
  // （" 123 " 与 "123" 判为同一人，与下一行的写侧判重同一条尺子）。判据单点在 @model，此处不各抄一份。
  for actor_id in @model.cc_fresh_subset(existing, @model.normalize_cc_actors(actor_ids)) {
    self.cc_instances.push({
      id: self.next_id(),
      process_instance_id: instance_id,
      actor_id,
      state: 0,
      create_time: None,
      create_user: Some(creator),
      update_time: None,
      update_user: None,
    })
  }
}

///|
/// issues/141 G2：某实例已有 cc 行的 actor id（写侧判重的读侧）。重复行照原样返回（不去重），
/// 与 MySQL 仓 `find_cc_actors` 的 `SELECT actor_id FROM wf_process_cc_instance WHERE ...` 同形状。
pub impl @spi.ProcessRepository for MemoryRepository with fn find_cc_actors(self, instance_id) {
  let out : Array[String] = []
  for cc in self.cc_instances {
    if cc.process_instance_id == instance_id {
      out.push(cc.actor_id)
    }
  }
  out
}

///|
/// issues/141 G2（spec 06 §4 · spec §11.2 原则 1）：幂等建 cc 行，返回**实际新建**的子集
/// （顺序与入参一致，同一次调用内的重复也折叠）。子集为空 ⇒ 调用方不得 fire CC_CREATE（码 4）。
/// 建行本身仍走 `create_cc_instance`（那一层也判重，两层同判据 ⇒ 直连旧方法的调用方也不会重复建行）。
pub impl @spi.ProcessRepository for MemoryRepository with fn create_cc_instance_if_absent(self, instance_id, creator, actor_ids) {
  // issues/141 G10：返回的子集也必须先归一 —— 三条入口拿这个子集去 fire CC_CREATE（码 4），
  // 子集里留一个空值就等于给空抄送人发了一次知会。
  let fresh =
    @model.cc_fresh_subset(self.find_cc_actors(instance_id), @model.normalize_cc_actors(actor_ids))
  if !fresh.is_empty() {
    self.create_cc_instance(instance_id, creator, fresh)
  }
  fresh
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn update_cc_status(self, instance_id, actor_id) {
  for cc in self.cc_instances {
    if cc.process_instance_id == instance_id && cc.actor_id == actor_id {
      cc.state = 1
    }
  }
}

///|
fn[T] page_slice(rows : Array[T], page_num : Int64, page_size : Int64) -> Array[T] {
  let start = ((page_num - 1L) * page_size).to_int()
  if start < 0 || start >= rows.length() {
    return []
  }
  let end = if start + page_size.to_int() < rows.length() {
    start + page_size.to_int()
  } else {
    rows.length()
  }
  let out : Array[T] = []
  for i in start..<end {
    out.push(rows[i])
  }
  out
}

///|
fn task_row_of(
  t : @model.ProcessTask,
  inst : @model.ProcessInstance?,
  define_info : @model.ProcessDefine?
) -> @model.TaskRow {
  let row = @model.TaskRow::new_empty()
  row.id = t.task_id
  row.process_instance_id = t.process_instance_id
  row.task_name = t.task_name
  row.display_name = t.display_name
  row.task_type = t.task_type
  row.perform_type = t.perform_type
  row.task_state = t.task_state
  row.operator = t.actor_id
  row.actor_id = t.actor_ids.get(0)
  row.finish_time = t.finish_time
  row.expire_time = t.expire_time
  row.form_key = t.form_key
  row.task_parent_id = t.parent_task_id
  row.variable = flow_data_json_string(t.variables)
  row.create_time = t.create_time
  row.create_user = t.create_user
  row.update_time = t.update_time
  row.update_user = t.update_user
  match inst {
    Some(i) => {
      row.process_define_id = Some(i.define_id)
      row.instance_state = Some(i.state)
      row.instance_operator = Some(i.operator)
      row.business_no = i.business_no
      row.instance_variable = flow_data_json_string(i.variables)
      row.instance_create_time = i.create_time
    }
    None => ()
  }
  match define_info {
    Some(d) => {
      row.define_name = Some(d.name)
      row.define_display_name = Some(d.display_name)
      row.define_version = Some(d.version)
    }
    None => ()
  }
  row
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn page_todo_tasks(self, query) {
  let rows : Array[@model.TaskRow] = []
  for tid in sorted_ids(self.tasks) {
    let t = self.tasks[tid]
    if t.task_state == @model.TaskState::Doing.code() && query_match(query, t.actor_ids) {
      let inst = self.instances.get(t.process_instance_id)
      let define_info = match inst {
        Some(i) => self.defines.get(i.define_id)
        None => None
      }
      rows.push(task_row_of(t, inst, define_info))
    }
  }
  let total = rows.length().to_int64()
  @model.PageResult::new(query.page_num(), query.page_size(), total, page_slice(rows, query.page_num(), query.page_size()))
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn page_done_tasks(self, query) {
  // issues/117（owner 拍板，与 SQL 仓 repository_page.mbt 的 page_done_tasks 逐条同判据）：
  // ① 状态集合 `task_state <> 10`（我经手过且不再是我待办：20 办结 / 30 撤回 / 40 终止 /
  //    99 废弃全含），原 `== 20` 会让撤回单从待办、已办两头消失；
  // ② operator 为空 ⇒ 空页，不得退化成"无过滤 = 全库已办"。
  let rows : Array[@model.TaskRow] = []
  let operator = match query.operator() {
    Some(op) => op.trim(chars=" \t\r\n").to_owned()
    None => ""
  }
  if operator.is_empty() {
    return @model.PageResult::new(query.page_num(), query.page_size(), 0L, [])
  }
  for tid in sorted_ids(self.tasks) {
    let t = self.tasks[tid]
    if t.task_state != @model.TaskState::Doing.code() && done_operator_match(query, t) {
      let inst = self.instances.get(t.process_instance_id)
      let define_info = match inst {
        Some(i) => self.defines.get(i.define_id)
        None => None
      }
      rows.push(task_row_of(t, inst, define_info))
    }
  }
  let total = rows.length().to_int64()
  @model.PageResult::new(query.page_num(), query.page_size(), total, page_slice(rows, query.page_num(), query.page_size()))
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn page_instances(self, query) {
  let rows : Array[@model.InstanceRow] = []
  for iid in sorted_ids(self.instances) {
    let i = self.instances[iid]
    if operator_eq(query, i.operator) {
      rows.push(instance_row_of(i, self.defines.get(i.define_id)))
    }
  }
  let total = rows.length().to_int64()
  @model.PageResult::new(query.page_num(), query.page_size(), total, page_slice(rows, query.page_num(), query.page_size()))
}

///|
fn instance_row_of(
  i : @model.ProcessInstance,
  define_info : @model.ProcessDefine?
) -> @model.InstanceRow {
  let row = @model.InstanceRow::new_empty()
  row.id = i.instance_id
  row.parent_id = i.parent_id
  row.process_define_id = i.define_id
  row.state = i.state
  row.parent_node_name = i.parent_node_name
  row.business_no = i.business_no
  row.operator = i.operator
  row.expire_time = i.expire_time
  row.variable = flow_data_json_string(i.variables)
  row.create_time = i.create_time
  row.create_user = i.create_user
  row.update_time = i.update_time
  row.update_user = i.update_user
  match define_info {
    Some(d) => {
      row.define_name = Some(d.name)
      row.define_display_name = Some(d.display_name)
      row.define_version = Some(d.version)
    }
    None => ()
  }
  row
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn page_cc_instances(self, query) {
  // issues/141 G1 归属条件必填（spec 06-facade §2.5）：归属列 cc.actor_id（本栈取值通道＝PageQuery.operator）
  // 缺键 / 空串 / 全空白 ⇒ **空页**，不得退化成"这条不加"= 返回全部有 cc 行的实例。判据与 MySQL 仓
  // 共用 @model.cc_ownership_operator 这一份 ⇒ 同一栈两个仓储同答案（issues/117 场景 27 那把尺子延长到 ccList）。
  if @model.cc_ownership_operator(query) is None {
    return @model.PageResult::new(query.page_num(), query.page_size(), 0L, [])
  }
  let rows : Array[@model.InstanceRow] = []
  for cc in self.cc_instances {
    // ccList「我的」：只留抄给我的行（cc.actor_id = operator），total 为过滤后计数
    if !operator_eq(query, cc.actor_id) {
      continue
    }
    // issues/138 行形状三要件（spec 06-facade.md §processInstance/ccList，基准＝boot2 内置版）：
    // ccList 的行**来自实例表**，cc 行只当过滤（上一句谓词按 spec 06 §2.5 钉的 `cc.actor_id`，本轮不动）。
    // 与 pageInstances 共用 instance_row_of ⇒「rows 同 processInstance/page 行结构」由构造保证 ——
    // 对齐 Java JdbcProcessRepository.pageInstances(query, cc=true)（行源 `FROM wf_process_instance t`
    // + `SELECT t.*`，cc 表退成 LEFT JOIN 过滤）与 PHP PDO 侧 pageCcInstances 共用 instanceRow()。
    // 旧写法逐列投 cc（id=cc.id、operator=cc.actor_id、parent_id/expire_time/variable 置空、
    // state 取 cc.state）正是条文点名的错法 ①＋③：operator＝被抄送人＝查询者本人，
    // 「operator 非空」这类判据在他自己的查询里恒真、永远照不出来；主键值也不是实例 id。
    match self.instances.get(cc.process_instance_id) {
      Some(i) => rows.push(instance_row_of(i, self.defines.get(i.define_id)))
      None => {
        // 悬挂 cc 行（实例已不在）：行源仍算实例侧 ⇒ 主键给**实例 id**（要件 1）；
        // 发起人无从可取 ⇒ 留空串，**不回落到 cc.actor_id**（要件 3：operator 不得是查询者本人）。
        // 本轮只改投影，计数口径维持已发布语义（该 cc 行照旧出行，不收「实例不在就不出行」那一档）。
        let row = @model.InstanceRow::new_empty()
        row.id = cc.process_instance_id
        row.state = cc.state
        row.operator = ""
        row.create_time = cc.create_time
        row.create_user = cc.create_user
        row.update_time = cc.update_time
        row.update_user = cc.update_user
        rows.push(row)
      }
    }
  }
  let total = rows.length().to_int64()
  @model.PageResult::new(query.page_num(), query.page_size(), total, page_slice(rows, query.page_num(), query.page_size()))
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn page_defines(self, query) {
  let rows : Array[@model.DefineRow] = []
  for did in sorted_ids(self.defines) {
    let d = self.defines[did]
    let row = @model.DefineRow::new_empty()
    row.id = d.id
    row.name = d.name
    row.display_name = d.display_name
    row.define_type = d.define_type
    row.state = d.state
    row.version = d.version
    row.create_time = d.create_time
    row.create_user = d.create_user
    row.update_time = d.update_time
    row.update_user = d.update_user
    rows.push(row)
  }
  let total = rows.length().to_int64()
  @model.PageResult::new(query.page_num(), query.page_size(), total, page_slice(rows, query.page_num(), query.page_size()))
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn count_todo_tasks(self, user_id) {
  let mut count = 0
  for _, t in self.tasks {
    if t.task_state == @model.TaskState::Doing.code() && t.actor_ids.contains(user_id) {
      count = count + 1
    }
  }
  count.to_int64()
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn get_all_instances(self) {
  let out : Array[@model.ProcessInstance] = []
  for iid in sorted_ids(self.instances) {
    out.push(self.instances[iid].clone())
  }
  out
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn get_all_tasks(self) {
  let out : Array[@model.ProcessTask] = []
  for tid in sorted_ids(self.tasks) {
    let task = self.tasks[tid].clone()
    if task.actor_ids.is_empty() {
      match self.task_actors.get(tid) {
        Some(actors) => task.actor_ids = actors.copy()
        None => ()
      }
    }
    out.push(task)
  }
  out
}


// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。
pub extend MemoryRepository with @spi.ProcessRepository::{add_task_actor, count_todo_tasks, create_cc_instance, create_cc_instance_if_absent, find_cc_actors, find_define_by_id, find_doing_tasks, find_done_tasks, find_history_tasks, find_instance_by_id, find_task_actors, find_task_by_id, get_all_instances, get_all_tasks, page_cc_instances, page_defines, page_done_tasks, page_instances, page_todo_tasks, remove_define, remove_task_actor, save_define, save_instance, save_task, update_cc_status, update_define, update_define_state, update_instance, update_task}
