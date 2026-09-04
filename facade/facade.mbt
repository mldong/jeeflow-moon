// JeeflowFacade —— 45 action 统一入口（方案 §3.3；java JeeflowFacade 为契约源）
// D-M3-1：页查询仅在有 m_ 过滤时做 facade 级后过滤+重分页（rust 无条件重分页会打折扣
// 未过滤场景的 recordCount，与 java 五键语义冲突；此处对齐 java）。

///|
pub(all) struct Facade[R, E] {
  engine : @engine.Engine[R, E]
  repo : R
  ext_repo : E
}

///|
pub fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::make(
  ctx : @spi.Ctx[R, E]
) -> Facade[R, E] {
  let repo = ctx.repository()
  let ext = ctx.ext_repository()
  let engine = @engine.Engine::make(ctx)
  { engine, repo, ext_repo: ext }
}

///|
pub fn[R, E] Facade::engine(self : Facade[R, E]) -> @engine.Engine[R, E] {
  self.engine
}

///|
/// 统一入口：flow(action, args) → {code,msg,data}
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::flow(
  self : Facade[R, E],
  action : String,
  args : Map[String, Json]
) -> Json raise {
  let outcome = try? self.dispatch(action, args)
  match outcome {
    Ok(data) => transform_output(ok_data(data))
    Err(e) => transform_output(err(e.message()))
  }
}

///|
async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::dispatch(
  self : Facade[R, E],
  action : String,
  args : Map[String, Json]
) -> Json raise @error.JeeflowError {
  match action {
    // ── 流程定义（8）──
    "processDefine/page" => self.define_page(args)
    "processDefine/detail" => self.define_detail(args)
    "processDefine/startAndExecute" => self.start_and_execute(args)
    "processDefine/deploy" => self.deploy(args)
    "processDefine/redeploy" => self.redeploy(args)
    "processDefine/remove" => self.define_remove(args)
    "processDefine/upAndDown" => self.define_up_and_down(args)
    "processDefine/getLastByName" => self.get_last_by_name(args)
    // ── 流程实例（14）──
    "processInstance/page" => self.instance_page(args)
    "processInstance/detail" => self.instance_detail(args)
    "processInstance/startAndExecute" => self.start_and_execute(args)
    "processInstance/withdraw" => self.withdraw(args)
    "processInstance/highLight" => self.high_light(args)
    "processInstance/approvalRecord" => self.approval_record(args)
    "processInstance/getAssigneeTextData" => self.get_assignee_text_data(args)
    "processInstance/bizData" => self.biz_data(args)
    "processInstance/createCCInstance" => self.create_cc_instance(args)
    "processInstance/updateCCStatus" => self.update_cc_status(args)
    "processInstance/ccList" => self.cc_list(args)
    "processInstance/stats/overview" => self.stats_overview(args)
    "processInstance/stats/trend" => self.stats_trend(args)
    "processInstance/stats/group" => self.stats_group(args)
    // ── 流程任务（9）──
    "processTask/todoList" => self.todo_list(args)
    "processTask/doneList" => self.done_list(args)
    "processTask/execute" => self.execute(args)
    "processTask/detail" => self.task_detail(args)
    "processTask/jumpAbleTaskNameList" => self.jump_able_task_name_list(args)
    "processTask/candidatePage" => self.candidate_page(args)
    "processTask/surrogate" => self.task_surrogate(args)
    "processTask/addCandidate" => self.task_surrogate(args)
    "processTask/latest" => self.task_latest(args)
    // ── 流程设计（9，需扩展仓储）──
    "processDesign/page" => self.design_page(args)
    "processDesign/detail" => self.design_detail(args)
    "processDesign/save" => self.design_save(args)
    "processDesign/update" => self.design_update(args)
    "processDesign/updateDefine" => self.design_update_define(args)
    "processDesign/remove" => self.design_remove(args)
    "processDesign/deploy" => self.design_deploy(args)
    "processDesign/redeploy" => self.design_redeploy(args)
    "processDesign/listByType" => self.design_list_by_type(args)
    // ── 委托代理（5，需扩展仓储）──
    "processSurrogate/page" => self.surrogate_page(args)
    "processSurrogate/save" => self.surrogate_save(args)
    "processSurrogate/update" => self.surrogate_update(args)
    "processSurrogate/detail" => self.surrogate_detail(args)
    "processSurrogate/remove" => self.surrogate_remove(args)
    _ => raise @error.UnknownAction(action)
  }
}

// ── 页查询公共（D-M3-1：有 m_ 过滤才后过滤+重分页）──

///|
pub fn facade_parse_m_filters(args : Map[String, Json]) -> Array[@model.QueryFilter] {
  let filters : Array[@model.QueryFilter] = []
  for key, value in args {
    if !key.starts_with("m_") {
      continue
    }
    let val_str = match value {
      Json::String(s) => s
      other => @json.stringify(other)
    }
    let rest = key.substring(start=2).to_string()
    let parts = split_char(rest, '_')
    if parts.length() >= 3 {
      let alias = parts[0]
      let op_str = parts[1]
      let column = camel_to_snake(join_char(parts, '_', 2))
      match @model.FilterOp::from_str(op_str) {
        Some(op) => filters.push(@model.QueryFilter::make(alias, op, column, val_str))
        None => ()
      }
    } else if parts.length() == 2 {
      let op_str = parts[0]
      if is_known_op(op_str) {
        match @model.FilterOp::from_str(op_str) {
          Some(op) => filters.push(@model.QueryFilter::make("t", op, camel_to_snake(parts[1]), val_str))
          None => ()
        }
      }
    }
  }
  filters
}

