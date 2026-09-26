// issues/116 批次 D：委托代理运行期自动生效的**引擎级**用例（内存仓通道）。
// 覆盖 spec/06 §4.5 条款 1（全部建任务路径）、1.1（processName 口径）、1.2（不级联）、
// 1.3（串行/并行会签）、1.4（多条并存时由「最新一条」裁决 —— 取数顺序见 issues/123 那段）、
// 2⚠️（并入参与者集合本身并落库）、
// 3（默认开启 + 可显式关闭）、4（缺仓储 / 仓储报错都不打断建单）、5①②③④（四判据）。
// 断言一律落**读回值**（仓储 find_task_actors / find_history_tasks），不断内存聚合副本。
// 门面出口级用例见 facade/surrogate_autoapply_test.mbt；SQL 仓真机对拍见
// repository-mysql/smoke（T1-I116）与 demo/cmd/t1_mysql（T1-F116）。

///|
/// 只把 `get_surrogate` 打炸的扩展仓储（条款 4：仓储报错不得打断建单）；
/// 其余方法全部转发给内存仓，保证"只有委托查询坏"这一故障形状。
struct BrokenExtRepository {
  inner : @mem.MemoryRepository
  mut calls : Int64
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn find_design_by_id(self, id) {
  self.inner.find_design_by_id(id)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn save_design(self, d) {
  self.inner.save_design(d)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn update_design(self, d) {
  self.inner.update_design(d)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn remove_design(self, id) {
  self.inner.remove_design(id)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn page_designs(self, q) {
  self.inner.page_designs(q)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn save_design_his(self, h) {
  self.inner.save_design_his(h)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn list_design_his(self, id) {
  self.inner.list_design_his(id)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn find_surrogate_by_id(self, id) {
  self.inner.find_surrogate_by_id(id)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn save_surrogate(self, s) {
  self.inner.save_surrogate(s)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn update_surrogate(self, s) {
  self.inner.update_surrogate(s)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn remove_surrogate(self, id) {
  self.inner.remove_surrogate(id)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn page_surrogates(self, q) {
  self.inner.page_surrogates(q)
}

impl @spi.ProcessExtRepository for BrokenExtRepository with fn get_surrogate(self, _op, _name, _time) {
  self.calls = self.calls + 1L
  raise @error.Business("故障注入：扩展仓储不可用")
}

///|
/// 引擎门面装配：ext 仓储默认就是同一个内存仓（委托台账 + 查询都走它）
fn sg_engine(
  repo : @mem.MemoryRepository,
  auto_apply~ : Bool = true
) -> @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository] {
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, repo).with_id_generator(fn() { gen.next_id() })
  @engine.Engine::make(ctx.with_surrogate_auto_apply(auto_apply))
}

///|
/// 直写台账（引擎级用例不经门面；门面写入口径在 facade 用例与 memory_test 里验）
async fn sg_put(
  repo : @mem.MemoryRepository,
  operator : String,
  agent : String,
  process_name : String,
  start_time~ : String? = None,
  end_time~ : String? = None,
  enabled~ : Int = 1
) -> Int64 raise {
  let sg : @model.ProcessSurrogate = {
    id: 0L,
    process_name,
    operator,
    surrogate: agent,
    start_time,
    end_time,
    enabled,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_surrogate(sg)
  sg.id
}

///|
/// 通用流程图：start → 若干 task 节点 → end（assignees 按序给每个节点的 assignee）
fn sg_flow(name : String, assignees : Array[String]) -> String {
  let nodes = StringBuilder()
  nodes.write_string("{\"id\": \"start\", \"type\": \"snaker:start\", \"text\": {\"value\": \"S\"}}")
  for i in 0..<assignees.length() {
    nodes.write_string(", {\"id\": \"n\{(i + 1)}\", \"type\": \"snaker:task\", \"text\": {\"value\": \"节点\{(i + 1)}\"}, \"properties\": {\"assignee\": \"\{assignees[i]}\", \"taskType\": 0, \"performType\": 0}}")
  }
  nodes.write_string(", {\"id\": \"end\", \"type\": \"snaker:end\", \"text\": {\"value\": \"E\"}}")
  let edges = StringBuilder()
  let total = assignees.length() + 2
  for i in 0..<(total - 1) {
    let src = if i == 0 { "start" } else { "n\{i}" }
    let dst = if i + 1 == total - 1 { "end" } else { "n\{i + 1}" }
    if i > 0 {
      edges.write_string(", ")
    }
    edges.write_string("{\"id\": \"e\{(i + 1)}\", \"sourceNodeId\": \"\{src}\", \"targetNodeId\": \"\{dst}\"}")
  }
  "{\"name\": \"\{name}\", \"displayName\": \"委托流\", \"type\": \"approval\", \"nodes\": [\{nodes.to_string()}], \"edges\": [\{edges.to_string()}]}"
}

///|
async fn sg_define(repo : @mem.MemoryRepository, define_name : String, content : String) -> Int64 raise {
  save_flow_define(repo, define_name, content)
}

///|
/// 按节点名找任务行（find_history_tasks 读的是仓储，不是聚合副本）
async fn sg_task(repo : @mem.MemoryRepository, iid : Int64, node : String) -> @model.ProcessTask raise {
  for t in repo.find_history_tasks(iid) {
    if t.task_name == node {
      return t
    }
  }
  abort("no task node=\{node} in instance \{iid}")
}

///|
fn sg_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("FAIL 断言失败：" + label)
    abort(label)
  }
}

///|
fn sg_has(list : Array[String], want : String, label : String) -> Unit {
  let pipe = "|"
  sg_check(list.contains(want), "\{label}（实际=<\{list.join(pipe)}> 应含 <\{want}>）")
}

///|
fn sg_absent(list : Array[String], unwanted : String, label : String) -> Unit {
  let pipe = "|"
  sg_check(!list.contains(unwanted), "\{label}（实际=<\{list.join(pipe)}> 不应含 <\{unwanted}>）")
}

// ══════════════════ 条款 1：全部建任务路径 ══════════════════

///|
async test "批次D 条款1: 发起路径建的第一批任务即并入代理人，且落在参与者表" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let did = sg_define(repo, "sg-start", sg_flow("sg-start", ["zhang"]))
  let _ = sg_put(repo, "zhang", "li", "sg-start")
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let task = sg_task(repo, inst.instance_id, "n1")
  // 读回值（= 将要落 wf_process_task_actor 的那一份），不是聚合里的临时集合
  let actors = repo.find_task_actors(task.task_id)
  sg_has(actors, "zhang", "授权人保留（委托不是转办）")
  sg_has(actors, "li", "条款2⚠️：代理人须随任务落到参与者表")
  sg_has(task.actor_ids, "li", "任务行 actor_ids 读回值同样含代理人")
}

///|
async test "批次D 条款1: 办理推进 / 跳转两条路径都应用委托" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let did = sg_define(repo, "sg-adv", sg_flow("sg-adv", ["leader", "zhang", "wang"]))
  let _ = sg_put(repo, "zhang", "li", "sg-adv")
  let _ = sg_put(repo, "wang", "li2", "sg-adv")
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let t1 = sg_task(repo, inst.instance_id, "n1")
  let _ = engine.execute_task_async(t1.task_id, "leader", @json.FlowData::new())
  // 推进出的新单（n2 由上一步办结后建出）——只挂发起一处的实现会在这里漏
  let t2 = sg_task(repo, inst.instance_id, "n2")
  sg_has(repo.find_task_actors(t2.task_id), "li", "办理推进路径：新单参与者含代理人")
  // 跳转（jump / rollback / 退回发起人共用同一条落库收口）
  let jumped = engine.execute_and_jump_async(t2.task_id, "zhang", @json.FlowData::new(), Some("n3"))
  match jumped {
    Ok(tasks) => {
      sg_check(!tasks.is_empty(), "跳转应产出目标节点任务")
      sg_has(
        repo.find_task_actors(tasks[0].task_id),
        "li2",
        "跳转路径：目标节点任务参与者含代理人",
      )
    }
    Err(e) => abort("跳转失败: \{e.message()}")
  }
}

///|
async test "批次D 条款1.3: 串行会签每一步都应用，但只进当步任务、不扩投票名册" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let content = $|{"name": "sg-seq", "displayName": "串行会签", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|   {"id": "cs", "type": "snaker:task", "text": {"value": "串行会签"},
  $|    "properties": {"assignee": "zhang,other", "taskType": 0, "performType": "1",
  $|                  "countersignType": "SEQUENTIAL"}},
  $|   {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $| ],
  $| "edges": [
  $|   {"id": "e1", "sourceNodeId": "start", "targetNodeId": "cs"},
  $|   {"id": "e2", "sourceNodeId": "cs", "targetNodeId": "end"}
  $| ]}
$|
  let did = sg_define(repo, "sg-seq", content)
  let _ = sg_put(repo, "zhang", "li", "sg-seq")
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let step1 = sg_task(repo, inst.instance_id, "cs")
  sg_has(repo.find_task_actors(step1.task_id), "li", "第一步任务并入代理人")
  sg_absent(step1.actor_ids, "other", "串行会签第一步仍只有第一人 + 其代理人")
  // 投票名册不得被扩（扩了就是改票数）
  let saved = repo.find_instance_by_id(inst.instance_id).unwrap()
  sg_check(
    saved.variables.get_str_or("csv_cs_operatorList", "<缺失>") == "zhang,other",
    "条款1.3：csv_cs_operatorList 必须仍是原名单（实际=\{saved.variables.get_str_or("csv_cs_operatorList", "<缺失>")})",
  )
  // 第二步（另一人）不沾前一个人的委托
  let _ = engine.execute_task_async(step1.task_id, "zhang", @json.FlowData::new())
  let step2_tasks = repo.find_doing_tasks(inst.instance_id, ["cs"])
  sg_check(step2_tasks.length() == 1, "串行会签推进后当步只剩一步在办")
  sg_absent(
    repo.find_task_actors(step2_tasks[0].task_id),
    "li",
    "后一步任务的参与者不受前一步委托影响",
  )
}

///|
async test "批次D 条款1.3: 并行会签并入代理人但不新增任务行" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let content = $|{"name": "sg-par", "displayName": "并行会签", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|   {"id": "cs", "type": "snaker:task", "text": {"value": "并行会签"},
  $|    "properties": {"assignee": "zhang,other", "taskType": 0, "performType": "1",
  $|                  "countersignType": "PARALLEL"}},
  $|   {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $| ],
  $| "edges": [
  $|   {"id": "e1", "sourceNodeId": "start", "targetNodeId": "cs"},
  $|   {"id": "e2", "sourceNodeId": "cs", "targetNodeId": "end"}
  $| ]}
$|
  let did = sg_define(repo, "sg-par", content)
  let _ = sg_put(repo, "zhang", "li", "sg-par")
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let cs_tasks = repo.find_history_tasks(inst.instance_id).filter(t => t.task_name == "cs")
  sg_check(cs_tasks.length() == 2, "并行会签仍是每人一票=2 行，不得因并入代理人多建行")
  let mine = cs_tasks.filter(t => t.actor_ids.contains("zhang"))
  sg_check(mine.length() == 1, "zhang 那一票唯一")
  sg_has(repo.find_task_actors(mine[0].task_id), "li", "zhang 那一票的参与者含代理人")
  let others = cs_tasks.filter(t => !t.actor_ids.contains("zhang"))
  sg_check(others[0].actor_ids == ["other"], "别的那一票完全不受影响")
}

// ══════════════════ 条款 1.1 / 1.2 / 1.4 ══════════════════

///|
async test "批次D 条款1.1: processName 取流程模型 name，未带时回落 define.name（诱饵行）" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  // 模型 JSON 里 name = "sg-model"，定义行故意写成 decoy-define（两者不一致的诱饵行）
  let did = sg_define(repo, "decoy-define", sg_flow("sg-model", ["zhang"]))
  let _ = sg_put(repo, "zhang", "li_decoy", "decoy-define")
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let t = sg_task(repo, inst.instance_id, "n1")
  sg_absent(repo.find_task_actors(t.task_id), "li_decoy", "配在 define.name 上的委托不得命中")
  // 模型未带 name 时才回落 define.name
  let repo2 = @mem.MemoryRepository::new()
  let engine2 = sg_engine(repo2)
  let nameless = sg_flow("sg-model", ["zhang"]).replace(old="\"name\": \"sg-model\"", new="\"noname\": \"sg-model\"")
  let did2 = sg_define(repo2, "only-define", nameless)
  let _ = sg_put(repo2, "zhang", "li_fallback", "only-define")
  let inst2 = engine2.start_async(did2, "applicant", @json.FlowData::new())
  sg_has(
    repo2.find_task_actors(sg_task(repo2, inst2.instance_id, "n1").task_id),
    "li_fallback",
    "模型未带 name 时须回落 wf_process_define.name",
  )
}

///|
/// 条款 1.1 的「未带 = 先 trim 再判空」**形态①**（独立审计 P0-1 指出本栈原本漏 trim）。
/// 漏 trim 不是显示差异而是**功能分叉**：拿带空白的串去 `wf_process_surrogate.process_name`
/// 做精确匹配必失配，只剩"全流程兜底"行能命中 ⇒ 该流程自己配的委托静默失效。
async test "批次D 条款1.1 补①: 模型名带前后空白须 trim 后再查委托" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  // 台账按**干净名**配置，只有引擎传出 trim 后的值才命中。
  // define.name 故意另起一个名，兼作"取模型还是取定义"的诱饵。
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let padded = sg_flow("sg-model", ["zhang"]).replace(
    old="\"name\": \"sg-model\"", new="\"name\": \"  sg-padded  \"",
  )
  let did = sg_define(repo, "decoy-padded", padded)
  let _ = sg_put(repo, "zhang", "li_padded", "sg-padded")
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  sg_has(
    repo.find_task_actors(sg_task(repo, inst.instance_id, "n1").task_id),
    "li_padded",
    "模型名带前后空白须 trim 后再查委托（台账存的是干净名 sg-padded）",
  )
}

///|
/// 条款 1.1「未带 = trim 后判空」**形态②**：模型名仅空白＝未带。
/// 不 trim 时 `"   "` 既非空串也非哨兵 `"unknown"`，会走"取模型名"分支 → 一条委托都查不到。
/// 与形态①**分成两条 test**：合在一条里前者 panic 会把这条挡掉，失能时看不出是谁红。
async test "批次D 条款1.1 补②: 模型名仅空白须回落 wf_process_define.name" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let blank = sg_flow("sg-model", ["zhang"]).replace(
    old="\"name\": \"sg-model\"", new="\"name\": \"   \"",
  )
  let did = sg_define(repo, "only-blankdef", blank)
  let _ = sg_put(repo, "zhang", "li_blank", "only-blankdef")
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  sg_has(
    repo.find_task_actors(sg_task(repo, inst.instance_id, "n1").task_id),
    "li_blank",
    "模型名仅空白须回落 wf_process_define.name 并命中（否则委托静默失效）",
  )
}

///|
async test "批次D 条款1.2: 不级联——A→B 且 B→C 时 C 不收单" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let did = sg_define(repo, "sg-cascade", sg_flow("sg-cascade", ["zhang"]))
  let _ = sg_put(repo, "zhang", "li", "sg-cascade")
  let _ = sg_put(repo, "li", "wang", "sg-cascade")
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let actors = repo.find_task_actors(sg_task(repo, inst.instance_id, "n1").task_id)
  sg_has(actors, "li", "一级委托生效")
  sg_absent(actors, "wang", "二级不得级联展开（环状委托死循环的防线）")
}

///|
async test "批次D 条款1.4: 多条命中取 id 最大，内存仓不得取遍历首条" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let did = sg_define(repo, "sg-multi", sg_flow("sg-multi", ["zhang"]))
  let old_id = sg_put(repo, "zhang", "li_old", "sg-multi")
  let new_id = sg_put(repo, "zhang", "li_new", "sg-multi")
  sg_check(new_id > old_id, "两条委托 id 递增（用例前提）")
  // 仓储判据本身
  let hit = repo.get_surrogate("zhang", "sg-multi", "2026-09-21 10:00:00")
  match hit {
    Some(s) => {
      sg_check(s.id == new_id, "条款1.4：查询须返回 id 最大那条（实际=\{s.id}）")
      sg_check(s.surrogate == "li_new", "条款1.4：代理人取最新一条")
    }
    None => abort("条款1.4：命中查询不得为空")
  }
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let actors = repo.find_task_actors(sg_task(repo, inst.instance_id, "n1").task_id)
  sg_has(actors, "li_new", "并入的是 id 最大那条的代理人")
  sg_absent(actors, "li_old", "旧委托不得覆盖")
}

