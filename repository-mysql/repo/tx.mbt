// ITransactionTemplate 真实现（spec/05 连接级 + 事务作用域绑定的 MoonBit 形态）
//
// 句柄挂在**仓储实例**上，不是进程级全局槽（issues/144）：本栈是单线程事件循环，多个请求
// 在 await 点互相交错，而全局 `Ref` 是进程级共享——A 的事务连接会被 B 看见并复用，
// A 回滚时把 B 已经返回给调用方的确认写入一起抹掉（案文 §2 X2 档，160 真库实测）。
// 旧注释拿 Python contextvars / Node AsyncLocalStorage 类比，那是错的：那两者按异步任务隔离
// （task-scoped），本栈没有 task-local，能用的只有"句柄随实例走"或"句柄显式传"。
// 本轮实测的语义前提（探针 P1–P5）：结构体拷贝共享同一个 `Ref` 槽 ⇒ 同一实例族的仓储调用
// 自动同事务；`new_request()` 派生的实例各持新槽 ⇒ 请求之间互不可见。
// 接线纪律：一个请求＝一个仓储实例（Web 层从启动期的 base 实例 `new_request()` 派生）。
//
// 模板内：取连接 → BEGIN → 回调 → COMMIT；回调抛错 → errdefer ROLLBACK → 异常外抛。
// 事务中的仓储方法共用该连接（open_or_tx() 优先复用事务连接，且事务中途不 close）。

///|
/// 请求级派生：同一份连接配置，独立的事务槽
pub fn MysqlRepository::new_request(self : MysqlRepository) -> MysqlRepository {
  // 块里只有一个 `{ … }` 时"代码块 vs 结构体字面量"有歧义（编译器直接点名）⇒ 限定写法
  MysqlRepository::{ config: self.config, tx: Ref(None) }
}

///|
/// 本实例是否处于事务中——判"这个仓储实例的事务槽"，不判"进程里有没有事务"
pub fn MysqlRepository::tx_active(self : MysqlRepository) -> Bool {
  self.tx.val is Some(_)
}

///|
/// 事务内取当前连接（测试/工具用；非事务态 None）
pub fn MysqlRepository::current_tx_conn(self : MysqlRepository) -> @client.MysqlConn? {
  self.tx.val
}

///|
/// MysqlRepository.open() 在事务态复用本实例的事务连接
async fn MysqlRepository::open_or_tx(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {
  match self.tx.val {
    Some(conn) => conn
    None => self.open()
  }
}

///|
/// 事务感知 close：本实例的事务连接由模板收尾，这里不关
fn MysqlRepository::close_conn(self : MysqlRepository, conn : @client.MysqlConn) -> Unit {
  match self.tx.val {
    Some(_) => ()
    None => conn.close()
  }
}

///|
pub(all) struct MysqlTxTemplate {
  repo : MysqlRepository
}

///|
pub fn MysqlTxTemplate::make(repo : MysqlRepository) -> MysqlTxTemplate {
  MysqlTxTemplate::{ repo }
}
///|
pub fn MysqlTxTemplate::from_env() -> MysqlTxTemplate raise {
  { repo: MysqlRepository::from_env() }
}

///|
/// 从仓储实例取模板：模板与调用方的仓储必然共用同一个事务槽
pub fn MysqlRepository::tx_template(self : MysqlRepository) -> MysqlTxTemplate {
  MysqlTxTemplate::{ repo: self }
}

///|
/// spec/05 模板形态：op 内该实例族的所有仓储调用共连接，异常整体回滚。
/// 回调收**绑定后的仓储实例**：调用方不需要（也不应该）再传第二次句柄，
/// 但拿到句柄就没法"用错实例"而静默走 autocommit。
/// 同一实例内嵌套仍不重复 BEGIN（`tx_active()` 命中即直接跑 op）——
/// 本案否定的只是"跨请求命中同一条复用分支"，不是嵌套复用本身。
/// ⚠ op 的错误集是**开放** `raise`（不是闭集 JeeflowError）：本栈里 `async fn` 不写 raise 注解
///   会被推成开放 Error，而 `Facade::flow` 正是这种形状 ⇒ 若这里收闭集，宿主**压根没法把一次
///   门面动作包进事务**（编译期就挡）。模板对"抛什么错"本就不该挑——任何错都回滚，原样外抛。
pub async fn MysqlRepository::execute_in_tx(
  self : MysqlRepository,
  op : async (MysqlRepository) -> Unit raise
) -> Unit raise {
  if self.tx_active() {
    op(self)
    return
  }
  let conn = self.config.open_conn()
  self.tx.val = Some(conn)
  // 1) BEGIN 的错误**先**映射成 JeeflowError，再交给下面的统一回滚臂——
  //    否则 catch 臂绑到的错误类型会含 DbError，`raise e` 与函数签名的 raise JeeflowError 不匹配。
  // 2) BEGIN 或 op 失败 ⇒ ROLLBACK（回滚自身失败不掩盖原错误）→ 清事务态 → 关连接 → 外抛原错误。
  // 收尾（回滚→清事务态→关连接）挂 errdefer：任何从这里外抛的错误都先走完这三步。
  // 旧形状是 try{…}catch{ e => {收尾; raise e} }，语义相同，但工具链已声明
  // "try/catch 将来不再捕获异步取消" ⇒ 收尾类逻辑的正解是 errdefer。
  errdefer {
    try {
      conn.rollback()
    } catch {
      _ => ()
    }
    self.tx.val = None
    conn.close()
  }
  try {
    conn.begin()
  } catch {
    e => raise @error.Internal("tx begin: \{e}")
  }
  op(self)
  // 3) COMMIT：照旧顺序 commit → 清态 → 关连接，**之后**才判错误
  //    （已提交不再回滚；但清态与关连接不能因为 commit 报错而被跳过——原实现正是这个顺序）。
  let commit_err = try {
    conn.commit()
    None
  } catch {
    e => Some(e)
  }
  self.tx.val = None
  conn.close()
  match commit_err {
    Some(e) => raise @error.Internal("tx commit: \{e}")
    None => ()
  }
}

///|
/// 模板入口（spec/05 的 ITransactionTemplate 命名位）：委派给绑定的仓储实例。
/// op 的错误集同为开放 `raise`，理由见上面 `MysqlRepository::execute_in_tx` 的注。
pub async fn MysqlTxTemplate::execute_in_tx(
  self : MysqlTxTemplate,
  op : async (MysqlRepository) -> Unit raise
) -> Unit raise {
  self.repo.execute_in_tx(op)
}