///|
fn split_char(s : String, sep : Char) -> Array[String] {
  let out : Array[String] = []
  let b = StringBuilder::new()
  for ch in s {
    if ch == sep {
      out.push(b.to_string())
      b.reset()
    } else {
      b.write_char(ch)
    }
  }
  out.push(b.to_string())
  out
}

///|
fn join_char(parts : Array[String], sep : Char, from : Int) -> String {
  let b = StringBuilder::new()
  for i in from..<parts.length() {
    if i > from {
      b.write_char(sep)
    }
    b.write_string(parts[i])
  }
  b.to_string()
}

///|
fn camel_to_snake(s : String) -> String {
  let b = StringBuilder::new()
  for ch in s {
    let c = ch.to_int()
    if c >= 65 && c <= 90 {
      b.write_char('_')
      b.write_char(Char::from_int(c + 32))
    } else {
      b.write_char(ch)
    }
  }
  b.to_string()
}

///|
fn is_known_op(s : String) -> Bool {
  let upper = s.to_upper()
  upper == "EQ" ||
  upper == "NE" ||
  upper == "LIKE" ||
  upper == "LLIKE" ||
  upper == "RLIKE" ||
  upper == "GT" ||
  upper == "LT" ||
  upper == "GE" ||
  upper == "LE" ||
  upper == "IN" ||
  upper == "NIN" ||
  upper == "BT"
}

///|
/// 行级过滤（camelCase 行键；值按字符串比较，对齐 rust matches_filter）
fn matches_filter(row : Json, f : @model.QueryFilter) -> Bool {
  let camel_col = camel_to_snake_inverse_for(f)
  let field_val = match row.value(camel_col) {
    Some(v) => Some(v)
    None => row.value(f.column())
  }
  let field_str = match field_val {
    Some(Json::String(s)) => s
    Some(v) => @json.stringify(v)
    None => return false
  }
  match f.op() {
    Eq => field_str == f.value()
    Ne => field_str != f.value()
    Like => field_str.contains(f.value())
    Gt => field_str > f.value()
    Lt => field_str < f.value()
    Ge => field_str >= f.value()
    Le => field_str <= f.value()
    In => {
      let mut any = false
      for v in f.value().split(",") {
        if v.to_string() == field_str {
          any = true
        }
      }
      any
    }
    Nin => {
      let mut any = false
      for v in f.value().split(",") {
        if v.to_string() == field_str {
          any = true
        }
      }
      !any
    }
    Bt => {
      let parts = split_char(f.value(), ',')
      if parts.length() == 2 {
        field_str >= parts[0] && field_str <= parts[1]
      } else {
        false
      }
    }
  }
}

///|
/// 过滤列 → 行键：先 camelCase（行键已 camel），失败退原 snake
fn camel_to_snake_inverse_for(f : @model.QueryFilter) -> String {
  // column 本身是 snake_case（facade_parse_m_filters 已转），行键为 camelCase
  let b = StringBuilder::new()
  let mut upper_next = true // 别名拼接后的首字母大写由 to_camel 统一处理，这里列名整体 camel
  let _ = upper_next
  for ch in f.column() {
    if ch == '_' {
      upper_next = true
    } else if upper_next {
      let c = ch.to_int()
      if c >= 97 && c <= 122 {
        b.write_char(Char::from_int(c - 32))
      } else {
        b.write_char(ch)
      }
      upper_next = false
    } else {
      b.write_char(ch)
    }
  }
  b.to_string()
}

///|
/// 有过滤时的后过滤 + 重分页
fn apply_filters_and_repaginate(
  rows : Array[Json],
  filters : Array[@model.QueryFilter],
  page_num : Int64,
  page_size : Int64
) -> Array[Json] {
  if filters.is_empty() {
    return rows
  }
  let kept : Array[Json] = []
  for row in rows {
    let mut ok = true
    for f in filters {
      if !matches_filter(row, f) {
        ok = false
      }
    }
    if ok {
      kept.push(row)
    }
  }
  let start = ((page_num - 1L) * page_size).to_int()
  let out : Array[Json] = []
  if start >= 0 && start < kept.length() {
    let end = if start + page_size.to_int() < kept.length() {
      start + page_size.to_int()
    } else {
      kept.length()
    }
    for i in start..<end {
      out.push(kept[i])
    }
  }
  out
}

///|
/// 页查询五键装配：repo 分页 → 行 JSON →（有 m_ 过滤则后过滤+重分页，D-M3-1）
fn[T] finalize_page(
  page : @model.PageResult[T],
  row_json : (T) -> Json,
  filters : Array[@model.QueryFilter],
  page_num : Int64,
  page_size : Int64
) -> Json {
  let rows_json : Array[Json] = []
  for r in page.rows() {
    rows_json.push(row_json(r))
  }
  let final_rows = apply_filters_and_repaginate(rows_json, filters, page_num, page_size)
  let total = if filters.is_empty() {
    page.record_count()
  } else {
    final_rows.length().to_int64()
  }
  let total_page = if total == 0L {
    0L
  } else {
    (total + page_size - 1L) / page_size
  }
  let obj = @json.empty_object()
  @json.obj_set(obj, "pageNum", @json.number_of(page_num))
  @json.obj_set(obj, "pageSize", @json.number_of(page_size))
  @json.obj_set(obj, "recordCount", @json.number_of(total))
  @json.obj_set(obj, "totalPage", @json.number_of(total_page))
  let rows = @json.empty_array()
  for r in final_rows {
    @json.arr_push(rows, r)
  }
  @json.obj_set(obj, "rows", rows)
  obj
}
