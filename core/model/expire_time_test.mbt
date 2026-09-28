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
// ⚠️ 只新增断言，没动任何既有断言的期望值。

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
test "i126-e3 天档走**日历加天**（月末/跨年/闰年/回拨），不是乘 86400" {
  defer { @model.set_clock(None) }
  et_clock("2026-01-31 23:00:00")
  et_eq(@model.process_time(Some("1d"), et_empty()), "2026-02-01 23:00:00", "月末进位")
  et_clock("2026-12-31 00:00:01")
  et_eq(@model.process_time(Some("1d"), et_empty()), "2027-01-01 00:00:01", "跨年")
  et_clock("2028-02-28 12:00:00")
  et_eq(@model.process_time(Some("1d"), et_empty()), "2028-02-29 12:00:00", "闰年 2/29 存在")
  et_clock("2026-03-01 12:00:00")
  et_eq(@model.process_time(Some("-1d"), et_empty()), "2026-02-28 12:00:00", "回拨跨月")
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
