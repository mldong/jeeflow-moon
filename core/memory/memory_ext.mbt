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
pub impl @spi.ProcessExtRepository for MemoryRepository with fn get_surrogate(self, operator, process_name, _time) {
  let mut found : @model.ProcessSurrogate? = None
  for _, sg in self.surrogates {
    if sg.operator == operator && sg.process_name == process_name && sg.enabled == 1 {
      found = Some(sg.clone())
    }
  }
  found
}
