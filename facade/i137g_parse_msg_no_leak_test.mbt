// issues/137-G／139：门面出口不得把 cjson 原文拼进 msg（moon 是 139 的两条残腿之一）。
//
// 改前实测形状：`processDefine/deploy` 喂坏 JSON ⇒ 出口 msg ＝ `解析错误: json: <cjson 原文>`，
// 底层解析详情直接进用户面，与 java 逐字基准（ModelParser「读取流程定义 JSON 失败」）及
// 「内部信息不进 msg」口径相反——其余六栈这条早已各自收敛：rust `ParseErrorWithCause`、
// go `facadeFixedError`（cause 走 Unwrap）、python 收进 `__cause__`、node 把原始异常留在错误对象、
// php 改 java 逐字文案。
//
// 修法走**新增变体** `ParseErrorWithCause(对外固定文案, 底层原文)`，不动 `ParseError` 本身——
// `core/error/error_test.mbt:21` 钉着 `ParseError("bad json").message().contains("bad json")`，
// 那是"调用方自己写的文案要能看见"的通用档，改它就是动既有测试期望值。
//
// 复用同包 helper：targs / code_of / msg_of（withdraw_transfer_test.mbt）。

///|
fn g137g_facade() -> @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository] {
  let repo = @mem.MemoryRepository::new()
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx = @spi.Ctx::new(repo, repo).with_id_generator(fn() { gen.next_id() })
  @facade.Facade::make(ctx)
}

///|
/// 具名而非闭包：本工具链对"能 raise 但未标 raise"的闭包推断已 deprecated（0020 告警），
/// attempt 的注释也要求把 raise 面显式写出来。
fn g137g_parse_broken() -> Json raise @error.JeeflowError {
  @json.parse_json("{ 坏 json ")
}

///|
/// 负向（改前红）：msg 只给逐字基准文案，且不得含任何底层详情标记。
async test "i137-G 门面：坏 JSON 部署的出口 msg 不含 cjson 原文" {
  let facade = g137g_facade()
  let env = facade.flow("processDefine/deploy", targs([
    ("operator", "user1"),
    ("content", "{ \"name\": \"x\", 这不是合法的 json "),
  ]))
  let code = code_of(env)
  let msg = msg_of(env)
  if code != 99999999L {
    abort("预期失败信封，实际 code=\{code}")
  }
  assert_eq(msg, "读取流程定义 JSON 失败")
  for mark in ["json:", "cjson", "expected", "line", "column", "{", "\\"] {
    if msg.contains(mark) {
      abort("内部详情泄漏进 msg：mark=\{mark} msg=\{msg}")
    }
  }
}

///|
/// 正向对照（判据不恒真）：同一条腿喂**合法** JSON 不得报这条文案。
async test "i137-G 正向对照：合法 content 走同一条腿不报解析失败" {
  let facade = g137g_facade()
  let env = facade.flow("processDefine/deploy", targs([
    ("operator", "user1"),
    ("content", "{\"name\":\"i137g-ok\",\"type\":\"approval\",\"nodes\":[]}"),
  ]))
  let msg = msg_of(env)
  if msg.contains("读取流程定义 JSON 失败") {
    abort("合法 JSON 被判解析失败 ⇒ 判据恒真：msg=\{msg}")
  }
}

///|
/// cause 分离的另一半：固定文案与底层原文各归各处（detail 只给日志，不进出口 msg）。
test "i137-G detail 档：message() 出固定文案、detail() 留底层原文" {
  let r = @error.attempt(g137g_parse_broken)
  match r {
    Ok(_) => abort("坏 JSON 必须 raise")
    Err(e) =>
      match e {
        @error.JeeflowError::ParseErrorWithCause(msg, d) => {
          assert_eq(msg, "读取流程定义 JSON 失败")
          if !d.contains("json:") {
            abort("detail 里要留底层原文，实际=\{d}")
          }
        }
        other => abort("期望 ParseErrorWithCause，实际=\{other.message()}")
      }
  }
}
