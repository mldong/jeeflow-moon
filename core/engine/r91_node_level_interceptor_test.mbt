// audit8 R91（issues/234 §4.2／spec02 §3 三条）——节点级拦截器声明的**优先序、回落与暴露**。
// 基准＝java `NodeModel.java:49-59`（取串：节点优先、空则回落流程根）＋`:64-77`（按名实例化，
// 解析不了就抛）：pre／post 两档各取各串；节点 `properties` 声明优先、串空才回落流程根同名键、
// **两档不叠加**；两档都没声明才回落引擎级注册列表；声明里的名字查不到 ⇒ 显式报错（带档位＋
// nodeId，issues/60 同一条纪律），不许静默跳过。键形按丙＝注册表键就是 java 类全名串（§8 现读：
// 五栈的拦截器键早已是 FQCN ⇒ 零装配改动），rust／本栈补声明解析时沿用同一串、不另发明短名。
//
// 本栈改前的形状（三件事，逐条对着普查表 moon 行）：`fire_pre/fire_post_interceptors` 只遍历
// 引擎级数组 ⇒ 声明族零命中；`ProcessModel` 连 `pre_interceptors` 字段都没有 ⇒ 根级 pre 声明
// 无处落；persist 的挂载闸门自己读一遍 properties ⇒ 同段判据的第二份实现。
//
// ⚠ 判据一律**跑真流程**（发起→办结 apply→办结 approval），不直调派发口：
//   1. 本栈 `*_test.mbt` 是包外测试（本轮实测报错 `Type Engine[...] has no method
//      fire_post_interceptors`），私有派发口根本调不到；
//   2. 同一条理由也挡住"假绿"——csharp 那轮正是把断言挂在没执行的步骤上，五档全空转。
//      挂点形状现读 `engine.mbt:187-310`＋`engine_ops.mbt:174`：start 节点前后都不 fire；
//      Task 节点只在**建单那一刻** fire pre（后置要等办结该任务才 fire）；end 节点 pre、post 都 fire。
//      ⇒ 发起＝apply-pre；办结 apply＝apply-post 再 approval-pre；办结 approval＝approval-post
//        再 end-pre／end-post。每档的期望串都照这张现读表写死。
//
// ⚠ 本栈模型已在 `exec.process_model` 里、无 DB 回查 ⇒ go／py／node 那条「根声明每定义只回查
// 一行」的读放大判据在此**结构性不可达**，故不立该档（不是漏立）。

///|
const R91_ROOT_PRE : String = "com.mldong.jeeflow.test.R91RootPre"
const R91_ROOT_POST : String = "com.mldong.jeeflow.test.R91RootPost"
const R91_APPLY_PRE : String = "com.mldong.jeeflow.test.R91ApplyPre"
const R91_APPLY_POST : String = "com.mldong.jeeflow.test.R91ApplyPost"
const R91_APPROVAL_POST : String = "com.mldong.jeeflow.test.R91ApprovalPost"
const R91_SLOW : String = "com.mldong.jeeflow.test.R91Slow"
const R91_FAST : String = "com.mldong.jeeflow.test.R91Fast"
const R91_GHOST : String = "com.mldong.jeeflow.test.R91Ghost"

///|
/// 根级两把声明键（空串＝该键不写＝"没声明"那一档）
fn r91_root_seg(
  pre : String,
  post : String
) -> String {
  let parts : Array[String] = []
  if !pre.is_empty() {
    parts.push("\"preInterceptors\": \"" + pre + "\"")
  }
  if !post.is_empty() {
    parts.push("\"postInterceptors\": \"" + post + "\"")
  }
  let inner = parts.join(", ")
  if inner.is_empty() {
    ""
  } else {
    ", " + inner
  }
}

///|
/// 节点 properties 里追加的两把声明键（写在 assignee/taskType/performType 之后）
fn r91_node_extra(
  pre : String,
  post : String
) -> String {
  let parts : Array[String] = []
  if !pre.is_empty() {
    parts.push(", \"preInterceptors\": \"" + pre + "\"")
  }
  if !post.is_empty() {
    parts.push(", \"postInterceptors\": \"" + post + "\"")
  }
  parts.join("")
}

