// demo 层时钟偏移解析（JEEFLOW_TZ_OFFSET）的判据：正例三种写法、负例一律 None。
// 负例的意义：解析失败必须**回落 UTC 而不是猜一个区**（issues/120 §9 契约句的可执行形状）。

///|
test "JEEFLOW_TZ_OFFSET 解析：整小时 / 小数小时 / 时:分 / 符号 / 上限" {
  assert_eq(parse_tz_offset_seconds("8"), Some(28800))
  assert_eq(parse_tz_offset_seconds("+8"), Some(28800))
  assert_eq(parse_tz_offset_seconds("-5"), Some(-18000))
  assert_eq(parse_tz_offset_seconds("5.5"), Some(19800))
  assert_eq(parse_tz_offset_seconds("-9.5"), Some(-34200))
  assert_eq(parse_tz_offset_seconds("+05:30"), Some(19800))
  assert_eq(parse_tz_offset_seconds("0"), Some(0))
  assert_eq(parse_tz_offset_seconds("14"), Some(50400))
}

///|
test "JEEFLOW_TZ_OFFSET 非法值一律 None（回落 UTC，不静默猜区）" {
  assert_eq(parse_tz_offset_seconds(""), None)
  assert_eq(parse_tz_offset_seconds("   "), None)
  assert_eq(parse_tz_offset_seconds("abc"), None)
  assert_eq(parse_tz_offset_seconds("20"), None) // 超 UTC+14
  assert_eq(parse_tz_offset_seconds("-20"), None)
  assert_eq(parse_tz_offset_seconds("+05:70"), None) // 分钟越界
  assert_eq(parse_tz_offset_seconds("8:"), None)
  assert_eq(parse_tz_offset_seconds(":30"), None)
  assert_eq(parse_tz_offset_seconds("8:30:00"), None)
  assert_eq(parse_tz_offset_seconds("+"), None)
  assert_eq(parse_tz_offset_seconds("-"), None)
  assert_eq(parse_tz_offset_seconds("1.5.5"), None)
}

///|
test "时钟注入：偏移换算正确，set_clock 注入/复原都生效（固定 epoch，免跨秒抖动）" {
  // 1767225600 = 2026-01-01T00:00:00Z
  let base = 1767225600L
  let utc = @model.format_unix_utc(base)
  let cn = @model.format_unix_utc(base + 28800L)
  assert_eq(utc, "2026-01-01 00:00:00")
  assert_eq(cn, "2026-01-01 08:00:00")
  assert_true(utc != cn) // 两串必须不同，否则这条等于没测
  @model.set_clock(Some(fn() { cn }))
  assert_eq(@model.current_time_str(), cn)
  @model.set_clock(None)
  assert_true(@model.current_time_str() != cn) // 复原回默认臂
}
