// issues/137 §3-6（spec 06-facade §processTask/removeTaskActor 语义 6 · owner 2026-10-02 拍
// 「两形并集」）—— **内存仓删除腿**的档位（T0）。纯函数档在 core/model 的
// i137_36_actor_delete_forms_test.mbt；MySQL 仓那一路的判据同一条（两仓必须同答案，
// issues/117 场景 27），真库腿按本仓既有惯例留给 T1/镜像轮。
//
// 与 i142b_task_actor_write_test.mbt 的分工：那份钉**写侧**（落库取 trim 值）与 142 §9.2 的
// "删除位 trim 命中"；本份钉**删除腿的并集**——既保住 142 那一半（规范行按 trim 形删得掉），
// 又补上本栈改前缺的另一半（未 trim 历史脏行按原值形删得掉）。
//
// ⚠️ 本份的既有测试**一行未改**：并集包含 trim 形，所以 i142b 那两格照绿。这正是选并集
// 而不是选"只丢空不 trim"的理由——后者会把 142 §9.2 已发版的判据打红（java 侧实测过：
// 变异成只产出原值形 ⇒ `normalizedRowIsStillDeletedByTrimmedForm` 当场红）。
//
// 种脏行一律**绕开写侧归一**直接写 `repo.task_actors`：`add_task_actor` 会 trim＋丢空，
// 正常路径建不出 " 9101 " 也建不出 actor_id='' 行，而这两档正是删除腿要照的。
// 脏行夹具用**前导空格**——MySQL 5.7 PAD SPACE 只忽略尾部空格、8.0 NO PAD 连尾部也算，
// 前导空格在任何排序规则下都与规范行不等，判据不会因跑在哪台库上而漂。

///|
async test "i137-§3-6 内存仓：未 trim 历史脏行按**原值形**真删掉（改前这一格红＝门面报成功的假成功）" {
  let repo = @memory.MemoryRepository::new()
  repo.task_actors[7051L] = [" 9101 ", "leader"]
  let _ = repo.remove_task_actor(7051L, [" 9101 "])
  // 改前本栈过 @model.normalize_actors ⇒ 实参被削成 "9101" ⇒ 脏行 " 9101 " 留在库里、
  // 门面却报成功（被摘的人待办还在）。并集带上原值形才真删得掉。
  assert_eq(repo.find_task_actors(7051L), ["leader"])
}

///|
async test "i137-§3-6 内存仓：规范行按 **trim 形**删得掉（issues/142 §9.2 既有判据不破）" {
  let repo = @memory.MemoryRepository::new()
  repo.task_actors[7052L] = ["8601", "leader"]
  let _ = repo.remove_task_actor(7052L, [" 8601 "])
  // 这一档是 142 §9.2 立的：绕过门面直连仓储传带空格的值，也要删得掉写侧归一后的规范行。
  // 若把并集退化成"只丢空不 trim"（owner A 案的字面形状），这一格当场红。
  assert_eq(repo.find_task_actors(7052L), ["leader"])
}

///|
async test "i137-§3-6 内存仓：同一个人的两形并存 ⇒ 两行都摘，其余参与人一行不动" {
  let repo = @memory.MemoryRepository::new()
  repo.task_actors[7053L] = [" 9101 ", "9101", "leader", "boss"]
  let _ = repo.remove_task_actor(7053L, [" 9101 "])
  // 按 §2.11 归一口径 " 9101 " 与 9101 本就是同一个人 ⇒ 两行都删才是"摘掉这个人"，不构成误删。
  // 语义 1「只摘不加、不动其他参与人」也在这里一并钉住。
  assert_eq(repo.find_task_actors(7053L), ["leader", "boss"])
}

///|
async test "i137-§3-6 内存仓：空值入参一行都不许删（历史 actor_id=''／纯空白脏行保留）" {
  let repo = @memory.MemoryRepository::new()
  repo.task_actors[7054L] = ["", "   ", "leader"]
  let _ = repo.remove_task_actor(7054L, ["", "   "])
  // 空归属值是 issues/129 那族"空 operator 读全库"的取证痕迹，不得被一次空值入参做掉
  assert_eq(repo.find_task_actors(7054L), ["", "   ", "leader"])
}

///|
async test "i137-§3-6 内存仓：全空入参是**零删除**，不得退化成清空全部参与者" {
  let repo = @memory.MemoryRepository::new()
  repo.task_actors[7055L] = ["zhangsan", "leader"]
  let _ = repo.remove_task_actor(7055L, ["", "  "])
  let _ = repo.remove_task_actor(7055L, [])
  // 少了这一条，一次误传空串就会留下永远无人可办、也无法撤回重派的死任务
  // （语义 5「至少需保留一名参与人」的仓储侧对偶）
  assert_eq(repo.find_task_actors(7055L), ["zhangsan", "leader"])
}

///|
async test "i137-§3-6 内存仓：反向哨兵 \"0\" 与 \"00\" 是两个人，摘一个不得连带另一个" {
  let repo = @memory.MemoryRepository::new()
  repo.task_actors[7057L] = ["0", "00", "leader"]
  let _ = repo.remove_task_actor(7057L, ["0"])
  assert_eq(repo.find_task_actors(7057L), ["00", "leader"])
}

///|
async test "i137-§3-6 内存仓：非参与者静默忽略（语义 7 幂等）＋任务不存在是零操作不 panic" {
  let repo = @memory.MemoryRepository::new()
  repo.task_actors[7056L] = ["zhangsan", "leader"]
  let _ = repo.remove_task_actor(7056L, ["stranger", " 9999 "])
  assert_eq(repo.find_task_actors(7056L), ["zhangsan", "leader"])
  // 不存在的 taskId：find_task_actors 返回 []，remove 是零操作
  let _ = repo.remove_task_actor(404404L, [" 9101 "])
  assert_eq(repo.find_task_actors(404404L), [])
}

///|
async test "i137-§3-6 内存仓：走写侧正规路径加的人，仍按 trim 形摘得掉（与 i142b 回归钉同源）" {
  let repo = @memory.MemoryRepository::new()
  let _ = repo.add_task_actor(7058L, ["  i137f  ", "keep"])
  assert_eq(repo.find_task_actors(7058L), ["i137f", "keep"]) // 前置：写侧落库存 trim 值
  let _ = repo.remove_task_actor(7058L, ["  i137f  "])
  assert_eq(repo.find_task_actors(7058L), ["keep"])
}
