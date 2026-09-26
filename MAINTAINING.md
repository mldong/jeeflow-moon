# jeeflow-moon 维护手册（MAINTAINING）

> **本仓 `docs/` 只放用户文档**（对齐 jeeflow-java 基准：SDK 用户只看用户向内容，
> `docs/` 会同步到 jeeflow-doc 公开文档站）。维护者向内容——工具链口径、测试分级、
> 发版通道、设计决策、契约对照——收在本文件（仓根，**不进 `docs/`、不上文档站**）。
> 用户向版本历史见 [docs/CHANGELOG.md](./docs/CHANGELOG.md)。

## 1. 工具链口径（机器无关）

> **`MOON_HOME` 是机器相关路径，由读者自己的安装位置决定**——本文件一律用占位符 `<MOON_HOME>`，
> 不写任何具体机器的路径。
>
> 工具链**安装**说明（Windows/Lunix 命令、32 位父进程坑、`moon update`）在用户文档
> [docs/getting-started.md](./docs/getting-started.md) 的「工具链（首次必装）」一节，
> 异地新会话按 getting-started 即可装出可用工具链；本节只留维护者口径（调用/构建目标/语法）。

### 调用

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

### 构建目标纪律（红线 R8）

| 场景 | target | 位置 |
|---|---|---|
| 日常开发/单测（全模块含 async） | `--target wasm` | 本机 |
| 纯计算包快速单测 | native 可直跑 | 本机（不 import async 的包） |
| MySQL 冒烟（T1） | `--target wasm` | 本机 → 开发服务器 `<DB_HOST>`:3306（vendored 解锁，见 §4 D-M0-2） |
| 验收正式口径 / demo 生产态 | native | CI（GitHub runner）/ 开发服务器（debian:bookworm + build-essential 独立容器，O4） |

> ⚠️ Windows 上 **native + async 结构性不可编译**（moonbitlang/async 运行时 C 源硬编码
> MSVC-only，`thread_pool.c:23 #error`），Windows 本机一律 wasm；不得为绕过而改工具链 C 源。

### 依赖版本（registry 包，非工具链）

registry 依赖在 `moon.mod` import 块钉精确版本（无 lockfile，R8.4）：
`moonbitstack/moondb@0.1.8`、`moonbitstack/moonmysql@0.4.0`、`moonbitlang/async@0.20.3`。
这与「工具链 latest-only」是两回事——**依赖包钉版本、编译器不钉**。

> 2026-09-19 坐标迁移：moondb/moonmysql 在 mooncakes 从 `Lfan-ke/` 迁到 `moonbitstack/`
> （包名同时去连字符：`moon-mysql` → `moonmysql`），旧 `Lfan-ke/*` 停在 0.1.7 / 0.3.1 不再更新。
> **两者必须成对迁移**——moonmysql 0.4.0 依赖 `moonbitstack/moondb@0.1.8`，若本仓仍钉
> `Lfan-ke/moondb@0.1.7` 会同时物化两套 moondb，`@moondb.Value`/`Row` 成为不同类型而编译失败。
> 详见 §4 D-M6-1。

### 语法口径备忘（moonc 0.10.x 实测，M1 起照此写）

- trait 方法显式 `Self` 第一参：`async fn find_by_id(Self, Int) -> T raise JeeflowError`（对齐 moondb Driver）
- 错误类型用 `raise`，不用旧 `!E` 后缀；错误枚举 `pub suberror`（外部构造 `pub(all) struct/enum`）
- 泛型：struct 裸参数 `Ctx[R, E]`，约束写在方法级 `pub fn[R : ProcessRepository] ...`（moondb `Pool[D : Driver]` 同款）
- 方法调用宏已去 `!`：`assert_eq(a, b)`、`panic(msg)`（`f!(...)` deprecated）
- 字符串插值 `"\{expr}"`；闭包调用加括号 `(f)(x)`
- async test：黑盒 `_test.mbt` + 包 moon.pkg `import { "moonbitlang/async", } for "test"` 即可（白盒 `_wbtest.mbt` 不解锁 async test，须运行时 import——见 §4 D-M0-1）
- `moon.mod`/`moon.pkg` 为 TOML 风格；workspace 互依赖版本化全名 `"mldong/jeeflow-core@0.1.0"`
- `moon info` 生成 `.mbti`；包级可 `supported_targets`（moonmysql client 即用此钉 native，本仓 vendored 解锁）

## 1.1 工具链版本与本机口径（2026-09-26 升到 latest）

- 本机：**moon 0.1.20260920 / moonc v0.10.14 / core bundle 0.10.14+7d59c7ec9**
  （此前 0.1.20260904 / v0.10.12 / core 0.10.12）。与 CI（`Dockerfile.demo`、`publish.yml`
  装 latest）终于同一把尺子——**此前本机旧、CI 新**，本机绿不等于 CI 绿。
  回滚点：`G:/dev-tools/moon.bak-20260904`（整目录 341M 快照，16 秒可回）。
- 升级姿势：`moon upgrade` 在无 tty 的 shell 里必挂（`IO error: not a terminal`，
  `--force` 与 winpty 都不行）⇒ 用官方 installer，且**必须先把 `$MOON_HOMEin` 预注入
  `$env:Path`**，否则脚本会把自己的路径写进用户级 PATH。
- **诊断渲染器 bug**：本版本 `moon check` / `moon test` 的人读输出会随机 panic
  （`ariadne-0.5.1: Label start is after its end`），且崩在编译成功之后，看起来像构建失败。
  ⇒ 本机所有编译/测试判定一律加 `--output-json`，成败看 `Finished. moon: ran N tasks` 与退出码。
- 新工具链下 `moonbitlang/async` 可升到 **0.22.4**（干净重建 49 tasks / 0 error / test 通过）；
  旧 core（0.10.12）没有 `eprintln` 才被迫钉 0.20.3，该偏斜已不存在。

### 1.2 零警告施工台账（第一轮，进行中→见 §1.3）与一条拦路发现

已完成（每步都 `moon check` 0 error + `moon test` 全通过）：机械改名归一 96 行、
`Map::new()`→`Map([])` 89 站点、保留词 `define`→`define_info` / `alias`→`table_alias` 165 行、
`derive(Eq, Show)`→Debug 13 处、测试限定名 20 处。629→431。
工具：`scripts/moon_diag_inventory.py`（吃 `--output-json`）、`scripts/moon_migrate_w{1,2,3}.py`、
`scripts/moon_try_fix.py`、`scripts/moon_patch.py`（本仓部分 .mbt 的 blob 带 `
`，
普通多行字符串匹配会落空，补丁必须容忍式并断言恰好命中 1 次）。

踩过的两个坑（都靠"编译器当裁判"兜住）：
1. 照 `moon check` 的 `unused_package` 删 import 会**删过头**——该诊断不含测试编译通道，
   把 `_test.mbt` / `for "test"` 要用的 `id_gen`/`@json`/`async` 判成未用（一次 38 个 error）。
   ~~正确口径：check 与 test **两个通道都报未用**才删。~~
   **该口径 09-26 已被证伪，见下方"零警告第二轮 · 位置与判据"第 3 条**：两个通道都报未用的
   `@id_gen` 删掉照样 11 个 error。现在的口径是**一条一验**（每删一条跑一遍全工程 check）。
