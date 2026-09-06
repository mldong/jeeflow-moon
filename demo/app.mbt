// demo HTTP server :8092 —— POST /wf/{action} 全转发 facade + /health + /api/stats + /api/reset + CORS
// demo 层零业务（方案 §2.6）；JEEFLOW_DEMO_STORE=memory(默认)|mysql；demo 层 body 解析失败→99999999+stderr 日志（rust 88 教训）

///|
pub(all) struct App {
  mut store : String
  mut memory_repo : @memory.MemoryRepository
  mut mem_facade : @facade.Facade[@memory.MemoryRepository, @memory.MemoryRepository]
  mut mysql_repo : @repo.MysqlRepository?
  mut my_facade : @facade.Facade[@repo.MysqlRepository, @spi.NoExtRepository]?
  mut seeded_defines : Int64
}

///|
pub async fn App::memory_only() -> App raise {
  let repo = @memory.MemoryRepository::new()
  seed_memory(repo)
  let n = 0L
  let ctx = make_mem_ctx(repo)
  let f = @facade.Facade::make(ctx)
  // T003：业务数据种子（引擎真实启动 16 进行中 + 9 已完成 + 8 委托）
  seed_business(f)
  {
    store: "memory",
    memory_repo: repo,
    mem_facade: f,
    mysql_repo: None,
    my_facade: None,
    seeded_defines: n,
  }
}

///|
fn make_mem_ctx(repo : @memory.MemoryRepository) -> @spi.Ctx[@memory.MemoryRepository, @memory.MemoryRepository] {
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.DefaultIdGenerator::new(2L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let ctx3 = ctx2.with_user_provider(demo_user_provider)
  let ctx4 = ctx3.with_org_user_provider(demo_org_provider())
  let _ = ctx4.with_user_search_provider(demo_user_search_provider())
  ctx4
}

///|
fn make_my_ctx(repo : @repo.MysqlRepository) -> @spi.Ctx[@repo.MysqlRepository, @spi.NoExtRepository] {
  let ctx = @spi.Ctx::new(repo, @spi.NoExtRepository::new())
  let gen = @id_gen.DefaultIdGenerator::new(2L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() })
  let ctx3 = ctx2.with_user_provider(demo_user_provider)
  let ctx4 = ctx3.with_org_user_provider(demo_org_provider())
  let _ = ctx4.with_user_search_provider(demo_user_search_provider())
  ctx4
}

///|
pub fn App::mysql_mode() -> App raise {
  let repo = @repo.MysqlRepository::from_env()
  let ctx4 = make_my_ctx(repo)
  {
    store: "mysql",
    memory_repo: @memory.MemoryRepository::new(),
    mem_facade: @facade.Facade::make(make_mem_ctx(@memory.MemoryRepository::new())),
    mysql_repo: Some(repo),
    my_facade: Some(@facade.Facade::make(ctx4)),
    seeded_defines: 0L,
  }
}

///|
pub async fn App::create() -> App raise {
  match @env.get_env_var("JEEFLOW_DEMO_STORE") {
    Some("mysql") => App::mysql_mode()
    _ => App::memory_only()
  }
}

///|
/// /api/reset：memory 重建状态 + 重载种子 + 复跑业务种子；mysql 仅清 demo 自身不可行（共享库）→ 回 ok
pub async fn App::reset(self : App) -> Unit raise {
  if self.store == "memory" {
    let repo = @memory.MemoryRepository::new()
    seed_memory(repo)
    self.memory_repo = repo
    let f = @facade.Facade::make(make_mem_ctx(repo))
    self.mem_facade = f
    seed_business(f)
  }
}

///|
/// 请求分发：返回 (status, json)
pub async fn App::handle(self : App, method : String, path : String, query_string : String, body : String) -> (Int, String) raise {
  if path == "/health" {
    return (200, "{\"status\":\"ok\",\"engine\":\"jeeflow-moon\",\"store\":\"" + self.store + "\"}")
  }
  if path == "/api/reset" {
    self.reset()
    return (200, "{\"code\":0,\"msg\":\"成功\"}")
  }
  if path == "/api/stats" {
    let operator = query_param(query_string, "operator").unwrap_or("user1")
    let todo = match self.store {
      "mysql" =>
        match self.mysql_repo {
          Some(r) => r.count_todo_tasks(operator)
          None => 0L
        }
      _ => self.memory_repo.count_todo_tasks(operator)
    }
    let q = @model.PageQuery::new(1L, 1L)
    q.set_operator(Some(operator))
    let instance_count = match self.store {
      "mysql" =>
        match self.mysql_repo {
          Some(r) => r.page_instances(q).record_count()
          None => 0L
        }
      _ => self.memory_repo.page_instances(q).record_count()
    }
    let obj = @json.empty_object()
    @json.obj_set(obj, "todoCount", @json.number_of(todo))
    @json.obj_set(obj, "instanceCount", @json.number_of(instance_count))
    return (200, @json.stringify(obj))
  }
  // POST /wf/{action} → facade 全转发
  if path.starts_with("/wf/") {
    let action = path.substring(start=4).to_string()
    // body 解析失败 → 99999999 + stderr（rust issue 88 教训）
    let trimmed = body.trim(chars=" \t\r\n").to_string()
    let parsed = if trimmed.is_empty() {
      Ok(@json.empty_object())
    } else {
      try? @json.parse_json(trimmed)
    }
    let args : Map[String, Json] = match parsed {
      Ok(Json::Object(m)) => {
        let copy : Map[String, Json] = Map::new()
        for k, v in m {
          copy[k] = v
        }
        copy
      }
      Ok(_) => {
        println("[demo] body 解析失败: 非 JSON 对象")
        raise @error.Business("body 必须是 JSON 对象")
      }
      Err(e) => {
        println("[demo] body 解析失败: \{e.message()}")
        raise @error.Business("body 解析失败: \{e.message()}")
      }
    }
    let result = match self.store {
      "mysql" =>
        match self.my_facade {
          Some(f) => f.flow(action, args)
          None => err_local("store 未初始化")
        }
      _ => self.mem_facade.flow(action, args)
    }
    return (200, @json.stringify(result))
  }
  (404, "{\"code\":99999999,\"msg\":\"unknown path: " + path + "\"}")
}

///|
fn err_local(msg : String) -> Json {
  let o = @json.empty_object()
  @json.obj_set(o, "code", @json.number_of(99999999L))
  @json.obj_set(o, "msg", @json.string_of(msg))
  o
}

///|
fn query_param(qs : String, key : String) -> String? {
  if qs.is_empty() {
    return None
  }
  for pair in qs.split("&") {
    let kv = pair.to_string()
    let idx = kv.find("=")
    match idx {
      Some(i) =>
        if kv.substring(start=0, end=i).to_string() == key {
          return Some(kv.substring(start=i + 1).to_string())
        }
      None => ()
    }
  }
  None
}
