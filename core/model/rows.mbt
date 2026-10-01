// 分页/行模型/用户信息 —— 移植自 rust model.rs L548-L771

///|
pub(all) struct ProcessDesign {
  mut id : Int64
  mut name : String
  mut display_name : String
  mut design_type : String
  mut icon : String?
  mut is_deployed : Int
  mut remark : String?
  mut create_time : String?
  mut create_user : String?
  mut update_time : String?
  mut update_user : String?
} derive(Eq)

///|
pub fn ProcessDesign::clone(self : ProcessDesign) -> ProcessDesign {
  { ..self }
}

///|
pub(all) struct ProcessDesignHis {
  mut id : Int64
  mut process_design_id : Int64
  mut content : String
  mut create_time : String?
  mut create_user : String?
} derive(Eq)

///|
pub fn ProcessDesignHis::clone(self : ProcessDesignHis) -> ProcessDesignHis {
  { ..self }
}

///|
pub(all) struct ProcessSurrogate {
  mut id : Int64
  mut process_name : String
  mut operator : String
  mut surrogate : String
  mut start_time : String?
  mut end_time : String?
  mut enabled : Int
  mut create_time : String?
  mut create_user : String?
  mut update_time : String?
  mut update_user : String?
} derive(Eq)

///|
pub fn ProcessSurrogate::clone(self : ProcessSurrogate) -> ProcessSurrogate {
  { ..self }
}

///|
/// 四判据单条裁决（规范 06 §4.5 条款 3/4 + 条款 1.4 / issues/123 §1）：
/// **本条**委托此刻对该授权人是否生效。
///
/// 调用方必须先按主键 id 在各作用域内选出「最新一条」再问本方法——本方法只裁决单条，
/// 不做多条择优。反过来写（先按判据过滤、剩下的才取最新）等价于"历史上出现过一条窗内
/// 委托就永久生效"：用户随后改停用 / 改到未来 / 改成自委托都不算数，
/// 这正是 issues/123 里 13 栈 `L2-17`/`L2-18` "窗外 / enabled=0 / 脏值一律并入"的成因。
/// SQL 仓与内存仓必须走同一份判据（条款 6 双仓同答案）。
///
/// - `enabled` **严格等于整数 1** 才生效：0 / 脏值 2 / 一切非 1 都不算（本栈 `enabled`
///   字段为非可空 `Int`，SQL 侧的 NULL 由 `map_surrogate` 折成 0，见该处注释）；
/// - 被委托人须**非空且非授权人本人**（自委托不新增、不重复）；
/// - `time` 为空串 ⇒ **不做窗口比较**（对齐 Java 的 `time == null`；本栈 SPI 形参是
///   非可空 `String`，"没有判定时刻"就用空串表达。引擎建单路径恒传 `current_time_str()`）；
/// - 窗口须覆盖判定时刻：`start_time > time` 或 `end_time < time` ⇒ 不生效，
///   起止为 `None`/空串 = 该侧不限。
///
/// 时间两侧写入前都归一成 `yyyy-MM-dd HH:mm:ss`（见 facade 的 `parse_surrogate_time`），
/// 故**文本序即时间序**，直接串比；基准为本栈 `@model.current_time_str()` 的 UTC
/// （issues/120 已拍定「MoonBit 暂不注入时钟基准、对拍对 MoonBit 豁免」，非本轮缺陷）。
pub fn ProcessSurrogate::is_effective(self : ProcessSurrogate, operator : String, time : String) -> Bool {
  if self.enabled != 1 {
    return false
  }
  // 与 Java 同形：只 trim 被委托人一侧（`surrogate` 是台账里的自由输入）
  let agent = self.surrogate.trim(chars=" \t\r\n").to_owned()
  if agent.is_empty() {
    return false
  }
  if agent == operator {
    return false
  }
  let now = time.trim(chars=" \t\r\n").to_owned()
  if now.is_empty() {
    return true
  }
  match self.start_time {
    Some(s) => {
      let v = s.trim(chars=" \t\r\n").to_owned()
      if !v.is_empty() && v.compare(now) > 0 {
        return false
      }
    }
    None => ()
  }
  match self.end_time {
    Some(s) => {
      let v = s.trim(chars=" \t\r\n").to_owned()
      if !v.is_empty() && v.compare(now) < 0 {
        return false
      }
    }
    None => ()
  }
  true
}

