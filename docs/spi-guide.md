# SPI 实现指南

> moon 引擎为**全异步 SPI**：仓储 SPI / 引擎 / 门面全 `async fn`，单一事件循环零嵌套。
> （MoonBit 无 `block_on`，其它语言的"同步 SPI + 桥接"形态在此不可移植——方案 §2.3。）

## SPI 清单

| SPI | 形态 | 说明 |
|-----|------|------|
| `ProcessRepository`（trait，29 方法） | 必需 | 定义/实例/任务/参与人/抄送/委托/设计 等全部持久化 |
| `ProcessExtRepository`（trait，13 方法） | 必需（可空实现） | 设计与委托扩展仓储；无则用 `@spi.NoExtRepository::new()` |
| `IUserProvider` | **async** 闭包 `(async (String) -> UserInfo? raise @error.JeeflowError)` | `getUser` 单方法，applicant/审批人信息。issues/146：本栈查库只有 async 一条路 ⇒ 同步形状等于逼宿主启动期快照（之后新人/调岗引擎看不见）。⚠️ 签名里 `raise @error.JeeflowError` 要逐字写，裸 `raise` 或不写都会 `Expr Type Mismatch`（不写时错误集塌成开放 `Error` 并外溢到调用方） |
| `IDynamicMetaProvider` | **async** 闭包组，定义在 `persist` 不在 core | 业务表元数据（列/类型/权限）。java 同位 `jeeflow-persist/meta/IDynamicMetaProvider` 的消费点是写侧/读侧元数据 ⇒ core 里没有需要表元数据的代码，端口挂 Ctx 就是死端口。见 `persist.md` |
| `IOrgUserProvider` | **async** 三闭包组 | 部门主管（含主职）/角色取人 |
| `IUserSearchProvider` | **async** 闭包组 | 审批人搜索（候选人双源） |
| 拦截器 / 事件监听器 / 取人与决策 handler | **async** 闭包 | issues/146 同批改形：这些回调的真实现要写库（persist 归档、站内信、业务节点），同步形状就是同一处病灶 |
| `IIdGenerator` | 闭包 `() -> Int64` | 缺省回退默认雪花（EPOCH 对齐联邦 1288834974657） |
| `IExpressionEvaluator` | 可选 | 缺省内置简单比较求值；决策路由用 |
| `IClock` | 闭包 `() -> String` | **MoonBit 特有**：core 无墙钟，时间全注入（测试注固定钟 = 快照字节级确定） |

## 注册方式（Ctx）

```moonbit
// 真查库的宿主实现：直接写 async 闭包（issues/146 的正式形状）
let user : (async (String) -> @model.UserInfo? raise @error.JeeflowError) =
  async fn(uid : String) raise @error.JeeflowError {
    let conn = repo.open_raw()
    let rows = @repo.q(conn, "SELECT real_name FROM sys_user WHERE id = ?", [@moondb.Text(uid)])
    let _ = conn.close()
    if rows.is_empty() { None } else { Some(@model.UserInfo::make(user_id=uid, real_name=...)) }
  }

let ctx = @spi.Ctx::new(repo, ext_repo)          // 泛型 [R, E]，仓储是类型参数
let ctx = ctx
  .with_id_generator(fn() { gen.next_id() })     // 纯计算 SPI 保持同步（json/expression/permission 同）
  .with_user_provider(user)
  .with_org_user_provider(my_org_fns)
  .with_user_search_provider(my_search_fns)
  .with_expression_evaluator(my_eval)
// 拦截器 / 事件监听器 / 决策与取人 handler 也走 Ctx（入参一律 async 闭包）：
ctx.register_interceptor(interceptor.as_interceptor())   // persist 等，order=100 后置
ctx.register_event_listener(my_listener)                 // 监听器 async ⇒ 站内信这类写型副作用可达
ctx.register_assignment_handler("com.mldong.wf.handler.XxxHandler", my_handler)  // Java FQCN 注册
```

## 纯内存实现的便捷口（`*_sync`）

```moonbit
let ctx = ctx
  .with_user_provider_sync(my_sync_provider)      // 形状＝旧签名，内部经 @spi.async_of_sync 桥
  .with_org_user_provider_sync(@spi.OrgUserProviderFnsSync { ... })
  .with_user_search_provider_sync(@spi.UserSearchProviderFnsSync { ... })
  .with_biz_data_reader_sync(my_reader)
ctx.register_event_listener_sync(my_listener)     // 拦截器/handler 同规律：register_*_sync
```

注册完的 `Ctx` 字段类型与 async 通道完全一致，引擎只认 async 那一种。之所以要有这组便捷口：
本栈编译器把"标了 async 但体内没有 await"判成 `unused_async` 警告（实测闭包字面量和 `fn` 声明**都判**、
且没有可摘的抑制属性），而"只传播不 raise"的 `raise @error.JeeflowError` 标注又会被判 `unused_error_type`；
若让每个内存实现点各写一条空转 async 闭包，警告闸的信号就被淹掉——集中到一处桥，注册点零警告
（`core/spi/context.mbt` 的 `async_of_sync` / `async_of_sync2` / `sync_listener`，全仓恒 3 条来源）。

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
6. **时间只有一把钟**：全栈的"现在"都出自 `@model.current_time_str()`（`core/model/clock.mbt`），
   宿主用 `@model.set_clock(...)` 注入；未注入时默认 **UTC**（MoonBit 标准库只有 `@env.now()`
   epoch 毫秒，无时区包，且明确不造 `@extern` FFI 偏门）。写测试要固定时刻就注入、`defer` 复原；
   **SQL 里不许出现 `NOW()`**（那会把数据库会话时区当成第二把钟）。详见 `integration.md`
   「时钟基准（宿主注入）」与 MAINTAINING.md D-M6-2。

完整坑位与决策依据见仓根 `MAINTAINING.md`（§2 已知坑、§4 代决策 D-M0~D-M6-2、§5 契约 C1–C28 → 实现落点映射；维护者向，不在本目录）。
