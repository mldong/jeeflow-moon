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
    defines: Map::new(),
    instances: Map::new(),
    tasks: Map::new(),
    task_actors: Map::new(),
    cc_instances: [],
    designs: Map::new(),
    design_his: [],
    surrogates: Map::new(),
  }
}

///|
fn MemoryRepository::next_id(self : MemoryRepository) -> Int64 {
  let v = self.id_counter
  self.id_counter = v + 1L
  v
}

///|
fn sorted_ids[V](map : Map[Int64, V]) -> Array[Int64] {
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
pub impl @spi.ProcessRepository for MemoryRepository with fn save_define(self, define) {
  if define.id == 0L {
    define.id = self.next_id()
  }
  self.defines[define.id] = define.clone()
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn update_define(self, define) {
  self.defines[define.id] = define.clone()
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
  let entry = match self.task_actors.get(task_id) {
    Some(v) => v
    None => {
      let v : Array[String] = []
      self.task_actors[task_id] = v
      v
    }
  }
  for a in new_actors {
    if !entry.contains(a) {
      entry.push(a)
    }
  }
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn remove_task_actor(self, task_id, remove_actors) {
  match self.task_actors.get(task_id) {
    Some(entry) => {
      let kept : Array[String] = []
      for a in entry {
        if !remove_actors.contains(a) {
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
  for actor_id in actor_ids {
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
pub impl @spi.ProcessRepository for MemoryRepository with fn update_cc_status(self, instance_id, actor_id) {
  for cc in self.cc_instances {
    if cc.process_instance_id == instance_id && cc.actor_id == actor_id {
      cc.state = 1
    }
  }
}

///|
fn page_slice[T](rows : Array[T], page_num : Int64, page_size : Int64) -> Array[T] {
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
  define : @model.ProcessDefine?
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
  match define {
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
      let define = match inst {
        Some(i) => self.defines.get(i.define_id)
        None => None
      }
      rows.push(task_row_of(t, inst, define))
    }
  }
  let total = rows.length().to_int64()
  @model.PageResult::new(query.page_num(), query.page_size(), total, page_slice(rows, query.page_num(), query.page_size()))
}

///|
pub impl @spi.ProcessRepository for MemoryRepository with fn page_done_tasks(self, query) {
  let rows : Array[@model.TaskRow] = []
  for tid in sorted_ids(self.tasks) {
    let t = self.tasks[tid]
    if t.task_state == @model.TaskState::Finished.code() {
      rows.push(task_row_of(t, self.instances.get(t.process_instance_id), None))
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
    rows.push(instance_row_of(i, self.defines.get(i.define_id)))
  }
  let total = rows.length().to_int64()
  @model.PageResult::new(query.page_num(), query.page_size(), total, page_slice(rows, query.page_num(), query.page_size()))
}

///|
fn instance_row_of(
  i : @model.ProcessInstance,
  define : @model.ProcessDefine?
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
  match define {
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
  let rows : Array[@model.InstanceRow] = []
  for cc in self.cc_instances {
    let inst = self.instances.get(cc.process_instance_id)
    let define = match inst {
      Some(i) => self.defines.get(i.define_id)
      None => None
    }
    let row = @model.InstanceRow::new_empty()
    row.id = cc.id
    row.parent_id = None
    row.process_define_id = match inst {
      Some(i) => i.define_id
      None => 0L
    }
    row.state = cc.state
    row.parent_node_name = None
    row.business_no = match inst {
      Some(i) => i.business_no
      None => None
    }
    row.operator = cc.actor_id
    row.expire_time = None
    row.variable = None
    row.create_time = cc.create_time
    row.create_user = cc.create_user
    row.update_time = cc.update_time
    row.update_user = cc.update_user
    match define {
      Some(d) => {
        row.define_name = Some(d.name)
        row.define_display_name = Some(d.display_name)
        row.define_version = Some(d.version)
      }
      None => ()
    }
    rows.push(row)
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
