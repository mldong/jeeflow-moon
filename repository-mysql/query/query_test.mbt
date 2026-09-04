///|
test "query: parse m_ params two-segment" {
  let args : Map[String, Json] = Map::new()
  args["m_LIKE_name"] = @json.string_of("t1-like-target")
  let filters = @query.parse_m_params(args)
  assert_eq(filters.length(), 1)
  assert_eq(filters[0].alias(), "t")
  assert_eq(filters[0].column(), "name")
  assert_true(filters[0].op() is Like)
  assert_eq(filters[0].value(), "t1-like-target")
}

///|
test "query: parse m_ params three-segment alias + camel to snake" {
  let args : Map[String, Json] = Map::new()
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
