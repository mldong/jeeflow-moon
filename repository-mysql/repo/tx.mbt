// ITransactionTemplate 真实现（spec/05 连接级 + 上下文绑定的 MoonBit 形态）
// 单线程事件循环 ⇒ 环境连接（ambient conn）即上下文绑定（对齐 Python contextvars/Node ALS 谱系，方案 §2.3）。
// 模板内：checkout 连接 → BEGIN → 回调 → COMMIT；回调抛错 → ROLLBACK → 异常外抛。
// 事务中的仓储方法共用该连接（open() 优先复用环境连接，且不在事务中途 close）。

///|
/// 环境事务连接（None = 非事务态，各方法独立连接）
let tx_conn : Ref[(@client.MysqlConn?)] = Ref::new(None)

///|
/// 事务内取当前连接（测试/工具用；非事务态 None）
pub fn current_tx_conn() -> @client.MysqlConn? {
  tx_conn.val
}

///|
/// MysqlRepository.open() 在事务态复用环境连接
async fn open_or_tx(self : MysqlRepository) -> @client.MysqlConn raise @error.JeeflowError {
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
  { config }
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
  let conn = try? self.config.open_conn()
  let conn = match conn {
    Ok(c) => c
    Err(e) => raise e
  }
  tx_conn.val = Some(conn)
  let outcome = try? {
    let begin = try? conn.begin()
    match begin {
      Ok(_) => ()
      Err(e) => raise @error.Internal("tx begin: \{e}")
    }
    op()
  }
  match outcome {
    Ok(_) => {
      let commit = try? conn.commit()
      tx_conn.val = None
      conn.close()
      match commit {
        Ok(_) => ()
        Err(e) => raise @error.Internal("tx commit: \{e}")
      }
    }
    Err(e) => {
      let _ = try? conn.rollback()
      tx_conn.val = None
      conn.close()
      raise e
    }
  }
}


