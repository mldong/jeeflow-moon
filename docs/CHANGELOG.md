# CHANGELOG

## 0.1.8（2026-09-23）

- **121 文案统一**：`JeeflowError::Business` 的两格退回上一步错误删掉码数字前缀（`engine_ops.mbt` 6 处 raise），
  注释由"码写在 Business(msg) 前缀"更正为"对外 msg 用固定中文文案、不含引擎内部码"；
  测试断言由 `starts_with("20010007")` 改成**逐字相等**（前缀回到任何位置都会红，已做变异对照）。
- **发版通道修复（本轮关键）**：`mldong/jeeflow-*` 的依赖 pin 从 `0.1.0` 升到 `0.1.7`。
  `moon publish` 会把产出的 zip 解包再 `moon check` 一遍，这一步 **vendored 的是 registry 上的依赖源码**；
  而 `jeeflow-core@0.1.0` 是旧泛型语法 `fn sorted_ids[V](...)`，当前 moonc 只认 `fn[V] name(...)`
  ⇒ 2 个 Parse error 把 `repository-mysql`/`facade` 的发布卡死（上一轮 4 模块只发出 2 个的原因就在这里，
  不是我们代码的错）。修复后 `moon publish --dry-run` 服务端回 `202 Accepted`。
- `docs/getting-started.md` 与 `README.md` 的 `0.1.6` 字面量 → `0.1.8`（文档站 `sync:langs` 才投影对）。

## 0.1.7（2026-09-22）

- issues/121 P1/P2：建单写 `parent_task_id` / `isFirstTaskNode`；`submitType=3` 改血缘版退回上一步
  （复活血缘前驱行，参与者取该行办结人，首任务节点行取该行 `u_userId`）。
- **发布状态留痕**：本轮只有 `jeeflow-core` 与 `jeeflow-persist` 的 0.1.7 上了 mooncakes，
  `jeeflow-repository-mysql` / `jeeflow-facade` 因上述 vendored 语法错未发出（由 0.1.8 补齐）。

## 0.1.6（2026-09-19）

MySQL 依赖坐标迁移到 `moonbitstack/`（`repository-mysql` 模块，引擎核心未动）：

- **上游搬家**：mooncakes 把整套 moonorm 生态从个人空间迁到组织空间，本仓两个直接依赖随之改坐标——
  `Lfan-ke/moon-mysql@0.3.1` → `moonbitstack/moonmysql@0.4.0`（包名去连字符）、
  `Lfan-ke/moondb@0.1.7` → `moonbitstack/moondb@0.1.8`。旧坐标停在迁移前版本不再更新。
- **两者必须成对迁**：moonmysql 0.4.0 的公开签名直接在 `Value`/`Row`/`ExecResult`/`Driver` 上暴露
  moondb 类型，只迁一半会同时物化两套 moondb——实测两种半迁形态分别死于构建计划拒绝和 5 个
  类型不匹配编译错（详见 MAINTAINING.md §4 D-M6-1）。
- **升级性质＝纯改名**：逐字节核对——moondb 0.1.7→0.1.8 的 `.mbt` 差异仅注释里的包名拼写；
  moonmysql 根包 `pkg.generated.mbti` 除包名外零差异；client 两文件 148 行差异全部是
  `@moon_mysql.` → `@moonmysql.` 别名改名（归一后与新版逐字节相同）。**零行为变化，无 API 适配**。
- **vendored 解锁保留**：新版 `client/moon.pkg` 依旧声明 `supported_targets = "native"`，
  wasm 限制未放开，D-M0-2 的 vendored 解锁不能删；`conn.mbt`/`driver.mbt` 按既定升级策略
  从 0.4.0 逐字节原样重拷（sha256 已核），与上游的唯一偏差仍只在 vendored `moon.pkg`。
- **消费面**：`repository-mysql/moon.mod` + `query`/`repo`/`smoke` 三包导入 + vendored `moon.pkg`
  改坐标；`repo/conn.mbt` 头注释与 `moon.mod` description 同步包名写法。core/persist/facade/demo
  无 registry 依赖变化，`moon.work` 成员不变。
- **验证**：T0 `moon test --target wasm` 119/119；T1 `moon run --target wasm repository-mysql/smoke`
  专用库 27 断言 ALL PASS（M1 分页五键 6 / M2 hydrate+全链 8 / M3 m_ LIKE 2 / M4 事务回滚 3 /
  M5 办理幂等 3 / I110 find_instance_by_id 水合 5）；负向两例错密码 `ServerError(1045, 28000)`、缺库
  `ServerError(1049, 42000)` 均 rc=1；T2 `smoke_t2.sh` ALL PASS，另跑 `store=mysql` 模式 demo 的
  HTTP 真 SQL 读路径（`/api/stats`、`processTask/todoList`）与不存在 define 发起负向；
  `check-action-manifest.mjs` 45 action 双向无差集；`consistency/moon.json` 逐字节未变。

