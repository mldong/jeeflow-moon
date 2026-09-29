// issues/138 ccList 行形状三要件（spec 06-facade.md §processInstance/ccList，基准＝boot2 内置版）。
//
// 病灶：内存仓把 cc.actor_id 投成 operator ⇒ 在**被抄送人自己的查询**里那一列恒等于他自己，
// 「operator 非空」这类判据永远照不出来。本栈 i129 那一格（operator_blank_test.mbt:201）的夹具
// 恰好 发起人＝被抄送人＝user1，两码事在它上面同形 ⇒ 照不出本案；已发布的 issues/108 那格更是
// 把错法 ① 直接写成了断言（本轮随修） 。这里按 PHP 同案的做法把种子用户做成**三方各异**，
// 再把值对到具体那一方：投 cc.actor_id 会撞上"等于查询者"，投 cc.create_user 会撞上"等于抄送发起人"。
//
// 本栈的格子（四个 async test）：
//   要件 1  行来自实例表 ⇒ 主键键名 `id` 且值＝实例 id（不是 cc 行 id）
//   要件 2  带 `operator` 键
//   要件 3  `operator` 的值＝流程发起人，且 ≠ 查询者本人、≠ 抄送发起人
//   形状    「rows 同 processInstance/page 行结构」⇒ ccList 行与实例行逐键相等
//   谓词    归属仍按 `cc.actor_id` 过滤（修 operator 不许顺手把谓词挪到发起人那一列，另设诱饵单）
//
// MySQL 腿的行为本机跑不了（T1 需要真库），它的守门格在 repository-mysql/repo/ 同名 i138 文件里
// 守投影 SQL 文本形状 —— 同一次改动，两支各守一边。

///|
fn i138_check(cond : Bool, label : String) -> Unit {
  if !cond {
    println("[i138-ccList 行形状] 红样：" + "\{label}")
    abort("[i138-ccList 行形状] 红样：" + "\{label}")
  }
}

///|
fn i138_facade(
  repo : @mem.MemoryRepository
) -> @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository] {
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, repo).with_id_generator(fn() { gen.next_id() })
  @facade.Facade::make(ctx)
}

