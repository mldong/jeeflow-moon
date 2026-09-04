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
  alias : String // "t" 主表 / "pd" 流程定义 等
  op : FilterOp
  column : String // snake_case 列名
  value : String
} derive(Eq)

///|
pub fn QueryFilter::alias(self : QueryFilter) -> String {
  self.alias
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
  alias : String,
  op : FilterOp,
  column : String,
  value : String
) -> QueryFilter {
  { alias, op, column, value }
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
    conditions: Map::new(),
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
