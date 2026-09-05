// facade 行 VO + 参数助手 —— 对齐 java *RowToMap / arg 助手（C2/C3/C15）

///|
fn obj_json(m : Map[String, Json]) -> Json {
  @json.empty_object() |> ignore
  let o = @json.empty_object()
  for k, v in m {
    @json.obj_set(o, k, v)
  }
  o
}

///|
pub fn define_row_to_json(r : @model.DefineRow) -> Json {
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(r.id))
  @json.obj_set(o, "name", @json.string_of(r.name))
  @json.obj_set(o, "display_name", @json.string_of(r.display_name))
  @json.obj_set(o, "type", @json.string_of(r.define_type))
  @json.obj_set(o, "state", num_json(r.state))
  @json.obj_set(o, "version", num_json(r.version))
  @json.obj_set(o, "create_time", opt_json(r.create_time))
  @json.obj_set(o, "create_user", opt_json(r.create_user))
  @json.obj_set(o, "update_time", opt_json(r.update_time))
  @json.obj_set(o, "update_user", opt_json(r.update_user))
  o
}

///|
pub fn task_row_to_json(r : @model.TaskRow) -> Json {
  let instance_ext = parse_json_map(r.instance_variable)
  let ext = parse_json_map(r.variable)
  if ext.size() == 0 {
    for k, v in instance_ext {
      ext[k] = v
    }
  }
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(r.id))
  @json.obj_set(o, "process_instance_id", i64_json(r.process_instance_id))
  @json.obj_set(o, "task_name", @json.string_of(r.task_name))
  @json.obj_set(o, "display_name", @json.string_of(r.display_name))
  @json.obj_set(o, "task_type", num_json(r.task_type))
  @json.obj_set(o, "perform_type", num_json(r.perform_type))
  @json.obj_set(o, "task_state", num_json(r.task_state))
  @json.obj_set(o, "operator", opt_json(r.operator))
  @json.obj_set(o, "finish_time", opt_json(r.finish_time))
  @json.obj_set(o, "expire_time", opt_json(r.expire_time))
  @json.obj_set(o, "form_key", opt_json(r.form_key))
  @json.obj_set(o, "task_parent_id", opt_i64_json(r.task_parent_id))
  @json.obj_set(o, "variable", opt_json(r.variable))
  @json.obj_set(o, "create_time", opt_json(r.create_time))
  @json.obj_set(o, "create_user", opt_json(r.create_user))
  @json.obj_set(o, "update_time", opt_json(r.update_time))
  @json.obj_set(o, "update_user", opt_json(r.update_user))
  @json.obj_set(o, "process_define_name", opt_json(r.define_name))
  @json.obj_set(o, "process_define_display_name", opt_json(r.define_display_name))
  @json.obj_set(o, "ext", obj_json(ext))
  @json.obj_set(o, "instance_ext", obj_json(instance_ext))
  @json.obj_set(o, "instance_create_time", opt_json(r.instance_create_time))
  @json.obj_set(o, "version", opt_num_json(r.define_version))
  @json.obj_set(o, "task_form_data", form_data_of_map(parse_json_map(r.variable), "tf_"))
  o
}

///|
pub fn instance_row_to_json(r : @model.InstanceRow) -> Json {
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(r.id))
  @json.obj_set(o, "parent_id", opt_i64_json(r.parent_id))
  @json.obj_set(o, "process_define_id", i64_json(r.process_define_id))
  @json.obj_set(o, "state", num_json(r.state))
  @json.obj_set(o, "parent_node_name", opt_json(r.parent_node_name))
  @json.obj_set(o, "business_no", opt_json(r.business_no))
  @json.obj_set(o, "operator", @json.string_of(r.operator))
  @json.obj_set(o, "expire_time", opt_json(r.expire_time))
  @json.obj_set(o, "variable", opt_json(r.variable))
  @json.obj_set(o, "create_time", opt_json(r.create_time))
  @json.obj_set(o, "create_user", opt_json(r.create_user))
  @json.obj_set(o, "update_time", opt_json(r.update_time))
  @json.obj_set(o, "update_user", opt_json(r.update_user))
  @json.obj_set(o, "process_define_name", opt_json(r.define_name))
  @json.obj_set(o, "process_define_display_name", opt_json(r.define_display_name))
  @json.obj_set(o, "process_define_version", opt_num_json(r.define_version))
  @json.obj_set(o, "ext", obj_json(parse_json_map(r.variable)))
  @json.obj_set(o, "display_name", opt_json(r.define_display_name))
  @json.obj_set(o, "version", opt_num_json(r.define_version))
  o
}

