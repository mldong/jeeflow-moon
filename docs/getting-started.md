# 快速开始

## 工具链（首次必装）

还没装 MoonBit 工具链的话，先装（**latest-only，不钉版本**——服务端对显式版本路径一律 403，钉版本不可行；编译器判错时按错误信息本地适配即可）：

| 平台 | 安装命令 |
|------|----------|
| Windows（PowerShell） | `irm https://cli.moonbitlang.com/install/powershell.ps1 \| iex` |
| Linux / macOS | `curl -fsSL https://cli.moonbitlang.com/install/unix.sh \| bash` |

- 装完先跑一次 `moon update` 刷新 registry 索引——工具链内置索引可能陈旧，不认识 async / moonmysql
  等依赖（`moon add` 自己也会刷新索引，但首次装完手动跑一次更稳；Quickstart 三步里没列它，
  拉不到依赖时先补这一步）。
- ⚠️ **Windows 专属坑**：从 32 位父进程链（某些终端启动器）跑安装脚本会误报
  `Install Failed: MoonBit for Windows is currently only available for x86 64-bit...`——
  原因是继承的 `$env:PROCESSOR_ARCHITECTURE` 为 `x86`（系统实际是 `PROCESSOR_ARCHITEW6432=AMD64`）。
  先覆盖 `$env:PROCESSOR_ARCHITECTURE='AMD64'` 再执行安装命令即可。
- 版本自查：`moon version` / `moonc -v`（`moonc` 无 `--version`）。
- 工具链装到哪都行，本文档后续用 `<your-moon-home>` 指代你的安装目录
  （Windows PowerShell 安装默认 `C:\Program Files\MoonBit`；Linux/macOS 官方脚本默认 `~/.moon`）。

## 安装（作为 SDK 依赖）

mooncakes.io 正式版本（0.x 线）。核心引擎仅依赖 MoonBit 标准库，按需引入仓储/门面——
`moon add` 不带版本即拉 latest，自动把解析到的精确版本写进 moon.mod（版本以各模块
`moon.mod` 与 [CHANGELOG](./CHANGELOG.md) 为准，活文档不手写版本号；
传递依赖 moondb/moonmysql/async 一并解析，无需手声明）：

```bash
moon new my-flow && cd my-flow                    # 消费者工程（没有 moon init）
moon add mldong/jeeflow-core                  # 引擎核心（运行时零 registry 依赖）
moon add mldong/jeeflow-facade                # 40+ action 统一门面
moon add mldong/jeeflow-persist               # 可选：业务数据动态入库（ARCHIVE/SYNC）
moon add mldong/jeeflow-repository-mysql      # 可选：MySQL 仓储（上游 moonmysql client，wasm 可直连）
moon add moonbitlang/async                    # flow() 是 async，async main 必须有它
```

> ⚠️ `moon.mod` 的 `version` 是**发版目标**，注册表 latest 可能落后一代（索引刷新有滞后）。
> 装不到期望版本先 `moon update` 再看 `moon add` 解析到的实际版本，别手工钉死。

## 5 分钟上手（内存仓储）

`flow` 是 `async`、`args` 是 `Map[String, Json]`，而包别名（`@spi` / `@memory` / `@facade`）
写在**消费者自己的 `moon.pkg`** 里——`moon.mod` 只管模块依赖，不解析别名。缺任意一项就是
`Package "memory" not found` / `unbound` 一屏报错。下面这份是实测跑通的完整形状（`moon new`
出的模板根包文件保持原样即可）：

```moonbit
// cmd/main/moon.pkg —— 少 @model / @error 这两行别名，下面的 provider 就写不出来
import {
  "mldong/jeeflow-core/spi" @spi,
  "mldong/jeeflow-core/memory" @memory,
  "mldong/jeeflow-core/model" @model,
  "mldong/jeeflow-core/error" @error,
  "mldong/jeeflow-core/id_gen" @id_gen,
  "mldong/jeeflow-core/json" @json,
  "mldong/jeeflow-facade" @facade,
  "moonbitlang/async",
}

pkgtype(kind: "executable")
```

