name = "mldong/jeeflow-demo"
version = "0.1.12"
license = "Apache-2.0"
preferred_target = "wasm"
readme = "README.md"
repository = "https://github.com/mldong/jeeflow-moon"
description = "jeeflow lightweight HTTP demo (:8092, run_forever, not published)"
import {
  "mldong/jeeflow-facade@0.1.7",
  "mldong/jeeflow-repository-mysql@0.1.7",
  "mldong/jeeflow-core@0.1.7",
  "moonbitlang/async@0.20.3",
  // cmd/t1_mysql 直连真机 MySQL 做断言读回（本模块不发布，不影响发布拓扑与依赖面）
  "moonbitstack/moondb@0.1.8",
}
