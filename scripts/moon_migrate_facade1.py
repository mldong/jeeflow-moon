#!/usr/bin/env python
"""facade 生产码的 Result 壳清理（新签名下"值即返回 + raise"）。

探针结论（scripts/moon_probe_catch_type.py，facade/facade.mbt 已按此改完）：
**闭集 raise 的函数里 catch 绑定值静态类型就是 JeeflowError** ⇒ `e.message()` 直接可用，
出口文案逐字不变。本脚本沿用同一形状。

改的三类：
  1. `match CALL { Ok(v) / Err(_) }`，CALL 已是 `-> T raise JeeflowError`
     （parse_model / biz_data_reader / user_provider / parse_json / parse_int / parse_int64）
  2. 非 raise 函数里裸调会 raise 的函数 ⇒ 编译器直接报
     "Function with error can only be used inside a function with error types in its signature"
  3. 隐式 await（async 函数不加 await 直呼）顺手改显式

语义守恒对照：Err ⇒ () 的落空路径一律换成"catch 到默认值 + 原判据同样落空"，
不新增传播（原来不抛的现在也不抛）。
"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from moon_patch import patch  # noqa: E402

EXT = "facade/actions_ext.mbt"
MAIN = "facade/actions_main.mbt"
ARGS = "facade/args.mbt"
OUT = "facade/outbound.mbt"
STATS = "facade/stats.mbt"

EXT_PAIRS = [
    (
        """  let outcome = @parser.parse_model(content)
  match outcome {
    Ok(model) => {
      design.name = model.name
      design.display_name = model.display_name
      design.design_type = model.model_type
    }
    Err(_) => ()
  }
""",
        """  // parse_model 是 `-> ProcessModel raise JeeflowError`：解析失败 ⇒ 三个字段保持原值
  //（旧 Err ⇒ () 同一条落空路径）
  try {
    let model = @parser.parse_model(content)
    design.name = model.name
    design.display_name = model.display_name
    design.design_type = model.model_type
  } catch {
    _ => ()
  }
""",
    ),
    (
        """      let outcome = (reader)(table, instance_id)
      match outcome {
        Ok(rows) => match rows {
          Some(row) => obj_json(row)
          None => @json.null_json()
        }
        Err(e) => raise @error.Business("业务数据读取失败: \\{e.message()}")
      }
""",
        """      // reader: `(String, Int64) -> Map[String,Json]? raise JeeflowError`
      let rows = try {
        (reader)(table, instance_id)
      } catch {
        e => raise @error.Business("业务数据读取失败: \\{e.message()}")
      }
      match rows {
        Some(row) => obj_json(row)
        None => @json.null_json()
      }
""",
    ),
    (
        """      let outcome = @parser.parse_model(d.content)
      match outcome {
        Ok(model) => {
          build_node_progress(model, history, node_progress)
          collect_path(model, model.get_start(), active, history_nodes, edges, inst.variables, history)
        }
        Err(_) => ()
      }
""",
        """      // 同上：坏定义 ⇒ 进度/路径两档都留空（旧 Err ⇒ ()）
      try {
        let model = @parser.parse_model(d.content)
        build_node_progress(model, history, node_progress)
        collect_path(model, model.get_start(), active, history_nodes, edges, inst.variables, history)
      } catch {
        _ => ()
      }
""",
    ),
]

MAIN_PAIRS = [
    (
        """      let info = match self.engine.context().user_provider {
        Some(get_user) =>
          match ((get_user)(actor)) {
            Ok(Some(u)) => u.real_name()
            _ => ""
          }
        None => ""
      }
""",
        """      // provider: `(String) -> UserInfo? raise JeeflowError`；取不到或报错 ⇒ 空串（旧语义）
      let info = match self.engine.context().user_provider {
        Some(get_user) =>
          try {
            match (get_user)(actor) {
              Some(u) => u.real_name()
              None => ""
            }
          } catch {
            _ => ""
          }
        None => ""
      }
""",
    ),
]

ARGS_PAIRS = [
    (
        """              match (@string.parse_int64(s)) {
                Ok(n) => Some(n)
                Err(_) => raise @error.Business("非法id: \\{s}")
              }
""",
        """              // parse_int64 是 `-> Int64 raise`：解析失败 ⇒ 非法 id（文案逐字不变）
              try {
                Some(@string.parse_int64(s))
              } catch {
                _ => raise @error.Business("非法id: \\{s}")
              }
