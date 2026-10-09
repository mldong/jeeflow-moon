// issues/154 · spec 06 §processInstance/approvalRecord「四条口径」与 §ccList 默认档的门面级判据。
//
// 基准（现读）：
// · java `JeeflowFacade.approvalRecord` 首列 `vo.put("id", String.valueOf(t.getTaskId()))`；
// · go `jeeflow-go/facade/facade.go` 同处同形；
// · spec 06 九键＝id / taskName / displayName / taskType / performType / taskState / operator /
//   finishTime / ext，且 `variable` 原串不得再出现（口径④）。
//
// ⚠️ 为什么必须有一支直接调 `Facade::approval_record`（不过 `flow`）：出口安全网
//   `facade/outbound.mbt` 的 `stringify_id_value` 会把任何键名为 `id` 的 **Number** 也字符串化，
//   所以只看 `flow()` 信封无法分辨「VO 构造时就落了串」与「落了 Number 被安全网救回来」——
//   后者正是 java 那句「宿主通道只保宿主，引擎不得依赖它」禁止的形状。raw 腿才是这一格的尺子。
//
// 复用同包 helper：targs / code_of / msg_of / data_of / rows_of / parse_iid / doing_task_for /
// linear_flow_json。

///|
fn i154_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i154-approvalRecord] 红样：" + "\{label}")
    abort("[i154-approvalRecord] 红样：" + "\{label}")
  }
}

///|
/// 出口九键（顺序＝口径要求的出口顺序：`id` 是**首列**）
const I154_NINE_KEYS : String =
  "id,taskName,displayName,taskType,performType,taskState,operator,finishTime,ext"

///|
/// 行对象键清单（按插入序，逗号连接）
fn i154_key_list(row : Json) -> String {
  match row {
    Json::Object(m) => {
      let out = StringBuilder()
      let mut first = true
      for k, _ in m {
        if !first {
          out.write_string(",")
        }
        first = false
        out.write_string(k)
      }
      out.to_string()
    }
    _ => "<非对象>"
  }
}

///|
/// 键清单渲染（消息用；本栈 core 的 inspect 不可用、Array 的 to_string 走已废弃的 Show）
fn i154_join(items : Array[String]) -> String {
  let out = StringBuilder()
  out.write_string("[")
  for i in 0..<items.length() {
    if i > 0 {
      out.write_string(",")
    }
    out.write_string(items[i])
  }
  out.write_string("]")
  out.to_string()
}

///|
/// approvalRecord 的 data ＝行数组本体（**不是**分页信封），所以同包 rows_of（找 rows 键）不适用。
fn i154_data_rows(data : Json) -> Array[Json] {
  match data {
    Json::Array(a) => a
    _ => []
  }
}

///|
/// 两侧键集是否互为子集（＝同集合）。用于口径③「ext ＝ 该行任务变量，不多不少」。
fn i154_same_key_sets(a : Array[String], b : Array[String]) -> Bool {
  let mut ok = a.length() == b.length()
  if ok {
    for k in a {
      if !b.contains(k) {
        ok = false
      }
    }
  }
  ok
}

///|
fn i154_json_keys(v : Json) -> Array[String] {
  match v {
    Json::Object(m) => {
      let out : Array[String] = []
      for k, _ in m {
        out.push(k)
      }
      out
    }
    _ => []
  }
}

///|
fn i154_flow_keys(fd : @json.FlowData) -> Array[String] {
  let out : Array[String] = []
  for k, _ in fd.inner() {
    out.push(k)
  }
  out
}

///|
/// 走完 start（自动办结 apply）+ task1（带 f_note）⇒ 两行历史，实例终结。
/// 实例变量里塞一个 f_reason：它只属于实例层，用来照"ext 回落实例变量"这一类病灶。
async fn i154_two_rows() -> (
  @mem.MemoryRepository,
  @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  Int64
) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i154-linear",
    display_name: "审批记录九键夹具",
    define_type: "approval",
    state: 1,
    content: linear_flow_json(),
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let env = facade.flow(
    "processInstance/startAndExecute",
    targs([
      ("processDefineId", define_info.id.to_string()),
      ("operator", "applicant"),
      ("f_reason", "只该出现在实例层"),
    ]),
  )
  i154_check(code_of(env) == 0L, "发起 code=0（msg=\{msg_of(env)}）")
  let iid = parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0"))
  let t1 = doing_task_for(repo, iid, "leader")
  let e2 = facade.flow(
    "processTask/execute",
    targs([
      ("processTaskId", t1.task_id.to_string()),
      ("operator", "leader"),
      ("submitType", "1"),
      ("f_note", "同意"),
    ]),
  )
  i154_check(code_of(e2) == 0L, "task1 办结 code=0（msg=\{msg_of(e2)}）")
  (repo, facade, iid)
}

