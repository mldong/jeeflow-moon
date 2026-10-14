// issues/201（audit8 队列 R79·owner 拍 C＝只统一「求值器自身抛异常 ⇒ 必须落一条带原因的可诊断
// 日志」，遍历宽度不钉）的 moon 腿判据。
//
// ⚠ 现读更正（与卡面/193 §1 记的落点不同，案文 201 §2 记账）：本栈「求值器抛」被吞的位置不在
// 门面 `actions_ext.mbt` 的 collect 腿 catch，而在**引擎** `core/engine/engine.mbt` 的
// `evaluate_expression`——SPI 那条腿外面罩着 `try { … } catch { _ => false }`，抛错在引擎内部
// 就折成 false 了，永远走不到门面那层 catch（门面 catch 只对 `simple_eval` 开放，而 simple_eval
// 现读零 raise ⇒ 那条是结构性不可达的第二层）。所以本栈的修点与日志口都在引擎。
//
// 三枚判据分工＝①失败⇒数据面维持折 false（宽度不钉＝行为不许变）；③合法判假⇒同样不收边；
// ②正常⇒真产出 e_a（阳性对照，防夹具没走到决策腿就自证绿）。三者数据面互不遮不住的部分由
// **日志**那一半判别：本栈日志口＝`println`（无注入 sink），取证口径照 162 的 moon 腿＝
// 测试进程 stdout grep，三档各用**不同 id 基**起栈（1/4000/8000）⇒ WARN 行按 instanceId 归因：
// ①档恰有两条（e_a/e_b 各一），②③档零条；变异（把 println 摘掉）⇒ ①档 0 行＝红。
// 文案本身另由纯函数 `@engine.eval_failure_warning` 单独断言（归因件齐，零副作用可测）。
//
// 复用同包 helper：targs / code_of / msg_of / data_of / parse_iid / doing_task_for。

///|
fn i201_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i201-evalLog] 红样：" + "\{label}")
    abort("[i201-evalLog] 红样：" + "\{label}")
  }
}

///|
/// 决策夹具：start →apply→ task1 →decision1，两条**带 expr** 的出边
///   e_a → vip_task → end（expr＝`i201_edge_a`，正常档判真）
///   e_b → norm_task → end（expr＝`i201_edge_b`，正常档判假）
/// 表达式取固定字面串：SPI 是测试替身，语义由替身给，不需要真比较——两档（判真/抛错）由
/// `mode` 槽切，实例路由阶段固定跑正常档（引擎选边与门面高亮共用同一个求值口）。
fn i201_decision_flow() -> String {
  let s = $|{"name": "i201-dec", "displayName": "201 求值失败日志夹具", "type": "approval",
  $| "nodes": [
  $|   {"id": "start", "type": "snaker:start"},
  $|   {"id": "apply", "type": "snaker:task",
  $|    "properties": {"assignee": "applicant", "taskType": 0, "performType": 0}},
  $|   {"id": "task1", "type": "snaker:task",
  $|    "properties": {"assignee": "leader", "taskType": 0, "performType": 0}},
  $|   {"id": "decision1", "type": "snaker:decision", "properties": {}},
  $|   {"id": "vip_task", "type": "snaker:task",
  $|    "properties": {"assignee": "boss", "taskType": 0, "performType": 0}},
  $|   {"id": "norm_task", "type": "snaker:task",
  $|    "properties": {"assignee": "hr", "taskType": 0, "performType": 0}},
  $|   {"id": "end", "type": "snaker:end"}
  $| ],
  $| "edges": [
  $|   {"id": "e0", "sourceNodeId": "start", "targetNodeId": "apply", "properties": {}},
  $|   {"id": "e1", "sourceNodeId": "apply", "targetNodeId": "task1", "properties": {}},
  $|   {"id": "e2", "sourceNodeId": "task1", "targetNodeId": "decision1", "properties": {}},
  $|   {"id": "e_a", "sourceNodeId": "decision1", "targetNodeId": "vip_task",
  $|    "properties": {"expr": "i201_edge_a"}},
  $|   {"id": "e_b", "sourceNodeId": "decision1", "targetNodeId": "norm_task",
  $|    "properties": {"expr": "i201_edge_b"}},
  $|   {"id": "e_a_end", "sourceNodeId": "vip_task", "targetNodeId": "end", "properties": {}},
  $|   {"id": "e_b_end", "sourceNodeId": "norm_task", "targetNodeId": "end", "properties": {}}
  $| ]}
$|

  s
}

