// issues/137 A · 批二 §3-4 moon 腿 —— **真库腿（T1）**：实例级 expire_time 这一列
// 真打进 160 那台 MySQL 的 `wf_process_instance.expire_time DATETIME(3)` 列再读回来，
// 判据一律取**库里的值**（DATE_FORMAT / TIMESTAMPDIFF / IS NULL / COUNT），不信内存聚合副本。
//
// 为什么这一腿有价值：修前的形状是**原串搬运**（`Some(et) => instance.expire_time = Some(et)`），
// 落库绑定点 repository-mysql/repo/repository.mbt:168 `opt_v(instance.expire_time)` 把 "2h"
// 原样塞进 datetime 参数。开发服务器 MySQL 5.7.31 实测 `@@sql_mode` 含 STRICT_TRANS_TABLES ⇒
// 服务端直接拒：
//   ERROR 1292 (22007): Incorrect datetime value: '2h' for column 'expire_time' at row 1
// ⇒ 整条发起 INSERT 失败，比"留 NULL"更糟。内存仓（@mem）对这一列不做类型校验，
// **T0 全绿也照不出这一条**，所以值必须真过一遍 datetime 列。
//
// 运行（隔离库**自建自删**，凭据只走 env，严禁指向 jeeflow / jeeflow_test 等既有库）：
//   mysql -h <H> -uroot -p -e "CREATE DATABASE jeeflow_moon_i137a CHARACTER SET utf8mb4"
//   mysql -h <H> -uroot -p jeeflow_moon_i137a < repository-mysql/schema/schema-mysql.sql
//   JEFFLOW_DB_HOST=<H> JEFFLOW_DB_PORT=3306 JEFFLOW_DB_USER=root JEFFLOW_DB_PWD=... \
//     JEFFLOW_DB_NAME=jeeflow_moon_i137a moon run --target wasm demo/cmd/i137a_mysql
//   mysql -h <H> -uroot -p -e "DROP DATABASE jeeflow_moon_i137a"
// SKIP_MYSQL=1 跳过（开发机口径；发版机连不上=fail 不是 skip，见 MAINTAINING.md §2 T1）。
// 数据纪律（R6）：id 全落 991xxx 段 + 测前测后自清理；只写本文件建的 define/实例行。
//
// 钟：@model.set_clock 钉在 2026-10-01 10:00:00 ⇒ 相对档给出**逐字可写死**的时刻，
// 断言不留带宽（"expire 非空"这种空判在这条腿上没牙——占位 now() 也"非空"）。

///|
fn skip_mysql() -> Bool {
  @env.get_env_var("SKIP_MYSQL") is Some("1")
}

///|
/// 值对比断言（真机对拍没有第二次机会靠猜定位 ⇒ 实得值必须打出来）
fn check_eq(actual : String, expected : String, label : String) -> Unit {
  if actual == expected {
    println("  PASS \{label} ⇒ 实得 <\{actual}>")
  } else {
    println("  FAIL \{label}")
    println("       实得=<\{actual}> 期望=<\{expected}>")
    abort("i137a-T1 assertion failed: \{label}")
  }
}

///|
/// 夹具：start → apply(发起人) → end 的线性流；root_extra 是**流程 JSON 根上**的片段
/// （`,"expireTime":"2h"` 这种），传 `""` ＝ 根上没这个键。
/// 表达式挂在**定义顶层**，不在节点 properties 里（节点级那一列由 issues/126 的格子守）。
fn i137a_flow(name : String, root_extra : String) -> String {
  let b = StringBuilder()
  b.write_string(
    "{\"name\":\"" + name + "\",\"displayName\":\"i137a flow\"" + root_extra + ",\"type\":\"approval\",\"nodes\":[",
  )
  b.write_string(
    "{\"id\":\"start\",\"type\":\"snaker:start\",\"properties\":{},\"text\":{\"value\":\"S\"}},",
  )
  b.write_string(
    "{\"id\":\"apply\",\"type\":\"snaker:task\",\"properties\":{\"assignee\":\"applicant\"},\"text\":{\"value\":\"A\"}},",
  )
  b.write_string(
    "{\"id\":\"end\",\"type\":\"snaker:end\",\"properties\":{},\"text\":{\"value\":\"E\"}}],\"edges\":[",
  )
  b.write_string(
    "{\"id\":\"e1\",\"sourceNodeId\":\"start\",\"targetNodeId\":\"apply\",\"properties\":{}},",
  )
  b.write_string(
    "{\"id\":\"e2\",\"sourceNodeId\":\"apply\",\"targetNodeId\":\"end\",\"properties\":{}}]}",
  )
  b.to_string()
}

