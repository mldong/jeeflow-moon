# jeeflow-moon 集成指南

> 面向 mldong 系框架/业务方：如何在宿主应用中嵌入 MoonBit 版 jeeflow 引擎（第 7 语言）。

## 安装（mooncakes.io）

在宿主模块的 `moon.mod` import 块按需引入（钉精确版本，无 lockfile）：

```toml
import {
  "mldong/jeeflow-core@1.0.0",           // 必需：引擎核心（运行时零依赖）
  "mldong/jeeflow-facade@1.0.0",         // 推荐：45 action 统一门面
  "mldong/jeeflow-persist@1.0.0",        // 可选：业务数据动态入库（ARCHIVE/SYNC）
  "mldong/jeeflow-repository-mysql@1.0.0", // 可选：MySQL 仓储（含 vendored 解锁的 client）
  "Lfan-ke/moondb@0.1.7",                // repository-mysql 的传递依赖（按需显式声明）
  "Lfan-ke/moon-mysql@0.3.1",
  "moonbitlang/async@0.20.3",
}
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
// 45 action 单入口：
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

## 环境变量

| 变量 | 说明 |
|---|---|
| `JEFFLOW_DB_HOST/PORT/USER/PWD/NAME` | MySQL 连接（凭据不入仓） |
| `JEEFLOW_DEMO_STORE` | demo 存储模式 memory（默认）/mysql |
| `SKIP_MYSQL` | 开发机跳过 T1（发版机连不上=fail） |
