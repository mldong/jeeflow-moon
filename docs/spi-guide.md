# SPI 实现指南

> moon 引擎为**全异步 SPI**：仓储 SPI / 引擎 / 门面全 `async fn`，单一事件循环零嵌套。
> （MoonBit 无 `block_on`，其它语言的"同步 SPI + 桥接"形态在此不可移植——方案 §2.3。）

## SPI 清单

| SPI | 形态 | 说明 |
|-----|------|------|
| `ProcessRepository`（trait，24 方法） | 必需 | 定义/实例/任务/参与人/抄送/委托/设计 等全部持久化 |
| `ProcessExtRepository`（trait，14 方法） | 必需（可空实现） | 设计与委托扩展仓储；无则用 `@spi.NoExtRepository::new()` |
| `IUserProvider` | 闭包 `(String) -> UserInfo?` | `getUser` 单方法，applicant/审批人信息 |
| `IOrgUserProvider` | 三闭包组 | 部门主管（含主职）/角色取人 |
| `IUserSearchProvider` | 闭包组 | 审批人搜索（候选人双源） |
| `IIdGenerator` | 闭包 `() -> Int64` | 缺省回退默认雪花（EPOCH 对齐联邦 1288834974657） |
| `IExpressionEvaluator` | 可选 | 缺省内置简单比较求值；决策路由用 |
| `IClock` | 闭包 `() -> String` | **MoonBit 特有**：core 无墙钟，时间全注入（测试注固定钟 = 快照字节级确定） |

## 注册方式（Ctx）

```moonbit
let ctx = @spi.Ctx::new(repo, ext_repo)          // 泛型 [R, E]，仓储是类型参数
let ctx = ctx
  .with_id_generator(fn() { gen.next_id() })
  .with_user_provider(my_user_provider)          // (String) -> UserInfo? raise JeeflowError
  .with_org_user_provider(my_org_fns)
  .with_user_search_provider(my_search_fns)
  .with_expression_evaluator(my_eval)
// 拦截器 / 事件监听器 / 决策与取人 handler 也走 Ctx：
ctx.register_interceptor(interceptor.as_interceptor())   // persist 等，order=100 后置
ctx.register_event_listener(my_listener)
ctx.register_assignment_handler("com.mldong.wf.handler.XxxHandler", my_handler)  // Java FQCN 注册
```

## 委托代理自动生效（引擎内置，默认开启）

`wf_process_surrogate` 台账配好之后，**建单那一刻**引擎会自动把被委托人并入该任务的参与者
（授权人保留、任一可办——委托不是转办，不摘原人），集成方**无需挂任何拦截器**。
契约见 spec/06 §4.5（条款 1~6）。本栈落点：`core/engine/surrogate.mbt`，挂在
**新任务落库唯一收口** `Engine::persist_tasks` 的 `save_task` 之前——发起、办理推进、
串行会签每一步、跳转四类路径共用这一个漏斗，结构上漏不掉。

⚠️ 并入的是**参与者集合本身**（`task.actor_ids`），随任务一起落 `wf_process_task_actor`；
**不走**"事后再调一次 `add_task_actor` 补写"那条路（Java 首版正是那条路，它在 taskId
分配前触发、补写打在空 id 上静默无效）。

- **显式关闭**：一行挂在构造链上即可 ——
  `@spi.Ctx::new(repo, ext_repo).with_surrogate_auto_apply(false)`；
  已建好的 `ctx` 直接 `ctx.with_surrogate_auto_apply(false)` 亦可（`Ctx` 是引用语义，原地生效）。
  关闭后回到"仅台账 CRUD"行为：`processSurrogate/*` 五个 action 照常，建单不再并入代理人。
  本栈 `Ctx` 只有 `Ctx::new` 一个构造入口，默认值即开启，不存在"零值即关闭"的旁路。
- **未配置扩展仓储 = 静默跳过**：`E = @spi.NoExtRepository`（`get_surrogate` 恒 None）即视为
  未配置；扩展仓储自身报错也只被吞成 None，绝不打断建单（委托是增强能力）。
- **`processName` 取值**：流程模型 `name`（对齐内置版 `getProcessModel().getName()` 的迁移基线），
  模型未带时回落 `wf_process_define.name`。
- **自建仓储必须满足的四判据**（内存仓与 SQL 仓对同一份数据要给同一答案）：
  ① 空 processName 全流程兜底（先按名精确、未命中再查 `process_name IS NULL OR = ''`）；
  ② 时间窗 `start_time <= now <= end_time`，任一侧 NULL/空 = 该侧不限；
  ③ 自委托过滤 `surrogate <> operator`；④ `enabled` **只认整数 1**（脏值不得当启用）。
  另：多条同时命中取 **id 最大**（SQL 侧 `ORDER BY id DESC`，内存侧不得取遍历首条）。
- **前置拦截器**：`ctx.register_pre_interceptor(...)` 走 `fire_pre_interceptors`（建单那一刻同样触发），
  与后置 `register_interceptor` **分通道**，避免 persist 的 PostInterceptor 被双触发。

## 内存实现参照

`core/memory`（`MemoryRepository`）是完整参照实现：同行为、零 I/O、行列举按 id 有序（测试确定性）。
自建仓储建议从它抄行为语义（水合、过滤、事务边界），生产用 `repository-mysql`（真事务
`MysqlTxTemplate`、`m_` 三段过滤、NULL 安全行读取、DATETIME 文本归一）。

## MoonBit 特有注意点（写实现前必读）

1. **id 全 Int64**：wasm 的 Int 是 32 位，雪花越界——全模型 id 一律 Int64。
2. **builtin Json Number 是 Double**：行 VO 的 id 在**构造期**即字符串化；出口 `stringify_ids`
   递归（含复数数组）是安全网而非第一道防线。
3. **`Array::sort` 对 String 在 wasm 排序结果错误**（直接调 `compare` 才对）——排序一律用
   `@model.sort_strings / sort_i64 / sort_int`。
4. **records 引用语义**：mut 字段原地共享，需要隔离时显式 `clone()`。
5. **async 无 await 关键字**：async 调用自动挂起；`moon test` 的 wasm 运行器 Windows 下
   socket/fs 会挂死——IO 验证写 `moon run` 可执行，不放 `_test.mbt`（D-M2-2）。

完整坑位与决策依据见仓根 `MAINTAINING.md`（§2 已知坑、§4 代决策 D-M0~D-M5、§5 契约 C1–C28 → 实现落点映射；维护者向，不在本目录）。