///|
/// 991xxx 段自清理（子行先删，否则按主键段反查扫不到）
async fn clean_991(repo : @repo.MysqlRepository) -> Unit raise {
  let conn = repo.open_raw()
  let _ = @repo.q(
    conn,
    "DELETE FROM wf_process_task_actor WHERE process_task_id IN (SELECT id FROM wf_process_task WHERE process_instance_id IN (SELECT id FROM wf_process_instance WHERE process_define_id >= 991000 AND process_define_id < 992000))",
    [],
  )
  let _ = @repo.q(
    conn,
    "DELETE FROM wf_process_cc_instance WHERE process_instance_id IN (SELECT id FROM wf_process_instance WHERE process_define_id >= 991000 AND process_define_id < 992000)",
    [],
  )
  let _ = @repo.q(
    conn,
    "DELETE FROM wf_process_task WHERE process_instance_id IN (SELECT id FROM wf_process_instance WHERE process_define_id >= 991000 AND process_define_id < 992000)",
    [],
  )
  let _ = @repo.q(
    conn,
    "DELETE FROM wf_process_instance WHERE process_define_id >= 991000 AND process_define_id < 992000",
    [],
  )
  let _ = @repo.q(conn, "DELETE FROM wf_process_define WHERE id >= 991000 AND id < 992000", [])
  @repo.close_conn(conn)
}

///|
async fn save_define(repo : @repo.MysqlRepository, id : Int64, content : String) -> Unit raise {
  let name = "i137a_\{id}"
  let conn = repo.open_raw()
  let _ = @repo.x(
    conn,
    // create_time 绑字面量而非 NOW()：issues/120 口径（SQL 侧不许出现 NOW()，全站一把钟）
    "INSERT INTO wf_process_define (id, name, display_name, type, state, content, version, create_time, create_user) VALUES (?, ?, ?, 'approval', 1, ?, 1, ?, 'i137a')",
    [
      @moondb.Int64(id), @moondb.Text(name), @moondb.Text(name), @moondb.Text(content),
      @moondb.Text("2026-10-01 09:00:00"),
    ],
  )
  @repo.close_conn(conn)
}

///|
/// 用户信息 provider（real_name = userId = operator）：判据 2 的 `u_realName` 档靠它
let i137a_user_provider : (String) -> @model.UserInfo? raise @error.JeeflowError =
  (uid) =>
    Some(
      @model.UserInfo::make(
        user_id=uid,
        real_name=uid,
        dept_id="dept1",
        dept_name="TestDept",
        post_id="post1",
        post_name="TestPost",
      )
    )

///|
/// 引擎 + 真机 MySQL 仓储。id 计数器 991500 起，**全流程共用一枚**（每格新造引擎会把
/// 计数器复位 ⇒ 实例主键撞车，这是本腿第一个要防的自伤）。
fn make_engine(repo : @repo.MysqlRepository) -> @engine.Engine[@repo.MysqlRepository, @spi.NoExtRepository] {
  let ctx = @spi.Ctx::new(repo, @spi.NoExtRepository::new())
  let counter : Ref[Int64] = Ref(991500L)
  let ctx2 = ctx.with_id_generator(fn() {
    let v = counter.val
    counter.val = v + 1L
    v
  }).with_user_provider(i137a_user_provider)
  @engine.Engine::make(ctx2)
}

// ── 库里读回助手（"行不存在"与"这一列为 NULL"分开断）──

///|
fn cell(r : @moondb.Row, col : String) -> String {
  match r.by_name(col) {
    None => "<无此列>"
    Some(v) =>
      match v {
        @moondb.Null => "<NULL>"
        @moondb.Text(s) => s
        @moondb.Blob(b) => @utf8.decode_lossy(b[:])
        @moondb.Int64(n) => n.to_string()
        @moondb.Int(n) => n.to_string()
        @moondb.Double(d) => d.to_string()
        @moondb.Bool(b) => if b { "1" } else { "0" }
      }
  }
}

///|
async fn sel_v(
  repo : @repo.MysqlRepository,
  sql : String,
  params : Array[@moondb.Value]
) -> String raise {
  let conn = repo.open_raw()
  let rows = @repo.q(conn, sql, params)
  @repo.close_conn(conn)
  if rows.is_empty() { "<无行>" } else { cell(rows[0], "v") }
}

