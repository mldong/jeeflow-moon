// issues/144 方案 b 的装配前提：`Ctx::for_request` 必须是**新建派生体**，不能是原地改。
// 三句各钉一件事，任何一句退化成别名都会红：
// ① 换仓储只影响派生体——若照下面那批 `with_*` 的"原地改 self"样式写，母体跟着一起换，
//    并发请求就共用同一个事务句柄（＝144 换个载体重演，而编译期和真库门禁都看不出来）；
// ② 注册容器逐个 copy——母体后续注册不回写派生体，反之亦然；
// ③ 闭包字段**按引用共享**是刻意的：id 生成器必须共用同一个实例（雪花同毫秒各自从 0 起会撞 id）。

///|
test "for_request：派生体独立、容器切开、闭包共享" {
  let base : @spi.Ctx[Int, Int] = @spi.Ctx::new(1, 101)
  let counter : Ref[Int] = Ref(0)
  let _ = base.with_action_permission_provider(fn(_a : String) -> Array[String] {
    counter.val = counter.val + 1
    []
  })
  let derived = base.for_request(2, 202)

  // ① 仓储只换在派生体上（原地样式在这一句红）
  assert_eq(derived.repository(), 2)
  assert_eq(derived.ext_repository(), 202)
  assert_eq(base.repository(), 1)
  assert_eq(base.ext_repository(), 101)

  // ② 注册容器互不串（快照语义，两侧都要验）
  base.register_interceptor_sync(1, fn(_e) {})
  assert_eq(derived.interceptors.length(), 0)
  derived.register_interceptor_sync(2, fn(_e) {})
  assert_eq(base.interceptors.length(), 1)

  // ③ 闭包字段共享同一个被捕获的状态（派生体调用推进的就是母体那个计数器）
  let d_provider = derived.action_permission_provider.unwrap()
  let _ = d_provider("x")
  assert_eq(counter.val, 1)
  let b_provider = base.action_permission_provider.unwrap()
  let _ = b_provider("x")
  assert_eq(counter.val, 2)
}
