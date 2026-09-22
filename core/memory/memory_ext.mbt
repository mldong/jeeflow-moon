// 扩展仓储（design/his/surrogate）—— 移植自 rust memory.rs ProcessExtRepository 段

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn find_design_by_id(self, design_id) {
  match self.designs.get(design_id) {
    Some(d) => Some(d.clone())
    None => None
  }
}

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn save_design(self, design) {
  if design.id == 0L {
    design.id = self.next_id()
  }
  self.designs[design.id] = design.clone()
}

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn update_design(self, design) {
  self.designs[design.id] = design.clone()
}

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn remove_design(self, design_id) {
  self.designs.remove(design_id)
}

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn page_designs(self, query) {
  let rows : Array[@model.ProcessDesign] = []
  for did in sorted_ids(self.designs) {
    rows.push(self.designs[did].clone())
  }
  let total = rows.length().to_int64()
  @model.PageResult::new(query.page_num(), query.page_size(), total, page_slice(rows, query.page_num(), query.page_size()))
}

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn save_design_his(self, his) {
  if his.id == 0L {
    his.id = self.next_id()
  }
  self.design_his.push(his.clone())
}

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn list_design_his(self, design_id) {
  // 最新在前（index 0）——对齐 Java JDBC 顺序 / design detail jsonObject
  let list : Array[@model.ProcessDesignHis] = []
  for h in self.design_his {
    if h.process_design_id == design_id {
      list.push(h.clone())
    }
  }
  let list = list.rev()
  list
}

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn find_surrogate_by_id(self, surrogate_id) {
  match self.surrogates.get(surrogate_id) {
    Some(s) => Some(s.clone())
    None => None
  }
}

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn save_surrogate(self, surrogate) {
  if surrogate.id == 0L {
    surrogate.id = self.next_id()
  }
  self.surrogates[surrogate.id] = surrogate.clone()
}

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn update_surrogate(self, surrogate) {
  self.surrogates[surrogate.id] = surrogate.clone()
}

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn remove_surrogate(self, surrogate_id) {
  self.surrogates.remove(surrogate_id)
}

///|
pub impl @spi.ProcessExtRepository for MemoryRepository with fn page_surrogates(self, query) {
  let rows : Array[@model.ProcessSurrogate] = []
  for sid in sorted_ids(self.surrogates) {
    rows.push(self.surrogates[sid].clone())
  }
  let total = rows.length().to_int64()
  @model.PageResult::new(query.page_num(), query.page_size(), total, page_slice(rows, query.page_num(), query.page_size()))
}

///|
/// 生效委托查询（issues/116 批次 D / spec 06 §4.5 条款 5 四判据 + 条款 6 双仓同答案）。
/// 与 SQL 仓 `repository-mysql/repo/repository_ext.mbt` 的 get_surrogate 逐条同构：
/// ① 空 processName 全流程兜底：先按当前流程名精确查，未命中再查 process_name 为 NULL/''；
/// ② 时间窗 start_time <= now <= end_time，任一侧 NULL/空 = 该侧不限；
/// ③ 自委托过滤 surrogate <> operator；
/// ④ enabled **只认整数 1**（0/脏值/NULL 一律不生效）。
///
/// ⚠️ **条款 1.4 的取数顺序（issues/123）：各作用域先按 id 取「最新一条」，再交
/// `@model.ProcessSurrogate::is_effective` 裁决这一条**；精确作用域那条判否后**仍要看**
/// 全流程作用域的最新一条。反过来写（先按 ②③④ 过滤、剩下的才取最新）等价于
/// "上一条窗内委托把用户后续改停用/改到未来/改自委托永久盖掉"——那正是 13 栈
/// `L2-17`/`L2-18` 恒并入的根因。两种写法只在"旧记录有效 + 新记录无效"这一形状上分叉，
/// 而它恰是用户真实操作序列 ⇒ `core/engine/surrogate_test.mbt` 的 4 格负向用例钉的就是它。
pub impl @spi.ProcessExtRepository for MemoryRepository with fn get_surrogate(self, operator, process_name, time) {
  let exact = self.newest_surrogate(operator, process_name, false)
  if @model.surrogate_scope_hit(exact, operator, time) {
    exact
  } else {
    // 判据①：精确作用域没有 / 有但判否，都仍要看全流程作用域自己那条最新的
    let global = self.newest_surrogate(operator, process_name, true)
    if @model.surrogate_scope_hit(global, operator, time) { global } else { None }
  }
}

///|
/// 取该授权人在指定流程作用域内 **id 最大（最新）的一条**；scope_global=true ⇒ 全流程作用域
/// （process_name 为空）。**不带任何生效判据过滤**——四判据由调用方交 `is_effective` 裁决
/// （对齐 SQL 侧 `ORDER BY id DESC LIMIT 1` 不带 WHERE 判据）。
fn MemoryRepository::newest_surrogate(
  self : MemoryRepository,
  operator : String,
  process_name : String,
  scope_global : Bool
) -> @model.ProcessSurrogate? {
  let mut best : @model.ProcessSurrogate? = None
  for _, sg in self.surrogates {
    if sg.operator != operator {
      continue
    }
    let in_scope = if scope_global {
      sg.process_name.is_empty()
    } else {
      !process_name.is_empty() && sg.process_name == process_name
    }
    if !in_scope {
      continue
    }
    match best {
      Some(b) => {
        if sg.id > b.id {
          best = Some(sg.clone())
        }
      }
      None => best = Some(sg.clone())
    }
  }
  best
}
