// issues/126 案 A · 任务行 expire_time 的**求值器** + 建单写点共用的赋值口。
//
// 本栈修前形状（启动词 §1 / §1.5 普查）：全仓**一句**到期表达式求值都没有——建单五处一律不赋
// 这一列，只有回退那支 `expire_time: history.expire_time` 有值，而那也不是"按节点表达式算"，
// 是"抄上一行"（上一行本身又从来没算过 ⇒ 恒空）。于是 wf_process_task.expire_time 几乎恒
// NULL ⇒ 逾期统计恒 0。所以本栈＝"先移植求值器，再接五处写点"，不是改四行。
//
// 基准＝boot2 内置版（owner 2026-09-28 拍板 A），语义逐字对齐：
//   - 求值器：boot2 mldong-wf-core engine/util/FlowUtil.java:92 ＝ jeeflow-java
//     jeeflow-core util/FlowUtil.java:64（commit d9e9397）
//   - 赋值口：jeeflow-java `ProcessInstance.applyExpireTime`（d9e9397）＋ 公开入口
//     `applyNodeExpireTime`（cb541d4，给"绕过建单 helper 直建任务行"的第五处用）
//   - 回退新建取**当前节点**表达式 + 随行变量：boot2 ProcessTaskServiceImpl.java:384-387
//     （`((TaskModel)current).getExpireTime()` + `hisVariable`）
//
// 求值器落在 model 包（不是启动词 §1.5 写的 `core/util/`——本栈没有那个目录）：本栈的钟与
// "yyyy-MM-dd HH:mm:ss" 格式化都在 model/clock.mbt（current_time_str / format_unix_utc），
// 这一列的落库形态就是那一串；与它同包才不必把私有的历法换算再抄一遍。

///|
/// 任务节点上配的到期表达式属性键
/// （对齐 boot2 `TaskParser.EXPIRE_TIME_KEY` ← 设计器 JSON 的 `properties.expireTime`）
pub let expire_time_prop : String = "expireTime"

///|
/// 变量档的三种落点。刻意做成三态，因为 §1.5 的两个易错点方向相反：
/// ①「值类型不认识」必须**落穿**到相对/绝对档；②「值是字符串但解析不出」必须**终局 NULL**
/// （Java 的 catch → return null），不许落穿。合并成一个 Option 就会把这两档写成一个行为。
priv enum VarTier {
  VtTime(String)
  VtUnparsable
  VtFallthrough
}

///|
/// 节点到期表达式求值。三档顺序**不可变**：
///   ⓪ expr 为 None / 去空白后为空 ⇒ None（这一列保持 NULL：不写 now()、不写 ''、不写 0）
///   ① args 里存在**键名 == expr 原串**的项 ⇒ 取该项的值：日期串 → 该时刻（解析失败 ⇒ **None，
///      且是终局**）；毫秒整数 → epoch + 该毫秒（秒级 floor）；其它类型 ⇒ **落穿**
///   ② 以 s|m|h|d 结尾且前缀是**非负**整数 ⇒ 当前时刻 + N 秒/分/时/天（**d 走日历加天**；
///      负前缀算「解析不出来」⇒ 落穿，issues/137 D）
///   ③ 否则把 expr 本身按 "yyyy-MM-dd HH:mm:ss" 严格解析 ⇒ 该时刻；失败 ⇒ None
///
/// **任何一档都不许返回"当前时间"**：本案病灶恰是"非空但错"的占位 now()（建单即逾期、
/// expire − create ≈ 0），一旦让 now() 当兜底，L2-27 那格就永远抓不到东西。
///
/// 与 Java 的两处**故意**差异（都不改变"空/非空"判点）：
///   1. Java `Integer.parseInt` 遇坏前缀（节点误配成 `xh`）抛异常**打断建单**；本栈按启动词
///      §1.9-3 统一走 C# 的**落穿 → NULL**（配置写错不该把流程卡死）。
///   2. Java SimpleDateFormat 是宽松档（`2031-02-30` 会滚到 3 月、尾部多余字符被忽略）；本栈与
///      go/C# 一致按**严格**日历校验 ⇒ NULL。
pub fn process_time(expr : String?, args : @json.FlowData) -> String? {
  let e = match expr {
    None => ""
    Some(s) => s
  }
  // ⓪ 没配 ⇒ NULL（Java 的 isNotBlank 门；owner 2026-09-28：不造默认值）
  if e.trim(chars=" \t\r\n").to_owned() == "" {
    return None
  }
  // ① 变量档（**优先于**相对档：args 里真有个键叫 "2h" 时取的是变量值，不是 now+2h）。
  //    键名用 expr **原串**，与 Java `args.containsKey(expireTime)` 同档。
  match variable_tier(e, args) {
    VtTime(t) => return Some(t)
    VtUnparsable => return None
    VtFallthrough => ()
  }
  // ② 相对档
  match relative_secs(e) {
    Some(secs) => return Some(format_unix_utc(secs))
    None => ()
  }
  // ③ 绝对档
  match parse_time_secs(e) {
    Some(secs) => Some(format_unix_utc(secs))
    None => None
  }
}