2. `try?` 迁移（77 处）不是纯语法活：真实牵出 63 个 error 站点，根因是
   **`repository-mysql` 的 DB 层错误处理建在被废弃的"效应推断"上**——
   vendored `moon_mysql_client.MysqlConn::connect` 的签名是 `-> MysqlConn`
   （既不返 `Result` 也不标 `raise`，靠体内 `@socket` 调用被旧编译器推断出错误效应），
   而 `repo/conn.mbt`/`tx.mbt` 写的是 `let outcome = try? connect(...)` + `match outcome { Ok/Err }`。
   旧 `try?` 在这里的语义是"物化成 Result"，新编译器弃办该写法且不再做效应推断 ⇒
   要改就得给 vendored 的 `connect/query/execute/begin/commit` **补 `raise` 标注**，
   而 vendored 的纪律是"逐字节原样拷贝（sha256 已核）"（D-M6-1）——
   这是一次策略决定，不是体力活，等 owner 拍：
   A) vendored 允许"仅加效应标注"的最小偏离并重核 sha 基线；
   B) 等上游 moonmysql/moondb 自己补标注（不可控）；
   C) 对该文件 `#make-silent` 静音 `try?` 弃办，先保住 vendored 的逐字一致。
   其余站点（SPI 闭包、`@string.parse_*`、`@json.parse_json`、`@cjson.parse`）性质清楚，
   塌成 `try CALL catch { 失败臂 } noraise { 成功臂 }` 即可，试算过：改写形状正确、
   负向断言强度不降（从"判 `Err(_)`"变成"确实 raise 才算过"）。

#### 2026-09-26 复核：A 案的真实边界（三条实测，别按"补几行标注"估工）

owner 让先查上游是否已修，再定 A/B/C。实测结论：**B 不成立，A 是子工程**。

1. 上游 **moonmysql 最新 0.7.2**（我们 vendored 自 0.4.0）的 `MysqlConn::connect/query/execute/
   begin/commit/rollback` 签名**依旧不标 `raise`**（`-> MysqlConn` / `-> ExecResult` / `-> Unit`），
   仍靠效应推断；且 `client/moon.pkg` 的 `supported_targets = "native"` **没有放开**
   ⇒ D-M0-2 的 vendored 解锁必须继续保留，"等上游修"不是一条路。
   顺带：0.7.2 的依赖里多了 `moonbitstack/moonpool@0.2.0`，真升 vendored 基线是另一次对齐。
2. **不碰 vendored 走不通**：对本仓 `repo/conn.mbt` 试 `let c = try connect(...) catch {...}
   noraise {...}` ⇒ 整式被判 `Expr Type Mismatch: has Unit, wanted MysqlConn`；
   保留 `match ... { Ok/Err }` 又因 `connect` 不返 Result 而报错。两头都不通。
3. **开放效应会级联**：`repo/tx.mbt:73` 报 `error type mismatched: wanted
   @mldong/jeeflow-core/error.JeeflowError, has Error.` —— 调用方签名只能声明有限错误类型，
   而被调链上的效应是未闭合的 `Error.`。 ⇒ 只标几个公开函数不够，要把 vendored 两个文件
   **自底向上做成效应显式**（体内每一层调用都要闭合，粗量 30~60 处标注/转换）。

#### 2026-09-26 二次更正：A 案作废——`try { 块 } catch` 就够了，vendored 不用动

上一条里"不碰 vendored 两头不通"的结论**是我用错了形状**：我试的是
`let v = try CALL catch {..} noraise {..}`（表达式形），它被判 `has Unit` 是**因为 `noraise`
臂与块值的合成规则**，不是因为 vendored 有开放效应。照上游 `driver.mbt::with_conn` 的写法
——**`try { CALL } catch { e => raise ... }`，块尾表达式即结果、不带 `noraise`**——
在副本 `shape2` 实测：`repository-mysql/repo/conn.mbt::open_conn` 改成该形状后
全工程 check 里 **conn.mbt 零 error**（剩下的 60 条都在 engine/interceptor 等待改站点）。

⇒ 结论替换为：**不需要给 vendored 补效应标注，也不产生偏离白名单**；
每个 `try?` 站点塌成 `try { CALL [后续处理] } catch { <失败臂> }` 即可：
  - 旧 Err 臂是 `raise X` ⇒ catch 臂 `e => raise X`；
  - 旧 Err 臂是回退值 ⇒ catch 臂 `_ => 回退值`；
  - 旧成功臂是 `Ok(Some(u))` 这类嵌套模式 ⇒ 把 `match 值 { Some(u) => .. None => .. }` 挪进 try 块里。
上游未标注 + `supported_targets="native"` 两条仍然成立（D-M0-2 的 vendored 继续保留、
真升 0.7.2 基线是另一轮），只是它们不再阻塞 `try?` 清零。

**A 的落点已量清（关键省力发现）**（⚠ 本节是"A 案作废"之前的量路记录，保留作参考：
最终没有走 vendored 效应显式化，`try?` 站点全部按上一节的 `try { 块 } catch { 臂 }` 收口）：
`vendored/moon_mysql_client/driver.mbt:49-50` 里上游
**自己已经做过同类收口** —— `fn to_db_error(e : Error) -> @moondb.DbError`，且 `Driver` 的
trait impl（`execute/query/begin/commit/rollback`）全都标了 `raise @moondb.DbError`。
缺的只是 **`conn.mbt` 里那批 `MysqlConn` inherent 方法**（`connect/query/execute/
begin/commit/rollback/close` 等）没做同样的闭合，而我们 `repo/conn.mbt`/`tx.mbt` 正是
直接调这批方法。实测效应入口只有 **6 处** socket 调用（`@socket.Addr::resolve`、
`@socket.Tcp::connect`、`tcp.read_exactly`、`write_bytes`），文件共 20 个函数。
⇒ A 不是发明偏离，而是**把上游在 driver 边界已用的 `to_db_error` 模式补到 conn 方法上**，
风格与上游一致、将来 re-vendor 好合。执行顺序：先闭合 vendored conn.mbt（含内部
`read_packet/write_*` 的传导标注）→ `moon check` 该包 0 error → 再落 63 个 `try?` 站点
（SPI 闭包与 parse 族可先走，已在副本试算过形状）→ 其余 4 类警告 → 全门禁 → 发版。

因此 A 的执行形状：单独一轮"vendored 效应显式化"，验收口径 =
`repository-mysql/vendored/moon_mysql_client/*` 与上游的 diff **只允许**
① 去 `supported_targets` 行、② 新增的 `raise`/错误转换；sha 基线重核并把两侧 diff 落档，
D-M6-1 的"逐字节原样拷贝"改写为"仅允许这两类偏离"。之后 63 个 `try?` 站点才有落点。
（↑ 这段是"A 案作废"之前的量路记录，保留作参考；实际没有走 vendored 效应显式化。）

### 1.3 零警告第二轮（2026-09-26，629→57）：位置锁不住，就把编译器当验收人

上一节把 error 清零后，警告从 360 一路清到 57。这一轮真正的收获不是体力，
是三条**方法论**，下次谁再做工具链迁移，直接照这三条做：

