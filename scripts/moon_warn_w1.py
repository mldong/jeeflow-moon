#!/usr/bin/env python
"""警告批次 W1：小类打包（fragile_catch_all / unused_async / 缺 import / ambiguous_block /
unresolved_type_variable / reserved_keyword）。

逐类判据（都是"编译器自己指出的形状问题"，不改语义）：

- fragile_catch_all 6 处：其中 5 处是上一轮把 `try? f()` 机械换成
  `try { f() } catch { e => raise e }` 造出来的**空壳**（原样再抛，等于没包）
  ⇒ 直接写调用。第 6 处是 tx 模板的"出错收尾再抛"⇒ 换 `errdefer`：
  工具链明说"try/catch 将来不再捕获异步取消"，收尾挂 errdefer 才是长期形状。
  ⚠ 这条是事务关键路径：改完必须跑 T1 的 t1_m4（回滚净）才算数。
- ambiguous_block：`fn make(...) -> T { { field } }` 这种"块里一个花括号"既能读成块
  又能读成结构体字面量 ⇒ 写成限定的 `T::{ field }`。
- unresolved_type_variable：`PageResult::new(.., [])` 的空数组元素类型推不出来
  ⇒ 在 let 上标注（测试只判 total_page，元素类型取 String 只为闭合推断）。
- reserved_keyword：`resume` / `method` 是将来要占用的词。owner 上一轮同类问题拍的是
  "真改名"（kw_define/kw_alias 那批），这里沿用：
    ProcessInstance::resume / ProcessTask::resume ⇒ resume_from_interrupt（全仓 0 调用点，
    也不是跨栈契约名——契约只钉 HTTP action 串与 JSON 形状）；
    App::handle 的形参 method ⇒ meth（与 @http.Request.meth 同名；无具名实参调用点）。
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

CONN = "repository-mysql/repo/conn.mbt"
REPO = "repository-mysql/repo/repository.mbt"
TX = "repository-mysql/repo/tx.mbt"
MT = "core/model/model_test.mbt"
AGG = "core/model/aggregate.mbt"
ENGINE = "core/engine/engine.mbt"
METADATA = "core/metadata/metadata.mbt"
SAA = "facade/surrogate_autoapply_test.mbt"
APP = "demo/app.mbt"
MAIN_PKG = "demo/cmd/main/moon.pkg"

CONN_PAIRS = [
    (
        """async fn open(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {
  try {
    self.config.open_conn()
  } catch {
    e => raise e
  }
}
""",
        """async fn open(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {
  // 上一轮 `try?` 换形时留下的空壳（catch 里原样再抛）：直接调用即可
  self.config.open_conn()
}
""",
    ),
]

REPO_PAIRS = [
    (
        """pub async fn MysqlRepository::open_raw(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {
  try {
    self.config.open_conn()
  } catch {
    e => raise e
  }
}
""",
        """pub async fn MysqlRepository::open_raw(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {
  // 同上：`try { … } catch { e => raise e }` 是空壳，去掉包装不改任何行为
  self.config.open_conn()
}
""",
    ),
    (
        """pub fn MysqlRepository::make(config : MysqlConfig) -> MysqlRepository {
  { config }
}
""",
        """pub fn MysqlRepository::make(config : MysqlConfig) -> MysqlRepository {
  // 块里只有一个 `{ … }` 时"代码块 vs 结构体字面量"有歧义（编译器直接点名）⇒ 限定写法
  MysqlRepository::{ config }
}
""",
    ),
]

TX_PAIRS = [
    (
        """pub fn MysqlTxTemplate::make(config : MysqlConfig) -> MysqlTxTemplate {
  { config }
}
""",
        """pub fn MysqlTxTemplate::make(config : MysqlConfig) -> MysqlTxTemplate {
  MysqlTxTemplate::{ config }
}
""",
    ),
    (
        """  let conn = try {
    self.config.open_conn()
  } catch {
    e => raise e
  }
  tx_conn.val = Some(conn)
""",
        """  let conn = self.config.open_conn()
  tx_conn.val = Some(conn)
""",
    ),
    (
        """  try {
    try {
      conn.begin()
    } catch {
      e => raise @error.Internal("tx begin: \\{e}")
    }
    op()
  } catch {
    e => {
      try {
        conn.rollback()
      } catch {
        _ => ()
      }
      tx_conn.val = None
      conn.close()
      raise e
    }
  }
""",
        """  // 收尾（回滚→清事务态→关连接）挂 errdefer：任何从这里外抛的错误都先走完这三步。
  // 旧形状是 try{…}catch{ e => {收尾; raise e} }，语义相同，但工具链已声明
  // "try/catch 将来不再捕获异步取消" ⇒ 收尾类逻辑的正解是 errdefer。
  errdefer {
    try {
      conn.rollback()
    } catch {
      _ => ()
    }
    tx_conn.val = None
    conn.close()
  }
  try {
    conn.begin()
  } catch {
    e => raise @error.Internal("tx begin: \\{e}")
  }
  op()
""",
    ),
]

MT_PAIRS = [
    (
        """  try {
    task.finish("user1")
  } catch {
    e => raise e
  }
""",
        """  task.finish("user1")
""",
    ),
    (
        """  try {
    finished.finish("user1")
  } catch {
    e => raise e
  }
""",
        """  finished.finish("user1")
""",
    ),
    ("""  let pr = @model.PageResult::new(1L, 10L, 25L, [])\n""",
     """  let pr : @model.PageResult[String] = @model.PageResult::new(1L, 10L, 25L, [])\n"""),
    ("""  let pr = @model.PageResult::new(1L, 10L, 0L, [])\n""",
     """  let pr : @model.PageResult[String] = @model.PageResult::new(1L, 10L, 0L, [])\n"""),
    ("""  let pr = @model.PageResult::new(1L, 10L, 20L, [])\n""",
     """  let pr : @model.PageResult[String] = @model.PageResult::new(1L, 10L, 20L, [])\n"""),
    ("""  let pr = @model.PageResult::new(1L, 10L, 1L, [])\n""",
     """  let pr : @model.PageResult[String] = @model.PageResult::new(1L, 10L, 1L, [])\n"""),
]

AGG_PAIRS = [
    ("""pub fn ProcessInstance::resume(self : ProcessInstance) -> Unit {""",
     """pub fn ProcessInstance::resume_from_interrupt(self : ProcessInstance) -> Unit {"""),
    ("""pub fn ProcessTask::resume(self : ProcessTask) -> Unit {""",
     """pub fn ProcessTask::resume_from_interrupt(self : ProcessTask) -> Unit {"""),
]

ENGINE_PAIRS = [
    (
        """pub fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::make(ctx : @spi.Ctx[R, E]) -> Engine[R, E] {
  { ctx }
}
""",
        """pub fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Engine::make(ctx : @spi.Ctx[R, E]) -> Engine[R, E] {
  Engine[R, E]::{ ctx }
}
""",
    ),
]

SAA_PAIRS = [
    ("""async fn sg_facade(""", """fn sg_facade("""),
]

APP_PAIRS = [
    ("""pub async fn App::handle(self : App, method : String, path : String, query_string : String, body : String) -> (Int, String) raise {""",
     """pub async fn App::handle(self : App, meth : String, path : String, query_string : String, body : String) -> (Int, String) raise {"""),
]

# core_package_not_imported：@env 是 core 包，本工具链起要在 moon.pkg 里显式 import
MAIN_PKG_PAIRS = [
    ("""  "moonbitlang/core/encoding/utf8" @utf8,\n""",
     """  "moonbitlang/core/encoding/utf8" @utf8,
  "moonbitlang/core/env" @env,\n"""),
]

if __name__ == "__main__":
    for path, pairs in [
        (CONN, CONN_PAIRS), (REPO, REPO_PAIRS), (TX, TX_PAIRS), (MT, MT_PAIRS),
        (AGG, AGG_PAIRS), (ENGINE, ENGINE_PAIRS), (SAA, SAA_PAIRS), (APP, APP_PAIRS),
        (MAIN_PKG, MAIN_PKG_PAIRS),
    ]:
        patch(path, pairs)