///|
/// 建单写点共用的赋值口（对齐 java `ProcessInstance.applyExpireTime`）：
/// 表达式 None/空白 ⇒ **直接 return**，这一列保持 NULL；配了但算不出 ⇒ 求值给 None，同样留空。
///
/// `args` 变量源两档**不许搞混**（搞混会让"表达式是个变量名"这一档跨栈给出不同答案）：
///   - 建单三处（普通 / 串行会签首位 / 并行会签全员）+ 串行推进位＝**实例变量**
///     ＝ java `this.variables` ＝ boot2 `execution.getArgs()`
///   - 回退/跳转新建＝**随行拷贝那份变量** ＝ boot2 的 `hisVariable`
pub fn apply_expire_time(task : ProcessTask, expr : String?, args : @json.FlowData) -> Unit {
  let e = match expr {
    None => ""
    Some(s) => s
  }
  if e.trim(chars=" \t\r\n").to_owned() == "" {
    return
  }
  task.expire_time = process_time(expr, args)
}

///|
/// "yyyy-MM-dd HH:mm:ss" **严格**解析 → epoch 秒：长度必须 19、五个分隔位逐位对、六段全数字、
/// 月/日/时/分/秒做日历合法性校验（含闰年 2 月）。与 clock.mbt `format_unix_utc`（UTC 口径）互逆。
/// 任一条不满足 ⇒ None（**不是** now）。
pub fn parse_time_secs(s : String) -> Int64? {
  let cs = s.to_array()
  if cs.length() != 19 {
    return None
  }
  if !(cs[4] == '-' && cs[7] == '-' && cs[10] == ' ' && cs[13] == ':' && cs[16] == ':') {
    return None
  }
  let y = match digits(cs, 0, 4) {
    Some(v) => v
    None => return None
  }
  let mo = match digits(cs, 5, 2) {
    Some(v) => v
    None => return None
  }
  let d = match digits(cs, 8, 2) {
    Some(v) => v
    None => return None
  }
  let hh = match digits(cs, 11, 2) {
    Some(v) => v
    None => return None
  }
  let mi = match digits(cs, 14, 2) {
    Some(v) => v
    None => return None
  }
  let ss = match digits(cs, 17, 2) {
    Some(v) => v
    None => return None
  }
  if mo < 1 || mo > 12 {
    return None
  }
  if d < 1 || d > days_in_month(y, mo) {
    return None
  }
  if hh > 23 || mi > 59 || ss > 59 {
    return None
  }
  Some(days_from_civil(y, mo, d) * 86400L + (hh * 3600 + mi * 60 + ss).to_int64())
}

///|
/// **日历**加 N 天（对齐 Java `Calendar.add(DAY_OF_MONTH, n)` / go `AddDate(0,0,n)`）：
/// 拆出年月日、日字段 += n、再合成 epoch 天。刻意不写 `secs + n*86400`——量纲要与基准同档
/// （启动词 §1：`d` 走日历加天，不乘 86400 秒）。
pub fn add_days(secs : Int64, n : Int) -> Int64 {
  let mut days = secs / 86400L
  let mut tod = secs % 86400L
  if tod < 0L {
    tod = tod + 86400L
    days = days - 1L
  }
  let (y, m, d) = civil_from_days(days)
  days_from_civil(y, m, d + n) * 86400L + tod
}

///|
/// 变量档取值：三态见 `VarTier`。
/// 没有这个键＝Java 的 `!containsKey` ⇒ 直接落穿到相对/绝对档。
fn variable_tier(expr : String, args : @json.FlowData) -> VarTier {
  match args.get(expr) {
    None => VtFallthrough
    Some(v) =>
      match v {
        Json::String(s) =>
          // 字符串档：解析失败即**终局** None（Java `catch (ParseException) return null`）
          match normalize_time_str(s) {
            Some(t) => VtTime(t)
            None => VtUnparsable
          }
        Json::Number(n, repr~) =>
          match millis_of(n, repr) {
            Some(secs) => VtTime(format_unix_utc(secs))
            None => VtFallthrough
          }
        // bool / object / array / JSON null ⇒ Java 三个 instanceof 全不命中 ⇒ **落穿**
        _ => VtFallthrough
      }
  }
}

