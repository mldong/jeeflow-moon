# 代决策日志（decisions-log）

> 约定（方案 §9 尾注）：契约语义冲突（R1）永远硬停，不适用代决策；本表只记**工程实现类**代决策。
> 每条含：问题 / 候选项 / 所选项 / 理由 / 状态，等用户逐条追认或纠正。

---

## D-M0-1 async test 的依赖形态（core 零依赖 vs 全异步测试）

- **问题**：`async test` 语法要求 `moonbitlang/async` 对包可见；但方案 §2.2 定稿 core 模块零 registry 依赖。
- **候选项**：
  1. core 包运行时 import async —— 破坏零依赖（实测可行，弃）
  2. core 包 `import { "moonbitlang/async", } for "test"` + 黑盒 `_test.mbt` 测试 —— 实测 async test 解锁，主代码 import 块保持空
  3. 白盒 `_wbtest.mbt` 写 async 测试 —— 实测 `for "test"` 不解锁白盒 async test（须运行时 import，弃）
- **所选项**：2。core/spi/moon.pkg 只写 `for "test"` 块；async 测试全部黑盒化（配 `pub(all)` 模型字段 + `with_*` 公开构造器）。
- **理由**：core 发布面（运行时依赖图）保持零依赖，与 Rust 先例 dev-dependencies（tokio）同构；aqueue（async 官方包）即此形态。
- **实测证据**：`moon test --target wasm -p mldong/jeeflow-core/spi` 2/2 绿（spike① + spike④ 运行时）。
- **状态**：待追认。
- **影响**：M1 起所有 core 异步测试走黑盒 `_test.mbt`；白盒测试仅限纯同步逻辑。

## D-M0-2 moon-mysql 0.3.1 client 包 wasm 解锁（vendored）

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
- **状态**：待追认。
- **关联**：方案 §2.4 表「T1 MySQL 冒烟 wasm 本机→160」一行因此依赖本 vendored 解锁，方案文档不改，以本日志为准。

## D-M0-3 Clock SPI 的默认实现来源（core/env.now() 的发现）

- **问题**：方案 §0.1/§3.4.1 定稿前提「MoonBit core 无墙钟 ⇒ 必须 Clock SPI」。实测 `moonbitlang/core/env`
  提供 `now() -> UInt64`（墙钟毫秒）与 `rand`，前提表述过时（不影响 Clock SPI 设计本身）。
- **候选项**：
  1. 废除 Clock SPI，直接用 @env.now() —— 违反方案 §3.2/§3.4.1 已定稿设计，弃
  2. 保留 Clock SPI；demo/测试的**默认注入实现**用 `@env.now()` 包装（生产形态），一致性测试仍注固定钟
- **所选项**：2。
- **理由**：Clock SPI 的真正价值是测试确定化（固定钟 2026-08-01 → stats 快照确定，方案 §3.4.1），
  这不因墙钟存在而贬值；默认实现有现成来源后 demo 无需自己搓钟。
- **状态**：待追认。

## D-M0-4 spike② 的 160 数据口径（计划内动作留痕，非分歧）

- spike② 在 160 `jeeflow` 库建一次性探针表 `wf_moon_spike_tmp`（wf_ 前缀），探针 id 990001/990002（9xxxxx 段），
  跑完 `DROP TABLE` 自清理——方案 §5 spike②「建表」要求与 R6「只动 jeeflow 库 wf_* 表 / 9xxxxx / 测后自清理」的交集口径。
  未新建库/表空间/账号，未触碰既有服务。
- **状态**：留痕备查。


## D-M3-1 facade 页查询的后过滤时机（对 java 五键语义的偏差修正）

- **问题**：rust facade 对所有页查询无条件做"后过滤+重分页"（`re_paginate` 把 recordCount 重置为当前页行数），
  未过滤场景下 recordCount 恒等于 min(pageSize, 行数)，与 java 五键语义（recordCount=过滤后总数）冲突。
- **所选项**：仅当请求携带 m_ 过滤时才做 facade 级后过滤+重分页；无过滤时透传仓储五键（仓储层 count 正确）。
- **状态**：待追认（已实现，rust 偏差以本日志为准）。

## D-M3-2 core 排序 wasm bug 绕行（issues/105-moon-）

- **问题**：moonc v0.10.11 wasm 目标 `Array::sort/sort_by` 对 String 排序结果错误（compare 直调正常），详见 `jeeflow-hub/issues/105-moon-*.md`。
- **所选项**：core/model/util.mbt 自写插入排序 `sort_strings/sort_i64/sort_int`，全仓 sort 使用点（memory sorted_ids/metadata 三处/stats 极值排序/demo seed）全部替换；单测锁定顺序。
- **状态**：待追认；工具链修复后可整体回退。

## D-M2-1 ITransactionTemplate 不进 Ctx（工程简化）

- **问题**：MoonBit 0.10 对"async 高阶函数类型作为 struct 可选字段"的类型化支持不稳定（多轮尝试均被推断/解析拒绝）。
- **所选项**：Ctx 不携带事务模板字段；`MysqlTxTemplate`（repository-mysql）作为独立类型提供
  `execute_in_tx(op)` 真事务（环境连接绑定=spec/05 连接级上下文的单线程形态），T1-M4 语义测试直接使用。
- **理由**：spec/05 本就"事务由业务层持有"；rust demo 同样 transaction_template=None。
- **状态**：待追认。

## D-M2-2 T1 走 moon run 可执行通道

- **问题**：`moon test` 的 wasm 测试运行器在 Windows 上对 socket/fs 读操作挂死
  （async_driver event_loop 差异；moon run 同目标无此问题）。
- **所选项**：T1 冒烟为可执行 `repository-mysql/smoke`（`moon run --target wasm`），断言失败 abort→非零退出；
  async test 仅限无 IO 的纯逻辑测试。
- **状态**：待追认；发版机口径不变（SKIP_MYSQL=1 跳过，连不上=fail）。
