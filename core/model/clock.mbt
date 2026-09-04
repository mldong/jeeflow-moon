// 可注时钟（方案 §3.4.1 / D-M0-3）：core 默认走 @env.now()，测试注入固定钟。
// MoonBit 单线程事件循环，全局 Ref 安全（无并发竞争）。

///|
let clock_ref : Ref[((() -> String))?] = Ref::new(None)

///|
pub fn set_clock(f : (() -> String)?) -> Unit {
  clock_ref.val = f
}

///|
/// 当前墙钟毫秒（@env.now() 的单位实测为 epoch 毫秒，见 model_test）
pub fn epoch_millis() -> Int64 {
  @env.now().to_int64()
}

///|
/// 当前墙钟秒
pub fn epoch_secs() -> Int64 {
  epoch_millis() / 1000L
}

///|
pub fn current_time_str() -> String {
  match clock_ref.val {
    Some(f) => f()
    None => format_unix_utc(epoch_secs())
  }
}

///|
/// Format unix seconds (UTC) as `yyyy-MM-dd HH:mm:ss`（civil_from_days, Howard Hinnant）
pub fn format_unix_utc(secs : Int64) -> String {
  let z = secs / 86400L + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = (z - era * 146097L).to_int()
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + (era * 400L).to_int()
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  let y = if m <= 2 { y + 1 } else { y }
  let tod = (secs % 86400L).to_int()
  let hh = tod / 3600
  let mm = (tod % 3600) / 60
  let ss = tod % 60
  let pad = (n : Int, w : Int) => {
    let s = n.to_string()
    let b = StringBuilder::new()
    for _ in 0..<(w - s.length()) {
      b.write_char('0')
    }
    b.write_string(s)
    b.to_string()
  }

  "\{pad(y, 4)}-\{pad(m, 2)}-\{pad(d, 2)} \{pad(hh, 2)}:\{pad(mm, 2)}:\{pad(ss, 2)}"
}