///|
/// 毫秒时间戳档 → epoch 秒（对齐 Java `toLocalDateTime(new Date(l))`；本栈这一列只到秒，
/// 秒级 floor 与 Java 落秒同一量纲，启动词 §1 已把它写进断言带宽）。
/// 原文（repr）优先按整数精确解析（D-M5-3 同款口径，防 Double 取整）；
/// 非整数值（Java 侧 Double 不匹配 `instanceof Long`）⇒ None ⇒ 交调用方**落穿**。
fn millis_of(n : Double, repr : String?) -> Int64? {
  match repr {
    Some(s) =>
      match parse_int64_strict(s) {
        Some(ms) => Some(div_floor(ms, 1000L))
        None => None
      }
    None =>
      if n.is_nan() || n.is_inf() {
        None
      } else if n != n.trunc() {
        None
      } else {
        Some(div_floor(n.to_int64(), 1000L))
      }
  }
}

///|
/// 相对档 Ns/Nm/Nh/Nd。后缀不认识、或前缀不是**非负**整数 ⇒ None（交回调用方走绝对档）。
/// 前缀**不做 trim**，与 Java `Integer.parseInt(substring(...))` 同判据。
///
/// issues/137 D（owner 2026-10-01 拍「判非负」，基准＝jeeflow-java `1649955` 的
/// `FlowUtil.parseIntOrNull`）：**负前缀同样算解析不出来** ⇒ 落穿绝对档 ⇒ 仍失败就 NULL。
/// 放行 `-5h` 会算出一个**过去**的时刻 ⇒ 新建行当场即逾期，比「没配到期时间」更难发现，也与
/// 上面那条「不允许退化成取当前时间」（issues/126 病灶）同向。四档共用这一处判负：本栈的
/// `d` 档唯一入口就是下面那个 `add_days`（日历加天，负数＝历日倒退，不是乘 86400），
/// 无旁路，故一处裁完 s/m/h/d 四档。只裁负、**不裁加号**。
fn relative_secs(expr : String) -> Int64? {
  let cs = expr.to_array()
  let len = cs.length()
  if len < 2 {
    return None
  }
  let unit = cs[len - 1]
  if !(unit == 's' || unit == 'm' || unit == 'h' || unit == 'd') {
    return None
  }
  let n = match parse_int_non_negative(expr[0:len - 1].to_owned()) {
    Some(v) => v
    None => return None
  }
  let base = expire_now_secs()
  if unit == 's' {
    Some(base + n.to_int64())
  } else if unit == 'm' {
    Some(base + (n * 60).to_int64())
  } else if unit == 'h' {
    Some(base + (n * 3600).to_int64())
  } else {
    Some(add_days(base, n))
  }
}

///|
/// 到期计算的"当前时刻"基准：**必须**走 clock.mbt 那把可注入的钟（`current_time_str()`），
/// 而不是裸读 `@env.now()`——否则测试/宿主注入固定钟时，行上的 create_time 与算出的
/// expire_time 会来自两把钟，"同一行 expire − create ≈ 表达式偏移"那格就无从判起
/// （issues/120 附证在本栈定的口径就是"只有一把钟"，见 facade/stats.mbt:182）。
/// 注入串不合 "yyyy-MM-dd HH:mm:ss" 时回退真实钟（宁缺判据不整块报错）。
fn expire_now_secs() -> Int64 {
  match parse_time_secs(current_time_str()) {
    Some(s) => s
    None => epoch_secs()
  }
}

///|
/// 日期串档：严格解析后**回格式化**（顺带把 "2030-5-6 ..." 这类非零填充串拒掉，与 go/C# 同档）
fn normalize_time_str(s : String) -> String? {
  match parse_time_secs(s) {
    Some(secs) => Some(format_unix_utc(secs))
    None => None
  }
}

///|
/// 定长数字段（任一字符非数字 ⇒ None）
fn digits(cs : Array[Char], from : Int, len : Int) -> Int? {
  let mut v = 0
  for i in 0..<len {
    let code = cs[from + i].to_int()
    if code < 48 || code > 57 {
      return None
    }
    v = v * 10 + (code - 48)
  }
  Some(v)
}

///|
/// 严格整数解析（可带 +/- 号，其余一律非数字 ⇒ None）。
/// 本栈刻意不引 `@string.parse_int`：一是 model 包没导 @string，二是它的容忍面比
/// Java parseInt 宽（前导空白），口径以这里为准。
fn parse_int_strict(s : String) -> Int? {
  parse_int_sign(s, false)
}

