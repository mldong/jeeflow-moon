// issues/212 · audit8 R44（spec 06 §2.2 分页缺省全局档：`pageNum` 从 1 起；`pageSize` 默认 10）。
//
// 六枚分页 action 不传 pageNum/pageSize 时信封必须回 1/10——修前本栈这六枚
// （define/instance/todo/done/design/surrogate）旧默认 20L，154④ 只收过 ccList 一枚。
// 显式传值档做阳性对照：防把"改默认"写成"改强制"。
//
// 复用同包 helper：targs / code_of / msg_of / data_of。

///|
fn i212_check(cond : Bool, label : String) -> Unit {
  if !cond {
    abort("[i212-page-defaults] 红样：" + label)
  }
}

///|
async test "i212 分页默认值全族 1/10" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let facade = @facade.Facade::make(ctx2)
  let actions : Array[String] = [
    "processDefine/page",
    "processInstance/page",
    "processTask/todoList",
    "processTask/doneList",
    "processDesign/page",
    "processSurrogate/page",
  ]
  for action in actions {
    let env = facade.flow(action, targs([]))
    i212_check(code_of(env) == 0L, "\{action} code≠0（msg=\{msg_of(env)}）")
    let pn = @json.get_i64(data_of(env), "pageNum").unwrap_or(-1L)
    let ps = @json.get_i64(data_of(env), "pageSize").unwrap_or(-1L)
    i212_check(
      pn == 1L && ps == 10L,
      "\{action} 缺省分页应为 1/10，实得 \{pn}/\{ps}（旧形状＝20）",
    )
  }
  // 阳性对照：显式传值不受默认档影响
  let env2 = facade.flow("processDefine/page", targs([("pageNum", "2"), ("pageSize", "7")]))
  i212_check(code_of(env2) == 0L, "define/page 显式传参 code≠0（msg=\{msg_of(env2)}）")
  let pn2 = @json.get_i64(data_of(env2), "pageNum").unwrap_or(-1L)
  let ps2 = @json.get_i64(data_of(env2), "pageSize").unwrap_or(-1L)
  i212_check(pn2 == 2L && ps2 == 7L, "显式 pageNum/pageSize 应原样回显，实得 \{pn2}/\{ps2}")
}