///|
async fn i154_raw_rows(facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], iid : Int64) -> Array[Json] raise {
  match facade.approval_record(targs([("id", iid.to_string())])) {
    Json::Array(a) => a
    _ => []
  }
}

///|
/// 口径④＋issues/154①：**raw** VO（不经 flow 的 stringify_ids 安全网）九键齐、首列 id、
/// id 在 VO 构造时就是 Json 字符串；`variable` 不在列集合里；ext 恒出对象。
async test "i154-④ 九键与首列 id（raw 腿，绕开出口安全网）" {
  let (_, facade, iid) = i154_two_rows()
  let rows = i154_raw_rows(facade, iid)
  i154_check(rows.length() == 2, "夹具自证：两行历史（实际 \{rows.length()} 行）")
  for r in rows {
    i154_check(
      i154_key_list(r) == I154_NINE_KEYS,
      "raw 行键集合与顺序＝九键，id 打头（实际 <\{i154_key_list(r)}>",
    )
    i154_check(
      @json.get(r, "id") is Some(Json::String(_)),
      "raw 行 id 是 Json 字符串——不是 Number 靠 outbound 的 stringify_ids 兜回来的",
    )
    i154_check(
      @json.get(r, "variable") is None,
      "口径④：`variable` 原串不得再出现在出口列集合里",
    )
    i154_check(
      @json.get(r, "ext") is Some(Json::Object(_)),
      "ext 是对象（任务变量唯一对外出口，issues/124）",
    )
  }
}

///|
/// 口径①：行序＝id 严格递增；出口序必须等于仓储真相序（不是门面自己重排出来的）。
async test "i154-① 审批记录行序 id ASC" {
  let (repo, facade, iid) = i154_two_rows()
  let env = facade.flow("processInstance/approvalRecord", targs([("id", iid.to_string())]))
  i154_check(code_of(env) == 0L, "approvalRecord code=0（msg=\{msg_of(env)}）")
  // ⚠ 本 action 的 data **就是行数组**（不是分页信封），故不能走同包 rows_of（那是给
  // {rows:[…]} 形状用的）——拿错形状会得到"0 行"的假信号。
  let rows = i154_data_rows(data_of(env))
  i154_check(rows.length() == 2, "两行历史（实际 \{rows.length()}）")
  let ids : Array[Int64] = []
  for r in rows {
    let s = @json.get_str(r, "id").unwrap_or("")
    i154_check(!s.is_empty(), "出口行的 id 必须是可读的十进制串（实际 <\{s}>）")
    ids.push(parse_iid(s))
  }
  for i in 1..<ids.length() {
    i154_check(
      ids[i] > ids[i - 1],
      "口径①：第 \{i} 行 id(\{ids[i]}) 必须严格大于第 \{i - 1} 行(\{ids[i - 1]})",
    )
  }
  let truth : Array[Int64] = []
  for t in repo.find_history_tasks(iid) {
    truth.push(t.task_id)
  }
  i154_check(
    truth.length() == ids.length() && truth[0] == ids[0] && truth[1] == ids[1],
    "出口序＝仓储 id 升序（内存仓 sorted_ids→@model.sort_i64；SQL 腿 ORDER BY id）",
  )
}

