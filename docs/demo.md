# 演示站（Demo）

## 本地起 demo（:8092）

```bash
export MOON_HOME=/g/dev-tools/moon PATH=$MOON_HOME/bin:$PATH
JEFFLOW_DEMO_STORE=memory moon run --target wasm demo/cmd/main   # 默认 memory
```

- `demo/cmd/main`：`run_forever` 常驻 HTTP 服务，~40 行完成完整装配（引擎 + 门面 + SPI + 种子）。
- 存储双模式：`JEEFLOW_DEMO_STORE=memory`（默认，内存仓储 + 15 个共享流程种子）| `mysql`（真库）。
- 8 具名用户 SPI（user1=张三 / leader=李四 / manager=王五 …），flows 种子 define id=1..N。

## 路由契约

| 路由 | 说明 |
|------|------|
| `POST /wf/{action}` | 全转发 facade（45 action） |
| `GET /health` | 健康检查（返回 engine/store） |
| `POST /api/reset` | memory 模式重建状态 + 重载种子；mysql 模式回 ok |
| `GET /api/stats?operator=` | 待办/实例计数（demo 专用） |
| CORS | 全开（本地 UI 直连） |

## jeeflow-ui 直连

前端 `?lang=moon` 分段 + `/moon-api` 代理：

- 线上：`https://jeeflow-demo.mldong.com/moon-api`（宿主 16086 → 容器 8092，内存仓储；
  容器需 `--security-opt seccomp=unconfined`——宿主老内核 seccomp 拦 wasm 运行时 syscall，D-M5-2）。
- 本地：`jeeflow-ui` 顶部分段切 MoonBit（apps/demo 已配 `/moon-api` 代理）。
- 全链路验证口径：发起 → 待办 → 同意 → state=20 → 高亮图（UI 浏览器实测 + T2 多轮）。

## T2 冒烟

```bash
moon run --target wasm demo/cmd/main    # 终端 1
bash scripts/smoke_t2.sh                # 终端 2：发起→待办→办理→完成→高亮→99999999 负向
```

demo 部署后 CI 亦自动跑 T2 门禁（数字 id 全链路，防雪花精度假绿复发，D-M5-3）。

## 一致性驱动（stats 快照）

```bash
moon run --target wasm demo/cmd/consistency > moon.json
```

固定数据集（2 流程 / 6 实例 / 5 任务）驱动 15 个 stats action，输出与六语言逐字段比对的
快照（`consistency/moon.json`，口径见 jeeflow-hub issues/103 §8）。
