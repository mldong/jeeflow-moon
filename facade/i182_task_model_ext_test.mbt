// issues/182（R16）· taskModel.ext 必须取节点 properties.field（原读无人写的 properties.ext ⇒ 恒 {}）。
// 基准＝java/go/py/node/php/csharp（spec 06:684「ext = 节点 properties.field 原样透传」）。
// 双锚设计：field 与诱饵 ext 两键同投——修前读 ext 会搬进诱饵内容（WRONG_KEY_DECOY），
// 修后必须只认 field（同一格同时证"读对了"与"没读错"）；负向档（无 field）保持 {} 形状
// （本栈既有形状，如实钉住，不借修改形状）。
// 复用同包 helper：i153_check / code_of / msg_of / data_of / parse_iid / doing_task_for /
// targs / i159_args（i153/i159/withdraw_transfer 文件里定义，同包可见）。

///|
/// 起点流：apply 自动办结，t1（leader）带 props_json 注入的 properties 内层内容
/// （properties 内层用 head + props_json + tail 拼接；$| 多行串不依赖插值写法）
fn i182_flow(props_json : String) -> String {
  let head = $|{"name": "i182-flow", "displayName": "I182", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start"},
  $|   {"id": "apply", "type": "snaker:task",
  $|    "properties": {"assignee": "applicant"}},
  $|   {"id": "t1", "type": "snaker:task", "text": {"value": "T1"},
  $|    "properties": {
$|
  let tail = $|}},
  $|   {"id": "end", "type": "snaker:end"}
  $| ],
  $| "edges": [
  $|   {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|   {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "t1"},
  $|   {"id": "e3", "sourceNodeId": "t1", "targetNodeId": "end"}
  $| ]}
$|
  head + props_json + tail
}

///|
/// 发起并到 t1 待办，返回 detail 的 data（含 taskModel）。
async fn i182_run(props_json : String) -> Json raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i182-flow",
    display_name: "I182",
    define_type: "approval",
    state: 1,
    content: i182_flow(props_json),
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let start = facade.flow("processInstance/startAndExecute", i159_args([
    ("processDefineId", @json.string_of(define_info.id.to_string())),
    ("operator", @json.string_of("applicant")),
  ]))
  i153_check(code_of(start) == 0L, "发起 code=0（msg=\{msg_of(start)}）")
  let iid = parse_iid(@json.get_str(data_of(start), "processInstanceId").unwrap_or("0"))
  let t1 = doing_task_for(repo, iid, "leader")
  let det = facade.flow("processTask/detail", targs([
    ("processTaskId", t1.task_id.to_string()),
    ("operator", "leader"),
  ]))
  i153_check(code_of(det) == 0L, "detail code=0（msg=\{msg_of(det)}）")
  data_of(det)
}

///|
/// 取 data.taskModel.ext（键必在；形状由用例各档钉）
fn i182_ext(data : Json) -> Json {
  @json.get(@json.get(data, "taskModel").unwrap(), "ext").unwrap()
}

///|
/// 正向＋反空转双锚：field 内容必须上到 ext，诱饵 properties.ext 键不得被读取。
async test "i182 正向：ext 取 field 内容且不读诱饵 ext 键" {
  let data = i182_run("\"assignee\": \"leader\", \"field\": {\"PERMISSION_f_note\": 1, \"f_tag\": \"x\"}, \"ext\": {\"WRONG_KEY_DECOY\": true}")
  let ext = i182_ext(data)
  match ext {
    Json::Object(m) => {
      i153_check(m.get("PERMISSION_f_note").is_some(), "ext 必须含 field 的 PERMISSION_f_note（修前读错键 ⇒ 恒 {}）")
      i153_check(m.get("f_tag").is_some(), "field 内容必须原样透传（缺 f_tag）")
      i153_check(m.get("WRONG_KEY_DECOY").is_none(), "诱饵 properties.ext 键不得被读取")
      i153_check(@json.get_i64(ext, "PERMISSION_f_note") == Some(1L), "PERMISSION_f_note 值应为 1")
    }
    _ => abort("ext 必须是对象（修前恒 {} 也是对象；本格靠键内容判，实得非对象）")
  }
}

///|
/// 负向：无 field 档 ⇒ 保持 {} 形状（本栈既有形状，如实钉住；且诱饵同样不得被读）。
async test "i182 负向：无 field 档 ext 保持 {} 且不读诱饵" {
  let data = i182_run("\"assignee\": \"leader\", \"ext\": {\"WRONG_KEY_DECOY\": true}")
  let ext = i182_ext(data)
  match ext {
    Json::Object(m) => {
      i153_check(m.length() == 0, "无 field ⇒ ext 必须为空对象（实得 \{m.length()} 键）")
    }
    _ => abort("ext 必须是对象（无 field 档本栈形状＝{}）")
  }
}

///|
/// 回归：taskModel 兄弟键（name/displayName/type/form）与行级 executable 不受本修影响。
async test "i182 回归：taskModel 兄弟键与行级出口不受影响" {
  let data = i182_run("\"assignee\": \"leader\", \"field\": {\"f_tag\": \"x\"}")
  let tm = @json.get(data, "taskModel").unwrap()
  i153_check(@json.get_str(tm, "name") == Some("t1"), "taskModel.name 应为 t1")
  i153_check(@json.get_str(tm, "displayName") == Some("T1"), "taskModel.displayName 应为 T1")
  i153_check(@json.get_str(tm, "type") == Some("task"), "taskModel.type 应为 task")
  i153_check(@json.get(tm, "form").is_some(), "taskModel.form 键仍在（无值档为 null）")
  let exec_ok = match @json.get(data, "executable") {
    Some(Json::True) => true
    _ => false
  }
  i153_check(exec_ok, "行级 executable 应为 true")
}