1. **诊断的行号不可信，列号可信。** 本仓 .mbt 的 blob 行尾是 `\r\r\n`
   （`.gitattributes` 里 `* -text` 不做转换，103 个跟踪文本文件里 102 个带 CR），
   moon 的行计数器对这种行尾会给出偏大的行号（实测 `core/engine/engine.mbt`
   报 145、真实是 112），而**诊断 context 的行号窗口跟着这个偏号走** ⇒
   想"按位置改"就锁不准。第一版按报告行号 + 单调指针配对，把
   `fn[R : X, E : Y]` 剪成 `fn[RE` 这类语法碎块，71 个 error 是编译器替我抓的。
   可用的三种配对法，按强度排：① 报告行 == 真行时（被前几轮重写过的区段行尾已回 CRLF/LF，
   这些文件报的行号就是真行号）用"行 + 列整对"；② 用"该列唯一命中目标 token"；
   ③ 两者都不可判 ⇒ **报歧义交人工**，不猜（W9 实跑 12/12 无歧义）。
2. **判"改对没有"的唯一裁判是改完再跑一次编译器**，而且必须是**全工程** check：
   包级 `moon check <pkg>` 会少报 `unused_trait_bound`，实测把该摘的约束判成"不该摘"。
   驱动器：`scripts/moon_warn_oracle.py`（先整批试一次，不过再逐站试多形态，
   每站只保留"0 error 且目标类警告数真降"的那版）、`scripts/moon_warn_w3.py`（约束摘除专用，
   同样以编译器为验收人）、`scripts/moon_warn_w5.py`（import 一条一验）。
3. **"两个编译通道都报未用"不能当准绳。** 上一节沉淀的那条口径本轮被证伪：
   check 与 test 两个通道都报 `@id_gen` 未用，删掉即 11 个 error；`core/handler`、
   `repository-mysql/query` 的 `@json` 同病。改成一条一验后的结果是
   **删成 17 条、拒 3 条**（`core/engine` 的 `@id_gen`、`core/handler` 的 `@json`、
   `query` 的 `@json`）——这三条以后别再照诊断删。

语言层的六条事实（都在这一轮踩出来，写代码时照这个形状写）：

| 事实 | 后果 / 正确写法 |
|---|---|
| 闭集 `raise E` 的调用放进 `try { }` ⇒ catch 绑定就是 `E` | `.message()`/`.code()` 直接可用，出口文案一字不用改 |
| **try 块里出现 `fail`/`abort`** | 它把 `Failure` 并进同一 raise 集 ⇒ 绑定退化成 open `Error`，判文案的站点集体报 "Type Error has no method message"。"没抛错就该红"这条判据必须写在 try 外面 |
| `impl Trait for T` 的方法**不再隐式提升**为常规方法 | 补 `pub extend T with Trait::{…}`；vendored 两文件要保逐字一致 ⇒ extend 落在同包的**本仓自有新文件** `vendored/moon_mysql_client/extend_driver.mbt` |
| `substring` 的返回类型跟着接收者走（String→String、StringView→StringView） | 同一串文本两种改法 ⇒ 整批正则必翻车（W6b 37 站全报 "String has no method to_owned"）；替代写法是切片 `s[a:b]` |
| 收尾型 `try { … } catch { e => { 收尾; raise e } }` | 换 `errdefer { 收尾 }`；工具链已声明 try/catch 将来不再捕获异步取消。事务模板 `execute_in_tx` 已换，T1 的回滚三格仍绿 |
| `try? f()` 机械换形会留下 `try { f() } catch { e => raise e }` **空壳** | fragile_catch_all 点的就是它，删包装即可（本仓 5 处）；另 1 处是真正的收尾逻辑 |

还有一条**编译器完全无声**的坑，值得单独记：把 `flow` 的成功臂从
`transform_output(ok_data(data))` 改成 `transform_output(outcome)` 时漏了 `ok_data` 一层，
类型照样是 `Json`、check 0 error，是 **T0 的「委托台账保存成功（msg=<无 msg 键>）」把它抓出来的**。
⇒ 批量改写型作业必须配一个"diff 里被删掉、却没在新增行里回来"的调用清单，
这里是 `scripts/audit_lost_calls.py`（本轮 3 条，逐条判过并记在站点注释里）。

**CI 侧的连带发现**：`Native Probe` 在 master 上是红的，崩因是 ariadne 渲染 warning 时 panic
（`Label start is after its end`），不是编译错误——本机 `moon test`/`moon run` 不带
`--output-json` 同样以 101 崩给用户看。⇒ **零警告顺带解掉 CI**；
发版前那一道"native 不带 --output-json 也要过"是自证这条的门禁，别省。

**残留判断**（写在这里免得下轮又当新发现）：`unused_error_type` 与 `unused_trait_bound`
两类呈**守恒**特征——摘掉 A 处的那一个，B 处冒出一个新的（实测：摘 `Engine::repo` 的
`E : ProcessExtRepository` ⇒ 21:11 那条消失、engine.mbt:532 与 engine_ops.mbt:193 各新增一条）。
逐点贪心因此不收敛，只能做**集合级不动点**。剩下的这几条要么整族重排签名（会动已发布的
门面效应声明形状），要么带 `// 约束留着是 API 文档` 的例外记档 —— 属发版前的口径决定，
不要顺手改。

## 2. 测试指南（T0/T1/T2 + 构建目标维度）

### T0 仓内快测（必绿门槛）

```bash
moon test --target wasm          # 全 workspace（119+ 用例：合规场景/submitType 矩阵/事件时机/出口纪律/persist）
```

- async 测试 = 黑盒 `_test.mbt` + 包 `moon.pkg` 的 `import { "moonbitlang/async" } for "test"`（§4 D-M0-1）。
- 负向纪律（R5）：关键行为配变异验证——改坏实现→测试必须红→还原。

### T1 MySQL 冒烟（wasm 本机 → 开发服务器）

前置（首次跑或换库时）——建库 → 导入建表 → 再跑 smoke，缺库缺表 smoke 会直接失败：

```bash
# 1. 建库（默认库名 jeeflow，可自定）
mysql -h <DB_HOST> -uroot -p -e "CREATE DATABASE IF NOT EXISTS jeeflow CHARACTER SET utf8mb4"

# 2. 导入建表 DDL（仓内副本；编辑源在 jeeflow-java，勿手改）
mysql -h <DB_HOST> -uroot -p jeeflow < repository-mysql/schema/schema-mysql.sql

# 3. 设连接 env 后跑 smoke
JEFFLOW_DB_HOST=<DB_HOST> JEFFLOW_DB_USER=root JEFFLOW_DB_PWD=... \
  moon run --target wasm repository-mysql/smoke

# 4. 门面级 withdraw/transfer 真机对拍（issues/114/115，断言全部读库里的列）
JEFFLOW_DB_HOST=<DB_HOST> JEFFLOW_DB_USER=root JEFFLOW_DB_PWD=... \
  moon run --target wasm demo/cmd/t1_mysql
```

- `demo/cmd/t1_mysql` 为什么单开一个可执行而不并进 smoke：本栈发布拓扑序是
  core → persist → repository-mysql → facade，让 `repository-mysql` 反向依赖 `facade` 会打破
  `publish.yml` 的按序发版；门面级 SQL 用例因此落在**不发布**的 demo 模块（先例 `demo/cmd/consistency`）。
  两边共用 9xxxxx 段 + 测前测后自清理（R6），`SKIP_MYSQL=1` 同样生效。
