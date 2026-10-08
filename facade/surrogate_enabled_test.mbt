// issues/148：委托 `enabled` 的写侧归一（spec 06 §4.5 条款 4「读写两侧分别定」）。
// 旧行为＝脏值抛 `99999999 非法id: abc`（连字段名都说错），门禁 L2-18 写侧那腿因此恒红。
// 两个用例都只走**公开门面 action**（本包测试件是独立 test 包，够不到源包的非 pub 项），
// 并且不只看信封：脏值档要**端到端按停用处理**（委托代理人不得并入），缺省档要照旧按启用并入
// —— 后者是反向哨兵，防止把缺省一起改死成 0。
// 读侧判据（只有数值 1 生效）另由 core/engine/surrogate_test.mbt 与 model 的 is_effective 用例钉。

///|
async fn se148_save(
  facade : @facade.Facade[@mem.MemoryRepository, @mem.MemoryRepository],
  enabled : Json?
) -> Json raise {
  let entries : Array[(String, Json)] = [
    ("operator", Json::string("leader")),
    ("surrogate", Json::string("li")),
    ("processName", Json::string("wt-linear")),
  ]
  match enabled {
    Some(v) => {
      let _ = entries.push(("enabled", v))
    }
    None => ()
  }
  facade.flow("processSurrogate/save", Map(entries))
}

///|
async test "148 脏值档：建单不抛，且按停用处理（委托代理人不并入）" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer {
    @model.set_clock(None)
  }
  let repo = @mem.MemoryRepository::new()
  let facade = sg_facade(repo)
  let did = sg_define_id(repo, linear_flow_json())
  for dirty in [
    @json.string_of("abc"),
    @json.string_of(""),
    @json.string_of("1x"),
    @json.null_json()
  ] {
    let env = se148_save(facade, Some(dirty))
    sg_ok(
      code_of(env) == 0L,
      "脏值档应建单成功，不得抛（实际 code=\{code_of(env)} msg=\{msg_of(env)}）",
    )
  }
  // 库里最新一条就是脏值档 ⇒ 写侧必须落成"停用"，否则代理人会被并进来
  let iid = sg_started(facade, did)
  let actors = repo.find_task_actors(doing_task_for(repo, iid, "leader").task_id)
  sg_ok(
    actors.contains("leader") && !actors.contains("li"),
    "脏值应按 enabled=0 处理：原人保留、代理人不并入（实际参与者=\{actors.join("|")}）",
  )
}

///|
async test "148 缺省与串化档：不带键=1、带 '1'=1，两种都该并入代理人（反向哨兵）" {
  @model.set_clock(Some(fn() { "2026-09-21 10:00:00" }))
  defer {
    @model.set_clock(None)
  }
  let repo = @mem.MemoryRepository::new()
  let facade = sg_facade(repo)
  let did = sg_define_id(repo, linear_flow_json())
  let omitted = se148_save(facade, None)
  sg_ok(code_of(omitted) == 0L, "缺省档应建单成功（msg=\{msg_of(omitted)}）")
  let iid1 = sg_started(facade, did)
  let actors1 = repo.find_task_actors(doing_task_for(repo, iid1, "leader").task_id)
  sg_ok(actors1.contains("li"), "缺省=1 应并入代理人（实际=\{actors1.join("|")}）")
  // 驱动把整数串化成的 "1" 同样要生效（issues/130 第 3 条）
  let str1 = se148_save(facade, Some(@json.string_of("1")))
  sg_ok(code_of(str1) == 0L, "'1' 档应建单成功（msg=\{msg_of(str1)}）")
  let iid2 = sg_started(facade, did)
  let actors2 = repo.find_task_actors(doing_task_for(repo, iid2, "leader").task_id)
  sg_ok(actors2.contains("li"), "串化 '1' 应生效并并入代理人（实际=\{actors2.join("|")}）")
}
