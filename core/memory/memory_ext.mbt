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
///    （两侧写入前都归一成 yyyy-MM-dd HH:mm:ss，见 facade 的 parse_surrogate_time，
///     故**文本序即时间序**，可直接串比）
/// ③ 自委托过滤 surrogate <> operator；
/// ④ enabled **只认整数 1**（0/脏值/NULL 一律不生效）。
/// 多条同时命中取 **id 最大**（对齐 SQL 侧 ORDER BY id DESC LIMIT 1）。
/// 原实现三处缺口：忽略 `_time`（无窗口条件）、无空 processName 兜底、无自委托过滤，
/// 且"取遍历到的首条"= Map 插入序=最早一条 —— 与 SQL 仓对同一份数据给出相反结论，
/// 正是 issues/116 §5 点名的同栈双仓分叉。
pub impl @spi.ProcessExtRepository for MemoryRepository with fn get_surrogate(self, operator, process_name, time) {
  // 判据 ①：精确名 → 空名兜底，两轮共用同一套窗口/自委托/enabled 谓词
  let exact = self.pick_surrogate(operator, time, fn(sg) {
    !process_name.is_empty() && sg.process_name == process_name
  })
  match exact {
    Some(_) => exact
    None => self.pick_surrogate(operator, time, fn(sg) { sg.process_name.is_empty() })
  }
}

///|
/// 按四判据筛，返回 id 最大的一条（无命中 None）。name_match 只判"这一轮用哪种流程名口径"。
fn MemoryRepository::pick_surrogate(
  self : MemoryRepository,
  operator : String,
  time : String,
  name_match : (@model.ProcessSurrogate) -> Bool
) -> @model.ProcessSurrogate? {
  let mut best : @model.ProcessSurrogate? = None
  let mut best_id = 0L
  for _, sg in self.surrogates {
    if sg.operator != operator || sg.surrogate == operator {
      continue
    }
    if sg.enabled != 1 {
      continue
    }
    if !surrogate_window_hit(sg.start_time, sg.end_time, time) {
      continue
    }
    if !name_match(sg) {
      continue
    }
    if sg.id > best_id {
      best = Some(sg.clone())
      best_id = sg.id
    }
  }
  best
}

///|
/// 时间窗判定（判据②）：NULL/空 = 该侧不限；否则按归一后的 'yyyy-MM-dd HH:mm:ss' 串比。
fn surrogate_window_hit(start_time : String?, end_time : String?, time : String) -> Bool {
  let now = time.trim(chars=" \t\r\n").to_string()
  match start_time {
    Some(s) => {
      let v = s.trim(chars=" \t\r\n").to_string()
      if !v.is_empty() && !now.is_empty() && v.compare(now) > 0 {
        return false
      }
    }
    None => ()
  }
  match end_time {
    Some(s) => {
      let v = s.trim(chars=" \t\r\n").to_string()
      if !v.is_empty() && !now.is_empty() && v.compare(now) < 0 {
        return false
      }
    }
    None => ()
  }
  true
}
