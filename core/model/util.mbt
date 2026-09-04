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
