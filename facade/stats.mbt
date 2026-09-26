// stats 3 action（issues/103，C23：全纯列/显式错误/空库全 0）
// 数据源：repo 批量查询（get_all_instances/get_all_tasks）+ facade 聚合（rust 同款架构）

///|
/// "yyyy-MM-dd[ HH:mm[:ss]]" → epoch 秒（civil 算法逆运算）
pub fn parse_epoch_secs(s : String) -> Int64? {
  let t = s.trim(chars=" \t\r\n").to_owned()
  if t.length() < 10 {
    return None
  }
  // parse_int 现签名 `-> Int raise`：日期三段任一失败 ⇒ 不是这个格式 ⇒ None。
  // 兜底挪进 parse_int_or_none（非 raise 函数里裸调会 raise 的函数，编译器直接拒绝），
  // 调用点形状与旧 Ok/Err 三档一一对应，只换构造器名。
  let y = parse_int_or_none(t[0:4].to_owned())
  let mo = parse_int_or_none(t[5:7].to_owned())
  let d = parse_int_or_none(t[8:10].to_owned())
  let (y, mo, d) = match (y, mo, d) {
    (Some(a), Some(b), Some(c)) => (a, b, c)
    _ => return None
  }
  let mut hh = 0
  let mut mi = 0
  let mut ss = 0
  if t.length() >= 19 {
    // 时间三段解析失败保持 0（旧 Err ⇒ () 语义）
    hh = parse_int_or(t[11:13].to_owned(), 0)
    mi = parse_int_or(t[14:16].to_owned(), 0)
    ss = parse_int_or(t[17:19].to_owned(), 0)
  }
  let days = days_from_civil(y, mo, d)
  Some(days.to_int64() * 86400L + (hh * 3600 + mi * 60 + ss).to_int64())
}

///|
/// `parse_int`（`-> Int raise`）兜底：默认值档 / None 档各一个入口，
/// 让"解析失败算不算错"这件事在调用点上写明白，而不是靠 Ok/Err 猜。
fn parse_int_or(s : String, fallback : Int) -> Int {
  try {
    @string.parse_int(s)
  } catch {
    _ => fallback
  }
}

///|
fn parse_int_or_none(s : String) -> Int? {
  try {
    Some(@string.parse_int(s))
  } catch {
    _ => None
  }
}

