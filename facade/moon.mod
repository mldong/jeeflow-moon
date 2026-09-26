name = "mldong/jeeflow-facade"
version = "0.1.13"
license = "Apache-2.0"
preferred_target = "wasm"
readme = "README.md"
repository = "https://github.com/mldong/jeeflow-moon"
description = "jeeflow unified facade: flow(action, args) 46 actions + contract outlet layer"
import {
  "mldong/jeeflow-core@0.1.13",
  "mldong/jeeflow-persist@0.1.13",
  // 仅 async test 运行期需要（core 已依赖同版本，非新增外部依赖面）
  "moonbitlang/async@0.20.3",
}
