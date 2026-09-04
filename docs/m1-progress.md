# M1–M4 移植进度（会话续接锚点）

> 用途：长会话上下文丢失后按此接续。每完成一小步就更新本文件。

## 状态总览

- [x] M0（commit 774e5fa）：骨架/manifest/spike×4/flows/schema/decisions-log
- [x] M1 core 全模块 + memory + 合规场景 + submitType 矩阵（T0 wasm 101/101 全绿，负向变异×2 红→还原）
- [ ] M2 repository-mysql + T1（wasm→160 + 160 native 双跑）
- [ ] M3 persist + facade 45 action + 出口层
- [ ] M4 demo :8092 全契约 + jeeflow-ui /moon-api
- [ ] M5 发版就绪材料（版本钉死/consistency/VERSIONS 草稿/脚本增补/docs 5 篇）——**不执行 publish/tag/push**

## M1 移植映射（rust → moon）

| Rust 文件 | MoonBit 包 | 状态 |
|---|---|---|
| error.rs(110) | core/error | 完成 |
| json.rs(632) | core/json（薄壳 builtin Json + FlowData） | 完成 |
| model.rs(1076) | core/model（Int64 id；clock 全局注入口） | 完成 |
| id_gen.rs(138) | core/id_gen | 完成 |
| spi.rs(222)+context.rs(151) | core/spi（替换 spike 文件） | 待 |
| parser.rs(558) | 完成 |core/parser | 待 |
| handler.rs(174) | 完成 |core/handler | 待 |
| event.rs(112) | 完成 |core/event | 待 |
| metadata.rs(319) | 完成 |core/metadata | 待 |
| interceptor.rs(312) | 完成 |core/interceptor | 待 |
| memory.rs(695) | 完成 |core/memory | 待 |
| engine.rs(2041, 含 22 场景 tests) | core/engine + core/engine/*_test.mbt | 完成（101 用例） |

## 已验证 MoonBit 事实（勿再试错）

- async test：黑盒 `_test.mbt` + 包 moon.pkg `import {"moonbitlang/async"} for "test"`；白盒不解锁
- trait 方法显式 `Self`；错误 `raise`（不用 `!E`）；错误类型 `pub suberror`
- struct：裸类型参数 + 方法级约束；外部可构造 `pub(all)`；`pub`=只读
- `assert_eq(a,b)` 无叹号；字符串插值 `"\{}"`；闭包调用 `(f)(x)`
- ids 必须 Int64（wasm Int=32 位，雪花越界）
- moon.mod/moon.pkg = TOML 风格；workspace 互依版本化全名
- builtin `Json` 枚举（Null/True/False/Number(Double,repr~)/String/Array/Object(Map)）+ @json.parse/stringify + as_* 访问器

## 时钟口径（D-M0-3）

core/model 全局可注时钟：`current_time_str()` 默认 @env.now() 包装（待实测单位），测试注入固定钟。
id_gen DefaultIdGenerator 同口径。

## 160 凭据

JEFFLOW_DB_HOST=192.168.1.3306?不对——HOST=192.168.1.160 PORT=3306 USER=root PWD 见 jeeflow-hub/AGENTS.md §3（不入本仓）。