///|
/// 作用域「最新一条」的裁决包装：该作用域没有记录 = 未命中。
/// 内存仓与 SQL 仓共用，保证两仓对同一份数据给出同一答案（条款 6）。
pub fn surrogate_scope_hit(sg : ProcessSurrogate?, operator : String, time : String) -> Bool {
  match sg {
    Some(s) => s.is_effective(operator, time)
    None => false
  }
}

///|
pub(all) struct CcInstance {
  mut id : Int64
  mut process_instance_id : Int64
  mut actor_id : String
  mut state : Int // 0=unread, 1=read
  mut create_time : String?
  mut create_user : String?
  mut update_time : String?
  mut update_user : String?
} derive(Eq)

///|
pub(all) struct TaskActor {
  mut id : Int64
  mut process_task_id : Int64
  mut actor_id : String
  mut create_time : String?
  mut create_user : String?
} derive(Eq)

///|
/// m_ 过滤条件（spec/06 §2.2）
pub(all) struct QueryFilter {
  table_alias : String // "t" 主表 / "pd" 流程定义 等
  op : FilterOp
  column : String // snake_case 列名
  value : String
} derive(Eq)

///|
pub fn QueryFilter::table_alias(self : QueryFilter) -> String {
  self.table_alias
}

///|
pub fn QueryFilter::op(self : QueryFilter) -> FilterOp {
  self.op
}

///|
pub fn QueryFilter::column(self : QueryFilter) -> String {
  self.column
}

///|
pub fn QueryFilter::value(self : QueryFilter) -> String {
  self.value
}

///|
pub fn QueryFilter::make(
  table_alias : String,
  op : FilterOp,
  column : String,
  value : String
) -> QueryFilter {
  { table_alias, op, column, value }
}

///|
pub(all) struct PageQuery {
  mut page_num : Int64
  mut page_size : Int64
  mut order_by : String?
  mut operator : String?
  conditions : Map[String, Json]
  filters : Array[QueryFilter]
}

///|
pub fn PageQuery::new(page_num : Int64, page_size : Int64) -> PageQuery {
  {
    page_num: if page_num < 1L { 1L } else { page_num },
    page_size: if page_size < 1L { 20L } else { page_size },
    order_by: None,
    operator: None,
    conditions: Map([]),
    filters: [],
  }
}

///|
pub fn PageQuery::page_num(self : PageQuery) -> Int64 {
  self.page_num
}

///|
pub fn PageQuery::page_size(self : PageQuery) -> Int64 {
  self.page_size
}

///|
pub fn PageQuery::set_page_num(self : PageQuery, n : Int64) -> Unit {
  self.page_num = if n < 1L { 1L } else { n }
}

///|
pub fn PageQuery::set_page_size(self : PageQuery, n : Int64) -> Unit {
  self.page_size = if n < 1L { 20L } else { n }
}

///|
pub fn PageQuery::operator(self : PageQuery) -> String? {
  self.operator
}

///|
pub fn PageQuery::set_operator(self : PageQuery, op : String?) -> Unit {
  self.operator = op
}

///|
pub fn PageQuery::order_by(self : PageQuery) -> String? {
  self.order_by
}

///|
pub fn PageQuery::set_order_by(self : PageQuery, s : String) -> Unit {
  self.order_by = Some(s)
}

///|
pub fn PageQuery::add_condition(self : PageQuery, key : String, value : Json) -> Unit {
  self.conditions[key] = value
}

///|
pub fn PageQuery::conditions(self : PageQuery) -> Map[String, Json] {
  self.conditions
}