// ══════════════════ 条款 5：四判据（内存仓） ══════════════════

///|
async test "批次D 条款5: 空 processName 兜底 / 时间窗 / 自委托 / enabled 四判据" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let now = "2026-09-21 10:00:00"
  let repo = @mem.MemoryRepository::new()
  // ① 空 processName = 全流程兜底；且"精确名未命中"才回落，命中优先
  let _ = sg_put(repo, "blank", "li", "")
  sg_check(repo.get_surrogate("blank", "any-flow", now) is Some(_), "①空 processName 兜底命中")
  // ② 时间窗：任一侧 NULL = 该侧不限
  let _ = sg_put(repo, "open", "li", "f", start_time=None, end_time=None)
  sg_check(repo.get_surrogate("open", "f", now) is Some(_), "②两侧 NULL = 不限")
  let _ = sg_put(repo, "future", "li", "f", start_time=Some("2026-09-25 00:00:00"))
  sg_check(repo.get_surrogate("future", "f", now) is None, "②开始时间未到不生效")
  let _ = sg_put(repo, "past", "li", "f", end_time=Some("2026-09-20 23:59:59"))
  sg_check(repo.get_surrogate("past", "f", now) is None, "②结束时间已过不生效")
  let _ = sg_put(repo, "inwin", "li", "f", start_time=Some("2026-09-01 00:00:00"), end_time=Some("2026-09-30 23:59:59"))
  sg_check(repo.get_surrogate("inwin", "f", now) is Some(_), "②窗口内生效")
  let _ = sg_put(repo, "edge", "li", "f", start_time=Some(now))
  sg_check(repo.get_surrogate("edge", "f", now) is Some(_), "②边界：start == now 含")
  let _ = sg_put(repo, "edge2", "li", "f", end_time=Some(now))
  sg_check(repo.get_surrogate("edge2", "f", now) is Some(_), "②边界：end == now 含")
  // ③ 自委托过滤
  let _ = sg_put(repo, "self", "self", "f")
  sg_check(repo.get_surrogate("self", "f", now) is None, "③自己委托给自己不生效")
  // ④ enabled 只认 1
  let _ = sg_put(repo, "off", "li", "f", enabled=0)
  sg_check(repo.get_surrogate("off", "f", now) is None, "④enabled=0 不生效")
  let _ = sg_put(repo, "dirty", "li", "f", enabled=2)
  sg_check(repo.get_surrogate("dirty", "f", now) is None, "④脏值不得默认当启用")
  // 授权人不同 / 流程名不匹配都不命中
  let _ = sg_put(repo, "other_person", "li", "f")
  sg_check(repo.get_surrogate("nobody", "f", now) is None, "授权人必须精确匹配")
  let _ = sg_put(repo, "named", "li", "flow-a")
  sg_check(repo.get_surrogate("named", "flow-b", now) is None, "有名字的委托不跨流程命中")
}

