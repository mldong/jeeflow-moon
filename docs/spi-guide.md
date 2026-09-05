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

完整坑位与决策依据见 `docs/decisions-log.md`（D-M0~D-M5）与 `docs/contract-notes.md`（契约 C1–C28 → 实现落点映射）。
