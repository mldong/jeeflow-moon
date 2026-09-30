// issues/142 B 批（spec 06-facade §2.11「归属值写侧归一」）—— **内存仓写侧** add_task_actor 兜底档（T0）。
//
// 为什么两层都挡（§2.11 要求①，与 §2.10 同构）：只修门面腿/引擎腿 ⇒ 绕过它们**直连仓储**的调用方
// （集成层、第三方仓储消费者）照样能往归属列 `wf_process_task_actor.actor_id` 灌空值 ——
// 那正是 issues/129 那族"空归属值读全库"的进水口。
//
// 本栈普查改前实测（issues/142 §2 B 表 moon 行「两仓判重不判空」）：
// `add_task_actor` 只做 `!entry.contains(a)` 判重 ⇒ `[""]` 落一行 actor_id=""、`["  "]` 落一行、
// `[" a ","a"]` 落两行（同一人两行，把"落库与比较取 trim 后的值"这条打穿）。
//
// 判据单点：@model 那一枚归一函数（issues/141 G10 落地时叫 normalize_cc_actors，
// 本批按 §2.11 尾注升格为通用单点并保留旧名转发）—— 引擎漏斗、门面手动腿、内存仓、MySQL 仓
// 四支读的都是同一份，"同一栈两个仓储两个答案"由构造堵死（issues/117 场景 27 那把尺子）。

///|
/// ① 直连仓储兜底：空串与纯空白 ⇒ 一行都不落（与 cc 腿的 repoWritePathAlsoDropsBlankActors 同名同判）
async test "i142-B 内存仓 直连 add_task_actor 空值⇒零行（绕过门面也挡得住）" {
  let repo = @memory.MemoryRepository::new()
  let _ = repo.add_task_actor(7001L, [""])
  assert_eq(repo.find_task_actors(7001L), [])
  let _ = repo.add_task_actor(7002L, ["  "])
  assert_eq(repo.find_task_actors(7002L), [])
  let _ = repo.add_task_actor(7003L, ["", "  ", "\t\n"])
  assert_eq(repo.find_task_actors(7003L), [])
  // 全空不许把键"点亮"成空集合以外的东西（读回仍是空）
  assert_eq(repo.find_task_actors(7003L), [])
}

///|
/// ② 混给只丢空、正常值一个不少；落库值取 trim 后的串（改前红：[" a ","a"] 落两行）
async test "i142-B 内存仓 混给只丢空＋落库取 trim 后的值" {
  let repo = @memory.MemoryRepository::new()
  let _ = repo.add_task_actor(7011L, ["a", "", "  ", "b"])
  assert_eq(repo.find_task_actors(7011L), ["a", "b"])
  // 空白包裹值与干净值是同一个人 ⇒ 同调用折叠
  let _ = repo.add_task_actor(7012L, [" 123 ", "123", "\t123\n"])
  assert_eq(repo.find_task_actors(7012L), ["123"])
  // 跨调用同理（判重读的是 trim 后的落库值）
  let _ = repo.add_task_actor(7013L, ["userB"])
  let _ = repo.add_task_actor(7013L, [" userB "])
  assert_eq(repo.find_task_actors(7013L), ["userB"])
  // 正向对照：判据不误伤
  let _ = repo.add_task_actor(7014L, ["userB", "userC"])
  assert_eq(repo.find_task_actors(7014L), ["userB", "userC"])
}

///|
/// ③ 反向哨兵："0" 与 "00" 是两个人，都得落；" " 是空白，丢掉
///    （严禁用语言自带 falsy 判据做判空 —— 判空一律 trim()==""）
async test "i142-B 内存仓 反向哨兵 \"0\"/\"00\" 两人都落（\" \" 按空白丢弃）" {
  let repo = @memory.MemoryRepository::new()
  let _ = repo.add_task_actor(7021L, ["0", "00", " ", "a"])
  assert_eq(repo.find_task_actors(7021L), ["0", "00", "a"])
  let _ = repo.add_task_actor(7022L, ["0"])
  assert_eq(repo.find_task_actors(7022L), ["0"])
}

///|
/// ④ 删除腿口径不破（本批只归一**写侧**）：干净值照旧精确摘除，摘完读回为空
async test "i142-B 内存仓 remove_task_actor 既有精确摘除口径不破（回归钉）" {
  let repo = @memory.MemoryRepository::new()
  let _ = repo.add_task_actor(7031L, ["x", "y"])
  let _ = repo.remove_task_actor(7031L, ["x"])
  assert_eq(repo.find_task_actors(7031L), ["y"])
  let _ = repo.remove_task_actor(7031L, ["y", "", "  "])
  assert_eq(repo.find_task_actors(7031L), [])
}

///|
/// ② 删除位（issues/142 §9.2 第二批）：「 8601 」删得掉 trim 后的 8601；归一后为空 ⇒ 一行不删——
///    历史 actor_id='' 脏行不得被空串入参批量误删（issues/129 的删除位对偶）
async test "i142-B 内存仓 remove_task_actor 删除位 trim 命中＋空档零删除（脏行保留）" {
  let repo = @memory.MemoryRepository::new()
  let _ = repo.add_task_actor(7041L, ["  i142d  "])
  assert_eq(repo.find_task_actors(7041L), ["i142d"])  // 前置：写侧落库存 trim 值
  let _ = repo.remove_task_actor(7041L, ["  i142d  "])
  assert_eq(repo.find_task_actors(7041L), [])
  // 历史脏行（旧版本写进去的 actor_id="" 行）：空串/全白入参一条都不许删
  repo.task_actors[7042L] = ["i142e", ""]
  let _ = repo.remove_task_actor(7042L, ["", "   "])
  let _ = repo.remove_task_actor(7042L, [])
  assert_eq(repo.find_task_actors(7042L), ["i142e", ""])
}