///|
async test "批次D 条款5/6: 引擎建单同样不吃窗外与停用委托" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  for c in ["窗外", "停用", "自委托"] {
    let label = c
    let repo = @mem.MemoryRepository::new()
    let engine = sg_engine(repo)
    let did = sg_define(repo, "sg-gate", sg_flow("sg-gate", ["zhang"]))
    match label {
      "窗外" => { let _ = sg_put(repo, "zhang", "li", "sg-gate", end_time=Some("2026-09-20 23:59:59")) }
      "停用" => { let _ = sg_put(repo, "zhang", "li", "sg-gate", enabled=0) }
      _ => { let _ = sg_put(repo, "zhang", "zhang", "sg-gate") }
    }
    let inst = engine.start_async(did, "applicant", @json.FlowData::new())
    let actors = repo.find_task_actors(sg_task(repo, inst.instance_id, "n1").task_id)
    sg_check(actors == ["zhang"], "\{label}委托不得并入（实际=\{actors.join("|")}）")
  }
}

// ══════════════════ issues/123 · 条款 1.4：多条并存时由「最新一条」裁决 ══════════════════
// 缺这几格，把实现改回"先按四判据过滤、剩下的才取最新"也不会红——而那个写法正是
// 13 栈 L2-17/L2-18 恒并入的根因（上一条窗内委托会把用户后续改停用/改到未来的设置永久盖掉）。
// 形状照 Java `SurrogateAutoApplyTest#assertNewestInvalidBeatsOlderValid`（commit 6feeae6）。