///|
pub fn design_to_json(d : @model.ProcessDesign) -> Json {
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(d.id))
  @json.obj_set(o, "name", @json.string_of(d.name))
  @json.obj_set(o, "display_name", @json.string_of(d.display_name))
  @json.obj_set(o, "type", @json.string_of(d.design_type))
  @json.obj_set(o, "icon", opt_json(d.icon))
  @json.obj_set(o, "is_deployed", num_json(d.is_deployed))
  @json.obj_set(o, "remark", opt_json(d.remark))
  @json.obj_set(o, "create_time", opt_json(d.create_time))
  @json.obj_set(o, "create_user", opt_json(d.create_user))
  @json.obj_set(o, "update_time", opt_json(d.update_time))
  @json.obj_set(o, "update_user", opt_json(d.update_user))
  o
}

///|
pub fn surrogate_to_json(s : @model.ProcessSurrogate) -> Json {
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(s.id))
  @json.obj_set(o, "process_name", @json.string_of(s.process_name))
  @json.obj_set(o, "operator", @json.string_of(s.operator))
  @json.obj_set(o, "surrogate", @json.string_of(s.surrogate))
  @json.obj_set(o, "start_time", opt_json(s.start_time))
  @json.obj_set(o, "end_time", opt_json(s.end_time))
  @json.obj_set(o, "enabled", num_json(s.enabled))
  @json.obj_set(o, "create_time", opt_json(s.create_time))
  @json.obj_set(o, "create_user", opt_json(s.create_user))
  @json.obj_set(o, "update_time", opt_json(s.update_time))
  @json.obj_set(o, "update_user", opt_json(s.update_user))
  o
}

///|
/// 对齐 java taskVo
pub fn task_vo(t : @model.ProcessTask) -> Json {
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(t.task_id))
  @json.obj_set(o, "process_instance_id", i64_json(t.process_instance_id))
  @json.obj_set(o, "task_name", @json.string_of(t.task_name))
  @json.obj_set(o, "display_name", @json.string_of(t.display_name))
  @json.obj_set(o, "task_type", num_json(t.task_type))
  @json.obj_set(o, "perform_type", num_json(t.perform_type))
  @json.obj_set(o, "task_state", num_json(t.task_state))
  @json.obj_set(o, "operator", opt_json(t.actor_id))
  @json.obj_set(o, "form_key", opt_json(t.form_key))
  @json.obj_set(o, "task_parent_id", opt_i64_json(t.parent_task_id))
  let actor_ids = @json.empty_array()
  for a in t.actor_ids {
    @json.arr_push(actor_ids, @json.string_of(a))
  }
  @json.obj_set(o, "task_actor_id_list", actor_ids)
  @json.obj_set(o, "task_form_data", form_data_of_flow(t.variables, "tf_"))
  @json.obj_set(o, "finish_time", opt_json(t.finish_time))
  @json.obj_set(o, "create_time", opt_json(t.create_time))
  o
}

///|
pub fn design_his_to_json(h : @model.ProcessDesignHis) -> Json {
  let o = @json.empty_object()
  @json.obj_set(o, "id", i64_json(h.id))
  @json.obj_set(o, "process_design_id", i64_json(h.process_design_id))
  @json.obj_set(o, "content", @json.string_of(h.content))
  @json.obj_set(o, "create_time", opt_json(h.create_time))
  @json.obj_set(o, "create_user", opt_json(h.create_user))
  o
}

// ── 参数助手（C2/C3 双收；C15 ids/id 双收空显式报错）──

///|
pub fn arg_str(args : Map[String, Json], key : String) -> String? {
  match args.get(key) {
    Some(Json::String(s)) => Some(s)
    _ => None
  }
}

///|
/// i64 双收：数字/字符串；存在但不可解析 → "非法id"
pub fn arg_i64(args : Map[String, Json], key : String) -> Int64? raise @error.JeeflowError {
  match args.get(key) {
    None => None
    Some(v) =>
      match @json.as_i64(v) {
        Some(n) => Some(n)
        None =>
          match v {
            Json::String(s) =>
              match (try? @string.parse_int64(s)) {
                Ok(n) => Some(n)
                Err(_) => raise @error.Business("非法id: \{s}")
              }
            _ => raise @error.Business("非法id: \{@json.stringify(v)}")
          }
      }
  }
}

///|
pub fn arg_str_or(args : Map[String, Json], key : String, default : String) -> String {
  arg_str(args, key).unwrap_or(default)
}

///|
pub fn arg_i64_or(args : Map[String, Json], key : String, default : Int64) -> Int64 raise @error.JeeflowError {
  match arg_i64(args, key) {
    Some(v) => v
    None => default
  }
}

