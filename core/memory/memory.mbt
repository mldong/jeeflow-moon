// jeeflow-core/memory —— M1 移植自 rust memory.rs（695 行）
// MemoryRepository[R 等价物]：方法签名 async 内部零 await（单线程无锁，方案 §2.3 配套语义）
// T0 口径仓储；行为测试与 MySQL 双跑防分叉（§4.3）