///|
/// 实例行数（先证明"这一行真落库了"，否则下面任何"这一列是 NULL"都恒真）
async fn inst_count(repo : @repo.MysqlRepository, iid : Int64) -> String raise {
  sel_v(
    repo, "SELECT CAST(COUNT(*) AS CHAR) AS v FROM wf_process_instance WHERE id = ?",
    [@moondb.Int64(iid)],
  )
}

///|
/// 这一列的**服务端 datetime 读数**（走 datetime 语义，不是原样吐字节）
async fn expire_of(repo : @repo.MysqlRepository, iid : Int64) -> String raise {
  sel_v(
    repo,
    "SELECT IFNULL(DATE_FORMAT(expire_time, '%Y-%m-%d %H:%i:%s'), '<NULL>') AS v FROM wf_process_instance WHERE id = ?",
    [@moondb.Int64(iid)],
  )
}

///|
/// 这一列**原样**读数（CAST AS CHAR，不经 DATE_FORMAT）：万一哪天列型被放宽成字符串档，
/// 这一格仍能一眼看出列上躺的是表达式原串还是时刻串
async fn expire_raw_of(repo : @repo.MysqlRepository, iid : Int64) -> String raise {
  sel_v(
    repo,
    "SELECT IFNULL(CAST(expire_time AS CHAR), '<NULL>') AS v FROM wf_process_instance WHERE id = ?",
    [@moondb.Int64(iid)],
  )
}

///|
/// 服务端算术读数：expire − create 的秒差（判"真求出了那一刻"，不信字符串回声）
async fn delta_of(repo : @repo.MysqlRepository, iid : Int64) -> String raise {
  sel_v(
    repo,
    "SELECT IFNULL(CAST(TIMESTAMPDIFF(SECOND, create_time, expire_time) AS CHAR), '<NULL>') AS v FROM wf_process_instance WHERE id = ?",
    [@moondb.Int64(iid)],
  )
}

///|
/// 值档格子（判据 1/2）：行必须存在、这一列必须**正好等于** expect
async fn value_case(
  repo : @repo.MysqlRepository,
  engine : @engine.Engine[@repo.MysqlRepository, @spi.NoExtRepository],
  did : Int64,
  root_extra : String,
  arg_key : String,
  arg_val : String,
  operator : String,
  expect : String,
  label : String
) -> Int64 raise {
  save_define(repo, did, i137a_flow("i137a_\{did}", root_extra))
  let args = @json.FlowData::new()
  if arg_key == "" {
    ()
  } else {
    args.insert_str(arg_key, arg_val)
  }
  let inst = engine.start_async(did, operator, args)
  let iid = inst.instance_id
  check_eq(inst_count(repo, iid), "1", "\{label}｜实例行落库")
  check_eq(expire_of(repo, iid), expect, "\{label}｜库里 expire_time（datetime 读数）")
  // 原样 CAST AS CHAR 读数带 DATETIME(3) 的毫秒位（实测 "2026-10-01 12:00:00.000"）：
  // 这一格证明的是"服务端把它当成 datetime 值收下了"，而不是把 '2h' 这样的原串存成了字符串
  check_eq(
    expire_raw_of(repo, iid), expect + ".000", "\{label}｜同列原样读数（CAST AS CHAR，DATETIME(3) 带 .000）"
  )
  iid
}

///|
/// 空档格子（判据 3/4）：三件事分开断——①行在 ②create_time 有值 ③这一列正好是 NULL
async fn null_case(
  repo : @repo.MysqlRepository,
  engine : @engine.Engine[@repo.MysqlRepository, @spi.NoExtRepository],
  did : Int64,
  root_extra : String,
  label : String
) -> Unit raise {
  save_define(repo, did, i137a_flow("i137a_\{did}", root_extra))
  let inst = engine.start_async(did, "applicant", @json.FlowData::new())
  let iid = inst.instance_id
  check_eq(inst_count(repo, iid), "1", "\{label}｜实例行落库")
  let ct = sel_v(
    repo,
    "SELECT IFNULL(DATE_FORMAT(create_time, '%Y-%m-%d %H:%i:%s'), '<NULL>') AS v FROM wf_process_instance WHERE id = ?",
    [@moondb.Int64(iid)],
  )
  check_eq(ct, "2026-10-01 10:00:00", "\{label}｜create_time 有值（对照，排除'根本没建行'）")
  check_eq(expire_of(repo, iid), "<NULL>", "\{label}｜这一列必须 NULL")
  check_eq(expire_raw_of(repo, iid), "<NULL>", "\{label}｜原样读数也是 NULL（不是空串/空白）")
}

