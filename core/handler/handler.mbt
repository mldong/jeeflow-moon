// 节点处理器 —— 移植自 rust handler.rs（CountersignHandler 纯函数门控 + IHandler 形态）
// IHandler 在 MoonBit 中为闭包形态（Ctx 装配），此处保留 rust 语义等价的纯函数。

///|
/// 会签门控纯函数（issues/94）：check_merge
/// - same_node_tasks：该会签节点全部任务（FINISHED/DOING/ABANDON）
/// - submit_type：exec args 的 submitType（Some(20)=会签不同意）
/// - completion_condition：countersignCompletionCondition（已 trim 由调用方保证可空）
/// - countersign_type：SEQUENTIAL / PARALLEL
pub fn check_merge(
  same_node_tasks : Array[@model.ProcessTask],
  submit_type : Int64?,
  completion_condition : String?,
  countersign_type : String
) -> Bool {
  let total = same_node_tasks.length()
  let mut finished = 0
  for t in same_node_tasks {
    if t.is_finished() {
      finished = finished + 1
    }
  }
  // 一票否决门：submitType==20 且 condition==ONE_VOTE_VETO（忽略大小写）
  match submit_type {
    Some(20L) =>
      match completion_condition {
        Some(cond) =>
          if cond.trim(chars=" \t\r\n").to_lower() == "one_vote_veto" {
            return true
          }
        None => ()
      }
    _ => ()
  }
  let upper = countersign_type.to_upper()
  if upper == "SEQUENTIAL" || upper == "SERIAL" {
    finished >= total
  } else {
    // PARALLEL（默认）
    match completion_condition {
      Some(cond) => {
        let c = cond.trim(chars=" \t\r\n")
        if c.is_empty() || c.to_lower() == "one_vote_veto" {
          // 无特殊条件（或 ONE_VOTE_VETO 但否决门未触发）→ 全部完成才 merged
          finished >= total
        } else {
          // 表达式条件（如 #nrOfCompletedInstances==2）：由引擎带门控变量求值，
          // 纯函数不判表达式，恒 false（rust 同款语义）
          false
        }
      }
      None => finished >= total
    }
  }
}
