
///|
test "unknown_edge_warning carries from/to" {
  let s = @engine.unknown_edge_warning("node-a", "node-b")
  assert_true(s.contains("from=node-a"))
  assert_true(s.contains("to=node-b"))
  assert_true(s.contains("WARNING"))
}
