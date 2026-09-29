// issues/141 G1 · ccList 归属条件必填（spec 06-facade §2.5）—— **内存腿**行为档。
//
// 病灶：memory 侧 page_cc_instances 把"没给 operator"折叠成 operator_eq 恒真 ⇒ 返回**全部**有 cc
// 行的实例；同栈的 MySQL 仓在没有归属条件时是 LEFT/INNER JOIN 放出全部实例——两仓同数据两个答案，
// 正是 issues/117 场景 27 立过法的那一类分叉。修法与 java 参考实现（3d1fc98）同一条判据：
// 归属列 cc.actor_id（本栈取值通道＝PageQuery.operator）**无有效条件 ⇒ 空页**（record_count=0、rows=[]）。
// 判据单点在 @model.cc_ownership_operator，两仓储共用 ⇒ 「两仓同答案」由构造保证，这里逐档钉住。
//
// ⚠️ 非归属列（m_ 可选过滤）的空值放行**不变**：G1 只关归属那一列，别把"这条没填"的通用放行一起吞掉。
// 门面出口那一侧的回归格（ccList 恒挂归属条件 ⇒ 短路不触发）在 facade 包：
// core/memory 不能反向依赖 facade，见 facade/i141_g1_g2_cc_test.mbt。

///|
/// 夹具用的流程定义（id=1 固定，便于实例 id 可预期）
fn g1_define() -> @model.ProcessDefine {
  {
    id: 1L,
    name: "i141-g1-cc",
    display_name: "i141 G1 归属必填夹具",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
}

///|
/// 夹具（刻意**非空**）：三实例 + 三行 cc ⇒ user1 名下 2 行、other 名下 1 行、全库 3 行。
/// 空仓上"0==0 自等假绿"，所以每一档都要先看得到"有有效条件时确实出行"。
async fn g1_setup() -> (@memory.MemoryRepository, Array[Int64]) raise {
  let repo = @memory.MemoryRepository::new()
  let d = g1_define()
  repo.save_define(d)
  let ids : Array[Int64] = []
  for who in ["user1", "user1", "other"] {
    let inst = @model.ProcessInstance::create(d, who, @json.FlowData::new())
    repo.save_instance(inst)
    ids.push(inst.instance_id)
  }
  repo.create_cc_instance(ids[0], "boss", ["user1"])
  repo.create_cc_instance(ids[1], "boss", ["user1"])
  repo.create_cc_instance(ids[2], "boss", ["other"])
  (repo, ids)
}

///|
/// ① 缺条件（operator 整条没给）⇒ 空页，且**不得**退化成"这条不加"返回全部实例
async test "i141-G1 内存仓 缺归属条件⇒空页（record_count=0 且 rows=[]）" {
  let (repo, _) = g1_setup()
  // 夹具非空自证：三行 cc 确实在仓里（否则下面 0==0 是假绿）
  assert_eq(repo.cc_instances.length(), 3)
  let page = repo.page_cc_instances(@model.PageQuery::new(1L, 50L))
  assert_eq(page.record_count(), 0L)
  assert_eq(page.rows().length(), 0)
}

///|
/// ② 空值条件（operator=""）⇒ 空页（"空串当真实值比对"与"直接空页"终局同档，这里钉终局）
async test "i141-G1 内存仓 空串归属条件⇒空页" {
  let (repo, _) = g1_setup()
  let q = @model.PageQuery::new(1L, 50L)
  q.set_operator(Some(""))
  let page = repo.page_cc_instances(q)
  assert_eq(page.record_count(), 0L)
  assert_eq(page.rows().length(), 0)
}

///|
/// ③ 全空白条件 ⇒ 空页（有效条件＝去空白后非空，与门面 operator_arg / SQL 侧 build_m_where 同档）
async test "i141-G1 内存仓 全空白归属条件⇒空页" {
  let (repo, _) = g1_setup()
  for blank in [" ", "   ", "\t", "\r\n"] {
    let q = @model.PageQuery::new(1L, 50L)
    q.set_operator(Some(blank))
    let page = repo.page_cc_instances(q)
    assert_eq(page.record_count(), 0L)
    assert_eq(page.rows().length(), 0)
  }
}

///|
/// ④ 正向对照：有效归属条件照常出行（防"一律空页"那种假修）
async test "i141-G1 内存仓 有效归属条件照常出行（正向对照）" {
  let (repo, ids) = g1_setup()
  let q = @model.PageQuery::new(1L, 50L)
  q.set_operator(Some("user1"))
  let page = repo.page_cc_instances(q)
  assert_eq(page.record_count(), 2L)
  assert_eq(page.rows().length(), 2)
  for r in page.rows() {
    // 行源＝实例表（issues/138 行形状），两行都抄给 user1 ⇒ 主键是实例 id
    assert_true(r.id == ids[0] || r.id == ids[1])
  }
  let q2 = @model.PageQuery::new(1L, 50L)
  q2.set_operator(Some("other"))
  let page2 = repo.page_cc_instances(q2)
  assert_eq(page2.record_count(), 1L)
  assert_eq(page2.rows()[0].id, ids[2])
  // 查无此人 ⇒ 空页（与新契约的"缺条件空页"是两回事，这条旧行为不许变）
  let q3 = @model.PageQuery::new(1L, 50L)
  q3.set_operator(Some("nobody"))
  assert_eq(repo.page_cc_instances(q3).record_count(), 0L)
}

///|
/// ⑤ 判据单点：@model.cc_ownership_operator 四档（缺键/空串/全空白 ⇒ None；有效 ⇒ Some **原值**）
/// 两仓储都调这一个函数 ⇒ 同一栈两个仓储不可能再给两个答案。
test "i141-G1 判据单点 cc_ownership_operator 四档" {
  let q0 = @model.PageQuery::new(1L, 10L)
  assert_true(@model.cc_ownership_operator(q0) is None)
  let q1 = @model.PageQuery::new(1L, 10L)
  q1.set_operator(Some(""))
  assert_true(@model.cc_ownership_operator(q1) is None)
  let q2 = @model.PageQuery::new(1L, 10L)
  q2.set_operator(Some(" \t\r\n "))
  assert_true(@model.cc_ownership_operator(q2) is None)
  let q3 = @model.PageQuery::new(1L, 10L)
  q3.set_operator(Some("user1"))
  // 有效档返回**原值**（不是空白化后的串）⇒ 比对语义与改前逐字一致
  assert_eq(@model.cc_ownership_operator(q3), Some("user1"))
  // 判据只看归属列那一档：塞进非归属列的 m_ 条件不影响判定
  let q4 = @model.PageQuery::new(1L, 10L)
  q4.set_operator(Some("user1"))
  q4.add_filter(@model.QueryFilter::make("pi", @model.Like, "display_name", ""))
  assert_eq(@model.cc_ownership_operator(q4), Some("user1"))
  let q5 = @model.PageQuery::new(1L, 10L)
  q5.add_filter(@model.QueryFilter::make("pi", @model.Eq, "business_no", ""))
  assert_true(@model.cc_ownership_operator(q5) is None)
}

///|
/// ⑥ 非归属列的空值放行**不变**：有效归属条件 + 空值 m_ 过滤 ⇒ 照旧出行（内存通道本就不做
/// m_ 后过滤，这条防后续照搬 SQL 侧通用放行时把归属列一起吞掉，与 i129-L2 同一条尺子）。
async test "i141-G1 内存仓 非归属列空值仍放行（不误伤）" {
  let (repo, _) = g1_setup()
  let q = @model.PageQuery::new(1L, 50L)
  q.set_operator(Some("user1"))
  q.add_filter(@model.QueryFilter::make("pi", @model.Like, "business_no", ""))
  q.add_filter(@model.QueryFilter::make("pd", @model.Eq, "name", ""))
  assert_eq(repo.page_cc_instances(q).record_count(), 2L)
  // 同一批空值过滤挂在**别人**的归属档上也不改变结论（0 行是归属决定的，不是空值过滤决定的）
  let q2 = @model.PageQuery::new(1L, 50L)
  q2.set_operator(Some("nobody"))
  q2.add_filter(@model.QueryFilter::make("pi", @model.Like, "business_no", ""))
  assert_eq(repo.page_cc_instances(q2).record_count(), 0L)
}