///|
/// start → apply(applicant) → approval(approver) → end（形状照共享夹具 flows/02-multi-task）
fn r91_flow(
  root_pre : String,
  root_post : String,
  apply_pre : String,
  apply_post : String,
  approval_post : String
) -> String {
  let root_seg = r91_root_seg(root_pre, root_post)
  let apply_extra = r91_node_extra(apply_pre, apply_post)
  let approval_extra = r91_node_extra("", approval_post)
  // 多行 `$|` 串直接当返回体会吃 deprecated_syntax 警告（本栈纪律＝零新增警告）⇒ 先 let 绑名再返回
  let flow =
  $|{"name": "r91", "displayName": "R91", "type": "approval"\{root_seg},
  $|"nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
  $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0\{apply_extra}}},
  $|  {"id": "approval", "type": "snaker:task", "text": {"value": "审批"},
  $|   "properties": {"assignee": "approver", "taskType": 0, "performType": 0\{approval_extra}}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|],
  $|"edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "approval"},
  $|  {"id": "e3", "sourceNodeId": "approval", "targetNodeId": "end"}
  $|]}
  flow
}

///|
/// ⑧ 专用夹具：根级两把键与 apply 的两把键**都写成空串**（根级空串逐字照共享夹具
/// `flows/10-mixed-mode.json:6-7` 的形状；节点级空串那半是本档额外补的，夹具里没有节点级空串样本）
const R91_EMPTY_DECL_FLOW : String =
  $|{"name": "r91-empty", "displayName": "R91E", "type": "approval",
  $| "preInterceptors": "", "postInterceptors": "",
  $| "nodes": [
  $|  {"id": "start", "type": "snaker:start", "text": {"value": "S"}},
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "发起申请"},
  $|   "properties": {"assignee": "applicant", "taskType": 0, "performType": 0,
  $|                "preInterceptors": "", "postInterceptors": ""}},
  $|  {"id": "approval", "type": "snaker:task", "text": {"value": "审批"},
  $|   "properties": {"assignee": "approver", "taskType": 0, "performType": 0}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $| ],
  $| "edges": [
  $|  {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
  $|  {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "approval"},
  $|  {"id": "e3", "sourceNodeId": "approval", "targetNodeId": "end"}
  $| ]}

///|
/// 打标拦截器：跑一次往 sink 追加一枚 label（Array 是引用语义 ⇒ 造它的那一档能看见自己那份）。
/// 经 `@spi.async_of_sync` 桥 ⇒ 夹具闭包不写 `async`／`raise` 标注，不新增 unused_async／
/// unused_error_type 警告（同包 `register_*_sync` 便捷口就是这个套路，见 `core/spi/context.mbt:369`）。
fn r91_itc(
  order : Int,
  label : String,
  sink : Array[String]
) -> @spi.InterceptorFn {
  let run = @spi.async_of_sync(fn(_exec) {
    sink.push(label)
  })
  { order: order, run: run }
}

///|
/// 命名拦截器全集（各档按需少给——少给本身就是判据：查不到必须抛）
fn r91_named_all(
  sink : Array[String]
) -> Array[(String, @spi.InterceptorFn)] {
  [
    (R91_ROOT_PRE, r91_itc(10, "root-pre", sink)),
    (R91_ROOT_POST, r91_itc(10, "root-post", sink)),
    (R91_APPLY_PRE, r91_itc(10, "apply-pre", sink)),
    (R91_APPLY_POST, r91_itc(10, "apply-post", sink)),
    (R91_APPROVAL_POST, r91_itc(10, "approval-post", sink)),
    (R91_SLOW, r91_itc(20, "slow", sink)),
    (R91_FAST, r91_itc(10, "fast", sink)),
  ]
}

///|
/// pre／post＝引擎级注册列表（两档都没声明时的回落面）；named＝按名注册表（声明档要的实体，
/// 键＝java 类全名串）。⚠ 两档同时注册是本案的形状：宿主既挂了全局拦截器、又按名给了实体。
fn r91_engine(
  pre : Array[@spi.InterceptorFn],
  post : Array[@spi.InterceptorFn],
  named : Array[(String, @spi.InterceptorFn)]
) -> (
  @engine.Engine[@mem.MemoryRepository, @mem.MemoryRepository],
  @mem.MemoryRepository,
) {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() }).with_user_provider_sync(compliance_user_provider)
  for i in pre {
    ctx2.register_pre_interceptor(i)
  }
  for i in post {
    ctx2.register_interceptor(i)
  }
  for kv in named {
    let (k, v) = kv
    ctx2.register_named_interceptor(k, v)
  }
  (@engine.Engine::make(ctx2), repo)
}

