// issues/126 案 A · 求值器档位单测（model 包，同步 test；引擎级写点用例见 core/engine/expire_time_test.mbt）。
//
// 这一档在本栈是**从零移植**（普查 §1.5：moon 全仓一句到期求值都没有），所以判点逐字照
// 启动词 §1.5 的"逐字语义"与三个易错点写：
//   ① 落穿（变量存在但类型不认识）不能当"解析失败"提前 NULL   → e6
//   ② 变量档优先于相对档（args 里真有个键叫 "2h" 时取变量值） → e7
//   ③ 解析失败返回 NULL，绝不退回 now()（那正是本案病灶的形状）→ e5 / e9
// 另外把"天档必须日历加、不乘 86400"（e3）与"严格 19 位 + 日历校验"（e11）钉住——
// 后面所有写点格子的"同一行 expire − create ≈ 偏移"判据都建立在这两档之上。
//
// ⚠️ 只新增断言，没动任何既有断言的期望值——唯一例外是 i126-e3 里 `-1d` 那一格，
// 它按 issues/137 D（owner 2026-10-01 拍「判非负」）翻面，并在同一格里用正数补回覆盖。

///|
fn et_args(entries : Array[(String, Json)]) -> @json.FlowData {
  let a = @json.FlowData::new()
  for (k, v) in entries {
    a.insert(k, v)
  }
  a
}

///|
fn et_empty() -> @json.FlowData {
  @json.FlowData::new()
}

///|
/// 注入本栈那把**唯一的**钟（clock.mbt `current_time_str()`）。
/// 到期求值的相对档必须以它为基准（见 expire_time.mbt `expire_now_secs` 那段），
/// 注入之后"偏移"才是可比对的精确值；defer 复位，不留给别的用例。
fn et_clock(s : String) -> Unit {
  @model.set_clock(Some(fn() { s }))
}