///|
/// 口径②：实例 id 不存在 ⇒ 空数组，**不得**报「流程实例不存在」（视图端点不因 id 不存在报错）。
async test "i154-② 实例不存在出空数组不报错" {
  let (_, facade, _) = i154_two_rows()
  let env = facade.flow("processInstance/approvalRecord", targs([("id", "4200000000000000001")]))
  i154_check(
    code_of(env) == 0L,
    "不存在的实例 id 也必须 code=0（实际 code=\{code_of(env)} msg=\{msg_of(env)}）",
  )
  i154_check(
    msg_of(env) != "流程实例不存在",
    "不得报「流程实例不存在」（实际 msg=\{msg_of(env)}）",
  )
  i154_check(i154_data_rows(data_of(env)).is_empty(), "出空数组（实际 \{i154_data_rows(data_of(env)).length()} 行）")
}

///|
/// 口径③：`ext` ＝**该行自己的**任务变量，逐行键集相等 ⇒ 结构上排除了"回落实例变量"
/// （实例变量 ⊋ 任何单行任务变量时，回落必然多键）。另加一正一负两档对照防夹具空转：
///   阳性＝task1 行的 ext 有 f_note（变量真的透出）；
///   阴性＝apply 行的 ext 没有 f_note（不是把全链变量糊成一坨）。
async test "i154-③ ext＝该行任务变量，不回落实例变量" {
  let (repo, facade, iid) = i154_two_rows()
  let his = repo.find_history_tasks(iid)
  let rows = i154_raw_rows(facade, iid)
  i154_check(his.length() == 2 && rows.length() == 2, "夹具自证：两行历史")
  for i in 0..<2 {
    let ext_obj = @json.get(rows[i], "ext").unwrap_or(@json.null_json())
    i154_check(
      i154_same_key_sets(i154_json_keys(ext_obj), i154_flow_keys(his[i].variables)),
      "第 \{i} 行 ext 键集＝该行任务变量键集（ext=\{i154_join(i154_json_keys(ext_obj))} vs 变量=\{i154_join(i154_flow_keys(his[i].variables))}）——两集不等即回落",
    )
  }
  // 阳性对照：f_note 落在 task1 行（下标 1）
  let ext1 = @json.get(rows[1], "ext").unwrap_or(@json.null_json())
  i154_check(
    @json.get(ext1, "f_note").is_some() && @json.get_str(ext1, "f_note").unwrap_or("") == "同意",
    "阳性对照：task1 行的 ext 透出本次提交变量 f_note=同意",
  )
  // 阴性对照：apply 行（下标 0）不得带上后来那次提交的变量
  let ext0 = @json.get(rows[0], "ext").unwrap_or(@json.null_json())
  i154_check(
    @json.get(ext0, "f_note") is None,
    "阴性对照：apply 行的 ext 不得有 task1 那次提交的 f_note",
  )
  // 实例层专属键 f_reason 若不在某行任务变量里，就绝不该出现在该行 ext 中
  for i in 0..<2 {
    let ext_i = @json.get(rows[i], "ext").unwrap_or(@json.null_json())
    let in_vars = his[i].variables.contains_key("f_reason")
    let in_ext = @json.get(ext_i, "f_reason") is Some(_)
    i154_check(
      in_vars || !in_ext,
      "口径③：第 \{i} 行任务变量没有 f_reason，ext 里却出现了 ⇒ 实例变量被回灌",
    )
  }
}

///|
/// issues/154④（spec 06 §ccList）：不传 pageSize 时默认档＝10（旧值 20 已判分叉）。
/// pageNum 默认 1 同批钉住；显式传值必须原样回显，不许被默认档吃掉。
async test "i154-④ ccList pageSize 默认 10" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx2)
  let env = facade.flow("processInstance/ccList", targs([("operator", "user1")]))
  i154_check(code_of(env) == 0L, "ccList code=0（msg=\{msg_of(env)}）")
  let ps = @json.get_i64(data_of(env), "pageSize").unwrap_or(-1L)
  i154_check(ps == 10L, "不传 pageSize ⇒ 默认 10（实际 \{ps}；旧形状＝20）")
  let pn = @json.get_i64(data_of(env), "pageNum").unwrap_or(-1L)
  i154_check(pn == 1L, "pageNum 默认 1（实际 \{pn}）")
  let env2 = facade.flow(
    "processInstance/ccList",
    targs([("operator", "user1"), ("pageSize", "5")]),
  )
  i154_check(
    @json.get_i64(data_of(env2), "pageSize").unwrap_or(-1L) == 5L,
    "显式 pageSize=5 必须原样回显",
  )
}