///|
/// 相对档前缀取整数（逐字对齐 java `FlowUtil.parseIntOrNull`，issues/137 D · owner 2026-10-01
/// 拍「判非负」）：非整数（`x`/`2.5`/`3h`）或**负数** ⇒ None，交调用方**落穿**，不抛。
///
/// 为什么不是给 `parse_int_sign` 传 `neg=true`（实读结论，别按字面猜这个参数）：`neg` 是
/// 「串首没有显式 +/- 号时**结果的默认符号**」，不是「是否允许负号」——串里一旦出现 `-`/`+`，
/// 它就覆盖你传的值（`negative = cs[0] == '-'`）。本文件两处调用都传 false，却依旧解析得出
/// `-5`，证明负号从来不被这个开关门控。改传参既裁不住负档，还会把无符号串整体变负。
///
/// 只裁负**不裁加号**：各栈整数解析（python `[+-]?`、node `[-+]?\d+`、php `[+-]?\d{1,18}`）都
/// 收 '+'，裁掉加号等于新造一处跨栈分叉。`-0` 同 java（`Integer.parseInt("-0") == 0`，不算负、
/// 放行）。
fn parse_int_non_negative(s : String) -> Int? {
  match parse_int_strict(s) {
    Some(v) => if v < 0 {
      None
    } else {
      Some(v)
    }
    None => None
  }
}

///|
/// 严格 Int64 解析（毫秒档用）
fn parse_int64_strict(s : String) -> Int64? {
  parse_int_sign64(s, false)
}

fn parse_int_sign(s : String, neg : Bool) -> Int? {
  let cs = s.to_array()
  let len = cs.length()
  let mut i = 0
  let mut negative = neg
  if len > 0 && (cs[0] == '-' || cs[0] == '+') {
    negative = cs[0] == '-'
    i = 1
  }
  if i >= len {
    return None
  }
  let mut v = 0
  while i < len {
    let code = cs[i].to_int()
    if code < 48 || code > 57 {
      return None
    }
    v = v * 10 + (code - 48)
    i = i + 1
  }
  if negative { Some(-v) } else { Some(v) }
}

fn parse_int_sign64(s : String, neg : Bool) -> Int64? {
  let cs = s.to_array()
  let len = cs.length()
  let mut i = 0
  let mut negative = neg
  if len > 0 && (cs[0] == '-' || cs[0] == '+') {
    negative = cs[0] == '-'
    i = 1
  }
  if i >= len {
    return None
  }
  let mut v = 0L
  while i < len {
    let code = cs[i].to_int()
    if code < 48 || code > 57 {
      return None
    }
    v = v * 10L + (code - 48).to_int64()
    i = i + 1
  }
  if negative { Some(-v) } else { Some(v) }
}

///|
/// 向下取整除（毫秒 → 秒在负 epoch 上也要落对；`/` 是向零截断）
fn div_floor(a : Int64, b : Int64) -> Int64 {
  let q = a / b
  let r = a % b
  if r != 0L && ((r < 0L) != (b < 0L)) { q - 1L } else { q }
}

fn leap_year(y : Int) -> Bool {
  (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn days_in_month(y : Int, m : Int) -> Int {
  match m {
    1 => 31
    2 => if leap_year(y) { 29 } else { 28 }
    3 => 31
    4 => 30
    5 => 31
    6 => 30
    7 => 31
    8 => 31
    9 => 30
    10 => 31
    11 => 30
    12 => 31
    _ => 0
  }
}

///|
/// 历日 → epoch 天：clock.mbt `format_unix_utc` 里那段 civil_from_days 的逆运算
/// （Howard Hinnant）。**d 允许越界**（如 1/32、2/0）——该式对 1..12 的月与越界日天然连续，
/// `add_days` 的"日历加天"就靠这一点，不必自己判月末。
fn days_from_civil(y0 : Int, m : Int, d : Int) -> Int64 {
  let y = if m <= 2 { y0 - 1 } else { y0 }
  let era = (if y >= 0 { y } else { y - 399 }) / 400
  let yoe = y - era * 400
  let mp = if m > 2 { m - 3 } else { m + 9 }
  let doy = (153 * mp + 2) / 5 + d - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  (era * 146097 + doe).to_int64() - 719468L
}

///|
/// epoch 天 → 历日：与 format_unix_utc 同一算法（只把"格式化"换成"返回三元组"）
fn civil_from_days(days : Int64) -> (Int, Int, Int) {
  let z = days + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = (z - era * 146097L).to_int()
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let yy = yoe + (era * 400L).to_int()
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  let y = if m <= 2 { yy + 1 } else { yy }
  (y, m, d)
}
