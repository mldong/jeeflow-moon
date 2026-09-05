# 快速开始

## 安装

mooncakes.io 正式版本（0.1.x，平台放开 1.x 后首版即 1.0.0 不断号）。核心引擎仅依赖 MoonBit 标准库，按需引入仓储/门面：

```toml
import {
  "mldong/jeeflow-core@0.1.2",     # 引擎核心（运行时零 registry 依赖）
  "mldong/jeeflow-facade@0.1.2",   # 45-action 统一门面
  "mldong/jeeflow-persist@0.1.2",  # 可选：业务数据动态入库（ARCHIVE/SYNC）
  "mldong/jeeflow-repository-mysql@0.1.2", # 可选：MySQL 仓储（含 vendored 解锁的 client）
}
```

> repository-mysql 传递依赖 `Lfan-ke/moondb` / `Lfan-ke/moon-mysql` / `moonbitlang/async` 按需显式声明。钉精确版本（mooncakes 无 lockfile）。

## 5 分钟上手（内存仓储）

```moonbit
// 引擎为泛型 [R : ProcessRepository, E : ProcessExtRepository]；小 SPI 走闭包字段
let repo = @memory.MemoryRepository::new()
let ctx  = @spi.Ctx::new(repo, repo)              // 无扩展仓储时第二参用 @spi.NoExtRepository::new()
let ctx  = ctx
  .with_id_generator(fn() { gen.next_id() })      // 缺省回退默认雪花
  .with_user_provider(my_user_provider)           // (String) -> UserInfo? raise JeeflowError
let facade = @facade.Facade::make(ctx)

// 所有工作流能力都是一次调用：
let resp = facade.flow("processDefine/startAndExecute", args)  // {code: 0, msg, data}
```

流程定义从共享 JSON 装入（15 个流程，`flows/` 副本已入库；单独引入时把流程 JSON 塞进
`processDesign/save` → `processDesign/deploy`，或直接用 demo 仓的种子逻辑）。

## MySQL 仓储

```moonbit
let repo = @repo.MysqlRepository::from_env()      // 读 JEFFLOW_DB_HOST/PORT/USER/PWD/NAME
let facade = @facade.Facade::make(ctx_with(repo))
```

- 建表 DDL：`repository-mysql/schema/schema-mysql.sql`（编辑源在 jeeflow-java，勿手改）。
- 真事务：`MysqlTxTemplate::from_env().execute_in_tx(op)`——op 内仓储调用共用环境连接，
  回调抛错整体回滚。

## 本地开发（本仓源码）

```bash
export MOON_HOME=/g/dev-tools/moon PATH=$MOON_HOME/bin:$PATH   # 便携工具链

moon test --target wasm              # T0：117 用例全绿（合规场景/submitType 矩阵/事件/出口契约）
moon run --target wasm demo/cmd/main # demo :8092（memory 默认）
bash scripts/smoke_t2.sh             # T2：发起→待办→办理→完成→高亮→负向
```

## 环境变量

| 变量 | 说明 |
|------|------|
| `JEFFLOW_DB_HOST/PORT/USER/PWD/NAME` | MySQL 连接（凭据不入仓） |
| `JEEFLOW_DEMO_STORE` | demo 存储模式 memory（默认）/ mysql |
| `SKIP_MYSQL` | 开发机跳过 T1（发版机连不上 = fail 不是 skip） |
