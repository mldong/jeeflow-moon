name = "mldong/jeeflow-repository-mysql"
version = "0.1.31"
license = "Apache-2.0"
preferred_target = "wasm"
readme = "README.md"
repository = "https://github.com/mldong/jeeflow-moon"
description = "jeeflow MySQL repository (moondb Driver trait + moonmysql async conn)"
import {
  "mldong/jeeflow-core@0.1.31",
  // issues/149：persist 的真库写侧（MysqlTableWriter implements DynamicTableWriter）
  "mldong/jeeflow-persist@0.1.31",
  "moonbitstack/moondb@0.2.0",
  "moonbitstack/moonmysql@0.7.3",
  "moonbitlang/async@0.22.4",
}
