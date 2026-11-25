///|
test "i257-define page alias rewrites every default t condition" {
  let got = @repo.define_page_where(" AND t.name = ? AND t.version = ?")
  let want = " AND pd.name = ? AND pd.version = ?"
  if got != want {
    println("[i257-define page alias] 期望 <\{want}> 实得 <\{got}>")
    abort("[i257-define page alias] 双条件别名未全部改写")
  }
}

///|
test "i257-define page alias keeps explicit pd conditions" {
  let got = @repo.define_page_where(" AND pd.name = ? AND t.version = ?")
  let want = " AND pd.name = ? AND pd.version = ?"
  if got != want {
    println("[i257-define page alias] 期望 <\{want}> 实得 <\{got}>")
    abort("[i257-define page alias] 显式别名被误改")
  }
}