///|
/// 夹具（三方各异 + 诱饵单）：
///   inst_x 发起人 boss   ／ 抄送：hr 发起 → 被抄送人 ccuser（＝查询者）
///   inst_y 发起人 boss2  ／ 抄送：boss2 发起 → 被抄送人 other
///   inst_z 发起人 ccuser ／ 没有任何抄送行  ← 诱饵：归属列若错挪到发起人身上，这行会混进来
///                          且 operator 恰等于查询者，"非空判据"照样看不出
async fn i138_setup() -> (
  @mem.MemoryRepository, @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository], Int64, Int64
) raise {
  let repo = @mem.MemoryRepository::new()
  let facade = i138_facade(repo)
  let define_info : @model.ProcessDefine = {
    id: 0L,
    name: "i138-flow",
    display_name: "i138 行形状夹具",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  repo.save_define(define_info)
  let vars = @json.FlowData::new()
  vars.insert_str("f_reason", "i138-实例变量")
  let inst_x = @model.ProcessInstance::create(define_info, "boss", vars)
  let inst_y = @model.ProcessInstance::create(define_info, "boss2", @json.FlowData::new())
  let inst_z = @model.ProcessInstance::create(define_info, "ccuser", @json.FlowData::new())
  repo.save_instance(inst_x)
  repo.save_instance(inst_y)
  repo.save_instance(inst_z)
  // cc.create_user＝hr（抄送发起人）与 inst_x.operator＝boss（流程发起人）刻意不同人 ⇒ 错法②也能照
  repo.create_cc_instance(inst_x.instance_id, "hr", ["ccuser"])
  repo.create_cc_instance(inst_y.instance_id, "boss2", ["other"])
  (repo, facade, inst_x.instance_id, inst_y.instance_id)
}

///|
/// ccList 出口行（信封 code 必须 0，否则是"报错当空页"假绿）
async fn i138_cc_rows(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  as_who : String
) -> Array[Json] raise {
  let env = facade.flow("processInstance/ccList", targs([("operator", as_who)]))
  let code = code_of(env)
  if code != 0L {
    abort("ccList(\{as_who}) 出口报错：code=\{code} msg=\{msg_of(env)}")
  }
  rows_of(data_of(env))
}

///|
/// 要件 1：行主键键名 `id`、值＝实例 id；把 cc 表原样投出来（主键是 cc 行 id）＝不合格
async test "i138-要件1 ccList 行 id＝实例 id 且≠cc 行 id" {
  let (repo, facade, iid_x, _) = i138_setup()
  let rows = i138_cc_rows(facade, "ccuser")
  i138_check(rows.length() == 1, "ccuser 查到 1 行（实际 \{rows.length()}）")
  let row = rows[0]
  i138_check(@json.get(row, "id") is Some(_), "行上存在键名 id")
  let cc_id = repo.cc_instances[0].id
  i138_check(cc_id != iid_x, "夹具可分辨：cc 行 id(\{cc_id}) ≠ 实例 id(\{iid_x})")
  i138_check(
    ob_cell(row, "id") == iid_x.to_string(),
    "id 的值＝实例 id \{iid_x}（实际 <\{ob_cell(row, "id")}>；旧写法出口的是 cc.id=\{cc_id}）",
  )
}

///|
/// 要件 2 + 3：`operator` 键在，且值对到**流程发起人**那一方 —— 既不是查询者（错法①）也不是抄送发起人（错法②）
async test "i138-要件2+3 operator＝流程发起人而非查询者/抄送发起人" {
  let (_, facade, _, _) = i138_setup()
  let rows = i138_cc_rows(facade, "ccuser")
  i138_check(rows.length() == 1, "ccuser 查到 1 行")
  let row = rows[0]
  let op = ob_cell(row, "operator")
  i138_check(@json.get(row, "operator") is Some(_), "行上存在键名 operator")
  i138_check(op != "<missing>" && !op.is_empty(), "operator 非空（实际 <\{op}>）")
  i138_check(op == "boss", "operator＝流程发起人 boss（实际 <\{op}>）")
  i138_check(op != "ccuser", "operator≠查询者本人 ccuser（投 cc.actor_id 的病灶，非空判据照不出来）")
  i138_check(op != "hr", "operator≠抄送发起人 hr（错法②：cc.create_user 不得占用 operator 键名）")
}

///|
/// 「rows 同 processInstance/page 行结构」：ccList 那一行必须与实例行逐键相等
async test "i138-形状 ccList 行逐键等于 processInstance/page 的实例行" {
  let (_, facade, iid_x, _) = i138_setup()
  let cc_rows = i138_cc_rows(facade, "ccuser")
  i138_check(cc_rows.length() == 1, "ccuser 查到 1 行")
  let env = facade.flow("processInstance/page", targs([("operator", "boss")]))
  i138_check(code_of(env) == 0L, "processInstance/page 出口 code=0（msg=\{msg_of(env)}）")
  let page_rows = rows_of(data_of(env))
  i138_check(
    page_rows.length() == 1 && ob_cell(page_rows[0], "id") == iid_x.to_string(),
    "boss 名下实例恰好 1 行且就是 inst_x（实际 \{page_rows.length()} 行）",
  )
  i138_check(
    cc_rows[0] == page_rows[0],
    "ccList 行与实例行逐键相等（旧写法 state/create_time/ext 全来自 cc 侧，必然不等）",
  )
}

///|
/// 归属谓词不许被顺手挪走：仍按 `cc.actor_id EQ operator` 过滤（spec 06 §2.5 口径表钉死）
async test "i138-谓词 仍按 cc.actor_id 过滤，诱饵单与发起人都不得冒行" {
  let (_, facade, iid_x, iid_y) = i138_setup()
  // boss 发起了 inst_x 但没被抄送；hr 只是发起这次抄送的人 —— 两者查 ccList 都必须是空页
  for who in ["boss", "hr"] {
    let rows = i138_cc_rows(facade, who)
    i138_check(
      rows.length() == 0,
      "\{who} 查 ccList＝空页（实际 \{rows.length()} 行；归属列错挪到 pi.operator 时 boss 会冒 1 行）",
    )
  }
  // 被抄送人 ccuser 自己也发过一单 inst_z（没有任何抄送行）⇒ 诱饵：归属列挪错就会多出一行，
  // 而且那一行的 operator 恰等于查询者本人，"非空判据"照样看不出
  let mine = i138_cc_rows(facade, "ccuser")
  i138_check(
    mine.length() == 1 && ob_cell(mine[0], "id") == iid_x.to_string(),
    "ccuser 只查到抄给自己的 inst_x 一行（实际 \{mine.length()} 行；诱饵单 inst_z 混进来就是归属列错了）",
  )
  let other_rows = i138_cc_rows(facade, "other")
  i138_check(other_rows.length() == 1, "other 查 ccList＝1 行（实际 \{other_rows.length()}）")
  i138_check(ob_cell(other_rows[0], "id") == iid_y.to_string(), "other 那行的 id＝inst_y")
  i138_check(
    ob_cell(other_rows[0], "operator") == "boss2",
    "other 那行的 operator＝inst_y 的发起人 boss2（两方各自的值都对得上，不是常量）",
  )
}