```moonbit
// cmd/main/main.mbt —— 引擎为泛型 [R : ProcessRepository, E : ProcessExtRepository]；小 SPI 走闭包字段
let user_provider : (String) -> @model.UserInfo? raise @error.JeeflowError =
  (id) =>
    if id == "user1" {
      Some(@model.UserInfo::make(user_id="user1", real_name="张三", dept_id="d1"))
    } else {
      None
    }

async fn main raise {
  let repo = @memory.MemoryRepository::new()
  let gen = @id_gen.DefaultIdGenerator::new(2L)
  let ctx = @spi.Ctx::new(repo, repo)   // 无扩展仓储时第二参用 @spi.NoExtRepository::new()
    .with_id_generator(fn() { gen.next_id() })   // 缺省回退默认雪花
    .with_user_provider(user_provider)
  let facade = @facade.Facade::make(ctx)
  let args : Map[String, Json] = { "processDefineId": 1, "operator": "applicant" }
  println(@json.stringify(facade.flow("processDefine/startAndExecute", args)))  // {code, msg, data}
}
```

```
$ moon run --target wasm cmd/main
{"code":99999999,"msg":"流程定义不存在: 1"}
```

`IUserProvider` 的签名必须逐字写成 `(String) -> @model.UserInfo? raise @error.JeeflowError`：
少 `@error.JeeflowError` 的裸 `raise`、或整个不写 `raise`，都会撞 `Expr Type Mismatch`
（两种报错原文都在实测里出现过）。

内存仓储 `MemoryRepository::new()` 起来是**空库**——上面那句 `99999999 流程定义不存在: 1` 就是
证据。流程定义要自己装入（见下）。

流程定义从共享 JSON 装入（16 个流程，`flows/` 副本已入库；单独引入时把流程 JSON 塞进
`processDesign/save` → `processDesign/deploy`，或直接用 demo 仓的种子逻辑）。

## MySQL 仓储

> 下面是**形状图**（`ctx_with(repo)` 是你的装配函数、`@repo` 是 `moon.pkg` 里给
> `mldong/jeeflow-repository-mysql/repo` 起的别名）；可编译的最小装配见上面「5 分钟上手」，
> 把 `@memory.MemoryRepository::new()` 换成 `@repo.MysqlRepository::from_env()`、
> `@spi.Ctx::new(repo, @spi.NoExtRepository::new())` 即可。

```moonbit
let repo = @repo.MysqlRepository::from_env()      // 读 JEFFLOW_DB_HOST/PORT/USER/PWD/NAME
let facade = @facade.Facade::make(ctx_with(repo))
```

- 建表 DDL：`repository-mysql/schema/schema-mysql.sql`（编辑源在 jeeflow-java，勿手改）。
- ⚠️ 给 `JEFFLOW_DB_NAME` 指一个**专用新库**（先建库再导上面的 DDL）：指向旧库或与其他栈共享的库会
  静默混表——schema 版本不齐时表现为莫名的缺列/水化失败，库内残留数据还会干扰分页/统计类断言。
- 真事务：句柄挂在**仓储实例**上（issues/144）——一个请求＝一个仓储实例。
  `let r = repo.new_request()` 派生请求级实例，`r.execute_in_tx(op)` 的 op 收绑定后的实例，
  op 内该实例族的仓储调用共用同一条连接，回调抛错整体回滚。
  ⚠ 同实例＝同事务：两个请求若共享同一个仓储实例，它们会互相看见对方的事务——这正是 144 修掉的那一格。
- 首次连库的建库/导入步骤与 env 口径见仓根 `MAINTAINING.md` §2 T1（维护者向，不在本目录）。

## 本地开发（本仓源码）

```bash
export MOON_HOME=<your-moon-home> PATH=$MOON_HOME/bin:$PATH   # MOON_HOME=你的工具链安装目录（见上方安装节）

moon test --target wasm              # T0：全绿（用例数以实跑读数为准；合规场景/submitType 矩阵/事件/出口契约）
moon run --target wasm demo/cmd/main # demo :8092（memory 默认）
bash scripts/smoke_t2.sh             # T2：发起→待办→办理→完成→高亮→负向
```

> 这三条是**单列命令**，但一个端口只能挂一个 demo：重复 `moon run` 会撞
> `通常每个套接字地址(协议/网络地址/端口)只允许使用一次`。已有实例在跑就换端口
> （`LISTEN_ADDR=127.0.0.1:8093 …`）并让冒烟跟着挪（`BASE=http://127.0.0.1:8093 bash scripts/smoke_t2.sh`），
> 口径见 [demo.md](./demo.md)「本地起 demo」。

## 环境变量

| 变量 | 说明 |
|------|------|
| `JEFFLOW_DB_HOST/PORT/USER/PWD/NAME` | MySQL 连接（凭据不入仓） |
| `JEEFLOW_DEMO_STORE` | demo 存储模式 memory（默认）/ mysql（mysql 需先建库导 schema 且不自动种子，见 [demo.md](./demo.md)） |
| `SKIP_MYSQL` | 开发机跳过 T1（发版机连不上 = fail 不是 skip） |
