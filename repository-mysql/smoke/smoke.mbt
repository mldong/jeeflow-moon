// M0 spike②（jeeflow-moon 正式落仓版）：moon-mysql（vendored 解锁 wasm）连 160
// 建表 → begin/rollback（行必须消失）→ begin/commit（行必须在）→ DROP 自清理
// 凭据只走 JEFFLOW_DB_* env（R6），id 用 9xxxxx 段（R6），测后自清理（R6）。
// M2 起 smoke/ 扩展为 T1 M1–M4 成建制冒烟（方案 §5 M2）。

///|
fn db_conf() -> (String, Int, String, String, String) raise {
  let host = @env.get_env_var("JEFFLOW_DB_HOST").unwrap_or("192.168.1.160")
  let port = match @env.get_env_var("JEFFLOW_DB_PORT") {
    Some(s) =>
      match (try? @string.parse_int(s)) {
        Ok(p) => p
        Err(_) => 3306
      }
    None => 3306
  }
  let user = @env.get_env_var("JEFFLOW_DB_USER").unwrap_or("root")
  let pwd = @env.get_env_var("JEFFLOW_DB_PWD").unwrap_or("")
  let name = @env.get_env_var("JEFFLOW_DB_NAME").unwrap_or("jeeflow")
  (host, port, user, pwd, name)
}

///|
async fn spike() -> Unit raise {
  let (host, port, user, pwd, name) = db_conf()
  let conn = @client.MysqlConn::connect(host, port, user, pwd, name)
  println("STEP1 connect \{host}:\{port}/\{name} OK")
  // 一次性探针表：wf_ 前缀、jeeflow 库内、跑完 DROP（R6：不动既有服务与库结构之外的任何东西）
  let _ = conn.execute("DROP TABLE IF EXISTS wf_moon_spike_tmp", [])
  let _ = conn.execute(
    "CREATE TABLE wf_moon_spike_tmp (id BIGINT PRIMARY KEY, v VARCHAR(64)) ENGINE=InnoDB",
    [],
  )
  println("STEP2 create table OK")
  // 负向：回滚必须真回滚
  conn.begin()
  let _ = conn.execute("INSERT INTO wf_moon_spike_tmp (id, v) VALUES (990001, 'rollback-me')", [])
  conn.rollback()
  let rows = conn.query("SELECT COUNT(*) FROM wf_moon_spike_tmp WHERE id = 990001", [])
  assert_eq(rows[0].int64(0), 0L)
  println("STEP3 rollback OK (row absent)")
  // 正向：提交必须真提交
  conn.begin()
  let _ = conn.execute("INSERT INTO wf_moon_spike_tmp (id, v) VALUES (990001, 'commit-me')", [])
  conn.commit()
  let rows2 = conn.query("SELECT v FROM wf_moon_spike_tmp WHERE id = 990001", [])
  assert_eq(rows2[0].text(0), "commit-me")
  println("STEP4 commit OK (row present)")
  // 回归：再插一行再删，确认连接可继续工作
  let _ = conn.execute("INSERT INTO wf_moon_spike_tmp (id, v) VALUES (990002, 'second')", [])
  let rows3 = conn.query("SELECT COUNT(*) FROM wf_moon_spike_tmp", [])
  assert_eq(rows3[0].int64(0), 2L)
  println("STEP5 second insert OK")
  // 自清理
  let _ = conn.execute("DROP TABLE wf_moon_spike_tmp", [])
  conn.close()
  println("STEP6 cleanup OK — SPIKE2 PASS (wasm vendored moon-mysql → 160 真事务)")
}

///|
fn main {
  @async.run_async_main(spike)
}