发版：tag `v0.1.6` → publish.yml CI 发 mooncakes 四模块（core/persist/repository-mysql/facade）。

## 0.1.5（2026-09-09）

五语言引擎 SQL 仓 `find_instance_by_id` 不装 tasks 修复（`246d1ab`，
`repository-mysql/repo/repository.mbt`）：

- **`MysqlRepository::find_instance_by_id` 水合任务**：此前只查 `wf_process_instance`
  单表，`tasks` 硬编码 `[]`，门面 `processInstance/detail` 的 tasks/activeTaskList
  恒为空数组（T015 gate26 L2-12 门禁真根因）。对齐 Java `findTasksByInstanceId` /
  PHP `PdoProcessRepository` / C# `FindTasksInternalAsync`（聚合水合口径）：
  二次查 `wf_process_task`（复用 `find_history_tasks`：`ORDER BY id` + `hydrate_tasks`
  批查 actor_ids，事务内经 `open_or_tx` 复用环境连接，autocommit 独立连接语义不变）。
- **级联安全性**：`update_instance` 本就不级联任务（仅实例行 state/variable/update_time），
  水合后 withdraw 的逐任务 `update_task` 路径不变；memory 仓本就水合（基线正确，未动）；
  引擎核心会签语义未动。
- **T0**：`smoke.mbt` 新增 `t1_i110_hydrate`（T1 通道 `moon run --target wasm`，真实 160
  MySQL，9903xx 独立 id 段 + `clean_9x` 自清理）：引擎 `start_async` 发起 doing 实例
  → 断言 `find_instance_by_id` 水合任务非空 + 带 actor_ids，且门面 detail 消费
  （遍历 `inst.tasks` 组 tasks/activeTaskList）非空。
- **验证**：`moon test --target wasm` 119/119 绿（单测套件未动）；`moon run
  repository-mysql/smoke` T1 ALL PASS（M1–M5 + 新增 I110 五断言全过）；
  `moon check --target wasm` 全 workspace 无硬错误。

发版：tag `v0.1.5` → publish.yml CI 发 mooncakes 四模块（core/persist/repository-mysql/facade）。

## 0.1.4（2026-09-07）

instancePage/ccList 缺 operator 过滤修复（`f073134`，`core/memory/memory.mbt`）：

- **`page_instances` 补 `i.operator` 过滤**：此前全量构建 rows 不读 `query.operator()`，
  任意用户「流程实例」页可见所有人实例。新增 `operator_eq` helper（String 列版），
  实例 operator 即发起人（与 java `t.operator EQ` / `JeeflowFacade.java:254` 同源，
  spec 06-facade §2.5）。过滤在构建 rows 时执行，`recordCount` 为过滤后计数（分页教训）。
- **`page_cc_instances` 补 `cc.actor_id` 过滤**：此前遍历 `cc_instances` 全量构建，
  「抄送我的」页返回所有人抄送行。按 `cc.actor_id = operator`（java `:649` 同口径）。
- **repository-mysql 路径核查无需改**：`page_instances`/`page_cc_instances` 的 count/select
  本就有 `AND pi.operator=?` / `AND cc.actor_id=?`，与 memory/java 三方口径一致（无
  式「OR create_user」偏宽）。
- T0 119 用例全绿（新增 instancePage/ccList operator 正负向 + 无 operator 全量回归）；
  T1 wasm→160 mysql smoke **ALL PASS**（M1–M5，含 instancePage 分页五键 + operator 过滤回归）。
- 红线保持：`processSurrogate/page`（我的委托）无过滤是全语言现状（T003 矩阵不变量 7 依赖），
  未动；`page_todo_tasks`/`page_done_tasks` 行为不变（收口保持）。

发版：tag `v0.1.4` → publish.yml CI 发 mooncakes 四模块 + demo-deploy 公网 moon demo 重建；
公网双身份（张三/李四）instancePage 与 ccList 互不可见复核。

## 0.1.3（2026-09-06）

stats 一致性补跑抓出的 4 处偏差修复（均在 `facade/stats.mbt`；
T0 117/117 回归绿，与 java/rust 快照 15/15 逐字段全等）：

- **overview `total` 按 stateIn 门控**：此前统计窗口内全量实例（缺省不剔 99，
  `stateIn=[10]` 也不生效）；对齐 java「total = 六状态计数之和」。
- **`stuckApprover` 按 actor 关系逐人计数**：此前只数主 actor，漏会签/加签的
  额外 actor（task_actor 关系里的 u10 丢失）。
- **`durationBucket` 固定 4 桶全枚举**：此前只发非空桶；对齐 java 空桶也输出（count=0）。
- **分组平级行序确定化**：count DESC + key ASC（此前按插入序，平级序不稳定）。

