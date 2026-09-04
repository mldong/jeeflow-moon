# jeeflow-moon · jeeflow 工作流引擎 MoonBit 实现（第 7 语言）

> 状态：**M0 完成**（仓骨架 + 契约固化 + 4 spike 全绿）。实施方案：
> [`../docs/moonbit-engine-implementation-plan.md`](../docs/moonbit-engine-implementation-plan.md)（唯一方案，§9 决策已定稿）。
> 移植模板：[`../jeeflow-rust/`](../jeeflow-rust/)（5 crate 切分 → 本仓 5 moon 模块）。

## workspace 布局（方案 §2.5）

| 模块 | 定位 | 依赖 |
|---|---|---|
| `core/` | 引擎核心：model/spi/engine/parser/handler/event/metadata/memory + json/error/id_gen。**运行时零 registry 依赖**（测试经 `for "test"` 引 async，见 docs/decisions-log.md D-M0-1） | 无 |
| `repository-mysql/` | MySQL 仓储（moondb Driver + moon-mysql async conn）+ 分页/m_ 解析 + schema 副本 + smoke | core、moondb、moon-mysql、async |
| `persist/` | DynamicTableWriter + PersistPostInterceptor + Meta | core |
| `facade/` | `flow(action, args)` 45 action + 契约出口层 | core、persist |
| `demo/` | 轻量 HTTP demo :8092（**不发布**） | facade、repository-mysql、async |

其余：`flows/`（15 份共享 LogicFlow 副本，编辑源=jeeflow-java）、`consistency/`（M5 生成 moon.json）、
`docs/`、`scripts/`。

## M0 产物清单

- **45 action manifest**：[docs/action-manifest.json](docs/action-manifest.json)（与 Java `JeeflowFacade` 实查 diff 无差集，
  校验器 [scripts/check-action-manifest.mjs](../scripts/check-action-manifest.mjs)，负向变异已验证红→还原）
- **4 spike 全绿**：
  1. `async test` wasm 跑绿（`core/spi/*_test.mbt`，2/2）
  2. moon-mysql（wasm，vendored 解锁）连 160 真事务：建表/rollback/commit/自清理
     （`repository-mysql/smoke/`；上游 client 包钉 native-only 的对策见 docs/decisions-log.md D-M0-2）
  3. `Server::run_forever` wasm :8092 curl 通（/health + 契约信封）
  4. 泛型约束引擎骨架 + 闭包字段 ServiceContext 编译并运行时验证（`core/spi/spike_service_context.mbt`）
- **schema-mysql.sql + flows/ 15 份副本**：与 jeeflow-java 编辑源逐字一致
- **spec 基线锚定**：java `58fd0b3` / doc `426a1db` / issue 起点 105（`-moon-` 后缀）——写入 manifest `_meta.baseline`

## 常用命令

```bash
# 工具链（Git Bash）
export MOON_HOME=/g/dev-tools/moon PATH=/g/dev-tools/moon/bin:$PATH

moon build --target wasm                                   # 全 workspace 构建
moon test  --target wasm                                   # 全 workspace 测试（T0）
node scripts/check-action-manifest.mjs                     # 45 action manifest gate

# T1 MySQL 冒烟（wasm → 160，凭据只走 env，红线 R6）
JEFFLOW_DB_HOST=192.168.1.160 JEFFLOW_DB_USER=root JEFFLOW_DB_PWD=... \
  moon run --target wasm repository-mysql/smoke

# demo（M0 = spike③ /health；M4 扩展全契约）
moon run --target wasm demo/cmd/main        # curl http://127.0.0.1:8092/health
```

## 文档

| 文档 | 内容 |
|---|---|
| [docs/toolchain.md](docs/toolchain.md) | 工具链钉死版本 + 构建目标纪律 + moonc 0.10.11 语法口径备忘 |
| [docs/decisions-log.md](docs/decisions-log.md) | 代决策日志（问题/候选/所选项/理由，等用户逐条追认） |
| [docs/action-manifest.json](docs/action-manifest.json) | 45 action 契约基准（M0 gate） |

## 红线速览（全文见方案 §0.2 R1–R9）

不自动 push；发版动作（mooncakes publish/tag/远端建仓）等用户账号与确认；160 只动 jeeflow 库 wf_* 表、
id 用 9xxxxx、测后自清理、凭据只走 `JEFFLOW_DB_*` env；三场景测试不过不 commit；工具链不进仓；
范围 = 引擎本体 + 轻量 demo + jeeflow-ui /moon-api 接入。
