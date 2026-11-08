# jeeflow-moon

- [mldong/jeeflow-core](https://mooncakes.io/docs/mldong/jeeflow-core)
- [mldong/jeeflow-facade](https://mooncakes.io/docs/mldong/jeeflow-facade)
- [在线演示](https://jeeflow-demo.mldong.com/?lang=moon)
- [Apache-2.0](./LICENSE)

jeeflow 是一个多语言联邦：Java 为参考实现，Go / Python / Node / PHP / Rust / C# / MoonBit 各语言
**对齐同一行为契约**——同一套 LogicFlow 共享流程定义（本仓 `flows/` 即入库副本）、同一
`99999999` 错误信封、同一分页五键、同一状态机。本引擎把全部能力收在
**一个统一门面** `flow(action, args) → {code, msg, data}` 后面：流程定义与部署、发起与办理、
跳转与撤回、会签闸门、抄送、委托、统计、业务数据入库（persist）。
引擎核心**运行时零依赖**（只用 MoonBit 标准库），全链 `async fn`、单一事件循环。

## 60 秒跑起来

工具链安装与首次配置见 [docs/getting-started.md](./docs/getting-started.md)（含 `moon update` 刷索引等
首跑细节）。

```bash
git clone https://github.com/mldong/jeeflow-moon.git && cd jeeflow-moon
export MOON_HOME=<your-moon-home> PATH=$MOON_HOME/bin:$PATH

moon test --target wasm                                   # T0 全量单测（条数以实跑读数为准）
moon run --target wasm demo/cmd/main                      # 演示服务 :8092（默认 memory 仓储）
bash scripts/smoke_t2.sh                                  # 发起 → 待办 → 办理 → 高亮 → 负向
```

> 命令里的 `--target wasm` 是刻意的：MoonBit 的 async 运行时在 MinGW/MSYS 宿主上编不了
> native（工具链限制，不是本仓的问题）。native 档由 CI 覆盖，见 [MAINTAINING.md](./MAINTAINING.md)
> 「构建目标纪律」。

### 在自己的模块里消费

也可以不跑 demo，直接 `moon add` 从注册表装（不带版本 = 拉 latest，自动写精确版本进 `moon.mod`）：

```bash
moon new my-flow && cd my-flow
moon add mldong/jeeflow-core      # 引擎核心（运行时零依赖）
moon add mldong/jeeflow-facade    # 统一门面 flow(action, args)
moon add moonbitlang/async        # flow 是 async；async main 需要它
```

下面是**完整可复制的模块**（两个文件，已验证 `moon run cmd/main`，输出见后）：

```moonbit
// cmd/main/moon.pkg
import {
  "mldong/jeeflow-core/spi" @spi,
  "mldong/jeeflow-core/memory" @memory,
  "mldong/jeeflow-core/json" @json,
  "mldong/jeeflow-facade" @facade,
  "moonbitlang/async",
}

pkgtype(kind: "executable")
```

```moonbit
// cmd/main/main.mbt — 仓储是泛型参数，小型 SPI 是闭包字段
async fn main raise {
  let repo   = @memory.MemoryRepository::new()
  let ctx    = @spi.Ctx::new(repo, repo)          // 无扩展仓储；MySQL 侧配 NoExtRepository
  let facade = @facade.Facade::make(ctx)
  let args : Map[String, Json] = { "processDefineId": 1, "operator": "applicant" }
  println(@json.stringify(facade.flow("processDefine/startAndExecute", args)))
}
```

```
{"code":99999999,"msg":"流程定义不存在: 1"}
```

这个信封就是设计要点：裸 `MemoryRepository` 出厂**是空的**——本仓 `flows/` 那套共享流程只由
demo 的 `seed_memory()` 灌入（不随任何发布模块提供）。自己的接入路径是：
`processDesign/save` → `processDesign/deploy` 部署一份自己的定义，再 `startAndExecute`。
要真实审批人与雪花 id，在 `Ctx` 上补 `.with_user_provider(...)` / `.with_id_generator(...)`，
SPI 全清单与写法见 [docs/spi-guide.md](./docs/spi-guide.md)。

## 线上演示（无需安装）

- [jeeflow 演示站 — MoonBit 档](https://jeeflow-demo.mldong.com/?lang=moon)：共享
  [jeeflow-ui](https://github.com/mldong/jeeflow-ui) 工作台，`?lang=moon` 把每个
  `POST /wf/{action}` 路由到本引擎 `:8092` 后端（`/moon-api/` 代理）。
- API 健康检查：[moon-api/health](https://jeeflow-demo.mldong.com/moon-api/health)

## 能力一览

| 能力 | 说明 | 详见 |
|---|---|---|
| 统一门面 | 全部 action 经 `flow(action, args)`，联邦信封（成功 `code=0` / 业务失败 `99999999`，未知 action 顶层拒绝）；action 分五组（流程定义 / 实例 / 任务 / 设计 / 委托），**权威清单 = [`scripts/action-manifest.json`](./scripts/action-manifest.json)** | [docs/engine-api.md](./docs/engine-api.md) |
| 出口契约层 | 每个响应统一过一遍：snake→camel 键、id 递归字符串化（含复数 id 数组，雪花超 float64）、时间 `yyyy-MM-dd HH:mm:ss`、分页五键（`pageNum/pageSize/recordCount/totalPage/rows`） | [docs/engine-api.md](./docs/engine-api.md) |
| 全异步引擎 | 仓储 SPI / 引擎 / 门面全 `async fn`，单一事件循环零嵌套（MoonBit 无 `block_on`，其它语言的"同步 SPI + 桥"形态在此不可移植）；操作覆盖 start / execute / jump / 跳转首尾 / 撤回 | [docs/spi-guide.md](./docs/spi-guide.md) |
| 会签闸门 | 并行全齐、串行逐个（全名册存任务变量）、比例表达式（`#nrOfCompletedInstances==2`）、一票否决（`ONE_VOTE_VETO`）；软否决 `submitType=20` | [docs/flow-definition.md](./docs/flow-definition.md) |
| 事件 | `TASK_CREATE`（落库后 fire，监听器可解析任务）/ `INSTANCE_END`（办结与驳回两路）/ `CC_CREATE`（逐人）；per-listener 故障隔离，坏监听器不断流 | [docs/spi-guide.md](./docs/spi-guide.md) |
| 元数据与处理器 | 7 个内置指派处理器按 Java FQCN 注册（申请人 / 部门负责人 / 表单字段 / 角色）、`EnumDictRegistry` 7 个 `wf_*` 字典、`HandlerRegistry` | [docs/spi-guide.md](./docs/spi-guide.md) |
| 业务数据入库 | 独立模块 `persist`：`persistMode` 驱动 **ARCHIVE**（办结+同意时一条幂等 INSERT）或 **SYNC**（发起 INSERT → 按任务节点 `PERMISSION_*` 字段权逐次 UPDATE → 终态 UPDATE），含表名安全检查 | [docs/persist.md](./docs/persist.md) |
| MySQL 仓储 | 独立模块，纯 MoonBit 线上协议客户端（`moonbitstack/moonmysql/client`，native + wasm）；`m_` 三段过滤、NULL 安全水合、DATETIME 文本归一、真 `BEGIN/COMMIT/ROLLBACK` 事务模板 | [docs/getting-started.md](./docs/getting-started.md)「MySQL 仓储」 |
| 内存仓储 | 在 core 内：行为一致、无 I/O；行列表按 id 排序保证测试确定 | [docs/getting-started.md](./docs/getting-started.md) |
| 时钟 SPI | core 不取墙钟，时间一律注入（`set_clock`）——统计快照与 `autoGenTitle` 在固定钟下字节稳定，一致性对拍靠它 | [docs/spi-guide.md](./docs/spi-guide.md) |

## 模块地图

| 模块 | mooncakes | 职责 |
|---|---|---|
| [`core`](./core) | [`mldong/jeeflow-core`](https://mooncakes.io/docs/mldong/jeeflow-core) | 模型 / 全异步 SPI / 引擎 / 解析器 / 事件 / 元数据 / 内存仓储（运行时零依赖） |
| [`facade`](./facade) | [`mldong/jeeflow-facade`](https://mooncakes.io/docs/mldong/jeeflow-facade) | 统一门面 `flow(action, args)` + 出口契约层 + 统计 |
| [`persist`](./persist) | [`mldong/jeeflow-persist`](https://mooncakes.io/docs/mldong/jeeflow-persist) | 业务数据入库：ARCHIVE / SYNC + 字段权限 |
| [`repository-mysql`](./repository-mysql) | [`mldong/jeeflow-repository-mysql`](https://mooncakes.io/docs/mldong/jeeflow-repository-mysql) | 纯 MoonBit 线上协议 MySQL 仓储 + 事务模板 |
| `demo` | 不发布 | `:8092` HTTP 演示 + jeeflow-ui `?lang=moon`；`demo/app.mbt:15-42` 是最小装配形状 |

版本号独立 0.x 线（mooncakes 平台约束），以各模块 `moon.mod` 与 [docs/CHANGELOG.md](./docs/CHANGELOG.md) 为准。

## 测试分级

T0（仓内全量单测）/ T1（真 MySQL 仓储级）/ T1-F（真 MySQL 门面级）/ T2（demo HTTP 冒烟）
四档，本机都跑 **wasm** 目标，native 由 CI 覆盖；各档命令、前置与覆盖范围见
[MAINTAINING.md](./MAINTAINING.md) §2。条数以实跑读数为唯一口径，文档与 CI 报告都不写死数字。

## 文档导航

| 文档 | 内容 |
|---|---|
| [docs/getting-started.md](./docs/getting-started.md) | 工具链安装、本地起 demo、MySQL 仓储接法 |
| [docs/engine-api.md](./docs/engine-api.md) | 门面 API、信封、出口/入口契约 |
| [docs/spi-guide.md](./docs/spi-guide.md) | SPI 清单（仓储 / 用户 / 事件 / 时钟…）与实现指南 |
| [docs/flow-definition.md](./docs/flow-definition.md) | LogicFlow JSON 流程定义格式 |
| [docs/persist.md](./docs/persist.md) | 业务数据入库（ARCHIVE / SYNC） |
| [docs/integration.md](./docs/integration.md) | mldong 系宿主集成指南 |
| [docs/demo.md](./docs/demo.md) | 演示服务运行细节（含 mysql 档） |
| [docs/CHANGELOG.md](./docs/CHANGELOG.md) | 版本历史（独立 0.x 线） |

跨语言规范（spec / 状态机 / 契约）在 [jeeflow-doc 文档站](https://jeeflow-doc.mldong.com/)
（MoonBit 语言指南：<https://jeeflow-doc.mldong.com/languages/moon/>）。
维护者向内容（工具链口径、发版通道、设计决策、契约对照）在
[MAINTAINING.md](./MAINTAINING.md)，不进 `docs/`、不上文档站。

## 出处

本引擎的工作流内核出自 [mldong 快速开发平台](https://gitee.com/mldong/mldong)
（Apache-2.0，Gitee 上 10k+ stars）的内置工作流模块；对外契约对齐 jeeflow 联邦的 Java
参考实现 [jeeflow-java](https://github.com/mldong/jeeflow-java)（Apache-2.0）。
同一套流程定义、同一信封、同一状态机，MoonBit 重写。

## 集成方

[mldong-moon](https://github.com/mldong/mldong-moon)（mldong 快速开发框架的 MoonBit 实现，
家族第 14 栈）把本引擎以 `plugins/jeeflow` 插件接入——业务方在同一个 MoonBit 栈上
同时拥有框架底座与 jeeflow 工作流。

## License

Apache-2.0.
