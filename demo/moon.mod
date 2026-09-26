name = "mldong/jeeflow-demo"
version = "0.1.13"
license = "Apache-2.0"
preferred_target = "wasm"
readme = "README.md"
repository = "https://github.com/mldong/jeeflow-moon"
description = "jeeflow lightweight HTTP demo (:8092, run_forever, not published)"
import {
  "mldong/jeeflow-facade@0.1.13",
  "mldong/jeeflow-repository-mysql@0.1.13",
  "mldong/jeeflow-core@0.1.13",
  "moonbitlang/async@0.22.4",
  // cmd/t1_mysql 直连真机 MySQL 做断言读回（本模块不发布，不影响发布拓扑与依赖面）
  "moonbitstack/moondb@0.2.0",
}
