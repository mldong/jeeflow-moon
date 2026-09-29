// issues/141 G10 · 空抄送人不建 cc 行 —— **内存仓写侧**兜底档（T0）。
//
// 为什么两层都挡（spec 06-facade §2.10 四点要求之一，基准＝java `5fbd5ac`）：只修漏斗
// （`core/engine` 的 parse_cc_actors）⇒ 绕过引擎/门面**直连仓储**的调用方（集成层、第三方仓储消费者）
// 照样能往 actor_id 里灌空值，那正是 issues/129 那族"空归属值读全库"的病根。
// 本栈普查改前实测：`repo.create_cc_instance(iid, "boss", [""])` 真落一行 actor_id=""；
// `["  "]` 落一行；`["a","","  "]` 落三行；`[" 123 "]` 与 `["123"]` 落两行（把 b4b6ade 的写侧判重打穿）；
// `create_cc_instance_if_absent` 返回的子集里也带着空值 ⇒ 三条入口拿它去 fire 就是给空抄送人发知会。
//
// 判据单点：@model.normalize_cc_actors（core/model/rows.mbt）——本仓、MySQL 仓、引擎漏斗、门面手动腿
// 四支读的都是这一份，"同一栈两个仓储两个答案"由构造堵死（issues/117 场景 27 那把尺子）。
//
// 复用同包 helper：g2_setup / g2_arr / g2_row_count（i141_g2_cc_idempotent_test.mbt）。

///|
fn g10m_ccvals(repo : @memory.MemoryRepository) -> Array[String] {
  repo.cc_instances.map(fn(c) { c.actor_id })
}

///|
/// ① 直连仓储兜底：空串档与纯空白档都必须零行（java 同名单格 repoWritePathAlsoDropsBlankActors）
async test "i141-G10 内存仓 直连 create_cc_instance 空值⇒零行（绕过引擎漏斗也挡得住）" {
  let (repo_a, iid_a) = g2_setup()
  let _ = repo_a.create_cc_instance(iid_a, "boss", [""])
  assert_eq(g10m_ccvals(repo_a), [])
  assert_eq(repo_a.find_cc_actors(iid_a), [])
  let (repo_b, iid_b) = g2_setup()
  let _ = repo_b.create_cc_instance(iid_b, "boss", ["  "])
  assert_eq(g10m_ccvals(repo_b), [])
  let (repo_c, iid_c) = g2_setup()
  let _ = repo_c.create_cc_instance(iid_c, "boss", ["", "  ", "\t\n"])
  assert_eq(g10m_ccvals(repo_c), [])
  // 全空 ⇒ 连"实例下有没有 cc"都不许变
  assert_eq(repo_c.find_cc_actors(iid_c), [])
}

///|
/// ② 直连仓储：混给只丢空，正常值原样落（判据不误伤）
async test "i141-G10 内存仓 直连混给只丢空：[a,空,纯空白]⇒只 a 一行" {
  let (repo, iid) = g2_setup()
  let _ = repo.create_cc_instance(iid, "boss", ["a", "", "  "])
  assert_eq(g10m_ccvals(repo), ["a"])
  assert_eq(repo.find_cc_actors(iid), ["a"])
  // 正向对照（java nonBlankCcActorsStillCreateRowsAndFire 的仓储档）：两个正常人两行保序
  let (repo2, iid2) = g2_setup()
  let _ = repo2.create_cc_instance(iid2, "boss", ["userB", "userC"])
  assert_eq(g10m_ccvals(repo2), ["userB", "userC"])
}

///|
/// ③ 落库值取 trim 后的串（G2/G10 咬合点）：跨调用与同调用两种重复都只许一行
async test "i141-G10 内存仓 trim 后同值命中写侧判重：[\" 123 \"]＋[\"123\"]⇒一行" {
  let (repo, iid) = g2_setup()
  let _ = repo.create_cc_instance(iid, "boss", [" 123 "])
  let _ = repo.create_cc_instance(iid, "boss", ["123"])
  assert_eq(g10m_ccvals(repo), ["123"])
  assert_eq(g2_row_count(repo, "123"), 1)
  // 同一次调用内的空白化重复也折叠
  let (repo2, iid2) = g2_setup()
  let _ = repo2.create_cc_instance(iid2, "boss", [" a ", "a", "\ta\t"])
  assert_eq(g10m_ccvals(repo2), ["a"])
  // 反向前后顺序：先干净值，再空白包裹值 ⇒ 仍一行
  let (repo3, iid3) = g2_setup()
  let _ = repo3.create_cc_instance(iid3, "boss", ["userB"])
  let _ = repo3.create_cc_instance(iid3, "boss", [" userB "])
  assert_eq(g10m_ccvals(repo3), ["userB"])
}

///|
/// ④ IfAbsent 返回的子集不含空值（三条入口拿它去 fire 码 4，子集里留空值＝给空抄送人发知会）
async test "i141-G10 内存仓 IfAbsent 子集不含空值／空子集⇒零行" {
  let (repo, iid) = g2_setup()
  let created = repo.create_cc_instance_if_absent(iid, "boss", ["", "  "])
  assert_eq(created, [])
  assert_eq(g10m_ccvals(repo), [])
  let created2 = repo.create_cc_instance_if_absent(iid, "boss", ["a", "", "  ", "b"])
  assert_eq(created2, ["a", "b"])
  assert_eq(g10m_ccvals(repo), ["a", "b"])
  // 已有行后再给空白包裹值 ⇒ 子集空（判重命中）⇒ 不新增行
  let created3 = repo.create_cc_instance_if_absent(iid, "boss", [" a ", "  b  "])
  assert_eq(created3, [])
  assert_eq(g10m_ccvals(repo), ["a", "b"])
}

///|
/// ⑤ 反向哨兵："0" 是正常 id，照建照返回（java normalActorIdsAreNotMistakenForBlank）
async test "i141-G10 内存仓 反向哨兵 \"0\" 不被当空值丢掉" {
  let (repo, iid) = g2_setup()
  let created = repo.create_cc_instance_if_absent(iid, "boss", ["0", "", "1"])
  assert_eq(created, ["0", "1"])
  assert_eq(g10m_ccvals(repo), ["0", "1"])
  let _ = repo.create_cc_instance(iid, "boss", [" 0 "])
  assert_eq(g10m_ccvals(repo), ["0", "1"])
  let (repo2, iid2) = g2_setup()
  let _ = repo2.create_cc_instance(iid2, "boss", ["0"])
  assert_eq(g10m_ccvals(repo2), ["0"])
}

///|
/// ⑥ 判据单点四档：本仓读的与引擎漏斗／门面／MySQL 仓读的是同一份 normalize_cc_actors
test "i141-G10 判据单点 normalize_cc_actors（四层共用那一份）" {
  assert_eq(@model.normalize_cc_actors([]), [])
  assert_eq(@model.normalize_cc_actors(["", "  ", "\t\n"]), [])
  assert_eq(@model.normalize_cc_actors(["a", "", "  ", "b"]), ["a", "b"])
  assert_eq(@model.normalize_cc_actors([" a ", "a", " 123 "]), ["a", "123"])
  assert_eq(@model.normalize_cc_actors(["0", "false"]), ["0", "false"])
  // 顺序保持（fire 序与入参序一一对应，spec §11.3 码 4 逐人一事件）
  assert_eq(@model.normalize_cc_actors(["c", "b", "a"]), ["c", "b", "a"])
}