///|
pub fn PageQuery::add_filter(self : PageQuery, f : QueryFilter) -> Unit {
  self.filters.push(f)
}

///|
pub fn PageQuery::filters(self : PageQuery) -> Array[QueryFilter] {
  self.filters
}

///|
/// 分页结果：恒五键契约（C22：pageNum/pageSize/recordCount/totalPage/rows）
pub(all) struct PageResult[T] {
  page_num : Int64
  page_size : Int64
  record_count : Int64
  total_page : Int64
  rows : Array[T]
}

///|
pub fn[T] PageResult::new(
  page_num : Int64,
  page_size : Int64,
  record_count : Int64,
  rows : Array[T]
) -> PageResult[T] {
  let total_page = if record_count == 0L {
    0L
  } else {
    (record_count + page_size - 1L) / page_size
  }
  { page_num, page_size, record_count, total_page, rows }
}

///|
pub fn[T] PageResult::page_num(self : PageResult[T]) -> Int64 {
  self.page_num
}

///|
pub fn[T] PageResult::page_size(self : PageResult[T]) -> Int64 {
  self.page_size
}

///|
pub fn[T] PageResult::record_count(self : PageResult[T]) -> Int64 {
  self.record_count
}

///|
pub fn[T] PageResult::total_page(self : PageResult[T]) -> Int64 {
  self.total_page
}

///|
pub fn[T] PageResult::rows(self : PageResult[T]) -> Array[T] {
  self.rows
}

///|
/// 待办/已办任务行
pub(all) struct TaskRow {
  mut id : Int64
  mut process_instance_id : Int64
  mut task_name : String
  mut display_name : String
  mut task_type : Int
  mut perform_type : Int
  mut task_state : Int
  mut operator : String?
  mut actor_id : String?
  mut finish_time : String?
  mut expire_time : String?
  mut form_key : String?
  mut task_parent_id : Int64?
  mut variable : String?
  mut create_time : String?
  mut create_user : String?
  mut update_time : String?
  mut update_user : String?
  // join instance
  mut process_define_id : Int64?
  mut instance_state : Int?
  mut instance_operator : String?
  mut business_no : String?
  mut instance_variable : String?
  mut instance_create_time : String?
  // join define
  mut define_name : String?
  mut define_display_name : String?
  mut define_version : Int?
} derive(Eq)

///|
pub fn TaskRow::new_empty() -> TaskRow {
  {
    id: 0L,
    process_instance_id: 0L,
    task_name: "",
    display_name: "",
    task_type: 0,
    perform_type: 0,
    task_state: 0,
    operator: None,
    actor_id: None,
    finish_time: None,
    expire_time: None,
    form_key: None,
    task_parent_id: None,
    variable: None,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
    process_define_id: None,
    instance_state: None,
    instance_operator: None,
    business_no: None,
    instance_variable: None,
    instance_create_time: None,
    define_name: None,
    define_display_name: None,
    define_version: None,
  }
}

///|
/// 实例行
pub(all) struct InstanceRow {
  mut id : Int64
  mut parent_id : Int64?
  mut process_define_id : Int64
  mut state : Int
  mut parent_node_name : String?
  mut business_no : String?
  mut operator : String
  mut expire_time : String?
  mut variable : String?
  mut create_time : String?
  mut create_user : String?
  mut update_time : String?
  mut update_user : String?
  mut define_name : String?
  mut define_display_name : String?
  mut define_version : Int?
} derive(Eq)

///|
pub fn InstanceRow::new_empty() -> InstanceRow {
  {
    id: 0L,
    parent_id: None,
    process_define_id: 0L,
    state: 0,
    parent_node_name: None,
    business_no: None,
    operator: "",
    expire_time: None,
    variable: None,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
    define_name: None,
    define_display_name: None,
    define_version: None,
  }
}

