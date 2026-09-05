# CHANGELOG

## 未发布（0.1.3 待发）

issues/103 §8 stats 一致性补跑抓出的 4 处偏差修复（均在 `facade/stats.mbt`；
T0 117/117 回归绿，与 java/rust 快照 15/15 逐字段全等）：

- **overview `total` 按 stateIn 门控**：此前统计窗口内全量实例（缺省不剔 99，
  `stateIn=[10]` 也不生效）；对齐 java「total = 六状态计数之和」。
- **`stuckApprover` 按 actor 关系逐人计数**：此前只数主 actor，漏会签/加签的
  额外 actor（task_actor 关系里的 u10 丢失）。
- **`durationBucket` 固定 4 桶全枚举**：此前只发非空桶；对齐 java 空桶也输出（count=0）。
- **分组平级行序确定化**：count DESC + key ASC（此前按插入序，平级序不稳定）。

新增一致性驱动 `demo/cmd/consistency`（固定数据集驱动 15 个 stats action，
输出 `consistency/moon.json` 快照，可复现）。

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