///|
/// 同作用域先插「窗内 + enabled=1」的**旧**记录，再插一条「更新但不生效」的记录 ⇒
/// 仓储层与引擎层都必须判否，**旧记录不得复活**。四种不生效形状各一格。
/// 逐格独立成 test（与条款 1.1 的两条同理）：合在一条里前者 panic 会把后面的挡掉，失能时看不出是谁红。
async fn sg_newest_invalid(
  label : String,
  newest_start~ : String? = None,
  newest_end~ : String? = None,
  newest_agent~ : String = "li_new",
  newest_enabled~ : Int = 1
) -> Unit raise {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let did = sg_define(repo, "sg-123", sg_flow("sg-123", ["zhang"]))
  // 旧：窗内 + enabled=1（"先滤后取"的写法下它就是剩下唯一的候选）
  let _ = sg_put(
    repo,
    "zhang",
    "li_valid_old",
    "sg-123",
    start_time=Some("2026-09-20 00:00:00"),
    end_time=Some("2026-09-22 00:00:00"),
  )
  // 新：id 更大那条，由它裁决
  let newer_id = sg_put(
    repo,
    "zhang",
    newest_agent,
    "sg-123",
    start_time=newest_start,
    end_time=newest_end,
    enabled=newest_enabled,
  )
  sg_check(newer_id > 0L, "用例前提：最新一条已入库")
  sg_check(
    repo.get_surrogate("zhang", "sg-123", "2026-09-21 10:00:00") is None,
    "\{label}：仓储层最新一条判否 ⇒ 旧记录不得顶上来",
  )
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let actors = repo.find_task_actors(sg_task(repo, inst.instance_id, "n1").task_id)
  sg_check(actors == ["zhang"], "\{label} ⇒ 引擎不得并入（实际=\{actors.join("|")}）")
}

