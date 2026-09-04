// ID 生成器 —— 移植自 rust id_gen.rs
// AtomicIdGenerator：单线程计数器（事件循环无抢占无锁，方案 §3.4.2）
// DefaultIdGenerator：雪花兼容（EPOCH=1288834974657，对齐 MyBatis-Plus IdWorker/联邦同 ID 空间）

///|
const EPOCH : Int64 = 1288834974657L

///|
const WORKER_ID_BITS : Int = 10

///|
const SEQUENCE_BITS : Int = 12

///|
const MAX_SEQUENCE : Int64 = 4095L // (1<<12)-1

///|
const TIMESTAMP_SHIFT : Int = WORKER_ID_BITS + SEQUENCE_BITS // 22

///|
const WORKER_ID_SHIFT : Int = SEQUENCE_BITS // 12

///|
pub(all) struct DefaultIdGenerator {
  worker_id : Int64
  // 单线程无锁（方案 §3.4.2）；时钟走 core/model epoch_millis
  mut last_timestamp : Int64
  mut sequence : Int64
}

///|
pub fn DefaultIdGenerator::new(worker_id : Int64) -> DefaultIdGenerator {
  { worker_id, last_timestamp: -1L, sequence: 0L }
}

///|
pub fn DefaultIdGenerator::next_id(self : DefaultIdGenerator) -> Int64 {
  let mut timestamp = @model.epoch_millis()
  if timestamp < self.last_timestamp {
    // 时钟回拨：前进一毫秒（demo/测试场景可接受；rust 为自旋等待）
    timestamp = self.last_timestamp + 1L
  }
  if timestamp == self.last_timestamp {
    self.sequence = (self.sequence + 1L) & MAX_SEQUENCE
    if self.sequence == 0L {
      timestamp = timestamp + 1L
    }
  } else {
    self.sequence = 0L
  }
  self.last_timestamp = timestamp
  ((timestamp - EPOCH) << TIMESTAMP_SHIFT) | (self.worker_id << WORKER_ID_SHIFT) | self.sequence
}

///|
/// 测试/确定性场景用计数器
pub(all) struct AtomicIdGenerator {
  mut counter : Int64
}

///|
pub fn AtomicIdGenerator::new(start : Int64) -> AtomicIdGenerator {
  { counter: start }
}

///|
pub fn AtomicIdGenerator::next_id(self : AtomicIdGenerator) -> Int64 {
  let v = self.counter
  self.counter = v + 1L
  v
}
