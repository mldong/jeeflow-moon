// 分页排序子句解析（audit8 R31/issues/197）。
//
// 病灶前身：`PageQuery.order_by` 在本栈是「声明了却全栈零消费者」——内存腿既不滤条件也不排序
// 还按 id 升序，SQL 腿硬编码 `ORDER BY pd.id DESC`，于是门面里 4 个带条件／带序的内部调用
// （deploy／processDesign redeploy／saveDeployedDefine／getLastByName）两条腿各给各的答案。
// 本文件是那把**共用**的尺子：解析口径逐字照 java
// `jeeflow-repository-jdbc/.../JdbcProcessRepository.buildOrder`（现读 :1257-1280）。

///|
/// 排序子句单项：列名（可能带别名前缀，由调用方剥）＋是否降序
pub(all) struct OrderTerm {
  column : String
  desc : Bool
}

///|
/// 解析 `order_by`：逗号分子句、空格分「列名 方向」；方向缺省升序，`desc` 大小写不敏感。
///
/// 与 java 的一处**刻意差别**：java 把 `kv[1].toUpperCase()` 原样拼进 SQL（列名有白名单、
/// 方向词没有），本函数只产出布尔值 ⇒ `order_by` 原文永不进 SQL 串，注入面为零。
/// 空串／全空白／只有方向词 ⇒ 空数组，由调用方各自回落缺省序。
pub fn parse_order_by(s : String) -> Array[OrderTerm] {
  let terms : Array[OrderTerm] = []
  for part in s.split(",").collect() {
    let tokens = split_space_tokens(part.to_owned())
    if tokens.length() > 0 {
      let desc = tokens.length() > 1 && tokens[1].to_lower() == "desc"
      terms.push(OrderTerm::{ column: tokens[0], desc: desc })
    }
  }
  terms
}

///|
/// 剥排序列的别名前缀：`t.version` / `pd.version` → `version`。
/// 门面沿 java 习惯写 `t.`，而本栈定义表在 SQL 腿里的别名是 `pd` ⇒ 两条腿各自把裸列名映射回去。
pub fn order_column_bare(column : String) -> String {
  let parts = column.split(".").collect()
  let n = parts.length()
  if n == 0 {
    column
  } else {
    parts[n - 1].to_owned()
  }
}

///|
/// 按空白切词（多空格／首尾空格产出的空串丢掉）
fn split_space_tokens(s : String) -> Array[String] {
  let out : Array[String] = []
  let trimmed = s.trim()
  for t in trimmed.split(" ").collect() {
    let item = t.to_owned()
    if !item.is_empty() {
      out.push(item)
    }
  }
  out
}