///|
/// 起一单并办结 task1 ⇒ 令牌越过 decision1 落在活跃 `vip_task`（正常档求值，两栈同源）。
/// `mode` 由调用方持有：路由完成后切成 raise/恒假档，再调 highLight。
/// `id_base` 逐档不同（1/4000/8000）⇒ stdout 里的 WARN 行能按 instanceId 归到具体那一档。
async fn i201_setup(
  id_base : Int64,
  mode : Array[String]
) -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], Int64) raise {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(id_base)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let ev : (String, Map[String, Json]) -> Json raise @error.JeeflowError =
    (expr, _vars) =>
      if mode[0] == "raise" {
        raise @error.Business("i201 夹具注入的求值失败")
      } else if mode[0] == "false" {
        @json.bool_of(false)
      } else if expr == "i201_edge_a" {
        @json.bool_of(true)
      } else {
        @json.bool_of(false)
      }
  let _ = ctx2.with_expression_evaluator(ev)
  let facade = @facade.Facade::make(ctx2)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i201-dec",
    display_name: "201 求值失败日志夹具",
    define_type: "approval",
    state: 1,
    content: i201_decision_flow(),
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let env = facade.flow(
    "processInstance/startAndExecute",
    targs([("processDefineId", define_info.id.to_string()), ("operator", "applicant")]),
  )
  i201_check(code_of(env) == 0L, "发起 code=0（msg=\{msg_of(env)}）")
  let iid = parse_iid(@json.get_str(data_of(env), "processInstanceId").unwrap_or("0"))
  let t1 = doing_task_for(repo, iid, "leader")
  let e2 = facade.flow(
    "processTask/execute",
    targs([
      ("processTaskId", t1.task_id.to_string()),
      ("operator", "leader"),
      ("submitType", "1"),
    ]),
  )
  i201_check(code_of(e2) == 0L, "task1 办结 code=0（msg=\{msg_of(e2)}）")
  // 夹具形状自证：必须停在活跃 vip_task，否则模型走不到 decision1 的两条出边（三档全恒真）
  let active_env = facade.flow("processInstance/highLight", targs([("id", iid.to_string())]))
  i201_check(code_of(active_env) == 0L, "自证高亮 code=0（msg=\{msg_of(active_env)}）")
  let act = i153_str_list(data_of(active_env), "activeNodeNames").join(",")
  i201_check(
    i153_str_list(data_of(active_env), "activeNodeNames").contains("vip_task"),
    "夹具应停在活跃 vip_task（实际 \{act}）",
  )
  (facade, iid)
}

///|
async fn i201_edges(facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], iid : Int64) -> Array[String] raise {
  let env = facade.flow("processInstance/highLight", targs([("id", iid.to_string())]))
  i201_check(
    code_of(env) == 0L,
    "拍 C 口径＝降级面保留，求值失败只许留痕不许变红（msg=\{msg_of(env)}）",
  )
  i153_str_list(data_of(env), "historyEdgeNames")
}

///|
/// 文案纯函数：归因四件齐（实例号/定义号/表达式/原因）＋中性事实措辞。
test "i201-evalLog 文案纯函数四件齐" {
  let line = @engine.eval_failure_warning(777L, 888L, "i201_edge_a", "boom")
  for piece in [
    "决策边表达式求值失败",
    "instanceId=777",
    "defineId=888",
    "expr=i201_edge_a",
    "err=boom",
  ] {
    i201_check(line.contains(piece), "文案缺归因件 \{piece}（实得 " + line + "）")
  }
}

///|
/// ① 求值失败档 ⇒ 两条决策出边都不收（宽度维持折 false＝行为与修前逐字同形），
/// 线性腿 e0/e1/e2 照收（失败只许影响决策边过滤）。日志由 stdout grep 判别（卷首口径）。
async test "i201-evalLog ① 求值失败按 false 处理" {
  let mode = ["good"]
  let (facade, iid) = i201_setup(1L, mode)
  mode[0] = "raise"
  println("i201-mark fail iid=\{iid}")
  let edges = i201_edges(facade, iid)
  for need in ["e0", "e1", "e2"] {
    i201_check(edges.contains(need), "线性腿 \{need} 必须照收（实得 " + edges.join(",") + "）")
  }
  for ban in ["e_a", "e_b"] {
    i201_check(!edges.contains(ban), "求值失败的边 \{ban} 不该收（实得 " + edges.join(",") + "）")
  }
}

///|
/// ② 正常档 ⇒ e_a 真收（阳性对照：证明这三枚夹具确实走到了决策边求值那条腿）。零日志由
/// stdout 里本档 instanceId 名下 WARN==0 判别。
async test "i201-evalLog ② 正常求值收 e_a" {
  let mode = ["good"]
  let (facade, iid) = i201_setup(4000L, mode)
  println("i201-mark good iid=\{iid}")
  let edges = i201_edges(facade, iid)
  i201_check(
    edges.contains("e_a"),
    "正常档必须收 e_a（本档若不收＝夹具没走到模型腿，①③档自证失效；实得 " + edges.join(",") + "）",
  )
  i201_check(!edges.contains("e_b"), "判假的 e_b 不该收（实得 " + edges.join(",") + "）")
}

///|
/// ③ 合法判假档（返回 @json.bool_of(false)、不抛）⇒ 同样不收 e_a，但**不许**落求值失败日志
/// （两档必须分得开，否则 WARN 会变成每次高亮都刷屏）。零日志由 stdout 判别。
async test "i201-evalLog ③ 合法判假不落日志" {
  let mode = ["good"]
  let (facade, iid) = i201_setup(8000L, mode)
  mode[0] = "false"
  println("i201-mark false iid=\{iid}")
  let edges = i201_edges(facade, iid)
  i201_check(!edges.contains("e_a"), "判假档 e_a 不该收（实得 " + edges.join(",") + "）")
  i201_check(!edges.contains("e_b"), "判假档 e_b 不该收（实得 " + edges.join(",") + "）")
}