///|
async test "批次123 最新一条窗外: 旧的窗内有效记录不得复活" {
  sg_newest_invalid("窗外", newest_start=Some("2026-09-25 00:00:00"))
}

///|
async test "批次123 最新一条 enabled=0: 旧的窗内有效记录不得复活" {
  sg_newest_invalid("enabled=0", newest_enabled=0)
}

///|
async test "批次123 最新一条 enabled 脏值 2: 契约只认 1，旧记录不得复活" {
  sg_newest_invalid("脏值 enabled=2", newest_enabled=2)
}

///|
async test "批次123 最新一条自委托: 旧的窗内有效记录不得复活" {
  sg_newest_invalid("自己委托给自己", newest_agent="zhang")
}

///|
/// 反向对照（正格）：最新一条**有效**时照常并入、原人保留，旧的那条停用也不拖累。
/// 有这一格在，上面四格的红才不是"委托整体失效"造成的假绿——变异对照要求改回旧形状时
/// 恰好只有那四格红、这一格仍绿。
async test "批次123 正向: 最新一条窗内且 enabled=1 ⇒ 并入代理人且原人保留" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let did = sg_define(repo, "sg-123-ok", sg_flow("sg-123-ok", ["zhang"]))
  let _ = sg_put(repo, "zhang", "li_stale", "sg-123-ok", enabled=0) // 旧：停用
  let _ = sg_put(repo, "zhang", "li_new", "sg-123-ok") // 新：enabled=1 + 两侧不限 = 窗内
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let actors = repo.find_task_actors(sg_task(repo, inst.instance_id, "n1").task_id)
  sg_has(actors, "zhang", "授权人保留（委托不是转办）")
  sg_has(actors, "li_new", "最新一条有效 ⇒ 并入其代理人")
  sg_absent(actors, "li_stale", "停用的旧记录不得并入")
}

