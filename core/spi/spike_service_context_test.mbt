// M0 spike①+④ 运行时验证：async test 在 wasm 目标真实跑绿（方案 §5 M0 spike ①）
// 同时覆盖 spike④ 的运行时行为：泛型约束引擎 + 闭包字段 ServiceContext 真的能跑。
// 注：async test 体内处于 raising 上下文，仓储错误直接传播即测试失败，无需 try/catch。

///|
struct MockRepo {}

///|
impl ProcessRepository for MockRepo with find_user_by_id(_self, id) {
  { user_id: "\{id}", real_name: "Mock\{id}" }
}

///|
impl ProcessRepository for MockRepo with save_marker(_self, _id) {
  ()
}

///|
struct MockExt {}

///|
impl ProcessExtRepository for MockExt with find_ext(_self, _id) {
  "ext"
}

///|
fn named_user_provider(uid : String) -> UserInfo raise JeeflowError {
  { user_id: uid, real_name: "Named\{uid}" }
}

///|
async test "spike: async test wasm + generic engine + closure ctx" {
  let ctx = Ctx::new(MockRepo::{}, MockExt::{})
  let engine = Engine::new(ctx)
  // 无 user_provider 注入 → 回落仓储返回的 real_name
  let out = engine.run(7)
  assert_eq(out, "Mock7/ext")
}

///|
async test "spike: closure field injection (user_provider)" {
  let ctx = Ctx::new(MockRepo::{}, MockExt::{})
  let ctx2 = ctx.with_user_provider(named_user_provider)
  let engine = Engine::new(ctx2)
  // 闭包字段命中 → 用注入的 provider 解析（provider 收到仓储返回的 real_name="Mock7"）
  let out = engine.run(7)
  assert_eq(out, "NamedMock7/ext")
}
