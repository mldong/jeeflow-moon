// jeeflow demo 应用层 —— 8 具名用户 SPI + flows 种子 + memory/mysql 双存储（方案 §2.6）

///|
/// 8 具名用户（对齐 rust demo-salvo / php demo-slim）
pub fn demo_users() -> Array[@model.UserInfo] {
  [
    @model.UserInfo::make(user_id="user1", real_name="张三", dept_id="dept1", dept_name="研发部", post_id="post1", post_name="工程师"),
    @model.UserInfo::make(user_id="userA", real_name="孙倩", dept_id="dept2", dept_name="产品部", post_id="post1", post_name="工程师"),
    @model.UserInfo::make(user_id="userB", real_name="周明", dept_id="dept2", dept_name="产品部", post_id="post2", post_name="经理"),
    @model.UserInfo::make(user_id="userC", real_name="吴婷", dept_id="dept3", dept_name="财务部", post_id="post1", post_name="工程师"),
    @model.UserInfo::make(user_id="leader", real_name="李四", dept_id="dept1", dept_name="研发部", post_id="post3", post_name="总监"),
    @model.UserInfo::make(user_id="manager", real_name="王五", dept_id="dept3", dept_name="财务部", post_id="post2", post_name="经理"),
    @model.UserInfo::make(user_id="director", real_name="赵六", dept_id="dept1", dept_name="研发部", post_id="post4", post_name="分管领导"),
    @model.UserInfo::make(user_id="boss", real_name="钱七", dept_id="dept0", dept_name="总经理办公室", post_id="post5", post_name="总经理"),
  ]
}

///|
fn find_user(uid : String) -> @model.UserInfo? {
  for u in demo_users() {
    if u.user_id() == uid {
      return Some(u)
    }
  }
  None
}

///|
/// IUserProvider 注入形态
pub fn demo_user_provider(uid : String) -> @model.UserInfo? raise @error.JeeflowError {
  find_user(uid)
}

///|
/// IOrgUserProvider：dept 经理/分管/角色 —— demo 规则：同部门 post2+ 视为经理层；boss 兜底
pub fn demo_org_provider() -> @spi.OrgUserProviderFns {
  {
    find_dept_leaders: fn(dept_id) {
      let out : Array[String] = []
      for u in demo_users() {
        if u.dept_id() == dept_id && (u.post_id() == "post2" || u.post_id() == "post3") {
          out.push(u.user_id())
        }
      }
      out
    },
    find_dept_main_leaders: fn(dept_id) {
      let out : Array[String] = []
      for u in demo_users() {
        if u.dept_id() == dept_id && (u.post_id() == "post4" || u.post_id() == "post5") {
          out.push(u.user_id())
        }
      }
      if out.is_empty() {
        ["boss"]
      } else {
        out
      }
    },
    find_by_role: fn(role_code) {
      // 节点 id 即角色码：demo 规则 leader/manager/director/boss 命中含对应前缀的角色
      let out : Array[String] = []
      for u in demo_users() {
        if u.user_id() == role_code || u.post_name().contains(role_code) {
          out.push(u.user_id())
        }
      }
      if out.is_empty() && role_code == "leader" {
        ["leader"]
      } else {
        out
      }
    },
  }
}

///|
/// IUserSearchProvider：关键词分页（realName/userId contains，realName 优先于 id）
pub fn demo_user_search_provider() -> @spi.UserSearchProviderFns {
  {
    page: fn(query) {
      let keyword = match query.operator() {
        Some(k) => k
        None => ""
      }
      let matched : Array[@model.UserInfo] = []
      for u in demo_users() {
        if keyword.is_empty() || u.real_name().contains(keyword) || u.user_id().contains(keyword) {
          matched.push(u)
        }
      }
      let rows : Array[Map[String, Json]] = []
      for u in matched {
        let row : Map[String, Json] = Map::new()
        row["id"] = @json.string_of(u.user_id())
        row["userId"] = @json.string_of(u.user_id())
        row["realName"] = @json.string_of(u.real_name())
        row["deptName"] = @json.string_of(u.dept_name())
        rows.push(row)
      }
      let start = ((query.page_num() - 1L) * query.page_size()).to_int()
      let page_rows : Array[Map[String, Json]] = []
      var i = start
      let total = rows.length()
      while i < total && i < start + query.page_size().to_int() {
        page_rows.push(rows[i])
        i = i + 1
      }
      @model.PageResult::new(query.page_num(), query.page_size(), total.to_int64(), page_rows)
    },
    find_by_id: fn(uid) {
      match find_user(uid) {
        Some(u) => {
          let row : Map[String, Json] = Map::new()
          row["id"] = @json.string_of(u.user_id())
          row["userId"] = @json.string_of(u.user_id())
          row["realName"] = @json.string_of(u.real_name())
          row["deptName"] = @json.string_of(u.dept_name())
          Some(row)
        }
        None => None
      }
    },
  }
}

///|
/// flows 目录定位（demo 层允许 fs）：候选目录探测
pub async fn flows_dir() -> String raise {
  for dir in ["../../flows", "../flows", "flows", "demo/../../flows"] {
    if @fs.can_read("\{dir}/01-simple.json") {
      return dir
    }
  }
  abort("flows dir not found")
}

///|
/// 种子：flows/ 按文件名序载 define(id=1..N) + design + design_his（listByType 契约完整）
pub async fn seed_memory(repo : @memory.MemoryRepository) -> Unit raise {
  let dir = flows_dir()
  let names : Array[String] = []
  let entries = @fs.readdir(dir)
  for e in entries {
    if e.ends_with(".json") {
      names.push(e)
    }
  }
  @model.sort_strings(names)
  var id = 1L
  for name in names {
    let data = @fs.read_file("\{dir}/\{name}")
    let content = data.text()
    let define : @model.ProcessDefine = {
      id,
      name: name.substring(start=0, end=name.length() - 5).to_string(),
      display_name: flow_display_name(content, name),
      define_type: "approval",
      state: 1,
      content,
      version: 1,
      create_time: Some(@model.current_time_str()),
      create_user: Some("system"),
      update_time: None,
      update_user: None,
    }
    repo.save_define(define)
    // design + his（发起页 listByType 契约）
    let design : @model.ProcessDesign = {
      id,
      name: define.name,
      display_name: define.display_name,
      design_type: "approval",
      icon: None,
      is_deployed: 1,
      remark: None,
      create_time: Some(@model.current_time_str()),
      create_user: Some("system"),
      update_time: None,
      update_user: None,
    }
    repo.save_design(design)
    let his : @model.ProcessDesignHis = {
      id,
      process_design_id: id,
      content,
      create_time: Some(@model.current_time_str()),
      create_user: Some("system"),
    }
    repo.save_design_his(his)
    id = id + 1L
  }
}

///|
fn flow_display_name(content : String, fallback : String) -> String {
  match (try? @json.parse_json(content)) {
    Ok(v) => @json.get_str(v, "displayName").unwrap_or(fallback)
    Err(_) => fallback
  }
}
