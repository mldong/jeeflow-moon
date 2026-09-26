#!/usr/bin/env python
"""demo/cmd/main/main.mbt 最后两处 Result 壳（App::handle / App::create 现在直接 raise）。

保留的两条既有语义（不是"顺手改"）：
  - 应用错误 → HTTP 200 + `{code:99999999,msg}` 信封，demo 层不吞错误（旧 Err 臂逐字）；
  - 启动失败要先把错误打到 stdout 再 abort —— 容器里 `docker logs` 只有这一处能看到原因。
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

PAIRS = [
    (
        """  let outcome = app.handle(method_of(req), path, "", body_text)
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
""",
        """  // App::handle 不再返回 Result：错误臂就地转成 99999999 信封（demo 层不吞），
  // 两臂合成同一个 (status, payload)，出口写法与旧代码逐一对应。
  let outcome = try {
    app.handle(method_of(req), path, "", body_text)
  } catch {
    e => {
      let obj = @json.empty_object()
      @json.obj_set(obj, "code", @json.number_of(99999999L))
      @json.obj_set(obj, "msg", @json.string_of("\\{e}"))
      (200, @json.stringify(obj))
    }
  }
  let (status, payload) = outcome
  conn.send_response(status, "application/json")
  conn.write_string(payload)
  conn.end_response()
""",
    ),
    (
        """  let outcome = @demo.App::create()
  match outcome {
    Err(e) => {
      println("demo 启动失败: \\{e}")
      abort("init failed")
    }
    Ok(app) => {
      // 监听 0.0.0.0：容器部署时 docker-proxy 从容器外转发（127.0.0.1 会 Empty reply）
      let listen = @env.get_env_var("LISTEN_ADDR").unwrap_or("0.0.0.0:8092")
      println("jeeflow-moon demo listening on \\{listen} store=\\{app.store}")
      let addr = @socket.Addr::parse(listen)
      let server = @http.Server(addr, reuse_addr=true)
      server.run_forever() <| fn(req, body, conn) {
        handle(app, req, body, conn)
      }
    }
  }
""",
        """  // App::create 不再返回 Result。启动失败仍先打一行原因再 abort：
  // 容器里 `docker logs` 只有这一处能看到失败原因（旧 Err 臂的判据不丢）。
  let app = try {
    @demo.App::create()
  } catch {
    e => {
      println("demo 启动失败: \\{e}")
      abort("init failed")
    }
  }
  // 监听 0.0.0.0：容器部署时 docker-proxy 从容器外转发（127.0.0.1 会 Empty reply）
  let listen = @env.get_env_var("LISTEN_ADDR").unwrap_or("0.0.0.0:8092")
  println("jeeflow-moon demo listening on \\{listen} store=\\{app.store}")
  let addr = @socket.Addr::parse(listen)
  let server = @http.Server(addr, reuse_addr=true)
  server.run_forever() <| fn(req, body, conn) {
    handle(app, req, body, conn)
  }
""",
    ),
]

if __name__ == "__main__":
    patch("demo/cmd/main/main.mbt", PAIRS)
