// ITransactionTemplate 真实现（spec/05 连接级 + 上下文绑定的 MoonBit 形态）
// 单线程事件循环 ⇒ 环境连接（ambient conn）即上下文绑定（对齐 Python contextvars/Node ALS 谱系，方案 §2.3）。
// 模板内：checkout 连接 → BEGIN → 回调 → COMMIT；回调抛错 → ROLLBACK → 异常外抛。
// 事务中的仓储方法共用该连接（open() 优先复用环境连接，且不在事务中途 close）。

///|
/// 环境事务连接（None = 非事务态，各方法独立连接）
let tx_conn : Ref[(@client.MysqlConn?)] = Ref(None)

///|
/// 事务内取当前连接（测试/工具用；非事务态 None）
pub fn current_tx_conn() -> @client.MysqlConn? {
  tx_conn.val
}

///|
/// MysqlRepository.open() 在事务态复用环境连接
async fn MysqlRepository::open_or_tx(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {
  match tx_conn.val {
    Some(conn) => conn
    None => self.open()
  }
}

///|
/// 事务态判断（close 跳过）
fn in_tx() -> Bool {
  tx_conn.val is Some(_)
}

///|
pub(all) struct MysqlTxTemplate {
  config : MysqlConfig
}

///|
pub fn MysqlTxTemplate::make(config : MysqlConfig) -> MysqlTxTemplate {
  MysqlTxTemplate::{ config }
}
///|
pub fn MysqlTxTemplate::from_env() -> MysqlTxTemplate raise {
  { config: MysqlConfig::from_env() }
}

///|
/// spec/05 模板形态：op 内所有仓储调用共连接，异常整体回滚
pub async fn MysqlTxTemplate::execute_in_tx(
  self : MysqlTxTemplate,
  op : async () -> Unit raise @error.JeeflowError
) -> Unit raise @error.JeeflowError {
  if in_tx() {
    // 已在事务中：嵌套模板直接执行（连接复用，不重复 BEGIN）
    op()
    return
  }
  let conn = self.config.open_conn()
  tx_conn.val = Some(conn)
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
    tx_conn.val = None
    conn.close()
  }
  try {
    conn.begin()
  } catch {
    e => raise @error.Internal("tx begin: \{e}")
  }
  op()
  // 3) COMMIT：照旧顺序 commit → 清态 → 关连接，**之后**才判错误
  //    （已提交不再回滚；但清态与关连接不能因为 commit 报错而被跳过——原实现正是这个顺序）。
  let commit_err = try {
    conn.commit()
    None
  } catch {
    e => Some(e)
  }
  tx_conn.val = None
  conn.close()
  match commit_err {
    Some(e) => raise @error.Internal("tx commit: \{e}")
    None => ()
  }
}


