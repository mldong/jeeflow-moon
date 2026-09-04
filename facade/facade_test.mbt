// facade 出口纪律测试（C1/C2/C5/C7/C22）+ persist ARCHIVE/SYNC

///|
test "outbound: stringify ids recursive incl plural arrays (C1)" {
  let input = @json.parse_json(
    "{\"id\":1000,\"processInstanceId\":1001,\"taskIds\":[2001,2002],\"child\":{\"recordId\":3001},\"name\":\"x\",\"count\":5}",
  )
  let out = @facade.stringify_ids(input)
  assert_eq(@json.get_str(out, "id").unwrap(), "1000")
  assert_eq(@json.get_str(out, "processInstanceId").unwrap(), "1001")
  match out.value("taskIds") {
    Some(Json::Array(arr)) => {
      assert_eq(arr.length(), 2)
      assert_eq(@json.as_str(arr[0]).unwrap(), "2001")
      assert_eq(@json.as_str(arr[1]).unwrap(), "2002")
    }
    _ => assert_true(false)
  }
  assert_eq(@json.get_str(out.value("child").unwrap(), "recordId").unwrap(), "3001")
  // 非id键不受影响
  assert_eq(@json.get_i64(out, "count").unwrap(), 5L)
  assert_eq(@json.get_str(out, "name").unwrap(), "x")
}

///|
test "outbound: null id stays null" {
  let input = @json.parse_json("{\"id\":null,\"other\":1}")
  let out = @facade.stringify_ids(input)
  assert_true(out.value("id").unwrap() is Json::Null)
}

///|
test "outbound: camelCase + opaque keys (C1 嵌套保留)" {
  let input = @json.parse_json(
    "{\"task_name\":\"a\",\"process_define_id\":10,\"ext\":{\"u_realName\":\"张三\",\"PERMISSION_f_note\":2},\"create_time\":\"2026-08-01T10:00:00\"}",
  )
  let out = @facade.transform_output(input)
  assert_eq(@json.get_str(out, "taskName").unwrap(), "a")
  assert_eq(@json.get_str(out, "processDefineId").unwrap(), "10")
  // 时间 T → 空格（C7）
  assert_eq(@json.get_str(out, "createTime").unwrap(), "2026-08-01 10:00:00")
  // opaque 嵌套键保留原样
  let ext = out.value("ext").unwrap()
  assert_true(@json.get_str(ext, "u_realName") is Some(_))
  assert_true(@json.get_i64(ext, "PERMISSION_f_note") is Some(_))
}

///|
test "outbound: envelope ok/error (信封)" {
  let ok_env = @facade.ok_data(@json.empty_object())
  assert_eq(@json.get_i64(ok_env, "code").unwrap(), 0L)
  assert_eq(@json.get_str(ok_env, "msg").unwrap(), "成功")
  let err_env = @facade.err("任务不存在")
  assert_eq(@json.get_i64(err_env, "code").unwrap(), 99999999L)
  assert_eq(@json.get_str(err_env, "msg").unwrap(), "任务不存在")
}

///|
test "args: dual string/number id (C2) + 非法id报错 (C3)" {
  let args : Map[String, Json] = Map::new()
  args["id"] = @json.string_of("1000")
  assert_eq(@facade.arg_i64(args, "id").unwrap(), 1000L)
  args["id"] = @json.number_of(1001L)
  assert_eq(@facade.arg_i64(args, "id").unwrap(), 1001L)
  args["id"] = @json.string_of("not-a-number")
  let outcome : Result[Int64?, @error.JeeflowError] = try? @facade.arg_i64(args, "id")
  assert_true(outcome is Err(_))
}

///|
test "args: ids/id dual + empty explicit error (C15)" {
  let args : Map[String, Json] = Map::new()
  args["ids"] = @json.array_of([@json.string_of("1"), @json.number_of(2L)])
  assert_true(@facade.arg_ids(args) == [1L, 2L])
  let single : Map[String, Json] = Map::new()
  single["id"] = @json.number_of(7L)
  assert_true(@facade.arg_ids(single) == [7L])
  let empty : Map[String, Json] = Map::new()
  let outcome : Result[Array[Int64], @error.JeeflowError] = try? @facade.arg_ids(empty)
  match outcome {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e.message(), "id 缺失或非法")
  }
}

///|
test "args: actorIds array or comma string" {
  let args : Map[String, Json] = Map::new()
  args["actorIds"] = @json.array_of([@json.string_of("u1"), @json.number_of(2L)])
  assert_true(@facade.arg_actor_ids(args) == ["u1", "2"])
  let args2 : Map[String, Json] = Map::new()
  args2["actorIds"] = @json.string_of(" u1 , u2 ")
  assert_true(@facade.arg_actor_ids(args2) == ["u1", "u2"])
}

///|
test "m_ params: facade filters (rust 同款 op 前缀)" {
  let args : Map[String, Json] = Map::new()
  args["m_LIKE_name"] = @json.string_of("审批")
  args["m_pd_EQ_state"] = @json.string_of("1")
  let filters = @facade.facade_parse_m_filters(args)
  assert_eq(filters.length(), 2)
}