- 连接全部走 env：`JEFFLOW_DB_HOST/PORT/USER/PWD/NAME`——**四个显式给全，别依赖 `from_env()` 的
  内置默认值**（那是一套开发机兜底，硬编码在 `repository-mysql/repo/conn.mbt`）；库名指向上方前置
  建的**专用新库**，别指旧库/与其他栈共享的库（静默混表，schema 不齐时表现为莫名的缺列/水化失败，
  见 getting-started.md「MySQL 仓储」警告）。开发服务器与凭据基准见宿主仓库 jeeflow-hub `AGENTS.md`，
  凭据本身不入本仓。
- 覆盖：分页五键 / hydrate 参与人+变量+DATETIME / m_ LIKE 真实走 SQL /
  事务回滚无半完成实例 / 并发办理幂等（§6.2 语义级）。
- 数据纪律（R6）：define/instance 全走 9xxxxx 段，测前测后自清理；
  `SKIP_MYSQL=1` 开发机跳过；**发版机连不上 MySQL = fail 不是 skip**。
- 正式口径另需开发服务器 native 双跑（docker debian:bookworm + build-essential 独立容器，O4）。

### T2 demo 冒烟

```bash
moon run --target wasm demo/cmd/main          # :8092（memory 默认）
bash scripts/smoke_t2.sh                       # 发起→待办→办理→完成→高亮→负向
```

jeeflow-ui 联调：`?lang=moon` 分段 / `/moon-api` 代理（apps/demo）。

### 已知坑（写测试前必读）

1. **`moon test` 的 wasm 运行器在 Windows 上 socket/fs 读会挂死**（§4 D-M2-2）——
   IO 相关验证写 `moon run` 可执行，别放 `_test.mbt`。
2. async test 仅黑盒 `_test.mbt` + `for "test"` 导入可行；白盒 `_wbtest.mbt` 不解锁（§4 D-M0-1）。
3. `Array::sort/sort_by` 对 String 在 wasm 排序结果错误——用 `@model.sort_strings/sort_i64/sort_int`（§4 D-M3-2）。
4. 断言用 `assert_eq/assert_true`（无裸 `assert`、无 `!` 后缀）。

## 3. mooncakes.io 发版通道（jeeflow-moon，独立 0.x 线，现 0.1.12）

> 原则：**首次发版失败可重试、tag 可删重打，版本号严禁跳号**（0.1.0 起完整递增，不断号）。
> CI 不跑测试——本地 T0/T1/T2 已验口径不变。

### 凭据（两种通道）

| 通道 | 凭据 | 说明 |
|---|---|---|
| GitHub Actions（推荐） | repo secrets：`MOON_TOKEN` / `MOON_USERNAME` | push tag `v*` 自动触发 `.github/workflows/publish.yml`，按拓扑序 publish 4 模块 |
| 本地手动（**当前主通道**） | `$MOON_HOME/credentials.json`（`{"token":..., "username":...}`，`moon login` 生成） | 按下方顺序手动执行 |

> ⚠️ CI 工具链坑（2026-09-04 首发连挂 5 轮 → 2026-09-05 定位修复；2026-09-09 复测精读后更正）：
> 1. **钉版下载 403**：脚本 host `cli.moonbitlang.com` 对显式版本路径一律 403（`binaries/0.1.20260827/*`
>    与 `cores/core-0.1.20260827.tar.gz` 实测完整 GET 403，响应体为 S3 原生 `AccessDenied`，
>    **服务端持久策略而非 CDN 瞬断**，换浏览器 UA 同样 403），仅 `latest` 别名可装——钉版本号的安装方式
>    在当前服务端策略下不可用。另：`www.moonbitlang.com` 同名路径此前记的「200」是 **Docusaurus 404 页**
>    （28944B HTML "Page Not Found"，latest/显式同内容），**并非产物**，不可作为钉版本通道；
> 2. **9/4 晚的 latest 是坏构建**：含"TOML moon.mod import @版本解析（registry not found）"缺陷，
>    后被官方撤回；2026-09-05 实测 latest 已回到 `0.1.20260827`（d0aaa07，与本地发版工具链同构建）；
> 3. **09-09 latest 前移 `0.1.20260904`**（v0.1.5 两次 attempt 均被当时存在的守卫拦截——工具链
>    下载两次都 100% 成功，失败点纯是版本断言；此前「CDN 403 卡原始 run」为本地复现误判，已推翻）。
> **09-09 策略定调（owner）**：latest 是向前别名、正常只前进（出 bug 也是修完升版本号，不回退），
> 版本守卫会在每次编译器正常更新时永久拦死发版，代价不值——**去掉 `EXPECTED_MOON_VERSION`
> 守卫，装 latest 直接发版**（owner 口径：不强校验版本，若最新编译器把既有代码判错——
> 如 0.1.20260904 的旧式泛型写法 parse error，见 0d23278——本地升级同款编译器复现、
> 按错误信息修/适配后 re-run 即可），install 步保留 `moon version` 输出
> 进 run log 留痕本次实际编译器。原 9/4 事故风险（坏构建上线）由「坏构建会被官方 yank/升版
> 修复」兜住；若真发出版本异常，mooncakes 侧按模块回滚重发（版本号不变）。
> 另加 `validate_only` 手动入参做通道自检（装工具链+依赖+native 构建跳过 publish）。

### 发布拓扑序（依赖向，每次发版固定）

```
core → persist → repository-mysql → facade
```

demo 模块不发布。

### GitHub Actions（推荐路径）

```bash
git push origin master            # 代码先行（本 clone 的 GitHub remote 名为 origin）
git tag v0.1.5 && git push origin v0.1.5   # 触发 publish workflow（版本号以 moon.mod 当前值为准）
```

- 失败重试（**按失败原因选路径，09-09 v0.1.5 教训**）：
  - **修复落在 master、tag 仍指旧 commit 时**（改 CI / 改源码修编译错）：Actions Re-run 或删 tag 重打
    都只 checkout tag 记录的那个旧 commit，**拿不到该修复**——须改用 `gh workflow run publish.yml`
    （workflow_dispatch，checkout master HEAD）或把 tag 重指到修复后的 commit 再推。
  - **纯偶发**（网络 / CDN / registry 抖动，代码与 CI 都没动）：直接 Actions 页 Re-run 原 run；
    或删 tag 重打（`git tag -d v0.1.5 && git push origin :refs/tags/v0.1.5 && git tag v0.1.5 && git push origin v0.1.5`）。
- 版本号不变（moon 走 **0.x 独立线**，现 0.1.12，见 §4 D-M5-1；下方示例的
  `1.0.0` 系早期文档残留，实际以仓内 `moon.mod` 当前版本为准），重试 publish 同版本号——mooncakes
  对已存在版本会拒绝，若部分模块已发成功：仅重发失败模块（workflow 幂等按模块步进），**不要 bump
  版本号来绕**。

### 本地手动（兜底）

```bash
export MOON_HOME=<your-moon-home> PATH=$MOON_HOME/bin:$PATH      # 机器无关；MOON_HOME=你的安装目录，装法见 docs/getting-started.md
cd core              && moon publish   # 1. mldong/jeeflow-core
cd ../persist        && moon publish   # 2. mldong/jeeflow-persist
cd ../repository-mysql && moon publish # 3. mldong/jeeflow-repository-mysql
cd ../facade         && moon publish   # 4. mldong/jeeflow-facade
```

### 回拉验证（发版后必做）

```bash
mkdir -p /tmp/pull-verify && cd /tmp/pull-verify
# 新建空模块 import 四包 @<当前版本>（引号包名格式 "mldong/jeeflow-core@0.1.5"，勿用裸 `name@ver` 空格写法）→ moon build --target wasm → 冒烟
```

