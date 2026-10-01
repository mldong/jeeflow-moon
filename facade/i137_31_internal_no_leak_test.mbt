// issues/137 §3-1（spec 06 §2.12）：门面出口**信封腿**——内部档（Internal）的原文不得进对外
// msg，出口只给固定文案 `流程处理失败`（逐字＝java JeeflowFacade.INTERNAL_FAILURE_MSG）；
// 引擎自己写的中文契约文案必须仍逐字透出（判据过宽＝把契约面静默改掉，java 侧这类文案一处
// 测试都没钉，本文件钉住）。判据形状照 java FacadeInternalErrorNoLeakTest。
//
// 驱动腿背景：repository-mysql conn.mbt:36/65/79、tx.mbt:76/90 五条 `Internal("mysql …: 驱动原文")`
// 把原文塞进 Internal 的 message，而 `Internal.message()＝"内部错误: <原文>"` 会经门面 flow()
// 的 catch（改前形状：出口 msg 直接取 e.message()）流进对外 msg——与 rust error.rs:84 同一条
// 通道。真库腿本机跑不了（native 需 cc＋真库），故用 test-only 扩展仓按五条腿的原文形状在
// wasm 档取证。覆盖面② bizData 族：actions_ext.mbt 的 reader catch 旧形状把第三方 provider
// 原文拼进 **Business 契约档**（契约档出口逐字透出⇒出口判别式挡不住，必须在构造点收口，
// java 基准 bizData 只给固定文案「业务数据读取失败」）。
//
// 复用同包 helper：setup / doing_task_for / targs / code_of / msg_of / data_of /
// linear_flow_json / parse_iid / i115f_arr / i115f_call / i115f_remove。不改动任何既有断言。

// ══════════════ test-only 扩展仓：按驱动腿同形状 raise Internal ══════════════

