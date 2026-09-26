// 本仓自有文件（不是上游拷贝）：vendored 的 conn.mbt/driver.mbt 保持逐字节原样，
// 显式 extend 声明只能落在同包，故另立此文件。见 MAINTAINING D-M6-1 的 vendored 纪律。


// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。
pub extend MysqlDriver with @moondb.Driver::{begin, close, commit, execute, ping, query, query_stream, rollback}
