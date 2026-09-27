///|
test "query: parse m_ params two-segment" {
  let args : Map[String, Json] = Map([])
  args["m_LIKE_name"] = @json.string_of("t1-like-target")
  let filters = @query.parse_m_params(args)
  assert_eq(filters.length(), 1)
  assert_eq(filters[0].table_alias(), "t")
  assert_eq(filters[0].column(), "name")
  assert_true(filters[0].op() is Like)
  assert_eq(filters[0].value(), "t1-like-target")
}

///|
test "query: parse m_ params three-segment alias + camel to snake" {
  let args : Map[String, Json] = Map([])
  args["m_pd_EQ_state"] = @json.string_of("1")
  args["m_EQ_taskName"] = @json.string_of("apply")
  args["m_empty"] = @json.string_of("")
  args["other_key"] = @json.string_of("x")
  let filters = @query.parse_m_params(args)
  assert_eq(filters.length(), 2)
}

///|
test "query: build where like" {
  let filters = [@model.QueryFilter::make("pd", @model.Like, "name", "abc")]
  let (where_sql, params) = @query.build_m_where(filters)
  assert_true(where_sql.contains("pd.name LIKE ?"))
  assert_eq(params.length(), 1)
}

///|
/// issues/129 案 A 第二层（SQL 侧兜底）：归属谓词列的**空值**不再走「空即丢条件」的
/// 通用放行，而是塌成 `AND 1=0`（空页）。断言的是纯函数的 SQL 片段 + 绑定值个数，
/// 不连 MySQL（T0 档）；同判据的真机对拍归 T1 smoke。
test "i129-L2 ownership blank EQ collapses to 1=0 with no bind param" {
  let args : Map[String, Json] = Map([])
  args["m_EQ_operator"] = @json.string_of("")
  let filters = @query.parse_m_params(args)
  // 改前这里被 is_empty_value 整条丢掉 ⇒ 「这条条件不加」= 读全库
  assert_eq(filters.length(), 1)
  assert_eq(filters[0].column(), "operator")
  assert_eq(filters[0].table_alias(), "t")
  let (where_sql, params) = @query.build_m_where(filters)
  assert_true(where_sql.contains(" AND 1=0"))
  // 占位符与绑定值必须同数（多 bind / 少 bind 会在 execute 期才炸）
  assert_eq(params.length(), 0)
}

///|
/// 四条归属列逐格钉：t.operator / pi.operator / ta.actor_id / cc.actor_id
/// （java OWNERSHIP_COLUMNS 同四列，别名按本栈写法）
test "i129-L2 four ownership columns all collapse to 1=0" {
  let keys : Array[String] = [
    "m_EQ_operator",
    "m_pi_EQ_operator",
    "m_ta_EQ_actorId",
    "m_cc_EQ_actorId",
  ]
  for key in keys {
    let args : Map[String, Json] = Map([])
    args[key] = @json.string_of("")
    let filters = @query.parse_m_params(args)
    assert_eq(filters.length(), 1)
    let (where_sql, params) = @query.build_m_where(filters)
    assert_true(where_sql.contains(" AND 1=0"))
    assert_eq(params.length(), 0)
  }
}

///|
/// 全空白归属值同档（`"   "` 过不了 is_empty_value，只能靠 trim 判据兜住）
test "i129-L2 whitespace-only ownership value collapses too" {
  let filters = [@model.QueryFilter::make("pi", @model.Eq, "operator", "   ")]
  let (where_sql, params) = @query.build_m_where(filters)
  assert_true(where_sql.contains(" AND 1=0"))
  assert_eq(params.length(), 0)
}

///|
/// 哨兵（案 A 明写「不许动通用放行」）：非归属列的空值仍按「没填」忽略；
/// 归属列拿到**非空**值仍正常拼 EQ —— 防把兜底写成「归属列一律空页」。
test "i129-L2 sentinel: generic blank skip and non-blank ownership intact" {
  let args : Map[String, Json] = Map([])
  args["m_LIKE_displayName"] = @json.string_of("")
  args["m_EQ_name"] = @json.string_of("")
  args["m_EQ_state"] = @json.null_json()
  let filters = @query.parse_m_params(args)
  assert_eq(filters.length(), 0)
  let (where_sql, params) = @query.build_m_where(filters)
  assert_eq(where_sql, "")
  assert_eq(params.length(), 0)
  let args2 : Map[String, Json] = Map([])
  args2["m_EQ_operator"] = @json.string_of("user1")
  let filters2 = @query.parse_m_params(args2)
  let (where2, params2) = @query.build_m_where(filters2)
  assert_true(where2.contains("t.operator = ?"))
  assert_eq(params2.length(), 1)
}
