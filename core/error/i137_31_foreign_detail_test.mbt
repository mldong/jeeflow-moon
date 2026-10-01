// issues/137 §3-1（spec 06 §2.12）：出口判别式**纯函数腿**——文案判据与副作用各自可测，
// 本文件测文案判据本身（is_foreign_detail / INTERNAL_FAILURE_MSG / detail() 的原文留存）。
// 门面出口的信封腿在 facade/i137_31_internal_no_leak_test.mbt；JSON 解析族批二已收口
// （ParseErrorWithCause＋detail()，facade/i137g_parse_msg_no_leak_test.mbt 钉住），本文件只
// 复核契约档不被判别式误吞（判据恒真＝把契约面静默改掉）。判据形状照 java
// FacadeInternalErrorNoLeakTest：泄漏各形状⇒固定文案；契约文案⇒逐字透出；原文没丢。

///|
test "i137-§3-1 判别式：Internal 各形 ⇒ foreign，固定文案逐字，原文留 message()/detail() 供日志" {
  // 固定文案逐字（八栈同一串，spec 06 §2.12／失败文案表新增行）
  assert_eq(@error.INTERNAL_FAILURE_MSG, "流程处理失败")
  // repository-mysql 五条驱动腿的原文形状（conn.mbt:36/65/79、tx.mbt:76/90 同形）＋裸包装
  let payloads = [
    "mysql connect: Access denied for user 'root'@'10.0.0.8' (using password: YES)",
    "mysql query: Table 'jeeflow.wf_process_task' doesn't exist",
    "mysql execute: Deadlock found when trying to get lock; try restarting transaction",
    "tx begin: connection reset by peer",
    "tx commit: MySQL server has gone away",
  ]
  for p in payloads {
    let e = @error.Internal(p)
    assert_true(e.is_foreign_detail())
    // 原文没有整个丢掉：日志档 message() 与 detail() 都取回得到
    assert_true(e.message().contains(p))
    match e.detail() {
      Some(d) => assert_eq(d, p)
      None => abort("Internal 的原文必须能从 detail() 取回: \{p}")
    }
  }
}

///|
test "i137-§3-1 判别式：契约档全部 non-foreign，message 逐字不动（判据不得恒真）" {
  let contract : Array[@error.JeeflowError] = [
    @error.Business("operator 必填"),
    @error.UnknownAction("processTask/nope"),
    @error.DefineNotFound(1L),
    @error.InstanceNotFound(2L),
    @error.TaskNotFound(3L),
    @error.PermissionDenied("无权限摘除该任务参与人"),
    @error.InvalidState("任务非进行中，不可摘除参与人"),
    @error.InvalidSubmitType(9L),
    @error.ParseError("bad json"),
    @error.ParseErrorWithCause("读取流程定义 JSON 失败", "json: Invalid character"),
  ]
  for e in contract {
    if e.is_foreign_detail() {
      abort("契约档被误判内部（判据恒真会把契约面静默改掉）: \{e.message()}")
    }
  }
  // 逐字抽查（spec 06 失败文案表）：判别式落地前后这些串一个字节都不许动
  assert_eq((@error.Business("operator 必填")).message(), "operator 必填")
  assert_eq((@error.Business("任务不存在")).message(), "任务不存在")
  assert_eq((@error.Business("至少需保留一名参与人")).message(), "至少需保留一名参与人")
  assert_eq((@error.TaskNotFound(3L)).message(), "任务不存在: 3")
  assert_eq(
    (@error.ParseErrorWithCause("读取流程定义 JSON 失败", "json: raw")).message(),
    "读取流程定义 JSON 失败",
  )
  // 通用档 ParseError（error_test.mbt:21 既有钉）行为不动
  assert_true((@error.ParseError("bad json")).message().contains("bad json"))
  // 批二既有机制不被本轮 Internal 扩展挤掉：ParseErrorWithCause 的 detail 腿仍在
  match (@error.ParseErrorWithCause("读取流程定义 JSON 失败", "json: raw")).detail() {
    Some(d) => assert_eq(d, "json: raw")
    None => abort("ParseErrorWithCause 的 detail 必须仍在")
  }
}
