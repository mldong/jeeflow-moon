#!/usr/bin/env python
"""demo 侧 4 处 Result 壳清理（新效果系统下 parse_json / parse_int64 / flow 都不再返回 Result）。

形状约束与前一批一致（见 scripts/moon_migrate_tests1.py 的文件头）：
  - try 块里不放 fail/abort，否则 catch 的 e 被撑成 open Error；
  - 闭集 raise ⇒ catch 绑定即 JeeflowError，`.message()` 可用（facade/facade.mbt 已实证）。

⚠ demo/cmd/consistency/main.mbt 是**八栈一致性快照的生成器**：改完必须复跑并对
  consistency/moon.json 做逐字节比对（本轮门禁之一），因为它的产物不能因迁移而漂移。
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

APP = "demo/app.mbt"
DEMO = "demo/demo.mbt"
CONS = "demo/cmd/consistency/main.mbt"
T1 = "demo/cmd/t1_mysql/main.mbt"

APP_PAIRS = [
    (
        """    let parsed = if trimmed.is_empty() {
      Ok(@json.empty_object())
    } else {
      @json.parse_json(trimmed)
    }
    let args : Map[String, Json] = match parsed {
      Ok(Json::Object(m)) => {
        let copy : Map[String, Json] = Map([])
        for k, v in m {
          copy[k] = v
        }
        copy
      }
      Ok(_) => {
        println("[demo] body 解析失败: 非 JSON 对象")
        raise @error.Business("body 必须是 JSON 对象")
      }
      Err(e) => {
        println("[demo] body 解析失败: \\{e.message()}")
        raise @error.Business("body 解析失败: \\{e.message()}")
      }
    }
""",
        """    // parse_json 现在直接 raise（不再返回 Result）：三档判据原样保留
    // ——空 body 当空对象；坏 JSON 打印并转 99999999（rust issue 88 的教训）；非对象另一条文案。
    let parsed = if trimmed.is_empty() {
      @json.empty_object()
    } else {
      try {
        @json.parse_json(trimmed)
      } catch {
        e => {
          println("[demo] body 解析失败: \\{e.message()}")
          raise @error.Business("body 解析失败: \\{e.message()}")
        }
      }
    }
    let args : Map[String, Json] = match parsed {
      Json::Object(m) => {
        let copy : Map[String, Json] = Map([])
        for k, v in m {
          copy[k] = v
        }
        copy
      }
      _ => {
        println("[demo] body 解析失败: 非 JSON 对象")
        raise @error.Business("body 必须是 JSON 对象")
      }
    }
""",
    ),
]

DEMO_PAIRS = [
    (
        """  match (@json.parse_json(content)) {
    Ok(v) => @json.get_str(v, "displayName").unwrap_or(fallback)
    Err(_) => fallback
  }
""",
        """  // parse_json 是 `-> Json raise`：坏 JSON ⇒ 回落 fallback（旧 Err 臂）
  try {
    @json.get_str(@json.parse_json(content), "displayName").unwrap_or(fallback)
  } catch {
    _ => fallback
  }
""",
    ),
]

CONS_PAIRS = [
    (
        """  let outcome = f.flow(action, args)
  match outcome {
    Ok(v) => out.push((label, v))
    Err(e) => {
      let o = @json.empty_object()
      @json.obj_set(o, "code", @json.number_of(99999999L))
      @json.obj_set(o, "msg", @json.string_of(e.to_string()))
      @json.obj_set(o, "data", @json.null_json())
      out.push((label, o))
    }
  }
""",
        """  // flow 自己就把引擎错误转成 err 信封（不再返回 Result）；这里的 catch 只兜门面之外的意外，
  // 仍按同一 {code:99999999,msg,data} 形状入册 ⇒ 快照两态可比、且不因迁移漂移。
  let outcome = try {
    f.flow(action, args)
  } catch {
    e => {
      let o = @json.empty_object()
      @json.obj_set(o, "code", @json.number_of(99999999L))
      @json.obj_set(o, "msg", @json.string_of("\\{e}"))
      @json.obj_set(o, "data", @json.null_json())
      o
    }
  }
  out.push((label, outcome))
""",
    ),
]

T1_PAIRS = [
    (
        """fn iid_of(env : Json) -> Int64 {
  let s = @json.get_str(env_data(env), "processInstanceId").unwrap_or("0")
  match (@string.parse_int64(s)) {
    Ok(v) => v
    Err(_) => abort("非法实例 id 出口值: \\{s}")
  }
}
""",
        """fn iid_of(env : Json) -> Int64 raise {
  let s = @json.get_str(env_data(env), "processInstanceId").unwrap_or("0")
  // parse_int64 是 `-> Int64 raise`：出口值坏掉仍旧 abort（旧 Err 臂）；
  // abort 在 catch 臂里 ⇒ 不污染 try 的 raise 集，但函数自己得声明 raise。
  try {
    @string.parse_int64(s)
  } catch {
    _ => abort("非法实例 id 出口值: \\{s}")
  }
}
""",
    ),
]

JOBS = [(APP, APP_PAIRS), (DEMO, DEMO_PAIRS), (CONS, CONS_PAIRS), (T1, T1_PAIRS)]

if __name__ == "__main__":
    for path, pairs in JOBS:
        patch(path, pairs)