///|
/// 库名必须是**显式指定的隔离库**：`MysqlConfig::from_env()` 的兜底库名是 `jeeflow`（160 上与
/// 其它栈共享的库），本腿开头就有 clean_991 的 DELETE ⇒ 少了这条守卫，漏配 env 的一次运行会
/// 直接往共享库里删 991xxx 段。红线（工单原文）："只允许用自建自删的隔离库，严禁清 160 上的
/// jeeflow_test／jeeflow 库" ⇒ 这里 fail 得越早越好，不 connect、不 delete。
fn require_isolated_db() -> Unit {
  // 本栈 wasm 档的 abort(msg) 只打 "RuntimeError: unreachable" + 栈，**消息原文不上屏**（实测），
  // 所以判点原因一律先 println 再 abort，否则读者只看到一个匿名 unreachable。
  match @env.get_env_var("JEFFLOW_DB_NAME") {
    None => {
      println(
        "JEFFLOW_DB_NAME 未设置：本腿会 DELETE，只允许指向自建隔离库（如 jeeflow_moon_i137a），拒绝跑在兜底库 jeeflow 上",
      )
      abort("i137a-T1 拒绝运行：JEFFLOW_DB_NAME 未设置")
    }
    Some(db) =>
      if db == "jeeflow" || db == "jeeflow_test" || db == "mldong" || db == "mldong-plus" {
        println("JEFFLOW_DB_NAME=\{db} 是共享/业务库，本腿只允许自建隔离库")
        abort("i137a-T1 拒绝运行：库名 \{db} 不是隔离库")
      } else {
        println("目标库 = \{db}（自建隔离库）")
      }
  }
}

