# 工具链（钉死版本，R7/R8）

> 本仓一切构建/测试/运行的工具链口径。**绝不修改 `G:\dev-tools\moon` 下任何文件**（红线 R8）。

## 钉死版本（2026-09-05 实测，与方案 §0.1 一致）

| 组件 | 版本 | 位置 |
|---|---|---|
| moon | 0.1.20260827 (d0aaa07 2026-08-27) | `G:\dev-tools\moon\bin\moon.exe` |
| moonc | v0.10.11+6ff76a5f9 (2026-08-28) | `G:\dev-tools\moon\bin\moonc.exe`（`moonc -v` 查版本，无 `--version`） |
| moonrun | 随 MOON_HOME 预编译 | wasm 目标运行器（`moon run --target wasm`） |
| registry 依赖 | `Lfan-ke/moondb@0.1.7`、`Lfan-ke/moon-mysql@0.3.1`、`moonbitlang/async@0.20.3` | import 块钉精确版本（无 lockfile，R8.4） |

## 调用（Git Bash，必须 `/g/` 盘符写法）

```bash
export MOON_HOME=/g/dev-tools/moon PATH=/g/dev-tools/moon/bin:$PATH
moon version          # moon 0.1.20260827
moonc -v              # v0.10.11+6ff76a5f9
```

PowerShell 跑 `G:\dev-tools\moon-env.ps1`。

## 构建目标纪律（方案 §2.4，红线 R8）

| 场景 | target | 位置 |
|---|---|---|
| 日常开发/单测（全模块含 async） | `--target wasm` | 本机 |
| 纯计算包快速单测 | native 可直跑 | 本机（不 import async 的包） |
| MySQL 冒烟（T1） | `--target wasm` | 本机 → 160:3306（vendored 解锁，见 decisions-log D-M0-2） |
| 验收正式口径 / demo 生产态 | native | 160（debian:bookworm + build-essential 独立容器，O4） |

> ⚠️ 本机 **native + async 结构性不可编译**（moonbitlang/async 运行时 C 源硬编码 MSVC-only，
> `thread_pool.c:23 #error`），本机一律 wasm；不得为绕过改工具链 C 源。

## 语法口径备忘（moonc 0.10.11 实测，M1 起照此写）

- trait 方法显式 `Self` 第一参：`async fn find_by_id(Self, Int) -> T raise JeeflowError`（对齐 moondb Driver）
- 错误类型用 `raise`，不用旧 `!E` 后缀；错误枚举 `pub suberror`（外部构造 `pub(all) struct/enum`）
- 泛型：struct 裸参数 `Ctx[R, E]`，约束写在方法级 `pub fn[R : ProcessRepository] ...`（moondb `Pool[D : Driver]` 同款）
- 方法调用宏已去 `!`：`assert_eq(a, b)`、`panic(msg)`（`f!(...)` deprecated）
- 字符串插值 `"\{expr}"`；闭包调用加括号 `(f)(x)`
- async test：黑盒 `_test.mbt` + 包 moon.pkg `import { "moonbitlang/async", } for "test"` 即可（白盒 `_wbtest.mbt` 不解锁 async test，须运行时 import——见 decisions-log D-M0-1）
- `moon.mod`/`moon.pkg` 为 TOML 风格；workspace 互依赖版本化全名 `"mldong/jeeflow-core@0.1.0"`
- `moon info` 生成 `.mbti`；包级可 `supported_targets`（moon-mysql client 即用此钉 native，本仓 vendored 解锁）