///|
/// page_designs 腿按 repository-mysql 驱动原文形状 raise Internal（payload＝驱动原文），
/// 其余方法平凡实现（本文件只走 processDesign/page 这一条 action）。
pub(all) struct I13731LeakExtRepo {
  payload : String
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn find_design_by_id(_self, _id) {
  None
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn save_design(_self, _d) {
  ()
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn update_design(_self, _d) {
  ()
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn remove_design(_self, _id) {
  ()
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn page_designs(self, _q) {
  raise @error.Internal(self.payload)
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn save_design_his(_self, _h) {
  ()
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn list_design_his(_self, _id) {
  []
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn find_surrogate_by_id(_self, _id) {
  None
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn save_surrogate(_self, _s) {
  ()
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn update_surrogate(_self, _s) {
  ()
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn remove_surrogate(_self, _id) {
  ()
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn page_surrogates(_self, _q) {
  @model.PageResult::new(1L, 20L, 0L, [])
}

///|
pub impl @spi.ProcessExtRepository for I13731LeakExtRepo with fn get_surrogate(_self, _op, _name, _time) {
  None
}

///|
fn i13731_leak_facade(
  payload : String
) -> @facade.Facade[@mem.MemoryRepository, I13731LeakExtRepo] {
  let repo = @mem.MemoryRepository::new()
  let ext : I13731LeakExtRepo = { payload, }
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, ext).with_id_generator(fn() { gen.next_id() })
  @facade.Facade::make(ctx)
}

// ══════════════ 泄漏各形状 ⇒ 出口 msg 逐字＝流程处理失败 ══════════════

///|
/// 驱动错误原文五形（五条驱动腿同文）＋裸包装形：出口 msg 一律逐字固定文案，
/// 原文一个字节不出（改前形状＝`内部错误: <原文>` 直接外透 ⇒ 本格红）。
async test "i137-§3-1 门面出口：Internal 各形原文 ⇒ msg 逐字＝流程处理失败" {
  let payloads = [
    "mysql connect: Access denied for user 'root'@'10.0.0.8' (using password: YES)",
    "mysql query: Table 'jeeflow.wf_process_design' doesn't exist",
    "mysql execute: Deadlock found when trying to get lock; try restarting transaction",
    "tx begin: connection reset by peer",
    "tx commit: MySQL server has gone away",
    "<Error: connection refused>", // 裸包装形：整个下层错误的 to_string 被搬进 message
  ]
  for p in payloads {
    let facade = i13731_leak_facade(p)
    let env = facade.flow(
      "processDesign/page",
      targs([("operator", "user1"), ("pageNum", "1"), ("pageSize", "10")]),
    )
    assert_eq(code_of(env), 99999999L)
    assert_eq(msg_of(env), "流程处理失败")
  }
}

// ══════════════ 覆盖面② bizData 族（第三方 provider 抛的东西） ══════════════

///|
fn i13731_reader_driver(
  _table : String,
  _iid : Int64
) -> Map[String, Json]? raise @error.JeeflowError {
  raise @error.Internal("mysql query: Unknown column 'f_amount' in 'field list'")
}

///|
fn i13731_reader_provider(
  _table : String,
  _iid : Int64
) -> Map[String, Json]? raise @error.JeeflowError {
  raise @error.Business("provider 原文: connection pool exhausted after 30s")
}

///|
/// 正常返回的 reader（正向对照腿）。表名守卫只为把 raise 档真用上——MoonBit 的函数值
/// 不做「不 raise ⇒ 可当 raise 型传」的子类型折算（实测 4014），而空挂 raise 注解会吃
/// unused_error_type 警告（零新增警告是发版门票）；测试现场 table 恒为流程 name，臂不可达。
fn i13731_reader_ok(
  table : String,
  _iid : Int64
) -> Map[String, Json]? raise @error.JeeflowError {
  if table.is_empty() {
    raise @error.Business("i13731: 空表名不该到这里")
  }
  Some(Map([("f_amount", @json.string_of("42"))]))
}

///|
/// bizData 现场：内存仓＋真实发起通道＋注册 reader（relTableName 缺省回落流程 name，
/// 与 setup 同一姿势，只是多挂 with_biz_data_reader）
async fn i13731_biz_setup(
  reader : (String, Int64) -> Map[String, Json]? raise @error.JeeflowError
) -> (@facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], Int64) raise {
  let repo = @mem.MemoryRepository::new()
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, repo).with_biz_data_reader(reader).with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i13731-biz",
    display_name: "bizData 泄漏腿流程",
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
    targs([("processDefineId", define_info.id.to_string()), ("operator", "applicant")]),
  )
  assert_eq(msg_of(env), "成功")
  let iid = @json.get_str(data_of(env), "processInstanceId").unwrap_or("0")
  (facade, parse_iid(iid))
}

///|
/// 驱动原文／第三方 provider 原文 ⇒ msg 逐字＝「业务数据读取失败」（java 基准同文），
/// 原文一个字节不出（改前形状＝`业务数据读取失败: <原文>` 拼接外透 ⇒ 本格红）。
async test "i137-§3-1 bizData 族：reader 抛的原文不得拼进契约档 msg" {
  let (f1, iid1) = i13731_biz_setup(i13731_reader_driver)
  let env1 = f1.flow(
    "processInstance/bizData",
    targs([("processInstanceId", iid1.to_string()), ("operator", "user1")]),
  )
  assert_eq(code_of(env1), 99999999L)
  assert_eq(msg_of(env1), "业务数据读取失败")
  let (f2, iid2) = i13731_biz_setup(i13731_reader_provider)
  let env2 = f2.flow(
    "processInstance/bizData",
    targs([("processInstanceId", iid2.to_string()), ("operator", "user1")]),
  )
  assert_eq(code_of(env2), 99999999L)
  assert_eq(msg_of(env2), "业务数据读取失败")
}

///|
/// 正向对照（判据不恒真）：reader 正常返回 ⇒ code 0 照常出 data
async test "i137-§3-1 bizData 正向对照：reader 正常返回 ⇒ code 0" {
  let (f, iid) = i13731_biz_setup(i13731_reader_ok)
  let env = f.flow(
    "processInstance/bizData",
    targs([("processInstanceId", iid.to_string()), ("operator", "user1")]),
  )
  assert_eq(code_of(env), 0L)
}

// ══════════════ 契约面不被误吞（判别式收窄成"一律固定文案"⇒ 本格红） ══════════════

///|
/// 引擎自己写的中文契约文案必须仍逐字透出（spec 06 失败文案表逐字串）。这一组与泄漏组同等
/// 重要：判据过宽会把契约面静默改掉，而 java 侧这类文案一处测试都没钉。
async test "i137-§3-1 契约面：引擎自写中文文案仍逐字透出（判据过宽 ⇒ 本格红）" {
  let (facade, repo, iid) = setup(linear_flow_json())
  let tid = doing_task_for(repo, iid, "leader").task_id
  // 未知 action（UnknownAction 档：回显调用方入参，java 同文）
  let env_unknown = facade.flow("no/such-action", targs([("operator", "user1")]))
  assert_eq(code_of(env_unknown), 99999999L)
  assert_eq(msg_of(env_unknown), "未知 action: no/such-action")
  // operator 必填（removeTaskActor 腿，i115-L 同判据）
  assert_eq(
    msg_of(
      i115f_call(
        facade,
        [
          ("processTaskId", @json.string_of(tid.to_string())),
          ("actorIds", i115f_arr(["leader"])),
        ],
      ),
    ),
    "operator 必填",
  )
  // 任务不存在（不带 id 尾巴的逐字档）
  assert_eq(
    msg_of(i115f_remove(facade, 424242L, i115f_arr(["9001"]), "flow.admin")),
    "任务不存在",
  )
  // 至少需保留一名参与人
  assert_eq(
    msg_of(i115f_remove(facade, tid, i115f_arr(["leader"]), "leader")),
    "至少需保留一名参与人",
  )
  // 任务非进行中，不可摘除参与人（先办结再摘）
  assert_eq(
    msg_of(
      facade.flow(
        "processTask/execute",
        targs([("processTaskId", tid.to_string()), ("operator", "leader"), ("submitType", "1")]),
      ),
    ),
    "成功",
  )
  assert_eq(
    msg_of(i115f_remove(facade, tid, i115f_arr(["leader"]), "flow.admin")),
    "任务非进行中，不可摘除参与人",
  )
  // JSON 解析族（批二既有收口）：ParseErrorWithCause 的契约文案经新判别式仍逐字透出、不被误吞
  let env_deploy = facade.flow(
    "processDefine/deploy",
    targs([("operator", "user1"), ("content", "{ \"name\": \"x\", 这不是合法的 json ")]),
  )
  assert_eq(code_of(env_deploy), 99999999L)
  assert_eq(msg_of(env_deploy), "读取流程定义 JSON 失败")
}
