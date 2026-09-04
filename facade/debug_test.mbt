///|
test "debug: stringify_ids leaves code untouched" {
  let input = @json.parse_json("{\"code\":0,\"msg\":\"成功\",\"pageNum\":1}")
  let out = @facade.stringify_ids(input)
  let s = @json.stringify(out)
  println("DEBUG stringify: \{s}")
  assert_eq(@json.get_i64(out, "code").unwrap(), 0L)
  assert_eq(@json.get_i64(out, "pageNum").unwrap(), 1L)
}
