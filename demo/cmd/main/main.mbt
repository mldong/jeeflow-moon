// demo HTTP server :8092（run_forever 常驻 + CORS，方案 §2.6）
// 启动：moon run --target wasm demo/cmd/main（JEEFLOW_DEMO_STORE 默认 memory）

///|
async fn handle(app : @demo.App, req : @http.Request, body : &@io.Reader, conn : @http.ServerConnection) -> Unit {
  // 读 body
  let buf = StringBuilder::new()
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
  let outcome = try? app.handle(method_of(req), path, "", body_text)
  match outcome {
    Ok((status, payload)) => {
      conn.send_response(status, "application/json")
      conn.write_string(payload)
      conn.end_response()
    }
    Err(e) => {
      // facade/应用错误 → 99999999 信封（demo 层不吞）
      let obj = @json.empty_object()
      @json.obj_set(obj, "code", @json.number_of(99999999L))
      @json.obj_set(obj, "msg", @json.string_of(e.to_string()))
      conn.send_response(200, "application/json")
      conn.write_string(@json.stringify(obj))
      conn.end_response()
    }
  }
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
  let outcome = try? @demo.App::create()
  match outcome {
    Err(e) => {
      println("demo 启动失败: \{e}")
      abort("init failed")
    }
    Ok(app) => {
      println("jeeflow-moon demo listening on 127.0.0.1:8092 store=\{app.store}")
      // 监听 0.0.0.0：容器部署时 docker-proxy 从容器外转发（127.0.0.1 会 Empty reply）
      let listen = @env.get_env_var("LISTEN_ADDR").unwrap_or("0.0.0.0:8092")
      let addr = @socket.Addr::parse(listen)
      let server = @http.Server(addr, reuse_addr=true)
      server.run_forever() <| fn(req, body, conn) {
        handle(app, req, body, conn)
      }
    }
  }
}