""",
    ),
    (
        """                match (@string.parse_int64(s)) {
                  Ok(n) => out.push(n)
                  Err(_) => raise @error.Business("非法id: \\{s}")
                }
""",
        """                // 同上（数组档）
                try {
                  out.push(@string.parse_int64(s))
                } catch {
                  _ => raise @error.Business("非法id: \\{s}")
                }
""",
    ),
]

OUT_PAIRS = [
    (
        """  match (@json.parse_json(t)) {
    Ok(v) => Some(v)
    Err(_) => None
  }
}
""",
        """  // parse_json 是 `-> Json raise JeeflowError`：坏 JSON ⇒ None（旧 Err 臂）
  try {
    Some(@json.parse_json(t))
  } catch {
    _ => None
  }
}
""",
    ),
    (
        """        match (@json.parse_json(t)) {
          Ok(Json::Object(m)) =>
            for k, v in m {
              out[k] = v
            }
          _ => ()
        }
""",
        """        // 坏 JSON 或非对象 ⇒ 空 map（旧 `_ => ()` / `Err ⇒ ()` 两臂合成一条）
        try {
          match @json.parse_json(t) {
            Json::Object(m) =>
              for k, v in m {
                out[k] = v
              }
            _ => ()
          }
        } catch {
          _ => ()
        }
""",
    ),
]

STATS_PAIRS = [
    (
        """  let y = (@string.parse_int(t.substring(start=0, end=4).to_string()))
  let mo = (@string.parse_int(t.substring(start=5, end=7).to_string()))
  let d = (@string.parse_int(t.substring(start=8, end=10).to_string()))
  let (y, mo, d) = match (y, mo, d) {
    (Ok(a), Ok(b), Ok(c)) => (a, b, c)
    _ => return None
  }
""",
        """  // parse_int 现签名 `-> Int raise`：日期三段任一失败 ⇒ 不是这个格式 ⇒ None。
  // 兜底挪进 parse_int_or_none（非 raise 函数里裸调会 raise 的函数，编译器直接拒绝），
  // 调用点形状与旧 Ok/Err 三档一一对应，只换构造器名。
  let y = parse_int_or_none(t.substring(start=0, end=4).to_string())
  let mo = parse_int_or_none(t.substring(start=5, end=7).to_string())
  let d = parse_int_or_none(t.substring(start=8, end=10).to_string())
  let (y, mo, d) = match (y, mo, d) {
    (Some(a), Some(b), Some(c)) => (a, b, c)
    _ => return None
  }
""",
    ),
    (
        """    match (@string.parse_int(t.substring(start=11, end=13).to_string())) {
      Ok(v) => hh = v
      Err(_) => ()
    }
    match (@string.parse_int(t.substring(start=14, end=16).to_string())) {
      Ok(v) => mi = v
      Err(_) => ()
    }
    match (@string.parse_int(t.substring(start=17, end=19).to_string())) {
      Ok(v) => ss = v
      Err(_) => ()
    }
""",
        """    // 时间三段解析失败保持 0（旧 Err ⇒ () 语义）
    hh = parse_int_or(t.substring(start=11, end=13).to_string(), 0)
    mi = parse_int_or(t.substring(start=14, end=16).to_string(), 0)
    ss = parse_int_or(t.substring(start=17, end=19).to_string(), 0)
""",
    ),
    (
        """///|
/// Howard Hinnant days_from_civil
""",
        """///|
/// `parse_int`（`-> Int raise`）兜底：默认值档 / None 档各一个入口，
/// 让"解析失败算不算错"这件事在调用点上写明白，而不是靠 Ok/Err 猜。
fn parse_int_or(s : String, fallback : Int) -> Int {
  try {
    @string.parse_int(s)
  } catch {
    _ => fallback
  }
}

///|
fn parse_int_or_none(s : String) -> Int? {
  try {
    Some(@string.parse_int(s))
  } catch {
    _ => None
  }
}

///|
/// Howard Hinnant days_from_civil
""",
    ),
]

JOBS = [(EXT, EXT_PAIRS), (MAIN, MAIN_PAIRS), (ARGS, ARGS_PAIRS),
        (OUT, OUT_PAIRS), (STATS, STATS_PAIRS)]

if __name__ == "__main__":
    for path, pairs in JOBS:
        patch(path, pairs)
