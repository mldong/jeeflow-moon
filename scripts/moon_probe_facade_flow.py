#!/usr/bin/env python
"""探针 A/B/C：`try { ... } catch { e => ... }` 里 e 的静态类型，以及 async 调用的合法写法。

背景：facade/facade.mbt 的 `flow` 是门面唯一出口，旧代码
`match self.dispatch(action, args) { Ok(data) / Err(e) => err(e.message()) }`。
dispatch 声明 `-> Json raise @error.JeeflowError`（**闭集**），所以理论上 catch 的 e
就是 JeeflowError、`.message()` 可用；但 flow 自己声明的是 `raise`（开集），
推断结果可能是 open `Error`。编译器说了算，三档依次试：
  A  隐式 await + e.message()
  B  隐式 await + "\\{e}"（Show）
  C  e 显式向上转型：match e { je => err(...) }
每次只跑 `moon check --target wasm ./facade` 然后看 facade.mbt 还有没有 error。

顺带证一件事：前一轮我把"scoped check 的 head -12 没打印 facade.mbt"当成了
"e.message() 通过"——那是**取样截断**，不是结论。这次一律按文件名过滤后全量看。
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

VAR = sys.argv[1] if len(sys.argv) > 1 else "A"

CUR = """  let outcome = try {
    await self.dispatch(action, args)
  } catch {
    e => err(e.message())
  }
"""

NEW = {
    "A": """  let outcome = try {
    self.dispatch(action, args)
  } catch {
    e => err(e.message())
  }
""",
    "B": """  let outcome = try {
    self.dispatch(action, args)
  } catch {
    e => err("\\{e}")
  }
""",
    "C": """  let outcome = try {
    await self.dispatch(action, args)
  } catch {
    e => err(e.message())
  }
""",
}[VAR]

if __name__ == "__main__":
    patch("facade/facade.mbt", [(CUR, NEW)])