### 发版前 checklist（缺一不包）

1. `moon test --target wasm` 全绿（本地）
2. T1 smoke ALL PASS（连库；`SKIP_MYSQL=1` 仅限无网开发机，发版机 fail）
3. `bash scripts/smoke_t2.sh` ALL PASS（demo 起着）
4. `node scripts/check-action-manifest.mjs` PASS
5. `consistency/moon.json` 与六语言逐字段比对（固定钟确定化）
6. 四模块 `moon.mod` version 一致且与 tag 一致

## 4. 代决策日志（decisions-log）

> 约定（方案 §9 尾注）：契约语义冲突（R1）永远硬停，不适用代决策；本表只记**工程实现类**代决策。
> 每条含：问题 / 候选项 / 所选项 / 理由 / 状态，等用户逐条追认或纠正。

### D-M0-1 async test 的依赖形态（core 零依赖 vs 全异步测试）

- **问题**：`async test` 语法要求 `moonbitlang/async` 对包可见；但方案 §2.2 定稿 core 模块零 registry 依赖。
- **候选项**：
  1. core 包运行时 import async —— 破坏零依赖（实测可行，弃）
  2. core 包 `import { "moonbitlang/async", } for "test"` + 黑盒 `_test.mbt` 测试 —— 实测 async test 解锁，主代码 import 块保持空
  3. 白盒 `_wbtest.mbt` 写 async 测试 —— 实测 `for "test"` 不解锁白盒 async test（须运行时 import，弃）
- **所选项**：2。core/spi/moon.pkg 只写 `for "test"` 块；async 测试全部黑盒化（配 `pub(all)` 模型字段 + `with_*` 公开构造器）。
- **理由**：core 发布面（运行时依赖图）保持零依赖，与 Rust 先例 dev-dependencies（tokio）同构；aqueue（async 官方包）即此形态。
- **实测证据**：`moon test --target wasm -p mldong/jeeflow-core/spi` 2/2 绿（spike① + spike④ 运行时）。
- **状态**：已追认（2026-09-05）。
- **影响**：M1 起所有 core 异步测试走黑盒 `_test.mbt`；白盒测试仅限纯同步逻辑。

### D-M0-2 moon-mysql 0.3.1 client 包 wasm 解锁（vendored）

- **问题**：`Lfan-ke/moon-mysql@0.3.1` 的 `client` 包（async `MysqlConn` 唯一载体）moon.pkg 声明
  `supported_targets = "native"`，wasm 构建被构建计划直接拒绝
  （"Selected backend 'wasm' is incompatible... supports [native]"）。
  方案 §0.1 实测表「moon-mysql wasm ✅」对 0.3.1 的 async API **不成立**（该表结论疑来自旧版本或仅 root codec 包）。
  备选方案 B（sync Driver）同在 client 包内，本机 wasm/native 均死（native 撞 MSVC 墙）。
- **候选项**：
  1. vendored：拷 client 两文件（conn.mbt/driver.mbt，681 行）入仓去掉限制，root codec 仍走 registry 0.3.1
  2. MySQL 全走 160 native（本机彻底放弃 MySQL；T1/巡检全部 ssh 到 160 跑）
  3. 等 upstream 解锁 / 找其他版本
- **所选项**：1，落在 `repository-mysql/vendored/moon_mysql_client/`（Apache-2.0，属文与升级策略见该包 moon.pkg 注释）。
- **理由**：**实测解锁后 wasm 下连接/建表/查询/begin-commit-rollback 全通**（160 MySQL 8，spike② STEP1–6），
  证明上游限制是保守声明而非技术墙；保住方案 §2.4 本机开发主循环（wasm → 160:3306）与 §2.3 全异步架构；
  vendor 面积仅 client 2 文件，root codec（wire 协议核心）不 vendor，0.3.x 升级仍可跟 upstream。
- **风险与回退**：若后续 wasm 出现目标特有 bug（大包分帧/流式查询），回退候选 2（160 native 口径，方案 §2.4 本就有此行）。
- **状态**：已追认（2026-09-05）。
- **关联**：方案 §2.4 表「T1 MySQL 冒烟 wasm 本机→160」一行因此依赖本 vendored 解锁，方案文档不改，以本日志为准。

### D-M0-3 Clock SPI 的默认实现来源（core/env.now() 的发现）

- **问题**：方案 §0.1/§3.4.1 定稿前提「MoonBit core 无墙钟 ⇒ 必须 Clock SPI」。实测 `moonbitlang/core/env`
  提供 `now() -> UInt64`（墙钟毫秒）与 `rand`，前提表述过时（不影响 Clock SPI 设计本身）。
- **候选项**：
  1. 废除 Clock SPI，直接用 @env.now() —— 违反方案 §3.2/§3.4.1 已定稿设计，弃
  2. 保留 Clock SPI；demo/测试的**默认注入实现**用 `@env.now()` 包装（生产形态），一致性测试仍注固定钟
- **所选项**：2。
- **理由**：Clock SPI 的真正价值是测试确定化（固定钟 2026-08-01 → stats 快照确定，方案 §3.4.1），
  这不因墙钟存在而贬值；默认实现有现成来源后 demo 无需自己搓钟。
- **状态**：已追认（2026-09-05）。

### D-M0-4 spike② 的 160 数据口径（计划内动作留痕，非分歧）

- spike② 在 160 `jeeflow` 库建一次性探针表 `wf_moon_spike_tmp`（wf_ 前缀），探针 id 990001/990002（9xxxxx 段），
  跑完 `DROP TABLE` 自清理——方案 §5 spike②「建表」要求与 R6「只动 jeeflow 库 wf_* 表 / 9xxxxx / 测后自清理」的交集口径。
  未新建库/表空间/账号，未触碰既有服务。
- **状态**：留痕备查。

### D-M3-1 facade 页查询的后过滤时机（对 java 五键语义的偏差修正）

- **问题**：rust facade 对所有页查询无条件做"后过滤+重分页"（`re_paginate` 把 recordCount 重置为当前页行数），
  未过滤场景下 recordCount 恒等于 min(pageSize, 行数)，与 java 五键语义（recordCount=过滤后总数）冲突。
- **所选项**：仅当请求携带 m_ 过滤时才做 facade 级后过滤+重分页；无过滤时透传仓储五键（仓储层 count 正确）。
- **状态**：已追认（2026-09-05）；已实现，rust 偏差以本日志为准。

### D-M3-2 core 排序 wasm 问题绕行（开发期观察，工具链 v0.10.11）

- **问题**：moonc v0.10.11 wasm 目标 `Array::sort/sort_by` 对 String 排序结果错误（compare 直调正常）。开发期实测：`["04-...","01-...","02-..."]` 排序后得 `[01,04,02]`。
- **所选项**：core/model/util.mbt 自写插入排序 `sort_strings/sort_i64/sort_int`，全仓 sort 使用点（memory sorted_ids/metadata 三处/stats 极值排序/demo seed）全部替换；单测锁定顺序。
- **状态**：已追认（2026-09-05）；工具链修复后可整体回退。

### D-M2-1 ITransactionTemplate 不进 Ctx（工程简化）