///|
/// Howard Hinnant days_from_civil
fn days_from_civil(y : Int, m : Int, d : Int) -> Int {
  let y2 = if m <= 2 { y - 1 } else { y }
  let era = (if y2 >= 0 { y2 } else { y2 - 399 }) / 400
  let yoe = y2 - era * 400
  let mp = (m + 9) % 12
  let doy = (153 * mp + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468
}

///|
/// epoch 秒 → (y, m, d)（civil_from_days）
fn civil_from_days(days : Int) -> (Int, Int, Int) {
  let z = days + 719468
  let era = (if z >= 0 { z } else { z - 146096 }) / 146097
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  let y = if m <= 2 { y + 1 } else { y }
  (y, m, d)
}

///|
fn pad2(n : Int) -> String {
  if n < 10 {
    "0" + n.to_string()
  } else {
    n.to_string()
  }
}

///|
/// ISO 周标签 YYYY-Www
fn iso_week_key(epoch_secs : Int64) -> String {
  let days = (epoch_secs / 86400L).to_int()
  // 1970-01-01 = 周四（周一=0 → 3）
  let weekday = (days + 3) % 7
  let thursday = days - weekday + 3
  let (y, _, _) = civil_from_days(thursday)
  let jan1 = days_from_civil(y, 1, 1)
  let week = (thursday - jan1) / 7 + 1
  y.to_string() + "-W" + pad2(week)
}

///|
/// 时间过滤：start/end 归一后字符串比较（格式自身可字典序比较）
fn in_range(create_time : String?, start : String?, end : String?) -> Bool {
  let ct = match create_time {
    Some(t) => t
    None => return true // 无时间参与聚合（对齐 rust stats_filter 的宽匹配）
  }
  match start {
    Some(s) => if ct < s { return false }
    None => ()
  }
  match end {
    Some(e) => if ct > e { return false }
    None => ()
  }
  true
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::stats_overview(
  self : Facade[R, E],
  args : Map[String, Json]
) -> Json raise @error.JeeflowError {
  let start = parse_surrogate_time(arg_str(args, "start"))
  let end = parse_surrogate_time(arg_str(args, "end"))
  // stateIn 缺省 [10,20,30,40,45,50]
  let state_in : Array[Int] = match args.get("stateIn") {
    Some(Json::Array(items)) => {
      let arr : Array[Int] = []
      for v in items {
        match @json.as_i64(v) {
          Some(n) => arr.push(n.to_int())
          None => ()
        }
      }
      if arr.is_empty() {
        [10, 20, 30, 40, 45, 50]
      } else {
        arr
      }
    }
    _ => [10, 20, 30, 40, 45, 50]
  }
  let all = (self.repo).get_all_instances()
  let mut total = 0L
  let mut in_progress = 0L
  let mut completed = 0L
  let mut withdrawn = 0L
  let mut rejected = 0L
  let mut suspended = 0L
  for inst in all {
    // B 对齐 java（issues/103）：total = 六状态计数之和，由 stateIn 门控（缺省剔除 99），
    // 不是窗口内全量；avgDuration/todayNew 不受 stateIn 影响
    if in_range(inst.create_time, start, end) && state_in.contains(inst.state) {
      total = total + 1L
      match inst.state {
        10 => in_progress = in_progress + 1L
        20 => completed = completed + 1L
        30 => withdrawn = withdrawn + 1L
        45 => rejected = rejected + 1L
        50 => suspended = suspended + 1L
        _ => ()
      }
    }
  }
  // todayNew：恒按当前钟当天
  let today_prefix = @model.current_time_str().substring(start=0, end=10).to_string()
  let mut today_new = 0L
  for inst in all {
    match inst.create_time {
      Some(ct) => if ct[0:10] == today_prefix { today_new = today_new + 1L }
      None => ()
    }
  }
  // 待办/逾期（全量）
  let tasks = (self.repo).get_all_tasks()
  let mut pending = 0L
  let mut overdue = 0L
  // issues/120 附证：本栈只有**一把钟**——`current_time_str()`（可被宿主 `set_clock` 注入）。
  // 这里原先读裸 `@model.epoch_secs()`，于是同一段统计里 `todayNew` 跟注入钟、逾期数不跟，
  // 宿主注入后（Rust 侧 120 §9/§10 已按此形状收口）两数会互相矛盾。
  // 未注入时 `current_time_str()` == `format_unix_utc(epoch_secs())`，parse 回来即原值 ⇒ 默认臂不变；
  // 兜底那臂只在宿主注入了不合 `yyyy-MM-dd HH:mm:ss` 的串时才走（宁缺判据不整块报错）。
  let now_secs = match parse_epoch_secs(@model.current_time_str()) {
    Some(s) => s
    None => @model.epoch_secs()
  }
  for t in tasks {
    if t.task_state == 10 {
      pending = pending + 1L
      match t.expire_time {
        Some(et) =>
          match parse_epoch_secs(et) {
            Some(exp) => if exp < now_secs { overdue = overdue + 1L }
            None => ()
          }
        None => ()
      }
    }
  }
  // 已完成任务聚合
  let mut task_total = 0L
  let mut countersign = 0L
  let mut on_time = 0L
  let mut on_time_denom = 0L
  for t in tasks {
    if t.task_state == 20 {
      task_total = task_total + 1L
      if t.perform_type == 1 {
        countersign = countersign + 1L
      }
      match (t.finish_time, t.expire_time) {
        (Some(f), Some(e)) =>
          match (parse_epoch_secs(f), parse_epoch_secs(e)) {
            (Some(fs), Some(es)) => {
              on_time_denom = on_time_denom + 1L
              if fs <= es {
                on_time = on_time + 1L
              }
            }
            _ => ()
          }
        _ => ()
      }
    }
  }
  // 平均完成时长（C23：MAX(task.finish_time)-create_time 的**均值**，非最大值）
  let mut dur_total = 0L
  let mut dur_count = 0L
  for inst in all {
    if inst.state == 20 && in_range(inst.create_time, start, end) {
      match stats_instance_duration_secs(inst.create_time, inst.tasks) {
        Some(dur) => {
          dur_total += dur
          dur_count += 1L
        }
        None => ()
      }
    }
  }
  let avg_duration = if dur_count > 0L { (dur_total / dur_count).to_int() } else { 0 }
  let o = @json.empty_object()
  @json.obj_set(o, "total", @json.number_of(total))
  @json.obj_set(o, "inProgress", @json.number_of(in_progress))
  @json.obj_set(o, "completed", @json.number_of(completed))
  @json.obj_set(o, "rejected", @json.number_of(rejected))
  @json.obj_set(o, "withdrawn", @json.number_of(withdrawn))
  @json.obj_set(o, "suspended", @json.number_of(suspended))
  @json.obj_set(o, "todayNew", @json.number_of(today_new))
  @json.obj_set(o, "avgDurationSeconds", @json.number_of(avg_duration.to_int64()))
  let denom = if completed + rejected > 0L { (completed + rejected).to_double() } else { 1.0 }
  @json.obj_set(o, "rejectRate", @json.number_f_of(round4(rejected.to_double() / denom)))
  @json.obj_set(o, "pendingTaskCount", @json.number_of(pending))
  @json.obj_set(o, "overdueTaskCount", @json.number_of(overdue))
  @json.obj_set(o, "countersignRate", @json.number_f_of(round4(if task_total > 0L {
    countersign.to_double() / task_total.to_double()
  } else {
    0.0
  })))
  @json.obj_set(o, "onTimeRate", @json.number_f_of(round4(if on_time_denom > 0L {
    on_time.to_double() / on_time_denom.to_double()
  } else {
    0.0
  })))
  o
}

///|
fn round4(v : Double) -> Double {
  (v * 10000.0 + 0.5).floor() / 10000.0
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::stats_trend(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let granularity = arg_str_or(args, "granularity", "")
  let start_s = parse_surrogate_time(arg_str(args, "start"))
  let end_s = parse_surrogate_time(arg_str(args, "end"))
  // C23：缺参/非法显式错误
  let start_v = match start_s {
    Some(s) => s
    None => raise @error.Business("trend 缺少必填参数：start/end/granularity")
  }
  let end_v = match end_s {
    Some(s) => s
    None => raise @error.Business("trend 缺少必填参数：start/end/granularity")
  }
  if granularity.is_empty() {
    raise @error.Business("trend 缺少必填参数：start/end/granularity")
  }
  if !(granularity == "hour" || granularity == "day" || granularity == "week" || granularity == "month") {
    raise @error.Business("granularity 参数非法，允许值：hour/day/week/month")
  }
  let buckets = enumerate_buckets(start_v, end_v, granularity)
  // 计数
  let counts : Map[String, (Int64, Int64)] = Map([])
  for b in buckets {
    counts[b] = (0L, 0L)
  }
  let all = (self.repo).get_all_instances()
  for inst in all {
    match inst.create_time {
      Some(ct) => {
        let bk = bucket_key_of(ct, granularity)
        match bk {
          Some(k) =>
            match counts.get(k) {
              Some((s, f)) => counts[k] = (s + 1L, f)
              None => ()
            }
          None => ()
        }
      }
      None => ()
    }
  }
  let tasks = (self.repo).get_all_tasks()
  for t in tasks {
    if t.task_state == 20 {
      match t.finish_time {
        Some(f) => {
          let bk = bucket_key_of(f, granularity)
          match bk {
            Some(k) =>
              match counts.get(k) {
                Some((s, fi)) => counts[k] = (s, fi + 1L)
                None => ()
              }
            None => ()
          }
        }
        None => ()
      }
    }
  }
  let series = @json.empty_array()
  for b in buckets {
    match counts.get(b) {
      Some((s, f)) => {
        let point = @json.empty_object()
        @json.obj_set(point, "bucket", @json.string_of(b))
        @json.obj_set(point, "started", @json.number_of(s))
        @json.obj_set(point, "finished", @json.number_of(f))
        @json.arr_push(series, point)
      }
      None => ()
    }
  }
  series
}

///|
/// 桶枚举（连续桶）：hour/day/week/month
fn enumerate_buckets(start_s : String, end_s : String, granularity : String) -> Array[String] {
  let buckets : Array[String] = []
  let start_secs = parse_epoch_secs(start_s).unwrap_or(0L)
  let end_secs = parse_epoch_secs(end_s).unwrap_or(0L)
  if granularity == "hour" {
    let mut cursor = start_secs / 3600L * 3600L
    while cursor <= end_secs {
      buckets.push(hour_key(cursor))
      cursor = cursor + 3600L
    }
  } else if granularity == "day" {
    let mut day = (start_secs / 86400L).to_int()
    let end_day = (end_secs / 86400L).to_int()
    while day <= end_day {
      let (y, m, d) = civil_from_days(day)
      buckets.push("\{y}-\{pad2(m)}-\{pad2(d)}")
      day = day + 1
    }
  } else if granularity == "week" {
    // 对齐周一
    let mut day = (start_secs / 86400L).to_int()
    let weekday = (day + 3) % 7
    day = day - weekday
    let end_day = (end_secs / 86400L).to_int()
    while day <= end_day {
      let thursday = day + 3
      let (y, _, _) = civil_from_days(thursday)
      let jan1 = days_from_civil(y, 1, 1)
      let week = (thursday - jan1) / 7 + 1
      buckets.push("\{y}-W\{pad2(week)}")
      day = day + 7
    }
  } else {
    // month
    let (y0, m0, _) = civil_from_days((start_secs / 86400L).to_int())
    let (y1, m1, _) = civil_from_days((end_secs / 86400L).to_int())
    let mut y = y0
    let mut m = m0
    while y < y1 || (y == y1 && m <= m1) {
      buckets.push("\{y}-\{pad2(m)}")
      m = m + 1
      if m > 12 {
        m = 1
        y = y + 1
      }
    }
  }
  buckets
}

///|
fn hour_key(epoch_secs : Int64) -> String {
  let days = (epoch_secs / 86400L).to_int()
  let (y, m, d) = civil_from_days(days)
  let hh = ((epoch_secs % 86400L) / 3600L).to_int()
  "\{y}-\{pad2(m)}-\{pad2(d)} \{pad2(hh)}:00"
}

///|
/// 时间值 → 桶键（不落入枚举桶返回 None）
fn bucket_key_of(time_str : String, granularity : String) -> String? {
  let norm = parse_surrogate_time(Some(time_str))
  match norm {
    Some(n) =>
      match parse_epoch_secs(n) {
        Some(secs) => {
          if granularity == "hour" {
            Some(hour_key(secs / 3600L * 3600L))
          } else if granularity == "day" {
            let (y, m, d) = civil_from_days((secs / 86400L).to_int())
            Some("\{y}-\{pad2(m)}-\{pad2(d)}")
          } else if granularity == "week" {
            Some(iso_week_key(secs))
          } else if granularity == "month" {
            let (y, m, _) = civil_from_days((secs / 86400L).to_int())
            Some("\{y}-\{pad2(m)}")
          } else {
            None
          }
        }
        None => None
      }
    None => None
  }
}

///|
pub async fn[R : @spi.ProcessRepository, E] Facade::stats_group(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
  let start = parse_surrogate_time(arg_str(args, "start"))
  let end = parse_surrogate_time(arg_str(args, "end"))
  let dimension = arg_str_or(args, "dimension", "define")
  let limit = arg_i64_or(args, "limit", 10L).to_int()
  let valid = [
    "state", "define", "category", "approver", "applicant", "node", "stuckNode", "stuckApprover", "durationBucket",
  ]
  if !valid.contains(dimension) {
    raise @error.Business("dimension 参数非法，允许值：state/define/category/approver/applicant/node/stuckNode/stuckApprover/durationBucket")
  }
  let rows : Array[Json] = []
  // [key, count, avgDurSeconds?]
  let counts : Map[String, Int64] = Map([])
  let durations : Map[String, Int64] = Map([])
  let dur_counts : Map[String, Int64] = Map([])
  // define 维度：key=编码 name，label=display_name（spec 06 §4.2 契约口径）
  let labels : Map[String, String] = Map([])
  fn bump(k : String) -> Unit {
    match counts.get(k) {
      Some(c) => counts[k] = c + 1L
      None => counts[k] = 1L
    }
  }
  if dimension == "state" || dimension == "applicant" || dimension == "category" {
    for inst in (self.repo).get_all_instances() {
      if !in_range(inst.create_time, start, end) {
        continue
      }
      if dimension == "state" {
        bump(inst.state.to_string())
      } else if dimension == "applicant" {
        if !inst.operator.is_empty() {
          bump(inst.operator)
        }
      } else {
        // category → define.type
        match (self.repo).find_define_by_id(inst.define_id) {
          Some(d) => bump(d.define_type)
          None => bump("")
        }
      }
    }
  } else if dimension == "define" {
    for inst in (self.repo).get_all_instances() {
      if !in_range(inst.create_time, start, end) {
        continue
      }
      match (self.repo).find_define_by_id(inst.define_id) {
        Some(d) => {
          bump(d.name)
          match labels.get(d.name) {
            None => labels[d.name] = d.display_name
            Some(_) => ()
          }
          // 已完成实例时长进 define 平均（C23）
          if inst.state == 20 {
            match stats_instance_duration_secs(inst.create_time, inst.tasks) {
              Some(dur) => {
                match durations.get(d.name) {
                  Some(v) => durations[d.name] = v + dur
                  None => durations[d.name] = dur
                }
                match dur_counts.get(d.name) {
                  Some(c) => dur_counts[d.name] = c + 1L
                  None => dur_counts[d.name] = 1L
                }
              }
              None => ()
            }
          }
        }
        None => ()
      }
    }
  } else if dimension == "approver" || dimension == "node" {
    for t in (self.repo).get_all_tasks() {
      if t.task_state != 20 {
        continue
      }
      if dimension == "approver" {
        match t.actor_id {
          Some(op) => if !op.is_empty() { bump(op) }
          None => ()
        }
      } else {
        if !t.display_name.is_empty() {
          let mut dur = 0L
          match (t.create_time, t.finish_time) {
            (Some(c), Some(f)) =>
              match (parse_epoch_secs(c), parse_epoch_secs(f)) {
                (Some(cs), Some(fs)) => dur = fs - cs
                _ => ()
              }
            _ => ()
          }
          bump(t.display_name)
          match durations.get(t.display_name) {
            Some(v) => durations[t.display_name] = v + dur
            None => durations[t.display_name] = dur
          }
          match dur_counts.get(t.display_name) {
            Some(c) => dur_counts[t.display_name] = c + 1L
            None => dur_counts[t.display_name] = 1L
          }
        }
      }
    }
  } else if dimension == "stuckNode" {
    for t in (self.repo).get_all_tasks() {
      if t.task_state == 10 && !t.display_name.is_empty() {
        bump(t.display_name)
      }
    }
  } else if dimension == "stuckApprover" {
    // 对齐 java：按 task_actor 关系逐人计数（含会签/加签的额外 actor），不只数主 actor
    for t in (self.repo).get_all_tasks() {
      if t.task_state == 10 {
        let actors = if t.actor_ids.is_empty() {
          match t.actor_id {
            Some(a) => [a]
            None => []
          }
        } else {
          t.actor_ids
        }
        for a in actors {
          if !a.is_empty() { bump(a) }
        }
      }
    }
  } else {
    // durationBucket：4 桶（sameDay/1to3d/3to7d/over7d）
    // 对齐 java：固定 4 桶全枚举，空桶也输出（count=0），不是只发非空桶
    counts["sameDay"] = 0L
    counts["1to3d"] = 0L
    counts["3to7d"] = 0L
    counts["over7d"] = 0L
    for inst in (self.repo).get_all_instances() {
      if inst.state != 20 || !in_range(inst.create_time, start, end) {
        continue
      }
      match (inst.create_time, parse_epoch_secs(inst.create_time.unwrap_or(""))) {
        (Some(_), Some(cs)) => {
          let mut latest_finish = cs
          for t in inst.tasks {
            match t.finish_time {
              Some(f) =>
                match parse_epoch_secs(f) {
                  Some(fs) => if fs > latest_finish { latest_finish = fs }
                  None => ()
                }
              None => ()
            }
          }
          let dur = latest_finish - cs
          let bucket = if dur < 86400L {
            "sameDay"
          } else if dur < 259200L {
            "1to3d"
          } else if dur < 604800L {
            "3to7d"
          } else {
            "over7d"
          }
          bump(bucket)
        }
        _ => ()
      }
    }
  }
  // 排序：count DESC，limit 截断
  let entries : Array[(String, Int64)] = []
  for k, v in counts {
    entries.push((k, v))
  }
  // count DESC 自写插入排序；平级按 key ASC（确定性序，java HashMap 序在快照数据集上与之等价）
  for i in 1..<entries.length() {
    let key = entries[i]
    let mut j = i - 1
    while j >= 0 && (entries[j].1 < key.1 || (entries[j].1 == key.1 && entries[j].0 > key.0)) {
      entries[j + 1] = entries[j]
      j = j - 1
    }
    entries[j + 1] = key
  }
  let mut i = 0
  for entry in entries {
    if i >= limit {
      break
    }
    let (k, c) = entry
    let row = @json.empty_object()
    @json.obj_set(row, "key", @json.string_of(k))
    match labels.get(k) {
      Some(l) => @json.obj_set(row, "label", @json.string_of(l))
      None => @json.obj_set(row, "label", @json.null_json())
    }
    @json.obj_set(row, "count", @json.number_of(c))
    if dimension == "node" || dimension == "define" {
      match (durations.get(k), dur_counts.get(k)) {
        (Some(total), Some(n)) =>
          if n > 0L {
            @json.obj_set(row, "avgDurationSeconds", @json.number_of((total / n).to_int().to_int64()))
          } else {
            @json.obj_set(row, "avgDurationSeconds", @json.null_json())
          }
        _ => @json.obj_set(row, "avgDurationSeconds", @json.null_json())
      }
    } else {
      @json.obj_set(row, "avgDurationSeconds", @json.null_json())
    }
    rows.push(row)
    i = i + 1
  }
  let arr = @json.empty_array()
  for r in rows {
    @json.arr_push(arr, r)
  }
  arr
}

///|
/// 实例办结时长秒（C23：MAX(task.finish_time) - create_time；时间缺失/不可解析返回 None；
/// 同秒完成返回 Some(0)，计入均值样本）
fn stats_instance_duration_secs(create_time : String?, tasks : Array[@model.ProcessTask]) -> Int64? {
  let base = match create_time {
    Some(c) => parse_epoch_secs(c)
    None => None
  }
  match base {
    Some(cs) => {
      let mut latest = cs
      for t in tasks {
        match t.finish_time {
          Some(f) =>
            match parse_epoch_secs(f) {
              Some(fs) => if fs > latest { latest = fs }
              None => ()
            }
          None => ()
        }
      }
      Some(if latest > cs { latest - cs } else { 0L })
    }
    None => None
  }
}
