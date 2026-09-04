// error + id_gen 单测 —— 移植自 rust error.rs / id_gen.rs tests

///|
test "error: code always business" {
  assert_eq((@error.Business("test")).code(), @error.ERR_BUSINESS)
  assert_eq((@error.UnknownAction("x")).code(), @error.ERR_BUSINESS)
  assert_eq((@error.DefineNotFound(1L)).code(), @error.ERR_BUSINESS)
  assert_eq((@error.TaskNotFound(1L)).code(), @error.ERR_BUSINESS)
  assert_eq((@error.PermissionDenied("x")).code(), @error.ERR_BUSINESS)
  assert_eq((@error.Internal("x")).code(), @error.ERR_BUSINESS)
  assert_eq(@error.ERR_BUSINESS, 99999999L)
}

///|
test "error: messages" {
  assert_true((@error.Business("msg")).message().contains("msg"))
  assert_true((@error.UnknownAction("test/act")).message().contains("test/act"))
  assert_true((@error.DefineNotFound(42L)).message().contains("42"))
  assert_true((@error.TaskNotFound(99L)).message().contains("99"))
  assert_true((@error.InvalidSubmitType(99L)).message().contains("99"))
  assert_true((@error.ParseError("bad json")).message().contains("bad json"))
  assert_true((@error.Business("未知 action")).message() == "未知 action")
}

///|
test "id_gen: atomic counter" {
  let gen = @id_gen.AtomicIdGenerator::new(100L)
  assert_eq(gen.next_id(), 100L)
  assert_eq(gen.next_id(), 101L)
  assert_eq(gen.next_id(), 102L)
}

///|
test "id_gen: snowflake monotonic + unique" {
  let gen = @id_gen.DefaultIdGenerator::new(1L)
  let id1 = gen.next_id()
  let id2 = gen.next_id()
  assert_true(id1 > 0L)
  assert_true(id2 > id1)
  let seen : Map[Int64, Unit] = Map::new()
  for _ in 0..<500 {
    let id = gen.next_id()
    assert_true(seen.get(id) is None)
    seen[id] = ()
  }
}
