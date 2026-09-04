// 状态/类型枚举（spec/03 + spec/07）—— 移植自 rust model.rs L13-L162
// 口径（C4/C5）：入口容错数字/字符串，出口一律数字 code

///|
pub(all) enum DefineState {
  Disable
  Enable
} derive(Eq, Show)

///|
pub fn DefineState::code(self : DefineState) -> Int {
  match self {
    Disable => 0
    Enable => 1
  }
}

///|
pub fn DefineState::from_code(code : Int) -> DefineState {
  if code == 0 {
    Disable
  } else {
    Enable
  }
}

///|
pub(all) enum InstanceState {
  Doing
  Finished
  Withdraw
  Interrupt
  Reject
  Pending
  Abandon
} derive(Eq, Show)

///|
pub fn InstanceState::code(self : InstanceState) -> Int {
  match self {
    Doing => 10
    Finished => 20
    Withdraw => 30
    Interrupt => 40
    Reject => 45
    Pending => 50
    Abandon => 99
  }
}

///|
pub fn InstanceState::from_code(code : Int) -> InstanceState? {
  match code {
    10 => Some(Doing)
    20 => Some(Finished)
    30 => Some(Withdraw)
    40 => Some(Interrupt)
    45 => Some(Reject)
    50 => Some(Pending)
    99 => Some(Abandon)
    _ => None
  }
}

///|
pub(all) enum TaskState {
  Doing
  Finished
  Withdraw
  Interrupt
  Pending
  Abandon
} derive(Eq, Show)

///|
pub fn TaskState::code(self : TaskState) -> Int {
  match self {
    Doing => 10
    Finished => 20
    Withdraw => 30
    Interrupt => 40
    Pending => 50
    Abandon => 99
  }
}

///|
pub fn TaskState::from_code(code : Int) -> TaskState? {
  match code {
    10 => Some(Doing)
    20 => Some(Finished)
    30 => Some(Withdraw)
    40 => Some(Interrupt)
    50 => Some(Pending)
    99 => Some(Abandon)
    _ => None
  }
}

///|
pub(all) enum TaskType {
  Major
  Assistant
  Record
} derive(Eq, Show)

///|
pub fn TaskType::code(self : TaskType) -> Int {
  match self {
    Major => 0
    Assistant => 1
    Record => 2
  }
}

///|
pub fn TaskType::from_code(code : Int) -> TaskType {
  match code {
    1 => Assistant
    2 => Record
    _ => Major
  }
}

///|
pub(all) enum PerformType {
  Normal
  Countersign
} derive(Eq, Show)

///|
pub fn PerformType::code(self : PerformType) -> Int {
  match self {
    Normal => 0
    Countersign => 1
  }
}

///|
pub fn PerformType::from_code(code : Int) -> PerformType {
  if code == 1 {
    Countersign
  } else {
    Normal
  }
}

///|
pub(all) enum CountersignType {
  Parallel
  Sequential
} derive(Eq, Show)

///|
pub fn CountersignType::from_str_name(s : String) -> CountersignType {
  let upper = s.to_upper()
  if upper == "SEQUENTIAL" || upper == "SERIAL" {
    Sequential
  } else {
    Parallel
  }
}

///|
pub(all) enum SubmitType {
  Apply
  Agree
  Reject
  Rollback
  Jump
  ReApply
  RollbackToOperator
  CountersignDisagree
} derive(Eq, Show)

///|
pub fn SubmitType::code(self : SubmitType) -> Int64 {
  match self {
    Apply => 0L
    Agree => 1L
    Reject => 2L
    Rollback => 3L
    Jump => 4L
    ReApply => 5L
    RollbackToOperator => 6L
    CountersignDisagree => 20L
  }
}

///|
pub fn SubmitType::from_code(code : Int64) -> SubmitType? {
  match code {
    0L => Some(Apply)
    1L => Some(Agree)
    2L => Some(Reject)
    3L => Some(Rollback)
    4L => Some(Jump)
    5L => Some(ReApply)
    6L => Some(RollbackToOperator)
    20L => Some(CountersignDisagree)
    _ => None
  }
}

///|
/// m_ 三段式过滤操作符（spec/06 §2.2）
pub(all) enum FilterOp {
  Eq
  Ne
  Like
  Gt
  Lt
  Ge
  Le
  In
  Nin
  Bt
} derive(Eq, Show)

///|
pub fn FilterOp::from_str(s : String) -> FilterOp? {
  match s.to_upper() {
    "EQ" => Some(Eq)
    "NE" => Some(Ne)
    "LIKE" => Some(Like)
    "LLIKE" => Some(Like)
    "RLIKE" => Some(Like)
    "GT" => Some(Gt)
    "LT" => Some(Lt)
    "GE" => Some(Ge)
    "LE" => Some(Le)
    "IN" => Some(In)
    "NIN" => Some(Nin)
    "BT" => Some(Bt)
    _ => None
  }
}
