#!/usr/bin/env python
"""engine.mbt / engine_ops.mbt：SPI 闭包"值即返回 + raise"的第三类清理。

上一轮把 `try?` 换成了 `try { } catch { }`；这轮清的是**同源的 Result 壳**：
老代码把"会 raise 的闭包/解析函数"当 `Result` 用（`Ok(v)`/`Err(_)` 臂），
新签名下它们的值类型就是 `T`（raise 走效果），于是 `Ok(v)` 与 `T` 撞类型。
判据来自编译器自己：
  Constr Type Mismatch(constructor Ok) has type Result[_/0,_/1] wanted String
  The error type is mismatched: wanted JeeflowError / has : Error.

三处语义等价性（都在"失败就当这一档不存在"的旧臂上）：
  - assignment handler：Err ⇒ ()，与"取到空串 ⇒ 不 return"同一条落空路径
  - compare_values：parse 失败 ⇒ None ⇒ 字符串兜底
  - submitType 字符串档：parse 失败 ⇒ None ⇒ 走后面判据
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

ENGINE = "core/engine/engine.mbt"
OPS = "core/engine/engine_ops.mbt"

ENGINE_PAIRS = [
    (
        """        Some(handler) => {
          let outcome = (handler)(exec)
          match outcome {
            Ok(result) => if !result.is_empty() { return split_actors(result) }
            Err(_) => ()
          }
        }
""",
        """        Some(handler) => {
          // handler 签名是 `-> String raise JeeflowError`：旧 `try?` 把 raise 折成 Result，
          // Err 臂就是"这一档跳过"；换成空串后下面的 !is_empty 判据走同一条落空路径。
          let result = try { (handler)(exec) } catch { _ => "" }
          if !result.is_empty() {
            return split_actors(result)
          }
        }
""",
    ),
    (
        """  let l = try {
    @string.parse_double(left)
  } catch {
    _ => None
  }
  let r = try {
    @string.parse_double(right)
  } catch {
    _ => None
  }
""",
        """  // parse_double 是 `-> Double raise`：`try` 两臂必须同类型，所以成功臂自己包 Some
  let l = try {
    Some(@string.parse_double(left))
  } catch {
    _ => None
  }
  let r = try {
    Some(@string.parse_double(right))
  } catch {
    _ => None
  }
""",
    ),
]

OPS_PAIRS = [
    (
        """          match (@string.parse_int64(s)) {
            Ok(v) => Some(v)
            Err(_) => None
          }
""",
        """          // parse_int64 是 `-> Int64 raise`：解析失败 ⇒ "没有数字档"（旧 Err ⇒ None）
          try {
            Some(@string.parse_int64(s))
          } catch {
            _ => None
          }
""",
    ),
]

if __name__ == "__main__":
    patch(ENGINE, ENGINE_PAIRS)
    patch(OPS, OPS_PAIRS)
