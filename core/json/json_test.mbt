// json 薄壳 + FlowData 单测 —— 移植自 rust json.rs tests

///|
test "json: parse simple object" {
  let val = @json.parse_json("{\"name\":\"test\",\"value\":42,\"flag\":true,\"nothing\":null}")
  assert_eq(@json.get_str(val, "name").unwrap(), "test")
  assert_eq(@json.get_i64(val, "value").unwrap(), 42L)
  let flag = @json.get(val, "flag").unwrap()
  assert_eq(@json.as_bool(flag).unwrap(), true)
  let nothing = @json.get(val, "nothing").unwrap()
  assert_true(@json.as_bool(nothing) is None)
}

///|
test "json: parse nested" {
  let val = @json.parse_json("{\"a\":{\"b\":\"c\"},\"d\":[1,2,3]}")
  let a = @json.get(val, "a").unwrap()
  assert_eq(@json.get_str(a, "b").unwrap(), "c")
  let d = @json.get(val, "d").unwrap()
  match d {
    Json::Array(arr) => assert_eq(arr.length(), 3)
    _ => assert_true(false)
  }
}

///|
test "json: roundtrip" {
  let val = @json.parse_json("{\"name\":\"test\",\"items\":[1,\"two\",null,true]}")
  let serialized = @json.stringify(val)
  let reparsed = @json.parse_json(serialized)
  assert_true(val == reparsed)
}

///|
test "json: invalid json raises" {
  assert_true((try? @json.parse_json("{invalid}")) is Err(_))
  assert_true((try? @json.parse_json("[1,2,")) is Err(_))
}

///|
test "json: empty input to null" {
  let val = @json.parse_json("   ")
  assert_true(val is Json::Null)
}

///|
test "json: utf8 chinese roundtrip" {
  let val = @json.parse_json("{\"value\":\"上级审批\"}")
  assert_eq(@json.get_str(val, "value").unwrap(), "上级审批")
}

///|
test "json: as_i64 dual number/string (C3)" {
  assert_eq(@json.as_i64(@json.number_f_of(42.0)).unwrap(), 42L)
  assert_eq(@json.as_i64(@json.string_of("42")).unwrap(), 42L)
  assert_true(@json.as_i64(@json.string_of("not a number")) is None)
  assert_true(@json.as_i64(@json.null_json()) is None)
}

///|
test "flowdata: insert/get/merge/prefix" {
  let fd = @json.FlowData::new()
  fd.insert_str("f_name", "张三")
  fd.insert_i64("f_amount", 1000L)
  fd.insert_str("operator", "user1")
  assert_eq(fd.get_str("f_name").unwrap(), "张三")
  assert_eq(fd.get_i64_or("f_amount", 0L), 1000L)
  assert_eq(fd.get_str_or("missing", "def"), "def")
  assert_true(fd.contains_key("operator"))
  assert_true(!fd.contains_key("missing"))
  assert_eq(fd.keys_with_prefix("f_").length(), 2)
  let fd2 = @json.FlowData::new()
  fd2.insert_str("b", "2")
  fd.merge(fd2)
  assert_eq(fd.get_str("b").unwrap(), "2")
  let removed = fd.remove("operator")
  assert_true(removed is Some(_))
  assert_true(!fd.contains_key("operator"))
  let obj = fd.to_object_json()
  let str = @json.stringify(obj)
  assert_true(str.contains("张三"))
}

///|
test "json: big-int id precision — >2^53 字面量走 repr 精确解析（D-M5-3 线上取整事故回归）" {
  // 2096086641704706050 不可被 double 精确表示（最近 double 是 …048）；
  // 修复前 as_i64 走 double 分量 → "任务不存在: …048"
  let big = @json.parse_json("{\"processTaskId\":2096086641704706050}")
  assert_eq(@json.get_i64(big, "processTaskId").unwrap(), 2096086641704706050L)
  // 小整数 / 字符串双收行为不变
  assert_eq(@json.get_i64(@json.parse_json("{\"n\":42}"), "n").unwrap(), 42L)
  let as_str = @json.parse_json("{\"id\":\"2096086641704706050\"}")
  assert_eq(@json.get_i64(as_str, "id").unwrap(), 2096086641704706050L)
}
