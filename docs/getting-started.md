# 快速开始

## 工具链（首次必装）

还没装 MoonBit 工具链的话，先装（**latest-only，不钉版本**——服务端对显式版本路径一律 403，钉版本不可行；编译器判错时按错误信息本地适配即可）：

| 平台 | 安装命令 |
|------|----------|
| Windows（PowerShell） | `irm https://cli.moonbitlang.com/install/powershell.ps1 \| iex` |
| Linux / macOS | `curl -fsSL https://cli.moonbitlang.com/install/unix.sh \| bash` |

- 装完先跑一次 `moon update` 刷新 registry 索引——工具链内置索引可能陈旧，不认识 async / moonmysql 等依赖，缺 `moon update` 时 `moon install` 会失败。
- ⚠️ **Windows 专属坑**：从 32 位父进程链（某些终端启动器）跑安装脚本会误报
  `Install Failed: MoonBit for Windows is currently only available for x86 64-bit...`——
  原因是继承的 `$env:PROCESSOR_ARCHITECTURE` 为 `x86`（系统实际是 `PROCESSOR_ARCHITEW6432=AMD64`）。
  先覆盖 `$env:PROCESSOR_ARCHITECTURE='AMD64'` 再执行安装命令即可。
- 版本自查：`moon version` / `moonc -v`（`moonc` 无 `--version`）。
- 工具链装到哪都行，本文档后续用 `<your-moon-home>` 指代你的安装目录
  （Windows PowerShell 安装默认 `C:\Program Files\MoonBit`；Linux/macOS 官方脚本默认 `~/.moon`）。

## 安装（作为 SDK 依赖）

mooncakes.io 正式版本（0.1.x 线）。核心引擎仅依赖 MoonBit 标准库，按需引入仓储/门面——
`moon add` 不带版本即拉 latest，自动把解析到的精确版本写进 moon.mod（实测 0.1.13，
传递依赖 moondb/moonmysql/async 一并解析，无需手声明）：

```bash
moon add mldong/jeeflow-core                  # 引擎核心（运行时零 registry 依赖）
moon add mldong/jeeflow-facade                # 40+ action 统一门面
moon add mldong/jeeflow-persist               # 可选：业务数据动态入库（ARCHIVE/SYNC）
moon add mldong/jeeflow-repository-mysql      # 可选：MySQL 仓储（含 vendored 解锁的 client）
```

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
- ⚠️ 给 `JEFFLOW_DB_NAME` 指一个**专用新库**（先建库再导上面的 DDL）：指向旧库或与其他栈共享的库会
  静默混表——schema 版本不齐时表现为莫名的缺列/水化失败，库内残留数据还会干扰分页/统计类断言。
- 真事务：`MysqlTxTemplate::from_env().execute_in_tx(op)`——op 内仓储调用共用环境连接，
  回调抛错整体回滚。
- 首次连库的建库/导入步骤与 env 口径见仓根 `MAINTAINING.md` §2 T1（维护者向，不在本目录）。

## 本地开发（本仓源码）

```bash
export MOON_HOME=<your-moon-home> PATH=$MOON_HOME/bin:$PATH   # MOON_HOME=你的工具链安装目录（见上方安装节）

moon test --target wasm              # T0：119 用例全绿（合规场景/submitType 矩阵/事件/出口契约）
moon run --target wasm demo/cmd/main # demo :8092（memory 默认）
bash scripts/smoke_t2.sh             # T2：发起→待办→办理→完成→高亮→负向
```

## 环境变量

| 变量 | 说明 |
|------|------|
| `JEFFLOW_DB_HOST/PORT/USER/PWD/NAME` | MySQL 连接（凭据不入仓） |
| `JEEFLOW_DEMO_STORE` | demo 存储模式 memory（默认）/ mysql（mysql 需先建库导 schema 且不自动种子，见 [demo.md](./demo.md)） |
| `SKIP_MYSQL` | 开发机跳过 T1（发版机连不上 = fail 不是 skip） |