///|
/// 首个存在的 i64（多候选键）
pub fn arg_id(args : Map[String, Json], keys : Array[String]) -> Int64? raise @error.JeeflowError {
  for k in keys {
    match arg_i64(args, k) {
      Some(v) => return Some(v)
      None => ()
    }
  }
  None
}

///|
/// actorIds：JSON 数组 / 逗号串双收
pub fn arg_actor_ids(args : Map[String, Json]) -> Array[String] {
  let out : Array[String] = []
  match args.get("actorIds") {
    Some(Json::Array(arr)) =>
      for v in arr {
        match v {
          Json::String(s) => if !s.is_empty() { out.push(s) }
          // id 字符串化走 repr 原文优先（>2^53 防 double 取整，D-M5-3）
          Json::Number(n, repr~) =>
            match repr {
              Some(s) => out.push(s)
              None => out.push(n.to_int64().to_string())
            }
          Json::Null => ()
          _ => ()
        }
      }
    Some(Json::String(s)) => {
      for part in s.split(",") {
        let t = part.to_string().trim(chars=" \t\r\n").to_string()
        if !t.is_empty() {
          out.push(t)
        }
      }
    }
    _ => ()
  }
  out
}

///|
/// 批量主键：{ids} 优先 {id} 兜底；空显式报错（issues/95）
pub fn arg_ids(args : Map[String, Json]) -> Array[Int64] raise @error.JeeflowError {
  let out : Array[Int64] = []
  match args.get("ids") {
    Some(Json::Array(arr)) =>
      for v in arr {
        match @json.as_i64(v) {
          Some(n) => out.push(n)
          None =>
            match v {
              Json::String(s) =>
                match (try? @string.parse_int64(s)) {
                  Ok(n) => out.push(n)
                  Err(_) => raise @error.Business("非法id: \{s}")
                }
              _ => raise @error.Business("非法id: \{@json.stringify(v)}")
            }
        }
      }
    _ => ()
  }
  if out.is_empty() {
    match arg_i64(args, "id") {
      Some(v) => out.push(v)
      None => ()
    }
  }
  if out.is_empty() {
    raise @error.Business("id 缺失或非法")
  }
  out
}

///|
/// submitType 双收（数字/字符串）
pub fn arg_submit_type(args : Map[String, Json], key~ : String = "submitType") -> Int64? raise @error.JeeflowError {
  arg_i64(args, key)
}

///|
/// content：字符串/对象/顶层 JSON 兼容（issues/27）
pub fn content_bytes(args : Map[String, Json]) -> String? {
  match args.get("content") {
    Some(Json::String(s)) => Some(s)
    Some(Json::Object(_)) | Some(Json::Array(_)) => Some(@json.stringify(args.get("content").unwrap()))
    Some(other) =>
      match other {
        Json::Null => None
        _ => Some(@json.stringify(other))
      }
    None => {
      let copy : Map[String, Json] = Map::new()
      for k, v in args {
        if k == "processDesignId" || k == "processDefineId" || k == "operator" || k == "id" || k == "pageNum" || k == "pageSize" {
          continue
        }
        copy[k] = v
      }
      if copy.size() == 0 {
        None
      } else {
        Some(@json.stringify(obj_json(copy)))
      }
    }
  }
}

///|
/// candidate 行键归一（issues/80）
pub fn candidate_row(actor_id : String, real_name : String, extra : Map[String, Json]?) -> Json {
  let row = @json.empty_object()
  @json.obj_set(row, "id", @json.string_of(actor_id))
  @json.obj_set(row, "realName", @json.string_of(if real_name.is_empty() { actor_id } else { real_name }))
  match extra {
    Some(src) => {
      match src.get("userId") {
        Some(v) => @json.obj_set(row, "userId", v)
        None =>
          match src.get("user_id") {
            Some(v) => @json.obj_set(row, "userId", v)
            None => ()
          }
      }
      match src.get("userName") {
        Some(v) => @json.obj_set(row, "userName", v)
        None =>
          match src.get("user_name") {
            Some(v) => @json.obj_set(row, "userName", v)
            None => ()
          }
      }
      match src.get("deptName") {
        Some(v) => @json.obj_set(row, "deptName", v)
        None =>
          match src.get("dept_name") {
            Some(v) => @json.obj_set(row, "deptName", v)
            None => ()
          }
      }
    }
    None => ()
  }
  row
}

///|
/// args → FlowData（剔除 facade 控制键）
pub fn args_to_flow_data(args : Map[String, Json], exclude : Array[String]) -> @json.FlowData {
  let fd = @json.FlowData::new()
  for k, v in args {
    let mut skip = false
    for e in exclude {
      if k == e {
        skip = true
      }
    }
    if !skip {
      fd.insert(k, v)
    }
  }
  fd
}