///|
/// 条款 1.4 的作用域回落：精确作用域那条**判否**后仍要看全流程作用域自己那条最新的
/// （Java `JdbcProcessExtRepositoryTest#testSurrogateCrudAndGet` 钉的同形：精确已过期 → 兜底全流程）。
/// 这一格钉住的是"实现写成'精确作用域有记录就直接返回、判否也不看全流程'"那种过修。
async test "批次123 兜底: 精确作用域判否后仍回落全流程作用域的最新一条" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let did = sg_define(repo, "sg-123-fb", sg_flow("sg-123-fb", ["zhang"]))
  let _ = sg_put(repo, "zhang", "li_global", "") // 全流程作用域：窗内有效
  let _ = sg_put(
    repo,
    "zhang",
    "li_exact",
    "sg-123-fb",
    end_time=Some("2026-09-20 23:59:59"),
  ) // 精确作用域：id 更大但已过期
  match repo.get_surrogate("zhang", "sg-123-fb", "2026-09-21 10:00:00") {
    Some(sg) => sg_check(
      sg.surrogate == "li_global",
      "精确作用域判否后须回落全流程作用域（实得代理人=\{sg.surrogate}）",
    )
    None => abort("精确作用域判否后仍应命中全流程那条")
  }
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let actors = repo.find_task_actors(sg_task(repo, inst.instance_id, "n1").task_id)
  sg_has(actors, "li_global", "引擎同样吃到全流程兜底")
  sg_absent(actors, "li_exact", "判否的精确作用域记录不得并入")
}

