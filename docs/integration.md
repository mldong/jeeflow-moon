# jeeflow-moon 集成指南

> 面向 mldong 系框架/业务方：如何在宿主应用中嵌入 MoonBit 版 jeeflow 引擎（第 7 语言）。

## 安装（mooncakes.io）

在宿主模块用 `moon add` 按需引入（不带版本 = 拉 latest，自动写精确版本进 moon.mod；
repository-mysql 的传递依赖 moondb/moonmysql/async 一并解析，无需手声明）：

```bash
moon add mldong/jeeflow-core                  # 必需：引擎核心（运行时零依赖）
moon add mldong/jeeflow-facade                # 推荐：40+ action 统一门面
moon add mldong/jeeflow-persist               # 可选：业务数据动态入库（ARCHIVE/SYNC）
moon add mldong/jeeflow-repository-mysql      # 可选：MySQL 仓储（含 vendored 解锁的 client）
```

## 最小装配（内存仓储）

```moonbit
// 引擎为泛型 [R : ProcessRepository, E : ProcessExtRepository]；小 SPI 走闭包字段
let repo = @memory.MemoryRepository::new()
let ctx = @spi.Ctx::new(repo, repo)            // 无扩展仓储时第二个参数用 NoExtRepository::new()
let ctx = ctx
  .with_id_generator(fn() { gen.next_id() })   // IIdGenerator（未注入回退默认雪花）
  .with_user_provider(my_user_provider)        // IUserProvider：(String) -> UserInfo? raise JeeflowError
  .with_org_user_provider(my_org_fns)          // IOrgUserProvider 三闭包组
  .with_user_search_provider(my_search_fns)    // IUserSearchProvider
  .with_expression_evaluator(my_eval)          // 可选；缺省内置简单比较求值
let facade = @facade.Facade::make(ctx)
// 40+ action 单入口：
let resp = facade.flow("processDefine/startAndExecute", args)  // {code,msg,data}
```

## MySQL 仓储

```moonbit
let repo = @repo.MysqlRepository::from_env()   // JEFFLOW_DB_HOST/PORT/USER/PWD/NAME
let facade = @facade.Facade::make(ctx_with(repo))
```

- 每操作独立连接、语句级 autocommit（联邦现状，对齐 rust/sqlx 线）。
- 真事务：`MysqlTxTemplate::from_env().execute_in_tx(op)` —— op 内仓储调用经环境连接共用，
  回调抛错整体回滚（spec/05 连接级 + 上下文绑定的单线程形态）。
- 建表 DDL：`repository-mysql/schema/schema-mysql.sql`（编辑源=jeeflow-java，勿手改）。

## 业务数据动态入库（persist）

```moonbit
let provider = @persist.InMemoryMetaProvider::new()
provider.register(my_table_meta)               // TableMeta：表/列/权限
let interceptor = @persist.PersistPostInterceptor::make(provider, my_writer)
ctx.register_interceptor(interceptor.as_interceptor())  // order=100 后置
```

- 流程 JSON 顶层 `"persistMode": "ARCHIVE" | "SYNC"` + `"relTableName": "业务表"`。
- ARCHIVE：结束+FINISHED+同意 → 幂等 INSERT（键 process_instance_id）。
- SYNC：发起 INSERT → 任务 UPDATE（按目标节点 `field.PERMISSION_*` 过滤）→ 结束定稿。

## 与 jeeflow-ui 直连

`demo/cmd/main` 即可运行的演示服务（:8092）：

```bash
JEFFLOW_DEMO_STORE=memory moon run --target wasm demo/cmd/main
```

路由契约：`POST /wf/{action}`（全转发 facade）+ `GET /health` + `POST /api/reset` + `GET /api/stats?operator=`。

## 时钟基准（宿主注入）

本栈只有**一把钟**：`core/model/clock.mbt` 的 `current_time_str()`。写库审计列
（`create_time`/`update_time`/`finish_time`）、`autoGenTitle`、转办留痕 `time`、委托生效窗判据、
stats 的 `todayNew`/逾期数全部走这一个出口。

```moonbit
// 宿主（框架壳 / demo / 测试）注入自己的本地钟；不注入 = 默认臂 UTC
@model.set_clock(Some(fn() { @model.format_unix_utc(@model.epoch_secs() + 28800L) }))
// 复原默认臂
@model.set_clock(None)
```

为什么默认是 UTC：MoonBit 标准库只有 `@env.now()`（epoch 毫秒），**没有时区包**，
纯 std 拿不到本地偏移。issues/120 §9 的裁定是「基准由宿主注入，引擎不自取」，
且明确**不自行 `@extern` 造 FFI 偏门**——所以未注入时宁可给 UTC，也不猜区。
契约句在 `jeeflow-doc` 的 `spec/06-facade.md` §2.4。

三条纪律（0.1.12 起有门禁钉住，见 MAINTAINING.md D-M6-2）：

1. **SQL 侧不许出现 `NOW()`**。`repository-mysql` 六条写路径（instance/task/design/surrogate 的
   `update_time`，task_actor/cc_instance 的 `create_time`）改绑引擎钟——`NOW()` 取的是
   **数据库会话时区**，与引擎那把钟不同基准（开发服务器 MySQL 实测 `+08:00`，差 8 小时）。
2. **判窗与写库同基准**：委托生效窗与 stats 逾期都读 `current_time_str()`，不再各自取裸墙钟。
3. **注入要能被测试确定化**：`set_clock` 就是给用例铺固定时刻用的（`moon test` 里注入、
   `defer` 复原）。

demo 已内置环境变量注入，无需写代码：

```bash
JEEFLOW_TZ_OFFSET=8 moon run --target wasm demo/cmd/main   # 东八墙钟
moon run --target wasm demo/cmd/main                       # 不配 ⇒ UTC
```

取值：**东为正的小时偏移**，支持 `8` / `+8` / `-5` / `5.5` / `+05:30`，上限 UTC+14；
未配或非法 ⇒ 保持 UTC，并在启动行打印所选基准（`时钟基准 = ...`）。线上 demo
（`.github/workflows/demo-deploy.yml`）已带 `-e JEEFLOW_TZ_OFFSET=8`。

## 环境变量

| 变量 | 说明 |
|---|---|
| `JEFFLOW_DB_HOST/PORT/USER/PWD/NAME` | MySQL 连接（凭据不入仓） |
| `JEEFLOW_DEMO_STORE` | demo 存储模式 memory（默认）/mysql |
| `JEEFLOW_TZ_OFFSET` | demo 时钟基准偏移（东为正小时，如 `8`/`+05:30`；未配=UTC） |
| `LISTEN_ADDR` | demo 监听地址（默认 `0.0.0.0:8092`） |
| `SKIP_MYSQL` | 开发机跳过 T1（发版机连不上=fail） |
