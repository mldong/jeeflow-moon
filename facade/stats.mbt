// stats 3 action（issues/103，C23：全纯列/显式错误/空库全 0）
// 数据源：repo 批量查询（get_all_instances/get_all_tasks）+ facade 聚合（rust 同款架构）

///|
/// "yyyy-MM-dd[ HH:mm[:ss]]" → epoch 秒（civil 算法逆运算）
pub fn parse_epoch_secs(s : String) -> Int64? {
  let t = s.trim(chars=" \t\r\n").to_string()
  if t.length() < 10 {
    return None
  }
  let y = (try? @string.parse_int(t.substring(start=0, end=4).to_string()))
  let mo = (try? @string.parse_int(t.substring(start=5, end=7).to_string()))
  let d = (try? @string.parse_int(t.substring(start=8, end=10).to_string()))
  let (y, mo, d) = match (y, mo, d) {
    (Ok(a), Ok(b), Ok(c)) => (a, b, c)
    _ => return None
  }
  var hh = 0
  var mi = 0
  var ss = 0
  if t.length() >= 19 {
    match (try? @string.parse_int(t.substring(start=11, end=13).to_string())) {
      Ok(v) => hh = v
      Err(_) => ()
    }
    match (try? @string.parse_int(t.substring(start=14, end=16).to_string())) {
      Ok(v) => mi = v
      Err(_) => ()
    }
    match (try? @string.parse_int(t.substring(start=17, end=19).to_string())) {
      Ok(v) => ss = v
      Err(_) => ()
    }
  }
  let days = days_from_civil(y, mo, d)
  Some(days.to_int64() * 86400L + (hh * 3600 + mi * 60 + ss).to_int64())
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
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::stats_overview(
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
  var total = 0L
  var in_progress = 0L
  var completed = 0L
  var withdrawn = 0L
  var rejected = 0L
  var suspended = 0L
  for inst in all {
    if in_range(inst.create_time, start, end) {
      total = total + 1L
      if state_in.contains(inst.state) {
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
  }
  // todayNew：恒按当前钟当天
  let today_prefix = @model.current_time_str().substring(start=0, end=10).to_string()
  var today_new = 0L
  for inst in all {
    match inst.create_time {
      Some(ct) => if ct.substring(start=0, end=10).to_string() == today_prefix { today_new = today_new + 1L }
      None => ()
    }
  }
  // 待办/逾期（全量）
  let tasks = (self.repo).get_all_tasks()
  var pending = 0L
  var overdue = 0L
  let today_secs = @model.epoch_secs()
  for t in tasks {
    if t.task_state == 10 {
      pending = pending + 1L
      match t.expire_time {
        Some(et) =>
          match parse_epoch_secs(et) {
            Some(exp) => if exp < today_secs { overdue = overdue + 1L }
            None => ()
          }
        None => ()
      }
    }
  }
  // 已完成任务聚合
  var task_total = 0L
  var countersign = 0L
  var on_time = 0L
  var on_time_denom = 0L
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
  var dur_total = 0L
  var dur_count = 0L
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
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::stats_trend(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
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
  let counts : Map[String, (Int64, Int64)] = Map::new()
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
    var cursor = start_secs / 3600L * 3600L
    while cursor <= end_secs {
      buckets.push(hour_key(cursor))
      cursor = cursor + 3600L
    }
  } else if granularity == "day" {
    var day = (start_secs / 86400L).to_int()
    let end_day = (end_secs / 86400L).to_int()
    while day <= end_day {
      let (y, m, d) = civil_from_days(day)
      buckets.push("\{y}-\{pad2(m)}-\{pad2(d)}")
      day = day + 1
    }
  } else if granularity == "week" {
    // 对齐周一
    var day = (start_secs / 86400L).to_int()
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
    var y = y0
    var m = m0
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
pub async fn[R : @spi.ProcessRepository, E : @spi.ProcessExtRepository] Facade::stats_group(self : Facade[R, E], args : Map[String, Json]) -> Json raise @error.JeeflowError {
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
  let counts : Map[String, Int64] = Map::new()
  let durations : Map[String, Int64] = Map::new()
  let dur_counts : Map[String, Int64] = Map::new()
  // define 维度：key=编码 name，label=display_name（spec 06 §4.2 契约口径）
  let labels : Map[String, String] = Map::new()
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
          var dur = 0L
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
    for t in (self.repo).get_all_tasks() {
      if t.task_state == 10 {
        match t.actor_id {
          Some(op) => if !op.is_empty() { bump(op) }
          None => ()
        }
      }
    }
  } else {
    // durationBucket：4 桶（sameDay/1to3d/3to7d/over7d）
    for inst in (self.repo).get_all_instances() {
      if inst.state != 20 || !in_range(inst.create_time, start, end) {
        continue
      }
      match (inst.create_time, parse_epoch_secs(inst.create_time.unwrap_or(""))) {
        (Some(_), Some(cs)) => {
          var latest_finish = cs
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
  // count DESC 自写插入排序
  for i in 1..<entries.length() {
    let key = entries[i]
    let mut j = i - 1
    while j >= 0 && entries[j].1 < key.1 {
      entries[j + 1] = entries[j]
      j = j - 1
    }
    entries[j + 1] = key
  }
  var i = 0
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
      var latest = cs
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