- **问题**：MoonBit 0.10 对"async 高阶函数类型作为 struct 可选字段"的类型化支持不稳定（多轮尝试均被推断/解析拒绝）。
- **所选项**：Ctx 不携带事务模板字段；`MysqlTxTemplate`（repository-mysql）作为独立类型提供
  `execute_in_tx(op)` 真事务（环境连接绑定=spec/05 连接级上下文的单线程形态），T1-M4 语义测试直接使用。
- **理由**：spec/05 本就"事务由业务层持有"；rust demo 同样 transaction_template=None。
- **状态**：已追认（2026-09-05）。

### D-M2-2 T1 走 moon run 可执行通道

- **问题**：`moon test` 的 wasm 测试运行器在 Windows 上对 socket/fs 读操作挂死
  （async_driver event_loop 差异；moon run 同目标无此问题）。
- **所选项**：T1 冒烟为可执行 `repository-mysql/smoke`（`moon run --target wasm`），断言失败 abort→非零退出；
  async test 仅限无 IO 的纯逻辑测试。
- **状态**：已追认（2026-09-05）；发版机口径不变（SKIP_MYSQL=1 跳过，连不上=fail）。

### D-M5-1 首发版本号 0.1.0（mooncakes 平台强制 0.x，O1 的 1.0.0 暂不可用）

- **问题**：mooncakes.io 早期阶段强制 `moon publish` 主版本必须为 0（实测报错
  "In this very early stage, the major version must be '0'. The version should follow the format of `0.x.y`"），
  O1 拍板的 v1.0.0 首发（方案 §7/§9）被平台拒绝。
- **候选项**：① 首发 0.1.0（平台放开后正常升 1.0.0）；② 等 mooncakes 支持 1.x 再首发（阻塞收口）；③ 跳号直上 1.0.1（被否——违背"不断号"原则）。
- **所选项**：①。四模块 + demo 首发钉 **0.1.0**；后续 0.1.x/0.2.x 递增；
  **平台放开 1.x 后首个版本即 1.0.0**（semver 标准 0.x→1.0.0 演进，非跳号；rust 断号教训不复发）。
- **状态**：已追认（2026-09-05）；本条属平台硬约束下的代决策（用户指示"不断号"精神完全保留）。

### D-M5-2 moon demo 容器 seccomp=unconfined（宿主 docker 18.09 默认 profile 拦截现代 syscall）

- **问题**：demo-deploy 容器在托管机持续 Up 但不监听 TCP、docker logs 0 字节。
  定位（2026-09-05，strace + A/B 对照）：宿主机 docker **18.09.1** 默认 seccomp 白名单停留在
  2018 年代，MoonBit native 异步运行时启动期某现代 syscall 被拦（EPERM），
  运行时吞掉错误后事件循环永久等待（strace 仅见纯 `epoll_wait(4,...)` 空转，
  fd 表只有 listener socket + eventpoll + 自管道；`--security-opt seccomp=unconfined`
  下 health 立即返回 `{"status":"ok"}`，其余条件全同）。
- **所选项**：workflow `docker run` 加 `--security-opt seccomp=unconfined`（仅 moon demo 容器，
  其余 demo 容器默认 profile 不动）。专用演示机 + 自家 CI 构建镜像，风险可接受。
- **备选未取**：① 定制 seccomp profile（18.09 default + 现代 syscall 放行）——需维护 vendored
  profile 且被拦 syscall 未能唯一确证，脆弱；② 容器内换 wasm + moonrun（handoff 方案 B）——
  moonrun 同为新 glibc 二进制，同样暴露于老 seccomp，且部署管线重写。
- **状态**：已追认（2026-09-05）；宿主机 docker 升级到新版默认 profile 后可回收该参数。

### D-M5-3 入站 JSON 大整数 id 走 repr 精确解析（上线后真回归抓出，本地 T2 假绿教训）

- **问题**：moon demo 上线后线上冒烟第 4 步"同意"报 `"任务不存在: 2096086641704706048"`
  （实发 taskId …050）——入站 JSON 数字统一走 `Json::Number` 的 **double 分量**，
  雪花 id（~2.1e18）远超 2^53 被取整；字符串 id 双收路径正常。Java 线上基线同链路数字 id 全通
  （state=20），属 moon 相对联邦的 parity 缺陷。
- **假绿根源**：本地 T2 此前 ALL PASS 是因为该次雪花 id 恰好 double 可精确表示
  （id 为 256 的整数倍，ULP=256；python 实测本地两次 taskId mod256=0）——
  冒烟通过与否取决于 id 低位是否凑巧对齐，health 门禁也探不出此类缺陷。
- **所选项**：`as_i64` 等 5 处 Number→Int64/id 串转换改为 **repr 优先**
  （core 词法器对超限字面量在 `Json::Number(n, repr~)` 保留原文，有 repr 按原文精确解析，
  无 repr 照旧 double 截断）：core/json as_i64、facade/args arg_actor_ids、
  core/engine parse_cc_actors、facade/outbound stringify_id_value（出口安全网同步加固）、
  repository-mysql value_to_string（SQL 字面量）；T0 增大整数精度回归测试（117 用例）；
  demo-deploy.yml 部署后加 T2 冒烟门禁（数字 id 全链路，防假绿复发）。
- **后果与跟进**：mooncakes 四模块 0.1.0 含此缺陷，已随 **0.1.1** 发版修复（2026-09-05，
  checklist 全绿：T0 117 / T1 160 / T2 多轮 / manifest 45 / mooncakes 回拉验证 PASS）；
  工具链暂不钉版本（bug 在本仓未用 repr，非 core 漂移）。
- **状态**：已随 0.1.1 发版落地，已追认（2026-09-05）。

### D-M5-4 发版 CI 通道恢复（latest 别名 + 版本守卫 + moon update）

- **问题**：publish.yml 首发连挂 5 轮后弃用（走本地 publish）。三层根因（2026-09-05 定位）：
  ① 服务端对显式版本路径一律 403（`binaries/0.1.20260827/*` GET 实测 403，`latest` 别名 200）——钉版本号的安装方式当前不可用；
  ② 9/4 晚 latest 是含"TOML moon.mod import @版本解析"缺陷的坏构建，后被官方撤回，
  2026-09-05 实测 latest=0.1.20260827（d0aaa07，与本地发版工具链同构建）；
  ③ `moon install` 前缺 `moon update`——0.1.20260827 内置 registry 索引陈旧，不认识 async/moon-mysql 等依赖
  （本地因缓存常新未暴露）。
- **所选项**：workflow 改装 latest + `EXPECTED_MOON_VERSION` 守卫（latest 漂移出已验证版本即 fail-fast）+
  `moon update` 前置 + `validate_only` 通道自检入参。自检绿后 tag v0.1.2 实战发版成功
  （run 33951631628，mooncakes 四模块 0.1.2 已生效）——CI 通道恢复。
- **遗留风险**：latest 未来漂移到坏构建时守卫会拦下；届时本地重验后更新期望版本。【2026-09-09 失效】版本守卫已按 owner 定调移除（`EXPECTED_MOON_VERSION` 删除，装 latest 直接发版），该风险随之不存在；坏构建风险改由「官方 yank/升版修复」兜底，详见本文件 §3。
- **状态**：已追认（2026-09-05）。其中版本守卫部分已被 2026-09-09 owner 定调取代（移除守卫、latest-only，见本文件 §3 / publish.yml），CI 通道部分仍然有效（0.1.2 已经 CI 通道发布，实战通过）。

### D-M5-5 stats 口径对齐（group/define 编码口径 + overview 均值）