///|
async fn r91_task_of(
  repo : @mem.MemoryRepository,
  iid : Int64,
  node_name : String
) -> @model.ProcessTask raise @error.JeeflowError {
  for t in repo.find_doing_tasks(iid, []) {
    if t.task_name == node_name {
      return t
    }
  }
  raise @error.Business("前置条件：待办里没有节点 " + node_name)
}

///|
async test "r91 ① 节点声明优先：不叠根声明、也不叠引擎级列表" {
  let sink : Array[String] = []
  let flow = r91_flow(R91_ROOT_PRE, R91_ROOT_POST, R91_APPLY_PRE, R91_APPLY_POST, "")
  let (engine, repo) = r91_engine(
    [r91_itc(10, "eng-pre", sink)],
    [r91_itc(10, "eng-post", sink)],
    r91_named_all(sink),
  )
  let did = save_flow_define(repo, "r91-1", flow)
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  // 建单那一刻只该有 apply 自己声明的那一条前置（根声明与引擎级列表都不参与）
  assert_eq(sink.join(">"), "apply-pre")
  let ta = r91_task_of(repo, inst.instance_id, "apply")
  let _ = engine.execute_task_async(ta.task_id, "applicant", @json.FlowData::new())
  // 办结 apply＝apply-post（节点档）；再进 approval，它没声明 pre ⇒ 落根档
  assert_eq(sink.join(">"), "apply-pre>apply-post>root-pre")
}

///|
async test "r91 ② 节点只声明 pre ⇒ post 落根档（两档各取各串、互不串档）" {
  let sink : Array[String] = []
  let flow = r91_flow(R91_ROOT_PRE, R91_ROOT_POST, R91_APPLY_PRE, "", "")
  let (engine, repo) = r91_engine([], [], r91_named_all(sink))
  let did = save_flow_define(repo, "r91-2", flow)
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  assert_eq(sink.join(">"), "apply-pre")
  let ta = r91_task_of(repo, inst.instance_id, "apply")
  let _ = engine.execute_task_async(ta.task_id, "applicant", @json.FlowData::new())
  assert_eq(sink.join(">"), "apply-pre>root-post>root-pre")
}

///|
async test "r91 ③ 根级 preInterceptors 被解析并派发（改前 pre 只读引擎级数组）" {
  let sink : Array[String] = []
  let flow = r91_flow(R91_ROOT_PRE, "", "", "", "")
  let (engine, repo) = r91_engine(
    [r91_itc(10, "eng-pre", sink)],
    [],
    r91_named_all(sink),
  )
  let did = save_flow_define(repo, "r91-3", flow)
  let _ = engine.start_async(did, "applicant", @json.FlowData::new())
  // 根级 pre 声明存在 ⇒ 走声明档，引擎级列表整体让位（不是"两条都跑"）
  assert_eq(sink.join(">"), "root-pre")
}

///|
async test "r91 ④ 同档多名按 order 升序，与声明串里的先后无关" {
  let sink : Array[String] = []
  // 声明串故意写成 SLOW,FAST（与 order 反序）⇒ 只有真按 order 排才出 fast>slow
  let flow = r91_flow("", "", "", R91_SLOW + "," + R91_FAST, "")
  let (engine, repo) = r91_engine([], [], r91_named_all(sink))
  let did = save_flow_define(repo, "r91-4", flow)
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let ta = r91_task_of(repo, inst.instance_id, "apply")
  let _ = engine.execute_task_async(ta.task_id, "applicant", @json.FlowData::new())
  assert_eq(sink.join(">"), "fast>slow")
}