// ══════════════════ 条款 3 / 4：开关与缺仓储 ══════════════════

///|
async test "批次D 条款3: 默认开启；with_surrogate_auto_apply(false) 显式关闭" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  // 关
  let repo = @mem.MemoryRepository::new()
  let off = sg_engine(repo, auto_apply=false)
  let did = sg_define(repo, "sg-off", sg_flow("sg-off", ["zhang"]))
  let _ = sg_put(repo, "zhang", "li", "sg-off")
  let inst = off.start_async(did, "applicant", @json.FlowData::new())
  let actors = repo.find_task_actors(sg_task(repo, inst.instance_id, "n1").task_id)
  sg_check(actors == ["zhang"], "关闭后回到仅台账（实际=\{actors.join("|")}）")
  // 开（默认，不显式调 API）
  let repo2 = @mem.MemoryRepository::new()
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let engine2 = @engine.Engine::make(@spi.Ctx::new(repo2, repo2).with_id_generator(fn() { gen.next_id() }))
  let did2 = sg_define(repo2, "sg-off", sg_flow("sg-off", ["zhang"]))
  let _ = sg_put(repo2, "zhang", "li", "sg-off")
  let inst2 = engine2.start_async(did2, "applicant", @json.FlowData::new())
  sg_has(
    repo2.find_task_actors(sg_task(repo2, inst2.instance_id, "n1").task_id),
    "li",
    "默认开启（不配开关也要生效）",
  )
}

///|
async test "批次D 条款4: 未配置扩展仓储（NoExtRepository）建单不受影响" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, @spi.NoExtRepository::new()).with_id_generator(fn() { gen.next_id() })
  let engine = @engine.Engine::make(ctx)
  let did = sg_define(repo, "sg-noext", sg_flow("sg-noext", ["zhang"]))
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let actors = repo.find_task_actors(sg_task(repo, inst.instance_id, "n1").task_id)
  sg_check(actors == ["zhang"], "缺扩展仓储 = 静默跳过（不报错、不并入）")
}

///|
async test "批次D 条款4: 委托查询报错被吞，建单照常" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let broken = BrokenExtRepository::{ inner: repo, calls: 0L }
  let _ = sg_put(repo, "zhang", "li", "sg-boom")
  let did = sg_define(repo, "sg-boom", sg_flow("sg-boom", ["zhang"]))
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, broken).with_id_generator(fn() { gen.next_id() })
  let engine = @engine.Engine::make(ctx)
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let actors = repo.find_task_actors(sg_task(repo, inst.instance_id, "n1").task_id)
  sg_check(actors == ["zhang"], "仓储报错时不得并入半成品代理人，也不得打断建单")
  sg_check(broken.calls > 0, "确认真的查过委托（否则本用例是假绿）")
}

///|
async test "批次D 回归: 无委托配置时零额外查询、参与者与耗时口径不变" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let engine = sg_engine(repo)
  let did = sg_define(repo, "sg-none", sg_flow("sg-none", ["a", "b"]))
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let t1 = sg_task(repo, inst.instance_id, "n1")
  sg_check(t1.actor_ids == ["a"], "无委托时参与者原样")
  let _ = engine.execute_task_async(t1.task_id, "a", @json.FlowData::new())
  let t2 = sg_task(repo, inst.instance_id, "n2")
  sg_check(t2.actor_ids == ["b"], "推进路径无委托时同样原样")
  let done = repo.find_history_tasks(inst.instance_id)
  sg_check(done.length() == 2, "任务行数不因委托逻辑而增减")
}
