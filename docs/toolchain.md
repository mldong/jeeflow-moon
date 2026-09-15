# 工具链（机器无关口径）

> 本仓一切构建/测试/运行的工具链口径：安装、调用、构建目标。
>
> **`MOON_HOME` 是机器相关路径，由读者自己的安装位置决定**——文档一律用占位符 `<MOON_HOME>`，
> 不写任何具体机器的路径。常见取值：
> - Windows：PowerShell 官方安装默认 `C:\Program Files\MoonBit`（或安装时自定义的 `$env:MOON_HOME`）；Git Bash 下用 POSIX 盘符写法（`/c/Program\ Files/MoonBit`）
> - Linux / macOS：`curl | bash` 官方安装默认 `~/.moon`

## 安装（latest-only，不钉版本）

> 2026-09-09 owner 定调（见 [PUBLISH.md](./PUBLISH.md) 与 `.github/workflows/publish.yml`）：
> 服务端对显式版本路径一律 403，**钉版本不可行**；`EXPECTED_MOON_VERSION` 版本守卫已移除，
> 安装一律装 latest，**不校验编译器版本**——最新编译器若把既有代码判错，
> 本地升级同款编译器复现、按错误信息修/适配后 re-run 即可（见 CHANGELOG 0.1.5）。

| 平台 | 安装命令 |
|------|----------|
| Windows（PowerShell） | `irm https://cli.moonbitlang.com/install/powershell.ps1 \| iex` |
| Linux / macOS | `curl -fsSL https://cli.moonbitlang.com/install/unix.sh \| bash` |

- 装完先跑一次 `moon update` 刷新 registry 索引——工具链内置索引可能陈旧，
  不认识 async / moon-mysql 等依赖（0.1.20260827 实测），缺 `moon update` 时 `moon install` 会失败（D-M5-4）。
- ⚠️ **Windows 专属坑**：从 32 位父进程链（某些终端启动器）跑安装脚本会误报
  `Install Failed: MoonBit for Windows is currently only available for x86 64-bit...`——
  原因是继承的 `$env:PROCESSOR_ARCHITECTURE` 为 `x86`（系统实际是 `PROCESSOR_ARCHITEW6432=AMD64`）。
  先覆盖 `$env:PROCESSOR_ARCHITECTURE='AMD64'` 再执行安装命令即可。
- 版本自查：`moon version` / `moonc -v`（`moonc` 无 `--version`）。

## 调用

```bash
# Git Bash（MSYS2）：Windows 路径必须用 POSIX 盘符写法（/c/…），/c: 或 C:/ 解析不到
export MOON_HOME=<your-moon-home>
export PATH=$MOON_HOME/bin:$PATH
moon version
```

```powershell
# Windows PowerShell
$env:PATH = "$env:MOON_HOME\bin;" + $env:PATH   # MOON_HOME 指向你的安装目录
moon version
```

```bash
# Linux / macOS（官方脚本默认装到 ~/.moon）
export PATH="$HOME/.moon/bin:$PATH"
```

> **红线（R8 原意）：不修改工具链安装目录下的任何文件。**工具链是外部依赖，
> 构建/目标类问题一律在代码侧解决（见下方「构建目标纪律」的结构性限制说明）。

## 构建目标纪律（红线 R8）

| 场景 | target | 位置 |
|---|---|---|
| 日常开发/单测（全模块含 async） | `--target wasm` | 本机 |
| 纯计算包快速单测 | native 可直跑 | 本机（不 import async 的包） |
| MySQL 冒烟（T1） | `--target wasm` | 本机 → 开发服务器 192.168.1.160:3306（vendored 解锁，见 decisions-log D-M0-2） |
| 验收正式口径 / demo 生产态 | native | CI（GitHub runner）/ 开发服务器（debian:bookworm + build-essential 独立容器，O4） |

> ⚠️ Windows 上 **native + async 结构性不可编译**（moonbitlang/async 运行时 C 源硬编码
> MSVC-only，`thread_pool.c:23 #error`），Windows 本机一律 wasm；不得为绕过而改工具链 C 源。

## 依赖版本（registry 包，非工具链）

registry 依赖在 `moon.mod` import 块钉精确版本（无 lockfile，R8.4）：
`Lfan-ke/moondb@0.1.7`、`Lfan-ke/moon-mysql@0.3.1`、`moonbitlang/async@0.20.3`。
这与「工具链 latest-only」是两回事——**依赖包钉版本、编译器不钉**。

## 语法口径备忘（moonc 0.10.x 实测，M1 起照此写）

- trait 方法显式 `Self` 第一参：`async fn find_by_id(Self, Int) -> T raise JeeflowError`（对齐 moondb Driver）
- 错误类型用 `raise`，不用旧 `!E` 后缀；错误枚举 `pub suberror`（外部构造 `pub(all) struct/enum`）
- 泛型：struct 裸参数 `Ctx[R, E]`，约束写在方法级 `pub fn[R : ProcessRepository] ...`（moondb `Pool[D : Driver]` 同款）
- 方法调用宏已去 `!`：`assert_eq(a, b)`、`panic(msg)`（`f!(...)` deprecated）
- 字符串插值 `"\{expr}"`；闭包调用加括号 `(f)(x)`
- async test：黑盒 `_test.mbt` + 包 moon.pkg `import { "moonbitlang/async", } for "test"` 即可（白盒 `_wbtest.mbt` 不解锁 async test，须运行时 import——见 decisions-log D-M0-1）
- `moon.mod`/`moon.pkg` 为 TOML 风格；workspace 互依赖版本化全名 `"mldong/jeeflow-core@0.1.0"`
- `moon info` 生成 `.mbti`；包级可 `supported_targets`（moon-mysql client 即用此钉 native，本仓 vendored 解锁）