///|
async test "r91 ⑤ 声明名查不到 ⇒ pre／post 两档各显式抛，文案带档位＋类名＋nodeId" {
  let sink : Array[String] = []
  // ⑤a pre 档：发起那一刻就该抛（apply 建单前 fire pre）
  let (engine_a, repo_a) = r91_engine([], [], [])
  let did_a = save_flow_define(repo_a, "r91-5a", r91_flow("", "", R91_GHOST, "", ""))
  let raised_pre = try {
    let _ = engine_a.start_async(did_a, "applicant", @json.FlowData::new())
    None
  } catch {
    e => Some(e)
  }
  // ⚠ 成功路径的 fail 必须在 try 外面（同包 compliance2_test.mbt:308 那条纪律）
  match raised_pre {
    None => fail("pre 档声明未注册名必须抛，不得静默跳过")
    Some(e) => assert_true(
      e.message() == "preInterceptors 声明的拦截器未注册: " + R91_GHOST + "（nodeId=apply）",
    )
  }
  // ⑤b post 档：办结 apply 时才抛（post 只在建单之后的那一步才 fire）
  let (engine_b, repo_b) = r91_engine(
    [],
    [],
    [(R91_APPLY_PRE, r91_itc(10, "apply-pre", sink))],
  )
  let did_b = save_flow_define(
    repo_b,
    "r91-5b",
    r91_flow("", "", R91_APPLY_PRE, R91_GHOST, ""),
  )
  let inst_b = engine_b.start_async(did_b, "applicant", @json.FlowData::new())
  let tb = r91_task_of(repo_b, inst_b.instance_id, "apply")
  let raised_post = try {
    let _ = engine_b.execute_task_async(tb.task_id, "applicant", @json.FlowData::new())
    None
  } catch {
    e => Some(e)
  }
  match raised_post {
    None => fail("post 档声明未注册名必须抛，不得静默跳过")
    Some(e) => assert_true(
      e.message() == "postInterceptors 声明的拦截器未注册: " + R91_GHOST + "（nodeId=apply）",
    )
  }
  // 前置腿真跑过、后置那条没实体 ⇒ sink 只有一枚（防"抛错前一条也没执行"那种自证式判据）
  assert_eq(sink.join(">"), "apply-pre")
}

///|
async test "r91 ⑥ 两节点各取各串（防按档位记串、不看节点）" {
  let sink : Array[String] = []
  let flow = r91_flow("", "", R91_APPLY_PRE, R91_APPLY_POST, R91_APPROVAL_POST)
  let (engine, repo) = r91_engine([], [], r91_named_all(sink))
  let did = save_flow_define(repo, "r91-6", flow)
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let ta = r91_task_of(repo, inst.instance_id, "apply")
  let _ = engine.execute_task_async(ta.task_id, "applicant", @json.FlowData::new())
  // 前置断言：令牌确实推进到了 approval（csharp 那轮的坑＝断言挂在没执行的步骤上）
  let tb = r91_task_of(repo, inst.instance_id, "approval")
  assert_eq(sink.join(">"), "apply-pre>apply-post")
  let _ = engine.execute_task_async(tb.task_id, "approver", @json.FlowData::new())
  // approval 的 post 取自己节点那串；end 没声明、也没有任何回落档 ⇒ 不追加
  assert_eq(sink.join(">"), "apply-pre>apply-post>approval-post")
}

///|
async test "r91 ⑦ 回归哨兵：两档都没声明 ⇒ 引擎级注册列表照旧派发" {
  let sink : Array[String] = []
  let flow = r91_flow("", "", "", "", "")
  let (engine, repo) = r91_engine(
    [r91_itc(10, "eng-pre", sink)],
    [r91_itc(20, "eng-post-2", sink), r91_itc(10, "eng-post-1", sink)],
    [],
  )
  let did = save_flow_define(repo, "r91-7", flow)
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  // pre 通道＝引擎级 pre 列表；后置列表不参与建单那一步
  assert_eq(sink.join(">"), "eng-pre")
  let ta = r91_task_of(repo, inst.instance_id, "apply")
  let _ = engine.execute_task_async(ta.task_id, "applicant", @json.FlowData::new())
  // 办结 apply＝引擎级 post 列表（按 order 升序）＋再进 approval 的引擎级 pre
  assert_eq(sink.join(">"), "eng-pre>eng-post-1>eng-post-2>eng-pre")
}

///|
async test "r91 ⑧ 空串声明＝没声明：不得绕开引擎级列表" {
  let sink : Array[String] = []
  let (engine, repo) = r91_engine(
    [r91_itc(10, "eng-pre", sink)],
    [r91_itc(10, "eng-post", sink)],
    [],
  )
  let did = save_flow_define(repo, "r91-8", R91_EMPTY_DECL_FLOW)
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  // 根级与节点级四把键全是空串 ⇒ 与"没写键"同档（共享夹具 10-mixed-mode 就是那形状）
  assert_eq(sink.join(">"), "eng-pre")
  let ta = r91_task_of(repo, inst.instance_id, "apply")
  let _ = engine.execute_task_async(ta.task_id, "applicant", @json.FlowData::new())
  assert_eq(sink.join(">"), "eng-pre>eng-post>eng-pre")
}