新增一致性驱动 `demo/cmd/consistency`（固定数据集驱动 15 个 stats action，
输出 `consistency/moon.json` 快照，可复现）。

doneList 双缺陷修复（2026-09-06 夜班批，`298c1ce`）：

- **`page_done_tasks` 解析 instance→define**：此前 define 硬编码 None，
  行 `processDefineDisplayName` 恒 null（公网「我的已办」流程列整列「-」）。
- **新增 `done_operator_match` 按 `t.actor_id=我` 过滤**：此前不过滤混入他人任务
  （对齐 java `t.operator EQ` / spec 06-facade doneList；过滤在算 total 前执行，
  保证 recordCount=命中数）。T0 118 用例全绿（显示名非 null + operator 正负向 + 无过滤回归）。
- **repository-mysql doneList operator 收敛** `t.operator=?`（原
  `t.operator=? OR t.create_user=?` 过宽，对齐 java；T1 wasm→160 smoke ALL PASS）。

发版：tag `v0.1.3` → publish.yml CI 发 mooncakes 四模块（run 34046826425）+
demo-deploy 公网 moon demo 重建（run 34046826422）；公网复核「我的已办」流程列
非「-」且仅本人任务（API + 浏览器双证据）。

## 0.1.2（2026-09-05）

- **publish.yml CI 通道恢复**（D-M5-4）：装 latest + `EXPECTED_MOON_VERSION` 守卫 +
  `moon update` 前置 + `validate_only` 自检；tag `v0.1.2` 实战发版成功（run 33951631628）。
- **stats 口径收口**（D-M5-5）：overview 均值修 max 误用；stats 计数/时长 int 出参与契约
  §4.2 同口径；公网 `/moon-api` 部署 + UI `?lang=moon` 全链路验证。

## 0.1.1（2026-09-05）

- **雪花 id 精度修复**（D-M5-3）：Number→Int64/id 串转换改 repr 优先（5 处：core/json
  `as_i64`、facade/args `arg_actor_ids`、core/engine `parse_cc_actors`、facade/outbound
  `stringify_id_value`、repository-mysql `value_to_string`）；T0 增大整数精度回归至 117 用例；
  demo-deploy.yml 加 T2 冒烟门禁（数字 id 全链路防假绿）。

## 0.1.0（2026-09-05）

jeeflow 工作流引擎 MoonBit 实现（第 7 语言）首发版本。独立版本线（联邦"契约同代、发版分轨"）。

> 注：mooncakes.io 早期阶段强制 0.x（D-M5-1）；平台放开 1.x 后首个版本即 1.0.0，不跳号。

### 引擎核心（mldong/jeeflow-core@1.0.0）

- 全异步架构：仓储 SPI / 引擎 / 门面全 async fn，唯一事件循环零嵌套（对齐 spec/05）。
- DDD 聚合根 ProcessInstance/ProcessTask，状态机 spec/03 全集。
- 45 action 契约基线（与 java JeeflowFacade 实查双向无差集，manifest 固化）。
- LogicFlow 解析（8 节点类型）、会签门控（串行逐个/并行全齐/比例表达式/一票否决）、
  事件三型（TASK_CREATE 落库后 fire / INSTANCE_END 办结+拒绝双路 / CC_CREATE 逐人）。
- 7 内置 AssignmentHandler（注册名=java 全限定名）+ EnumDictRegistry 7 字典 + HandlerRegistry。
- MemoryRepository（T0）；Clock SPI（测试注固定钟确定化）；运行时零 registry 依赖。

### repository-mysql（mldong/jeeflow-repository-mysql@1.0.0）

- IProcessRepository 24 方法 + IProcessExtRepository 14 方法（moondb Driver + moon-mysql async conn）。
- m_ 三段式过滤解析、分页五键、NULL 安全行读取、DATETIME 文本归一、MysqlTxTemplate 真事务。
- vendored 解锁 moon-mysql client 的 native-only 限制（wasm 可连，决策 D-M0-2）。

### persist（mldong/jeeflow-persist@1.0.0）

- DynamicTableWriter trait + 内存实现；PersistPostInterceptor（ARCHIVE 幂等归档 / SYNC 同步演进 +
  字段权限 PERMISSION_* 双格式键 + 状态列探测）；表名安全检查。

### facade（mldong/jeeflow-facade@1.0.0）

- `flow(action, args)` 45 action 统一入口；出口强制层（camelCase + id 递归字符串化含复数数组 +
  时间归一）；stats 纯列聚合（overview/trend 4 桶/group 9 维）。

### demo（不发布）

- :8092 轻量服务：`POST /wf/{action}` 全转发 + health/stats/reset + CORS；
  8 具名用户 SPI；flows 种子 define id=1..N；memory/mysql 双存储。
- jeeflow-ui `/moon-api` 代理 + `?lang=moon` 分段。
