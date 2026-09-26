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
  // 时钟基准先于装配注入（issues/120 §9：引擎不自取基准，由宿主供给；本栈无集成壳 ⇒ demo 就是宿主）
  apply_clock_from_env()
  match @env.get_env_var("JEEFLOW_DEMO_STORE") {
    Some("mysql") => App::mysql_mode()
    _ => App::memory_only()
  }
}

///|
/// 时钟基准注入。`JEEFLOW_TZ_OFFSET` 接受**东为正**的小时偏移，三种写法：
/// `8` / `+8` / `-5`（整小时）、`5.5` / `-9.5`（小数小时）、`+05:30`（时:分）。
///
/// **未配或解析失败 ⇒ 不注入**，保持引擎默认臂 UTC —— 宁可显示 UTC，也不静默替用户猜一个区
/// （这也是 120 那条契约句的可执行形状：基准由宿主注入的时钟决定，未注入不作跨栈承诺）。
pub fn apply_clock_from_env() -> Unit {
  match @env.get_env_var("JEEFLOW_TZ_OFFSET") {
    None => println("时钟基准 = UTC（未配 JEEFLOW_TZ_OFFSET）")
    Some(raw) =>
      match parse_tz_offset_seconds(raw) {
        Some(secs) => {
          let delta = secs.to_int64()
          @model.set_clock(Some(fn() { @model.format_unix_utc(@model.epoch_secs() + delta) }))
          println("时钟基准 = JEEFLOW_TZ_OFFSET=\{raw}（\{secs} 秒）")
        }
        None => println("时钟基准 = UTC（JEEFLOW_TZ_OFFSET=\{raw} 解析失败）")
      }
  }
}

///|
/// 纯数字解析。本工具链的 `@string.parse_int` 是 raise 形态（旧写法 `(...)` 配 Ok/Err
/// 在两代编译器间含义不同），而这里偏移量只允许十进制数字，自己扫更直白。
fn digits_to_int(s : String) -> Int? {
  let cs = s.to_array()
  if cs.is_empty() {
    return None
  }
  let zero = '0'.to_int()
  let mut acc = 0
  for ch in cs {
    let d = ch.to_int() - zero
    if d < 0 || d > 9 {
      return None
    }
    acc = acc * 10 + d
  }
  Some(acc)
}

///|
/// 解析小时偏移为秒。上限 UTC+14（50400 秒），越界或格式不符 ⇒ None（调用侧回落 UTC）。
pub fn parse_tz_offset_seconds(raw : String) -> Int? {
  let s = raw.trim(chars=" \t\r\n").to_string()
  if s.is_empty() {
    return None
  }
  let neg = s.has_prefix("-")
  let body =
    if s.has_prefix("+") || s.has_prefix("-") {
      s.substring(start=1, end=s.length()).to_string()
    } else {
      s
    }
  if body.is_empty() {
    return None
  }
  let magnitude =
    if body.contains_char(':') {
      hh_mm_to_secs(body)
    } else if body.contains_char('.') {
      decimal_hours_to_secs(body)
    } else {
      match digits_to_int(body) {
        Some(h) => Some(h * 3600)
        None => None
      }
    }
  match magnitude {
    Some(v) =>
      if v > 50400 {
        None
      } else {
        Some(if neg { -v } else { v })
      }
    None => None
  }
}

///|
/// `HH:MM` → 秒（只允许一个冒号）
fn hh_mm_to_secs(body : String) -> Int? {
  match body.find(":") {
    None => None
    Some(i) => {
      let hs = body.substring(start=0, end=i).to_string()
      let ms = body.substring(start=i + 1, end=body.length()).to_string()
      if ms.contains_char(':') {
        return None
      }
      match (digits_to_int(hs), digits_to_int(ms)) {
        (Some(h), Some(m)) =>
          if m > 59 {
            None
          } else {
            Some(h * 3600 + m * 60)
          }
        _ => None
      }
    }
  }
}

///|
/// `H.M` → 秒（只允许一个小数点；小数补齐/截断到两位后按「百分之一小时」换算：
/// `.5` ⇒ 50 ⇒ 1800 秒，`.75` ⇒ 45 ⇒ 2700 秒）
fn decimal_hours_to_secs(body : String) -> Int? {
  match body.find(".") {
    None => None
    Some(i) => {
      let hs = body.substring(start=0, end=i).to_string()
      let fs = body.substring(start=i + 1, end=body.length()).to_string()
      if fs.contains_char('.') {
        return None
      }
      let h =
        match digits_to_int(hs) {
          Some(v) => v
          None => return None
        }
      let pad2 =
        if fs.is_empty() {
          "00"
        } else if fs.length() == 1 {
          fs + "0"
        } else {
          fs.substring(start=0, end=2).to_string()
        }
      match digits_to_int(pad2) {
        Some(dd) => Some(h * 3600 + dd * 36)
        None => None
      }
    }
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
  if path.has_prefix("/wf/") {
    let action = path.substring(start=4).to_string()
    // body 解析失败 → 99999999 + stderr（rust issue 88 教训）
    let trimmed = body.trim(chars=" \t\r\n").to_string()
    // parse_json 现在直接 raise（不再返回 Result）：三档判据原样保留
    // ——空 body 当空对象；坏 JSON 打印并转 99999999（rust issue 88 的教训）；非对象另一条文案。
    let parsed = if trimmed.is_empty() {
      @json.empty_object()
    } else {
      try {
        @json.parse_json(trimmed)
      } catch {
        e => {
          println("[demo] body 解析失败: \{e.message()}")
          raise @error.Business("body 解析失败: \{e.message()}")
        }
      }
    }
    let args : Map[String, Json] = match parsed {
      Json::Object(m) => {
        let copy : Map[String, Json] = Map([])
        for k, v in m {
          copy[k] = v
        }
        copy
      }
      _ => {
        println("[demo] body 解析失败: 非 JSON 对象")
        raise @error.Business("body 必须是 JSON 对象")
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