///|
fn et_define() -> @model.ProcessDefine {
  {
    id: 1L,
    name: "et-flow",
    display_name: "到期时间求值",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
}

///|
/// 期望 NULL 这一列（**不许**退化成"只判非空"：非空但等于 now 正是病灶）
fn et_none(got : String?, label : String) -> Unit {
  match got {
    None => ()
    Some(v) => abort("\{label}：本该留 NULL，实得 \{v}")
  }
}

///|
fn et_eq(got : String?, want : String, label : String) -> Unit raise {
  match got {
    Some(v) => assert_eq(v, want)
    None => abort("\{label}：本该是 \{want}，实得 NULL")
  }
}

///|
test "i126-e1 未配三态（None / 空串 / 纯空白）⇒ 一律 NULL，不造默认值" {
  et_clock("2026-09-28 10:00:00")
  defer { @model.set_clock(None) }
  // 变量池里放一个"就叫 2h 的键"，万一实现把空表达式也丢进求值，当场就会被算出值
  let a = et_args([("2h", @json.string_of("2030-01-01 00:00:00"))])
  et_none(@model.process_time(None, a), "expr=None")
  et_none(@model.process_time(Some(""), a), "expr=空串")
  et_none(@model.process_time(Some("   "), a), "expr=纯空白")
}

///|
test "i126-e2 相对档四单位 ⇒ 以注入钟为基准加偏移（含跨午夜 25h）" {
  et_clock("2026-09-28 10:00:00")
  defer { @model.set_clock(None) }
  let a = et_empty()
  et_eq(@model.process_time(Some("45s"), a), "2026-09-28 10:00:45", "45s")
  et_eq(@model.process_time(Some("30m"), a), "2026-09-28 10:30:00", "30m")
  et_eq(@model.process_time(Some("2h"), a), "2026-09-28 12:00:00", "2h")
  et_eq(@model.process_time(Some("1d"), a), "2026-09-29 10:00:00", "1d")
  et_eq(@model.process_time(Some("25h"), a), "2026-09-29 11:00:00", "25h 跨午夜")
}

///|
test "i126-e3 天档走**日历加天**（月末/跨年/闰年/正向跨月大档），不是乘 86400；负档 ⇒ NULL" {
  defer { @model.set_clock(None) }
  et_clock("2026-01-31 23:00:00")
  et_eq(@model.process_time(Some("1d"), et_empty()), "2026-02-01 23:00:00", "月末进位")
  et_clock("2026-12-31 00:00:01")
  et_eq(@model.process_time(Some("1d"), et_empty()), "2027-01-01 00:00:01", "跨年")
  et_clock("2028-02-28 12:00:00")
  et_eq(@model.process_time(Some("1d"), et_empty()), "2028-02-29 12:00:00", "闰年 2/29 存在")
  et_clock("2026-03-01 12:00:00")
  // issues/137 D owner 2026-10-01 拍判非负：原断 `-1d` 回拨跨月生效＝放行负偏移，本格按裁定翻面
  // （负前缀算「解析不出来」⇒ 落穿绝对档 ⇒ NULL；放行即新建行当场已逾期，正是 issues/126 病灶形状）
  et_none(
    @model.process_time(Some("-1d"), et_empty()),
    "负数天档（原「回拨跨月」格）：判非负后必须 NULL",
  )
  // 翻面后这一格不再走 add_days 倒退，原由它承担的跨月历日算术用**正数**补回同等覆盖：
  // 同一条 Feb/Mar 边界（正向进位）+ 跨月大档 + 跨年大档
  et_clock("2026-02-28 12:00:00")
  et_eq(@model.process_time(Some("1d"), et_empty()), "2026-03-01 12:00:00", "正向进位跨月 Feb→Mar")
  et_clock("2026-01-01 12:00:00")
  et_eq(@model.process_time(Some("31d"), et_empty()), "2026-02-01 12:00:00", "跨月大档（Jan→Feb）")
  et_clock("2026-12-15 08:00:00")
  et_eq(@model.process_time(Some("20d"), et_empty()), "2027-01-04 08:00:00", "跨年大档（Dec→Jan）")
  et_clock("2026-09-28 10:00:00")
  et_eq(@model.process_time(Some("30d"), et_empty()), "2026-10-28 10:00:00", "进月")
}

///|
test "i126-e4 变量档：日期串与毫秒时间戳都取该时刻（钟故意拨在别处）" {
  et_clock("2026-09-28 10:00:00")
  defer { @model.set_clock(None) }
  let due_ms = @model.parse_time_secs("2030-05-06 07:08:09").unwrap_or(0L) * 1000L
  let a = et_args([
    ("deadline", @json.string_of("2030-05-06 07:08:09")),
    ("dueMs", @json.number_of(due_ms)),
  ])
  et_eq(@model.process_time(Some("deadline"), a), "2030-05-06 07:08:09", "变量档-日期串")
  et_eq(@model.process_time(Some("dueMs"), a), "2030-05-06 07:08:09", "变量档-毫秒时间戳")
}

///|
test "i126-e5 变量档字符串解析不出 ⇒ 终局 NULL，**不落穿**（键名故意叫 2h）" {
  et_clock("2026-09-28 10:00:00")
  defer { @model.set_clock(None) }
  // 若实现把"值是字符串但解析失败"当落穿，相对档会给出 12:00:00 —— 这一格当场分辨两种写法
  let a = et_args([("2h", @json.string_of("not-a-date"))])
  et_none(@model.process_time(Some("2h"), a), "变量档字符串解析失败必须终局 NULL")
}

///|
test "i126-e6 落穿：变量值是 bool/object/array/JSON null/非整数数值 ⇒ 继续走相对档" {
  et_clock("2026-09-28 10:00:00")
  defer { @model.set_clock(None) }
  let a = et_args([
    ("2h", @json.bool_of(true)),
    ("3h", @json.empty_object()),
    ("4h", @json.array_of([@json.string_of("x")])),
    ("5h", @json.null_json()),
    ("6h", @json.number_f_of(1.5)),
  ])
  et_eq(@model.process_time(Some("2h"), a), "2026-09-28 12:00:00", "bool 落穿")
  et_eq(@model.process_time(Some("3h"), a), "2026-09-28 13:00:00", "object 落穿")
  et_eq(@model.process_time(Some("4h"), a), "2026-09-28 14:00:00", "array 落穿")
  et_eq(@model.process_time(Some("5h"), a), "2026-09-28 15:00:00", "JSON null 落穿")
  et_eq(@model.process_time(Some("6h"), a), "2026-09-28 16:00:00", "非整数数值落穿（Java 的 Double 档）")
}

///|
test "i126-e7 变量档**优先于**相对档：args 里真有个键叫 2h 时取变量值" {
  et_clock("2026-09-28 10:00:00")
  defer { @model.set_clock(None) }
  let a = et_args([("2h", @json.string_of("2027-03-04 05:06:07"))])
  et_eq(@model.process_time(Some("2h"), a), "2027-03-04 05:06:07", "变量档压过相对档")
}

///|
test "i126-e8 绝对档：表达式本身是日期串 ⇒ 该时刻，与钟无关" {
  et_clock("2020-01-01 00:00:00")
  defer { @model.set_clock(None) }
  et_eq(
    @model.process_time(Some("2031-03-04 05:06:07"), et_empty()),
    "2031-03-04 05:06:07",
    "绝对档",
  )
}

///|
test "i126-e9 解析不出 ⇒ NULL 而不是 now（含误配 xh 的落穿口径 §1.9-3）" {
  et_clock("2026-09-28 10:00:00")
  defer { @model.set_clock(None) }
  let a = et_empty()
  let cases : Array[(String, String)] = [
    ("not-a-time", "纯垃圾串"),
    ("xh", "相对档前缀不是整数：Java 抛异常打断建单，本案按 C# 落穿→NULL"),
    ("2h30m", "双单位串"),
    ("2031-03-04", "缺时分秒"),
    ("2031-02-30 00:00:00", "日历上不存在的日子"),
    ("2031-13-01 00:00:00", "月份越界"),
    ("2031-03-04 25:00:00", "小时越界"),
  ]
  for (expr, why) in cases {
    match @model.process_time(Some(expr), a) {
      None => ()
      Some(v) => abort("\{why}（expr=\{expr}）本该 NULL，实得 \{v}——退化成 now 就是本案病灶")
    }
  }
}

///|
test "i126-e10 apply_expire_time：未配不动这一列，算不出也只留 NULL，配了才写" {
  et_clock("2026-09-28 10:00:00")
  defer { @model.set_clock(None) }
  let inst = @model.ProcessInstance::create(et_define(), "user1", et_empty())
  let t = inst.create_task("approve", "审批", ["u"], "user1", @model.Major, @model.Normal, None, None)
  et_none(t.expire_time, "create_task 本身不该赋这一列")
  @model.apply_expire_time(t, None, et_empty())
  et_none(t.expire_time, "expr=None")
  @model.apply_expire_time(t, Some(""), et_empty())
  et_none(t.expire_time, "expr=空串")
  @model.apply_expire_time(t, Some("   "), et_empty())
  et_none(t.expire_time, "expr=纯空白")
  @model.apply_expire_time(t, Some("xh"), et_empty())
  et_none(t.expire_time, "expr=解析不出")
  @model.apply_expire_time(t, Some("2h"), et_empty())
  et_eq(t.expire_time, "2026-09-28 12:00:00", "expr=2h")
}

///|
test "i126-e11 parse_time_secs 与 format_unix_utc 互逆 + 严格拒绝（差值判据的量纲地基）" {
  for s in ["1970-01-01 00:00:00", "2000-02-29 12:34:56", "2026-09-28 10:00:00", "2038-01-19 03:14:07"] {
    let secs = match @model.parse_time_secs(s) {
      Some(v) => v
      None => abort("该收下的日期串被拒了：" + s)
    }
    assert_eq(@model.format_unix_utc(secs), s)
  }
  for s in [
    "2026-9-28 10:00:00",
    "2026-09-2810:00:00",
    "2026-09-28 10:00",
    "2026-09-31 00:00:00",
    "2025-02-29 00:00:00",
    "2026-09-28T10:00:00",
  ] {
    match @model.parse_time_secs(s) {
      None => ()
      Some(v) => abort("该拒的串被收下了：" + s + " -> " + @model.format_unix_utc(v))
    }
  }
}

///|
/// issues/137 D（owner 2026-10-01 拍「判非负」；基准＝jeeflow-java `1649955`
/// `ExpireTimeOnCreateTest.negativeRelativeExpressionStaysNull` ＋ spec/04「相对档前缀须非负整数」）：
/// 四档（s/m/h/d）负前缀一律算「解析不出来」⇒ 落穿绝对档 ⇒ 仍失败就 NULL，任何一档都不许退回当前
/// 时间——放行 `-5h` 会算出**过去**的时刻 ⇒ 新建行当场即逾期，比"没配到期时间"更难发现。
/// 正向对照钉 `+2h`/`+45s`：只裁负、**不裁加号**（python `[+-]?`／node `[-+]?\d+`／php
/// `[+-]?\d{1,18}` 都收 '+'，裁加号等于新造一处跨栈分叉），顺带钉变量档／绝对档／issues/137 C
/// 的坏前缀落穿档**都没被波及**（判负点在相对档前缀解析，毫秒变量档走 parse_int64_strict 不在路上）。
test "i137d1 负数相对档四单位 ⇒ NULL 落穿；加号档/变量档/绝对档/坏前缀档不变" {
  et_clock("2026-09-28 10:00:00")
  defer { @model.set_clock(None) }
  let a = et_empty()
  // ① 负数四档：逐档钉（本栈四档共用同一处判负，一处裁完，无旁路）
  for (expr, why) in [
    ("-5h", "负数时档"),
    ("-5d", "负数天档（日历加天会倒退）"),
    ("-30s", "负数秒档"),
    ("-10m", "负数分档"),
  ] {
    et_none(@model.process_time(Some(expr), a), why + "（expr=" + expr + "）")
  }
  // ② 正向对照：加号档仍算得出 ⇒ 上面四判不是「带符号一律拒」的恒真
  et_eq(@model.process_time(Some("+2h"), a), "2026-09-28 12:00:00", "+2h 加号档仍合法")
  et_eq(@model.process_time(Some("+45s"), a), "2026-09-28 10:00:45", "+45s 加号秒档")
  et_eq(@model.process_time(Some("2h"), a), "2026-09-28 12:00:00", "2h 不变")
  et_eq(@model.process_time(Some("2d"), a), "2026-09-30 10:00:00", "2d 不变")
  et_eq(
    @model.process_time(Some("-0s"), a),
    "2026-09-28 10:00:00",
    "-0s 不算负数：同 java `Integer.parseInt(\"-0\") == 0`，放行",
  )
  // ③ 变量档 / 绝对档不变
  let v = et_args([("dueAt", @json.string_of("2026-12-31 10:00:00"))])
  et_eq(@model.process_time(Some("dueAt"), v), "2026-12-31 10:00:00", "变量档不变")
  et_eq(
    @model.process_time(Some("2026-12-31 10:00:00"), a),
    "2026-12-31 10:00:00",
    "绝对档不变",
  )
  // ④ 坏前缀行为不变（issues/137 C 的落穿口径不因本次判负而漂）
  et_none(@model.process_time(Some("xh"), a), "坏前缀 xh 照旧落穿 ⇒ NULL")
  et_none(@model.process_time(Some("2.5h"), a), "小数前缀照旧落穿 ⇒ NULL")
}