- **问题**：七语言公网 demo 契约验证（jeeflow-ui 工作台联调触发）发现 moon 侧偏差：
  ① `stats/group`(define) key 用 display_name（契约=编码 name）、label=null（契约=display_name）、avgDurationSeconds=null；
  ② `stats/overview` avgDurationSeconds 误取**最大值**（跨实例 max），契约=均值（C23）。
- **所选项**：define 分组改按 `d.name` + labels 表；node/define 维度 avg=D总量/样本数（新增 dur_counts）；
  时长口径抽 `stats_instance_duration_secs` 助手（C23：MAX(task.finish_time)-create_time）；
  overview 改均值。T0 117 全绿；本地+公网（0.1.2 部署后）复核 key=01-simple/label=简单审批流程/avg=1。
- **同类待办**：java 参考实现 trend started/finished 与 group avgDurationSeconds 返回**字符串**（契约 int）——
  记，六语言待核（本轮不动，涉 §6.8 全覆盖）。
- **状态**：待追认（随 0.1.2 已发布）。

### D-M6-1 moondb/moonmysql 依赖坐标迁移到 moonbitstack

- **问题**：上游在 mooncakes 把整套 moonorm 生态从个人空间迁到组织空间——`Lfan-ke/moon-mysql`
  → `moonbitstack/moonmysql`（0.3.1 → 0.4.0）、`Lfan-ke/moondb` → `moonbitstack/moondb`
  （0.1.7 → 0.1.8），包名同时**去掉连字符**。旧坐标停在迁移前版本不再更新，需决定跟迁范围。
- **候选项**：
  1. 只迁 moonmysql，moondb 留 `Lfan-ke/moondb@0.1.7` —— **实测不可行（2026-09-19 两种半迁形态都跑过）**：
     - 半迁（vendored client 跟新、其余包留旧）：`moon check` 在**构建计划阶段**即拒绝——
       `Import moonbitstack/moondb@0.1.8 exists in global environment, but its containing module
       is not imported by mldong/jeeflow-repository-mysql`（模块 `moon.mod` 未声明该模块，其包不可导入）；
     - 全留旧 moondb（moon.mod + 四个 pkg 一律 `Lfan-ke/moondb@0.1.7`，仅 moonmysql 用新版）：
       构建计划放行但 **5 个类型不匹配**编译错，两套 moondb 被同时物化、同名类型互为不同类型，如
       `conn.mbt:438` `@moonmysql.bind_params` `has type Array[@Lfan-ke/moondb.Value] /
       wanted Array[@moonbitstack/moondb.Value]`，`conn.mbt:495` `@moonmysql.build_text_rows`
       的 `Row` 同款（`Failed with 506 warnings, 5 errors`）。
  2. moonmysql + moondb 成对迁到 `moonbitstack/`，vendored client 两文件按 D-M0-2
     升级策略从 0.4.0 原样重拷
- **所选项**：2。
- **理由**：迁移是**纯改名**，无行为变化——逐字节实测：moondb 0.1.7→0.1.8 的 `.mbt` 差异仅
  注释/README 里的包名拼写；moonmysql 根包 `pkg.generated.mbti` 除包名外**零差异**；
  client 两文件差异 148 行全部是 `@moon_mysql.` → `@moonmysql.` 别名改名
  （`sed 's/@moon_mysql\./@moonmysql./g'` 归一后与新版逐字节相同）。
  而 moonmysql 0.4.0 的公开接口直接在签名上暴露 moondb 类型（`Value`/`Row`/`ExecResult`/`Driver`），
  消费侧与本仓 vendored client 必须落在**同一个** moondb 实例上——上面两种半迁形态的实测失败即是这条约束的显形。
- **D-M0-2 仍然成立（复测结论）**：新版 `moonbitstack/moonmysql@0.4.0` 的 `client/moon.pkg`
  **依旧声明 `supported_targets = "native"`**，wasm 限制没有放开，vendored 解锁不能删。
  相比 0.3.1 唯一实质变化是 client 包新增了 `pkg.generated.mbti`（接口面固化，
  `MysqlConn`/`MysqlDriver`/`MysqlRowStream` 签名与旧版一致）。
- **vendor 面积**：`conn.mbt`/`driver.mbt` 现为上游 0.4.0 **逐字节原样拷贝**（sha256 已核），
  与上游的唯一偏差仍只在 vendored `moon.pkg`（去掉 `supported_targets` 行）。
- **状态**：待追认（2026-09-19）。
- **验证**：T0 `moon test --target wasm` 119/119；T1 `moon run --target wasm
  repository-mysql/smoke` 专用库 27 断言 ALL PASS（M1 6 + M2 8 + M3 2 + M4 事务回滚 3 +
  M5 幂等 3 + I110 水合 5）；负向两例——错密码 `ServerError(1045, 28000)`、不存在库 `ServerError(1049, 42000)`，
  rc 均为 1（也反证 `JEFFLOW_DB_*` env 真实生效，非默认值假绿）；T2 `smoke_t2.sh` ALL PASS +
  `store=mysql` 模式 demo HTTP 读路径通（`/api/stats`、`todoList` 真 SQL）；
  `check-action-manifest.mjs` 45/45；`consistency/moon.json` 逐字节未变。

### D-M6-2 时间基准：SQL 侧摘 `NOW()`，demo 由 `JEEFLOW_TZ_OFFSET` 注入东八

- **问题**（issues/120 的两处残留 + 一个产品诉求）：
  1. `repository-mysql` 六条写路径的时间列写 SQL `NOW()`，取的是**数据库会话时区**，
     而引擎写出的列是它自己那把钟。开发服务器 160 实测 `@@session.time_zone=+08:00`
     （`NOW()=2026-09-26 01:45:30` 对 `UTC_TIMESTAMP()=2026-09-25 17:45:30`）⇒ 同一行
     `create_time`(引擎) 与 `update_time`(DB) 差 8 小时；最实的一格是「抄送我的」列表——
     `wf_process_cc_instance.create_time` 会被 `page_cc_instances` SELECT 回并投影给前端。
  2. `facade/stats.mbt` 的逾期判据读裸 `@model.epoch_secs()`（`@env.now()`，**注入不了**），
     而同段的 `todayNew` 读 `current_time_str()` ⇒ 宿主一旦注入，两个数互相矛盾。
  3. 本栈无集成壳 ⇒ demo 就是宿主，owner 要 demo 站显示本地时间。
- **候选项**（先找库、再定路）：
  1. 零依赖：demo 读 env 偏移，`set_clock(format_unix_utc(epoch_secs + offset))`。
  2. 引 `caijiewei295/tzif-engine@0.1.0`：真 TZif，DST 精确。
  3. 引官方 `moonbitlang/x` 的 `x/time`：`fixed_zone` / `Zone::from_tzif2`。
  4. 引 `iceBear67/time@0.1.2`：js 臂 `Intl` 自动取系统区、native 臂 `localtime`。
  5. demo 从 wasm 换 js target（为了让 4 的 `Intl` 生效）。
