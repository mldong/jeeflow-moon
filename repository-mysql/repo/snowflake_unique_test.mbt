///|
/// R111 门禁补牙：同进程连续取号必须互异（旧形每次 new 一个生成器 ⇒ 同毫秒同 id）。
test "snowflake singleton returns unique ids" {
  let a = @repo.next_snowflake_id()
  let b = @repo.next_snowflake_id()
  assert_true(a != b)
  let seen : Set[Int64] = Set([], capacity=101)
  for _ in 0..<100 {
    seen.add(@repo.next_snowflake_id())
  }
  assert_eq(seen.length(), 100)
}
