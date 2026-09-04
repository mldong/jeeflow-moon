// M0 spike③：Server::run_forever 常驻服务 + curl 复核（方案 §5 M0 spike ③）
// :8092 为 MoonBit demo 专属端口（8080-8082/8090/8091/8100 已占，方案 §0.1）。
// M4 将扩展为 demo 全契约（POST /wf/{action} 全转发 facade + /api/stats + /api/reset + 种子，方案 §2.6）。

///|
async fn handle(
  req : @http.Request,
  _body : &@io.Reader,
  conn : @http.ServerConnection
) -> Unit {
  let path = req.path
  if path == "/health" {
    conn.send_response(200, "application/json")
    conn.write_string("{\"status\":\"ok\",\"engine\":\"jeeflow-moon\",\"store\":\"memory\"}")
    conn.end_response()
    return
  }
  conn.send_response(404, "application/json")
  conn.write_string("{\"code\":99999999,\"msg\":\"unknown path: " + path + "\"}")
  conn.end_response()
}

///|
fn main {
  @async.run_async_main(() => {
    let addr = @socket.Addr::parse("127.0.0.1:8092")
    let server = @http.Server(addr, reuse_addr=true)
    println("jeeflow-moon demo listening on 127.0.0.1:8092")
    server.run_forever() <| handle
  })
}
