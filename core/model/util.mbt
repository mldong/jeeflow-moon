///|
fn upper_ascii(ch : Char) -> Char {
  let code = ch.to_int()
  if code >= 97 && code <= 122 {
    Char::from_int(code - 32)
  } else {
    ch
  }
}

///|
pub fn format_time(s : String) -> String {
  s
}

///|
/// snake_case → camelCase
pub fn to_camel_case(s : String) -> String {
  let b = StringBuilder::new()
  let mut upper_next = false
  for ch in s {
    if ch == '_' {
      upper_next = true
    } else if upper_next {
      b.write_char(upper_ascii(ch))
      upper_next = false
    } else {
      b.write_char(ch)
    }
  }
  b.to_string()
}

///|
/// 逐码位字典序比较——绕开 String::compare 在 wasm sort 内部的怪异行为
/// （实测 core sort/sort_by 排 String 结果错误而 compare 直调正常；D-M3-2）
pub fn cmp_str(a : String, b : String) -> Int {
  let ac = a.to_array()
  let bc = b.to_array()
  let n = if ac.length() < bc.length() { ac.length() } else { bc.length() }
  for i in 0..<n {
    let d = ac[i].to_int() - bc[i].to_int()
    if d != 0 {
      return d
    }
  }
  ac.length() - bc.length()
}

///|
/// String 插入排序（cmp_str 承载）
pub fn sort_strings(arr : Array[String]) -> Unit {
  for i in 1..<arr.length() {
    let key = arr[i]
    let mut j = i - 1
    while j >= 0 && cmp_str(arr[j], key) > 0 {
      arr[j + 1] = arr[j]
      j = j - 1
    }
    arr[j + 1] = key
  }
}

///|
/// Int64 插入排序（数值序；防同款 core 排序问题扩散）
pub fn sort_i64(arr : Array[Int64]) -> Unit {
  for i in 1..<arr.length() {
    let key = arr[i]
    let mut j = i - 1
    while j >= 0 && arr[j].compare(key) > 0 {
      arr[j + 1] = arr[j]
      j = j - 1
    }
    arr[j + 1] = key
  }
}

///|
/// Int 插入排序
pub fn sort_int(arr : Array[Int]) -> Unit {
  for i in 1..<arr.length() {
    let key = arr[i]
    let mut j = i - 1
    while j >= 0 && arr[j].compare(key) > 0 {
      arr[j + 1] = arr[j]
      j = j - 1
    }
    arr[j + 1] = key
  }
}
