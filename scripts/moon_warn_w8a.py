#!/usr/bin/env python
"""警告批次 W8a：core/json/json.mbt 的两个"转发助手"**手改**，先于 jget 菜谱。

为什么先手改：`@json.get` / `as_str` 的助手体本身就是 `value.value(key)` / `value.as_string()`
这两个被弃办的调用；jget 菜谱会把 `X.value(K)` 换成 `@json.get(X, K)`，
若助手体也被换成就变成**自递归**（栈爆在运行期，编译器不一定拦）。
所以这一档先把助手体换成编译器建议的判形，之后菜谱再动别处就安全了。

顺手把 as_array 补上：Json 的 `.as_array()` 也在弃办名单里，而本仓没有对应助手；
补一个与 get/as_str 同形的 `as_array`，让菜谱有地方可去（而不是把判形散到 3 个调用点）。
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

PAIRS = [
    (
        """pub fn get(value : Json, key : String) -> Json? {
  value.value(key)
}
""",
        """pub fn get(value : Json, key : String) -> Json? {
  // `Json.value` 已弃办，建议形就是这一句；本仓所有"取对象键"都从这里过，
  // 所以只改这一处，其余 70+ 个 `.value(` 站点交给菜谱换成 @json.get(...)。
  if value is Object(obj) {
    obj.get(key)
  } else {
    None
  }
}
""",
    ),
    (
        """pub fn as_str(value : Json) -> String? {
  value.as_string()
}
""",
        """pub fn as_str(value : Json) -> String? {
  // 同上：`Json.as_string` 已弃办
  if value is String(s) {
    Some(s)
  } else {
    None
  }
}

///|
/// `Json.as_array` 的替身（本仓原来没有这一档，三个调用点各写一遍判形不如集中一处）
pub fn as_array(value : Json) -> Array[Json]? {
  if value is Array(a) {
    Some(a)
  } else {
    None
  }
}
""",
    ),
]

if __name__ == "__main__":
    patch("core/json/json.mbt", PAIRS)