///|
/// 定义行
pub(all) struct DefineRow {
  mut id : Int64
  mut name : String
  mut display_name : String
  mut define_type : String
  mut state : Int
  mut version : Int
  mut create_time : String?
  mut create_user : String?
  mut update_time : String?
  mut update_user : String?
} derive(Eq)

///|
pub fn DefineRow::new_empty() -> DefineRow {
  {
    id: 0L,
    name: "",
    display_name: "",
    define_type: "",
    state: 0,
    version: 0,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
}

///|
/// 用户信息（IUserProvider 返回）
pub(all) struct UserInfo {
  user_id : String
  real_name : String
  dept_id : String
  dept_name : String
  post_id : String
  post_name : String
} derive(Eq)

///|
pub fn UserInfo::make(
  user_id~ : String,
  real_name~ : String,
  dept_id? : String = "",
  dept_name? : String = "",
  post_id? : String = "",
  post_name? : String = ""
) -> UserInfo {
  { user_id, real_name, dept_id, dept_name, post_id, post_name }
}

///|
pub fn UserInfo::user_id(self : UserInfo) -> String {
  self.user_id
}

///|
pub fn UserInfo::real_name(self : UserInfo) -> String {
  self.real_name
}

///|
pub fn UserInfo::dept_id(self : UserInfo) -> String {
  self.dept_id
}

///|
pub fn UserInfo::dept_name(self : UserInfo) -> String {
  self.dept_name
}

///|
pub fn UserInfo::post_id(self : UserInfo) -> String {
  self.post_id
}

///|
pub fn UserInfo::post_name(self : UserInfo) -> String {
  self.post_name
}


///|
/// issues/141 G1（spec 06-facade §2.5「抄送分页归属条件必填」）：ccList 归属列 `cc.actor_id` 的
/// **有效条件**判定。本栈该列的取值通道是 `PageQuery.operator`（门面 ccList 恒挂这条；SQL 仓拿它拼
/// `AND cc.actor_id = ?`，内存仓拿它比对 `cc.actor_id`）：
/// · 缺键（None）／空串／去空白后为空 ⇒ **无效**（等同"这条没给"）；
/// · 其余 ⇒ 有效，返回**原值**（不拿空白化后的值去比对，避免改动既有匹配语义）。
/// 判据只有这一份，两仓储（`core/memory/memory.mbt` 与 `repository-mysql/repo/repository_page.mbt`）
/// 都调它 ⇒「同一栈两个仓储两个答案」由构造堵死（issues/117 场景 27 那把尺子延长到 ccList）。
/// 判据无效 ⇒ `page_cc_instances` 必须返回**空页**，严禁退化成"这条不加"而放出全部实例。
/// 非归属列（m_ 可选过滤）的空值放行不在本函数管辖内，维持既有通用放行不变。
pub fn cc_ownership_operator(query : PageQuery) -> String? {
  match query.operator() {
    Some(op) =>
      if op.trim(chars=" \t\r\n").is_empty() {
        None
      } else {
        Some(op)
      }
    None => None
  }
}

///|
/// issues/141 G2（spec 06 §4「抄送写侧判重＝幂等空操作」）：从请求的抄送人里挑出**实际会新建**的子集 ——
/// 已经有 cc 行的人跳过（①不新增行 ②不重置未读 state ③不更新原行时间），**同一次调用内的重复也折叠**，
/// 顺序与入参一致。判重落在写侧：查询侧不引入去重、历史重复行也不清理（owner 2026-09-29 拍）。
/// 为什么返回子集而不是 Unit：spec §11.2 原则 1「码值表达发生了什么事实」⇒ 重复抄送没发生"创建"，
/// 就不得 fire CC_CREATE（码 4）。建 cc 的三条入口（发起 `f_ccActors`／办理 `tf_ccActors`／
/// 门面手动 `createCCInstance`）一律拿这个子集去 fire，子集为空 ⇒ 整支不发。
pub fn cc_fresh_subset(existing : Array[String], requested : Array[String]) -> Array[String] {
  let fresh : Array[String] = []
  for actor_id in requested {
    if !existing.contains(actor_id) && !fresh.contains(actor_id) {
      fresh.push(actor_id)
    }
  }
  fresh
}

/// issues/142 B 批（spec 06-facade §2.11「归属值写侧归一 · actor_id 与 task id」，owner 2026-09-30
/// 拍「八栈一起收：两形同判据＋写侧兜底＋trim＋哨兵」；基准＝java `StringUtils.normalizeCcActors` 那一枚）：
/// issues/141 G10 落地的那枚归一判据在这里**升格为通用单点** —— 参与者/抄送人集合一律过同一枚：
/// 逐元素 **trim**、**空串与纯空白一律丢弃**、同一次调用内的重复折叠（顺序保持），
/// 落库与比较一律取 **trim 后的值**。
///
/// 为什么是「升格」而不是「另立一枚」（§2.11 尾注原话：「归一判据请复用 §2.10 已落地的那一枚单点
/// ……必要时改名成通用的 normalizeActors——**不要再抄第二份**」）：两份判据迟早分叉，本栈普查实读
/// 到的正是「同一把尺子长两副面孔」——`create_cc_instance` 过归一、紧邻的 `task_surrogate` 不过。
/// 旧名 `normalize_cc_actors` 保留为**转发**（见下），判据本体只这一份。
///
/// 覆盖的写点（§2.11 表，与 §2.10 的抄送三入口同一枚）：
/// · 门面腿：`processTask/addCandidate`、`processTask/surrogate`（同体）、`processTask/transfer` 的
///   fromActor/toActor（单值档走下面的 `normalize_actor`）、`processInstance/createCCInstance`；
/// · 漏斗腿：`core/engine` 的 `parse_cc_actors` 与发起/办理两侧的 f_/tf_nextNodeOperator（§2.11 消费腿）；
/// · 写侧层：内存仓与 MySQL 仓的 `add_task_actor`／`create_cc_instance`／`create_cc_instance_if_absent
///   —— **两层都挡**：只修门面腿则绕过门面直连仓储的调用方照样灌空值（issues/129 那族病根）。
///
/// ⚠️ **反向哨兵**：判据是「trim 后 `is_empty()`」，**不是 falsy** —— `"0"`、`"00"`、`"false"` 这类
/// 「看起来像空」的正常 id 必须保留，且 `"0"` 与 `"00"` 是**两个人**（严禁松散比较把第二个静默折叠）；
/// `" "` 纯空白按本条丢弃（与 §2.10 逐字同源）。
pub fn normalize_actors(raw : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for actor_id in raw {
    let t = actor_id.trim(chars=" \t\r\n").to_owned()
    if !t.is_empty() && !out.contains(t) {
      out.push(t)
    }
  }
  out
}

///|
/// 归属值**删除腿**展开（issues/137 §3-6 · spec 06 §processTask/removeTaskActor 语义 6，
/// owner 2026-10-02 拍「两形并集」）：把待删列表展开成 `DELETE` 真正要绑的值 ——
/// **空值一律丢弃，非空值同时保留「原值」与「trim 值」两形**（保序、按字面去重）。
///
/// 判据本体仍只有 `normalize_actors` 那一枚：本函数把单个元素喂给它——返回空 ⇒ 该元素是空值
/// （`""`/纯空白）⇒ 丢弃；返回 `[t]` ⇒ `t` 就是 trim 形。**不在这里抄第二份 trim/is_empty**
/// （§2.11 尾注「不要再抄第二份」）。
///
/// 为什么必须两形、只取一头各有一种假成功（1.8.36 之前八栈正好分成这两派，没有一处两全）：
/// · 只取 **trim 形**（本栈与 php/csharp/rust 的旧形状）⇒ 门面按语义 6 交出的历史脏行原值
///   `" 9101 "` 被削成 `9101`，真库 NO PAD 排序规则下那一行删不掉而门面报成功——被摘的人待办还在；
/// · 只取 **原值形**（go/node/python/java 的旧形状）⇒ 绕过门面直连仓储的调用方传 `" 8601 "` 时
///   删不掉写侧归一后落库的规范行（issues/142 §9.2 那一路）；且空值照喂 `DELETE`，
///   把历史 `actor_id=''` 脏行批量误删（那是替脏数据做掉唯一痕迹）。
///
/// 并集同时满足两侧。按 §2.11 归一口径 `" 9101 "` 与 `9101` 本就是**同一个人**，两行都删才是
/// "摘掉这个人"的正确结果，不构成误删。去重按**字面**做，不按"trim 后相同"折叠原值形：
/// `" 9101 "` 与 `"  9101  "` 是两种不同的原值形，都要保留（库里可能正是其中任一种脏法）。
///
/// 反向哨兵同 `normalize_actors`：`"0"` 是合法 id 必须留下，且 `"0"` 与 `"00"` 是两个人。
/// 返回空数组 ⇒ 调用方**一条 DELETE 都不发**（早退，不得退化成"清空该任务全部参与者"）。
pub fn actor_delete_forms(raw : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for actor_id in raw {
    match normalize_actors([actor_id]) {
      [t] => {
        if !out.contains(actor_id) {
          out.push(actor_id) // 原值形：保住未 trim 的历史脏行
        }
        if !out.contains(t) {
          out.push(t) // trim 形：保住写侧归一后的规范行
        }
      }
      _ => () // 空值（""/纯空白）⇒ 丢弃，不喂 DELETE
    }
  }
  out
}
///|
/// 单个归属值归一（§2.11 表里 `transfer` 的 fromActor/toActor 是「单值档」）：判据**复用**
/// `normalize_actors`，不另写第二枚 trim/is_empty。空串与纯空白 ⇒ `None`，调用方按本仓既有的
/// 「缺参数」错误信封报错（§2.11 要求③：不新造错误码与文案）。
pub fn normalize_actor(raw : String) -> String? {
  match normalize_actors([raw]) {
    [v] => Some(v)
    _ => None
  }
}

///|
///|
/// 逗号串 → 参与者序（issues/142 B 批）：切元素在本函数完成，判据仍交回 `normalize_actors`
/// 那一枚单点 —— 本栈"逗号串形态"的三条腿（引擎 assignee/assignmentHandler 解析、门面出口侧
/// 候选人名册、nextNodeOperator 消费腿）由此共用同一把尺子，不再各写一份 trim/is_empty。
/// 数字/布尔等非字符串元素不在这一档（那是 Json 形态的事，走 `@engine.parse_actors` 的形状适配）。
pub fn normalize_comma_actors(s : String) -> Array[String] {
  let out : Array[String] = []
  for part in s.split(",") {
    out.push(part.to_owned())
  }
  normalize_actors(out)
}

/// issues/141 G10 时这枚判据的旧名（当时只挂抄送一支）：§2.11 把它逐字搬到任务侧后升格为
/// `normalize_actors`，本名**保留为转发** —— 已发布 mooncakes 模块（mldong/jeeflow-core，0.1.x 线）
/// 的公开成员，既有调用方与既有测试不破；判据**不在这里复制**。
pub fn normalize_cc_actors(raw : Array[String]) -> Array[String] {
  normalize_actors(raw)
}


// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。
pub extend ProcessDesign with Eq::{equal, not_equal}
pub extend ProcessDesignHis with Eq::{equal, not_equal}
pub extend ProcessSurrogate with Eq::{equal, not_equal}
pub extend CcInstance with Eq::{equal, not_equal}
pub extend TaskActor with Eq::{equal, not_equal}
pub extend QueryFilter with Eq::{equal, not_equal}
pub extend TaskRow with Eq::{equal, not_equal}
pub extend InstanceRow with Eq::{equal, not_equal}
pub extend DefineRow with Eq::{equal, not_equal}
pub extend UserInfo with Eq::{equal, not_equal}
