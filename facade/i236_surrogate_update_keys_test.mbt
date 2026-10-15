// issues/236（audit8 R68）moon 侧两档判据：
// ① 委托 update 的四腿缺键＝清空（spec06 §4.5 缺键档；基准＝java `applySurrogateFields` 无条件覆盖。
//    旧形状＝`processName`/`surrogate` 保留＋窗与 enabled 清空＝八栈里的混合第三形）；
// ② 布尔折算 `enabled=true` ⇒ 1（spec06 §4.5 条款 5；旧形状 `Json::True` 落到 as_i64⇒None 再落
//    字符串档 parse 失败 ⇒ 0，等于把「启用」读成「停用」，java 同病灶、本轮一并改）。
// 两档都只走公开门面 action（本包测试件是独立 test 包，够不到源包的非 pub 项）。

///|
fn i236_enabled(d : Json) -> Int64 {
  match d {
    Json::Object(m) =>
      match m.get("enabled") {
        Some(v) =>
          match @json.as_i64(v) {
            Some(n) => n
            None => -99L
          }
        None => -98L
      }
    _ => -97L
  }
}

///|
fn i236_blank(d : Json, key : String) -> Bool {
  // 条文规定 null／空串／键缺失三形等价（读侧兜底判 IS NULL OR = ''），都算「已清空」
  match @json.get_str(d, key) {
    None => true
    Some(v) => v.trim(chars=" \t\r\n").is_empty()
  }
}

///|
async test "236 缺键档：只带 id 的 update 清空流程名与被委托人、enabled 复位 1、operator 保留" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let facade = sg_facade(repo)
  let saved = facade.flow(
    "processSurrogate/save",
    targs([
      ("operator", "leader236"),
      ("surrogate", "li236"),
      ("processName", "i236-clear"),
      ("startTime", "2026-08-01 00:00:00"),
      ("endTime", "2026-08-31 23:59:59"),
      ("enabled", "0"),
    ]),
  )
  sg_ok(code_of(saved) == 0L, "预置 save 应成功（msg=\{msg_of(saved)}）")
  let sg_id = @json.get_str(data_of(saved), "id").unwrap_or("0")

  // 基线（阳性对照）：改之前四腿必须真有值——键名或形状猜错时这里就红，不许让后面的断言空转
  let before = data_of(facade.flow("processSurrogate/detail", targs([("id", sg_id)])))
  sg_ok(
    @json.get_str(before, "processName") == Some("i236-clear"),
    "基线：detail 应能读到 process_name=i236-clear，实得 \{@json.get_str(before, "processName").unwrap_or("(缺)")}",
  )
  sg_ok(i236_enabled(before) == 0L, "基线：enabled 应为 0，实得 \{i236_enabled(before)}")

  let upd = facade.flow("processSurrogate/update", targs([("id", sg_id)]))
  sg_ok(code_of(upd) == 0L, "只带 id 的 update 应成功（msg=\{msg_of(upd)}）")
  let d = data_of(facade.flow("processSurrogate/detail", targs([("id", sg_id)])))

  sg_ok(
    i236_blank(d, "processName"),
    "缺 processName ⇒ 应清空，实得 \{@json.get_str(d, "processName").unwrap_or("(缺)")}",
  )
  sg_ok(i236_blank(d, "surrogate"), "缺 surrogate ⇒ 应清空，实得 \{@json.get_str(d, "surrogate").unwrap_or("(缺)")}")
  sg_ok(
    @json.get_str(d, "operator") == Some("leader236"),
    "operator 专例：缺省必须保留原授权人，实得 \{@json.get_str(d, "operator").unwrap_or("(缺)")}",
  )
  sg_ok(i236_enabled(d) == 1L, "缺 enabled ⇒ 复位 1（java enabledArg==null⇒1 同形），实得 \{i236_enabled(d)}")
}

///|
async test "236 布尔档：enabled=true 落 1、false 落 0（true 被折成 0＝把启用读成停用）" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer { @model.set_clock(None) }
  let repo = @mem.MemoryRepository::new()
  let facade = sg_facade(repo)
  let saved = facade.flow(
    "processSurrogate/save",
    targs([("operator", "leader236b"), ("surrogate", "li236b"), ("processName", "i236-bool"), ("enabled", "0")]),
  )
  sg_ok(code_of(saved) == 0L, "预置 save 应成功（msg=\{msg_of(saved)}）")
  let sg_id = @json.get_str(data_of(saved), "id").unwrap_or("0")

  let on_args : Map[String, Json] = Map([("id", Json::string(sg_id)), ("enabled", @json.bool_of(true))])
  let on = facade.flow("processSurrogate/update", on_args)
  sg_ok(code_of(on) == 0L, "布尔 enabled=true 应接受（msg=\{msg_of(on)}）")
  let d_on = data_of(facade.flow("processSurrogate/detail", targs([("id", sg_id)])))
  sg_ok(i236_enabled(d_on) == 1L, "布尔 true ⇒ 1，实得 \{i236_enabled(d_on)}（旧形状此处落 0）")

  let off_args : Map[String, Json] = Map([("id", Json::string(sg_id)), ("enabled", @json.bool_of(false))])
  let off = facade.flow("processSurrogate/update", off_args)
  sg_ok(code_of(off) == 0L, "布尔 enabled=false 应接受（msg=\{msg_of(off)}）")
  let d_off = data_of(facade.flow("processSurrogate/detail", targs([("id", sg_id)])))
  sg_ok(i236_enabled(d_off) == 0L, "布尔 false ⇒ 0，实得 \{i236_enabled(d_off)}")

  // 回归：字符串数字档不受布尔支影响
  let back = facade.flow("processSurrogate/update", targs([("id", sg_id), ("enabled", "1")]))
  sg_ok(code_of(back) == 0L, "字符串 \"1\" 档应接受")
  let d_back = data_of(facade.flow("processSurrogate/detail", targs([("id", sg_id)])))
  sg_ok(i236_enabled(d_back) == 1L, "字符串 \"1\" ⇒ 1，实得 \{i236_enabled(d_back)}")
}
