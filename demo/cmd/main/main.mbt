// demo HTTP server :8092（run_forever 常驻 + CORS，方案 §2.6）
// 启动：moon run --target wasm demo/cmd/main（JEEFLOW_DEMO_STORE 默认 memory）

///|
async fn handle(app : @demo.App, req : @http.Request, body : &@io.Reader, conn : @http.ServerConnection) -> Unit {
  // 读 body
  let buf = StringBuilder()
  while body.read_some() is Some(data) {
    buf.write_string(@utf8.decode_lossy(data))
  }
  let body_text = buf.to_string()
  let path = req.path
  // CORS 预检
  if method_of(req) == "OPTIONS" {
    conn.send_response(204, "text/plain")
    conn.write_string("")
    conn.end_response()
    return
  }
  // App::handle 不再返回 Result：错误臂就地转成 99999999 信封（demo 层不吞），
  // 两臂合成同一个 (status, payload)，出口写法与旧代码逐一对应。
  let outcome = try {
    app.handle(method_of(req), path, "", body_text)
  } catch {
    e => {
      let obj = @json.empty_object()
      @json.obj_set(obj, "code", @json.number_of(99999999L))
      @json.obj_set(obj, "msg", @json.string_of("\{e}"))
      (200, @json.stringify(obj))
    }
  }
  let (status, payload) = outcome
  conn.send_response(status, "application/json")
  conn.write_string(payload)
  conn.end_response()
}

///|
fn method_of(req : @http.Request) -> String {
  match req.meth {
    Get => "GET"
    Post => "POST"
    Put => "PUT"
    Delete => "DELETE"
    Options => "OPTIONS"
    _ => "GET"
  }
}

///|
async fn main {
  // App::create 不再返回 Result。启动失败仍先打一行原因再 abort：
  // 容器里 `docker logs` 只有这一处能看到失败原因（旧 Err 臂的判据不丢）。
  let app = try {
    @demo.App::create()
  } catch {
    e => {
      println("demo 启动失败: \{e}")
      abort("init failed")
    }
  }
  // 监听 0.0.0.0：容器部署时 docker-proxy 从容器外转发（127.0.0.1 会 Empty reply）
  let listen = @env.get_env_var("LISTEN_ADDR").unwrap_or("0.0.0.0:8092")
  println("jeeflow-moon demo listening on \{listen} store=\{app.store}")
  let addr = @socket.Addr::parse(listen)
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever() <| fn(req, body, conn) {
    handle(app, req, body, conn)
  }
}