///|
async fn i137a_t1() -> Unit raise {
  require_isolated_db()
  @model.set_clock(Some(fn() {
    "2026-10-01 10:00:00"
  }))
  let repo = @repo.MysqlRepository::from_env()
  let engine = make_engine(repo)
  clean_991(repo)

  println("── 判据1：写进去的是求值结果，不是表达式原串 ─────────────────────────")
  // 修前这一格在真库上是硬错：'2h' 进 datetime 列 ⇒ ERROR 1292 (22007)，整条发起 INSERT 失败
  let iid_2h = value_case(
    repo, engine, 991001L, ",\"expireTime\":\"2h\"", "", "", "applicant",
    "2026-10-01 12:00:00", "判据1 相对档 2h",
  )
  // 服务端算术：expire − create 恰好 7200s（占位 now() 给 0；搬原串则这格压根存不进去）
  check_eq(delta_of(repo, iid_2h), "7200", "判据1｜服务端 TIMESTAMPDIFF(expire-create)=7200")

  println("── 判据1 续：其余档位同样进得了 datetime 列 ────────────────────────")
  let _e_45m = value_case(
    repo, engine, 991002L, ",\"expireTime\":\"45m\"", "", "", "applicant",
    "2026-10-01 10:45:00", "判据1 相对档 45m",
  )
  // d 档走**日历加天**（本栈 add_days，不乘 86400）：10-01 + 3d ⇒ 10-04 同一时刻
  let _e_3d = value_case(
    repo, engine, 991003L, ",\"expireTime\":\"3d\"", "", "", "applicant",
    "2026-10-04 10:00:00", "判据1 相对档 3d（日历加天）",
  )
  let _e_abs = value_case(
    repo, engine, 991015L, ",\"expireTime\":\"2031-03-04 05:06:07\"", "", "", "applicant",
    "2031-03-04 05:06:07", "判据1 绝对档",
  )

  println("── 判据2：求值的 args＝发起参数（已注入用户信息 + autoGenTitle 那份）──")
  // ① 表达式＝发起时提交的变量名 ⇒ 取该变量的值
  let _e_var = value_case(
    repo, engine, 991004L, ",\"expireTime\":\"dueAt\"", "dueAt", "2030-05-06 07:08:09",
    "applicant", "2030-05-06 07:08:09", "判据2① 发起提交的变量 dueAt",
  )
  // ② 表达式＝u_realName ⇒ 这个键只在 add_user_info **注入之后**那份 args 里存在
  //    （provider 把 real_name 做成 == operator，故 operator 取成一个合法时刻串）。
  //    实现若误传"未经注入的原始 args"，这一档落穿 ⇒ 真库列是 NULL ⇒ 本格红。
  let _e_u = value_case(
    repo, engine, 991005L, ",\"expireTime\":\"u_realName\"", "", "", "2030-05-06 07:08:09",
    "2030-05-06 07:08:09", "判据2② 已注入用户信息的那份 args",
  )

  println("── 判据3：定义没配顶层 expireTime ⇒ 该列 NULL ──────────────────────")
  null_case(repo, engine, 991006L, "", "判据3 根上缺 expireTime 键")
  null_case(repo, engine, 991007L, ",\"expireTime\":null", "判据3 配成 JSON null")
  null_case(repo, engine, 991008L, ",\"expireTime\":\"\"", "判据3 配成空串")
  // 纯空白这一格在真库上另有一层意义：`opt_v(Some("   "))` 会绑 Text("   ") ⇒
  // STRICT_TRANS_TABLES 下同样是 1292 Incorrect datetime value ⇒ 赋空串/赋空白都不是 NULL
  null_case(repo, engine, 991009L, ",\"expireTime\":\"   \"", "判据3 配成纯空白")

  println("── 判据4：配了但算不出 ⇒ NULL，不兜底 now ─────────────────────────")
  for (did, expr, why) in [
    (991010L, "-5h", "§3-2 判非负：负前缀算解析不出来 ⇒ 落穿"),
    (991011L, "not-a-time", "三档全不命中"),
    (991012L, "2h ", "§3-3 分界②：单位符判定用未 trim 的原串末位"),
    (991016L, "xh", "相对档前缀非整数 ⇒ 落穿绝对档 ⇒ 失败"),
    (991017L, "2031-02-30 00:00:00", "严格日历校验不过（宽松档会滚到 3 月）"),
    (991018L, "2031-03-04", "长度不够 19 ⇒ 落穿"),
  ] {
    null_case(repo, engine, did, ",\"expireTime\":\"\{expr}\"", "判据4 算不出 \{why}")
  }

  println("── 判据5：水合读回与真库列同一把尺子（不新造第二把）────────────────")
  let row = match repo.find_instance_by_id(iid_2h) {
    Some(i) => i
    None => abort("判据5：仓储读回没有这一行")
  }
  check_eq(row.expire_time.unwrap_or("<NULL>"), "2026-10-01 12:00:00", "判据5｜MysqlRepository 水合值")
  let ruler = @model.process_time(Some("2h"), row.variables)
  check_eq(
    row.expire_time.unwrap_or("<NULL>"), ruler.unwrap_or("<NULL>"),
    "判据5｜逐字 == @model.process_time 的输出",
  )

  println("── 第二处写点：start_with_parent_async（子流程发起腿）同形整改 ──────")
  let child = engine.start_with_parent_async(991001L, "user1", @json.FlowData::new(), 991999L, "sub")
  check_eq(inst_count(repo, child.instance_id), "1", "写点二｜子流程实例行落库")
  check_eq(
    expire_of(repo, child.instance_id), "2026-10-01 12:00:00",
    "写点二｜配 2h ⇒ 与主发起同一把尺子、同一个值",
  )
  check_eq(delta_of(repo, child.instance_id), "7200", "写点二｜服务端 TIMESTAMPDIFF=7200")
  let child2 = engine.start_with_parent_async(991006L, "user1", @json.FlowData::new(), 991998L, "sub")
  check_eq(
    expire_of(repo, child2.instance_id), "<NULL>", "写点二｜未配 ⇒ NULL（别只修主发起那一处）",
  )
  let child3 = engine.start_with_parent_async(991010L, "user1", @json.FlowData::new(), 991997L, "sub")
  check_eq(expire_of(repo, child3.instance_id), "<NULL>", "写点二｜负档落穿 ⇒ NULL，不兜底 now")

  clean_991(repo)
  @model.set_clock(None)
  println("i137a T1 真库腿 ALL PASS (wasm → 160:3306)")
}

///|
async fn run() -> Unit raise {
  if skip_mysql() {
    println("SKIP_MYSQL=1 → i137a 真库腿 skipped（开发机口径；发版机连不上=fail）")
    return
  }
  i137a_t1()
}

///|
fn main {
  @async.run_async_main(run)
}