- **实测读数**（全部在 wasm 通道上跑——本机 native 不可构建，见 D-M2-2/issues/118 §2.2）：
  - `moonbitlang/x/time@0.5.5`：`fixed_zone("Asia/Shanghai", 28800)` ✅
    出 `2026-09-26 05:58:18 / offset=+08:00`；但 `Zone::from_tzif2` 喂真实
    `/usr/share/zoneinfo/Asia/Shanghai`（393 字节，TZif v2）**不报错、三个时点全给 `Z`**
    （`1990-05-13T12:00Z` 那格本该 `+09:00`）⇒ 官方 tzif 路径当前不可信，
    而它相对"零依赖 + 固定偏移"并无增量 ⇒ **排除 3**。
  - `caijiewei295/tzif-engine@0.1.0` 吃**同一份字节** ✅：`29 transitions`，
    1990-05-13 → `21:00:00 utoff=32400 dst=true CDT`、2026-09-26 → `08:00:00 utoff=28800 CST`
    ⇒ DST 精确这条路目前只有它可用；代价是引一个只有单一版本的社区依赖 + 内联 tzif 字节。
    **留作升级路径**（真要面向多时区受众时启用），本轮不引。
  - `iceBear67/time@0.1.2`：按 target 分臂，**wasm 臂 `wasm_ffi.mbt` 是桩**——时区直接返回
    `"UTC"`，`current_date/current_time/epoch_seconds` 一律返回 `0`（比我们的默认臂更弱）
    ⇒ **排除 4**；要用它就得走 5（换 target，牵动 Dockerfile/部署链），一并排除。
  - **关键事实**：wasm 上没有任何库能"自动知道"机器在哪个时区，库只做换算——
    区名/偏移必须有人给。这与 120 §9「基准由宿主注入，引擎不自取」同形，不是妥协。
- **所选项**：1（demo 层 env 偏移）；2 挂为将来升级路径并在此留档实测结论。
  同时把 (1)(2) 两处**引擎侧不同基准**按"单一钟"收口——这部分与产品诉求无关，本来就该修。
- **附带新坑（务必别再踩）**：moondb 把 `DATETIME(3)` 结果列投成 **`@moondb.Blob`**，
  本仓 `smoke.cell()` 对 Blob 回 `<BLOB>` ⇒ 按文本比时间会**恒红**（本轮先撞上再绕开）。
  处理：旁挂 `select_cell_dt()` 按库内 `value_to_text` 同规则 `@utf8.decode_lossy` 解码，
  **不动**老 `cell()` 的 `<NULL>`/`<无此列>` 三档标记语义（其它判据依赖它）。
- **状态**：已实施（2026-09-26），待 owner 追认。
- **验证**：T0 `moon test` **168/168**（162 基线 + `facade/stats_clock_test.mbt` 3 +
  `demo/clock_test.mbt` 3）；T1 仓储级 `repository-mysql/smoke` **111 PASS / exit 0**，
  含新增 T1-I120 七格（六列 + 摘掉注入的对照组，实测「库里读回值 == 注入串」逐字相等）；
  T1-F 门面级 `demo/cmd/t1_mysql` ALL PASS；T2 本机 demo 三分支实测——
  配 `JEEFLOW_TZ_OFFSET=8` ⇒ 实例 `createTime=2026-09-26 06:11:08`（真实 UTC `22:11:08` + 8h），
  未配 ⇒ `2026-09-25 22:11:24`（UTC）且启动行打印"未配"，非法值 `abc` ⇒ UTC 且打印"解析失败"
  （**不静默猜区**）。变异对照在副本 `G:/dev-tools/tmp/moon-mut-i120` 做（主树未碰）：
  把 `now_v()` 换成模拟 DB `+08:00` ⇒ `FAIL 实际=2026-09-26 01:59:18，注入串=2026-09-25 05:59:17`，
  证明判据真能分辨"库里用的是哪把钟"。

## 5. 契约对照（moon ↔ java ↔ 六语言）

> 契约源：`scripts/action-manifest.json`（M0 与 java `JeeflowFacade` 实查双向无差集，精确计数以 manifest 为准）。
> 本文件记录 MoonBit 实现的关键契约落点与语言特有注意点。

### 40+ action（5 组）

| 组 | 数量 | 入口方法 |
|---|---|---|
| processDefine | 8 | define_page/detail/start_and_execute/deploy/redeploy/remove/up_and_down/get_last_by_name |
| processInstance | 14（含 stats 3） | instance_page/detail/start_and_execute/withdraw/bizData/highLight/approvalRecord/getAssigneeTextData/createCCInstance/updateCCStatus/ccList/stats_overview/stats_trend/stats_group |
| processTask | 9 | todo_list/done_list/execute/task_detail/jump_able_task_name_list/candidate_page/surrogate/add_candidate/latest |
| processDesign | 9（需扩展仓储） | design_page/detail/save/update/updateDefine/remove/deploy/redeploy/listByType |
| processSurrogate | 5（需扩展仓储） | page/save/update/detail/remove |

### 契约要点（方案 §4 C 条目 → moon 落点）

| 契约 | 落点 |
|---|---|
| C1 id 字符串化递归含复数数组 | `facade/outbound.mbt stringify_ids`（行 VO 构造期即字符串化，雪花 >2^53 免 Double 精度丢失） |
| C2/C3 id 双收（数字/字符串；非法→非法id） | `facade/args.mbt arg_i64` |
| C4/C5 performType 容错入口+数字出口 | `core/parser` perform_type / `facade` 数字 code 输出 |
| C7 时间 yyyy-MM-dd HH:mm:ss | Clock 注入（model.current_time_str）+ 出口 T→空格 + mysql DATETIME 文本归一 19 位 |
| C8–C10 会签 | `core/engine` 门控（串行逐个/并行全齐/比例表达式/一票否决）+ `core/handler check_merge` |
| C11 抄送双路径（f_ccActors/tf_ccActors） | `engine start_async` / `execute_task_async` + CC_CREATE 逐人 fire |
| C12/C13 事件三型 + per-listener 兜底 | `core/event`（TASK_CREATE 落库后 fire 时机） |
| C14 action 全齐/加签去重追加/决策 true 边 | manifest + `engine collect_path` + `repo add_task_actor` |
| C15 ids/id 双收、空显式报错 | `facade arg_ids` |
| C16–C20 persist | `persist/interceptor.mbt`（幂等键/权限双格式键/状态列探测/表名安全） |
| C22 分页五键 | `facade finalize_page`（仅 m_ 过滤时后过滤+重分页，§4 D-M3-1） |
| C23 stats 纯列/显式错误 | `facade/stats.mbt` |
| C25 autoGenTitle 先注入 u_* 再生成 | `engine add_user_info + gen_auto_title` |
| C26 surrogate 双格式时间/enabled=0 不折叠 | `facade actions_ext` |
| C28 withdraw 30/30 | `model withdraw` + `facade withdraw` 级联持久化 |

### MoonBit 特有注意点

- **ids 必须 Int64**：wasm Int=32 位，雪花越界（全模型 id 用 Int64）。
- **builtin Json Number 是 Double**：行 VO 的 id 在构造期即字符串化；`Int64::to_json()` 输出字符串（core 惯例），勿直接用于数字契约键（`@json.number_of` 已绕行）。
- **String::compare/Array::sort wasm 怪异**：排序一律用 `@model.sort_strings/sort_i64/sort_int`（§4 D-M3-2）。
- **async 无 await 关键字**：async 调用自动挂起；`moon test` 的 wasm 运行器 Windows 下 socket/fs 挂死 → IO 测试走 `moon run` 可执行（§4 D-M2-2）。
- **records 引用语义**：mut 字段原地共享，克隆点显式 `clone()`（rust Clone 语义的显式化）。
