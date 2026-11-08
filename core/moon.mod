name = "mldong/jeeflow-core"
version = "0.1.61"
// 效应/约束注解在本引擎里是承重的：async 不带 raise 会宽化成 Error（调用侧要求 JeeflowError 会失配），
// 泛型约束服务于 impl 形状而不是可有可无的重复。0.10.19 新引入的三类"未用"提示会把它们误报成冗余，
// 故在本模块关闭这三类（result_error_return 只影响显式 Result 的 API，attempt 处另有就地抑制）。
warnings = "-unused_async-unused_error_type-unused_trait_bound-result_error_return"
license = "Apache-2.0"
preferred_target = "wasm"
readme = "README.md"
repository = "https://github.com/mldong/jeeflow-moon"
description = "jeeflow workflow engine core (MoonBit port, zero registry deps)"

import {
  "moonbitlang/async@0.22.7",
}
