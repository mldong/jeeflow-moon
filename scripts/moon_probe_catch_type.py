#!/usr/bin/env python
"""facade/facade.mbt 单点探针：catch 绑定值的静态类型到底是 JeeflowError 还是 open Error。

`flow` 是门面唯一出口：dispatch 声明 `raise @error.JeeflowError`（闭集），
旧代码 `match outcome { Ok(data) / Err(e) => err(e.message()) }` 里的 e 由
Result 的第二个类型参数钉成 JeeflowError。换成 `try/catch` 后 e 的类型要实测：
  - 若是 JeeflowError ⇒ `.message()` 直接过，出口文案逐字不变（首选）
  - 若是 open Error    ⇒ 只能 `\\{e}` 走 Show（Show 里就是 message()，仍等值）
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

PAIRS = [
    (
        """  let outcome = self.dispatch(action, args)
  match outcome {
    Ok(data) => transform_output(ok_data(data))
    Err(e) => transform_output(err(e.message()))
  }
""",
        """  // dispatch 是 `-> Json raise JeeflowError`：raise 即旧 Err 臂，出口转 err 信封
  let outcome = try {
    await self.dispatch(action, args)
  } catch {
    e => err(e.message())
  }
  transform_output(outcome)
""",
    ),
]

if __name__ == "__main__":
    patch("facade/facade.mbt", PAIRS)
