#!/usr/bin/env python
"""engine.mbt：add_user_info 的 Result 壳 → UserInfo? raise（单一钟轮后续的第二类偏差清理）。

user_provider 的签名是 `(String) -> @model.UserInfo? raise @error.JeeflowError`
（core/spi/context.mbt:58），旧代码写 `Ok(Some(user))` 是把 raise 误当 Result。
失败语义保持"吞掉、不炸发起路径"。
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

P = "core/engine/engine.mbt"

OLD = """      // 取用户失败按旧语义吞掉（_ => ()），不炸发起路径
      try {
        match (get_user)(operator) {
          Ok(Some(user)) => PLACEHOLDER
          args.insert_str("u_userId", user.user_id())
          args.insert_str("u_realName", user.real_name())
          args.insert_str("u_deptId", user.dept_id())
          args.insert_str("u_deptName", user.dept_name())
          args.insert_str("u_postId", user.post_id())
          args.insert_str("u_postName", user.post_name())
        }
        _ => ()
      }
"""

NEW = """      // provider 签名是 `(String) -> UserInfo? raise JeeflowError`：
      // 取用户失败按旧语义吞掉（catch 到 _ => ()），不炸发起路径。
      try {
        match (get_user)(operator) {
          Some(user) => {
            args.insert_str("u_userId", user.user_id())
            args.insert_str("u_realName", user.real_name())
            args.insert_str("u_deptId", user.dept_id())
            args.insert_str("u_deptName", user.dept_name())
            args.insert_str("u_postId", user.post_id())
            args.insert_str("u_postName", user.post_name())
          }
          None => ()
        }
      } catch {
        _ => ()
      }
"""

if __name__ == "__main__":
    patch(P, [(OLD, NEW)])
