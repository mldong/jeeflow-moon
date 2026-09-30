# 演示站（Demo）

## 本地起 demo（:8092）

```bash
export MOON_HOME=<your-moon-home> PATH=$MOON_HOME/bin:$PATH      # 装法见 getting-started.md 安装节
JEEFLOW_DEMO_STORE=memory moon run --target wasm demo/cmd/main   # 默认 memory（该变量可省）
```

> ⚠️ 变量名是 `JEEFLOW_DEMO_STORE`（两个 E），**不是** `JEFFLOW_DEMO_STORE`。本栈前缀两套并存：
> demo 侧 `JEEFLOW_DEMO_STORE` / `JEEFLOW_TZ_OFFSET`，MySQL 侧 `JEFFLOW_DB_*`。
> 两种踩法现在都会打一行 `警告：…` 并回落 memory（`App::create()` 只认逐字 `memory` / `mysql`，
> 大小写敏感）：拼错名 ⇒ 警告点名"那条变量没生效"；值不认识 ⇒ 警告点名非法值。
> ⚠️ 这条警告是 **v0.1.23 之后的 master** 才有；线上 `:8092` 演示镜像按 v0.1.23 构建，那一版是
> 静默回落——所以任何时候都只认启动横幅里的 `store=`。
> （历史留痕：09-30 新手盲测实测旧写法拼错时整条被忽略、无报错无警告、`/api/reset` 照样回
> `code=0`，会得到一个"看起来起来了"的假 mysql demo。）
>
> 一个端口只能起一个 demo：第二次 `moon run` 会撞
> `通常每个套接字地址(协议/网络地址/端口)只允许使用一次`。换端口用
> `LISTEN_ADDR=127.0.0.1:8093 moon run --target wasm demo/cmd/main`。

- `demo/cmd/main`：`run_forever` 常驻 HTTP 服务。入口 `main.mbt` 70 行；完整装配分布在
  `demo/app.mbt`(334) + `demo/demo.mbt`(202) + `demo/seed_business.mbt`(526)，其中最小装配形状是
  `App::memory_only()` + `make_mem_ctx()`（`demo/app.mbt:15-42`）。
- 存储双模式：`JEEFLOW_DEMO_STORE=memory`（默认，内存仓储 + 16 个共享流程种子，零前置）| `mysql`（真库）。
- ⚠️ mysql 模式前提：先建**专用新库**并导入 `repository-mysql/schema/schema-mysql.sql`（连接 env 口径见
  [getting-started.md](./getting-started.md)「MySQL 仓储」）；且 **demo 不自动种流程**——内存模式的 16 个
  共享流程不会写入真库，起来后 define 列表为空，需自行 `processDesign/save` → `processDesign/deploy`。
  只想看效果请用默认 memory 模式。
- 8 具名用户 SPI（user1=张三 / leader=李四 / manager=王五 …），flows 种子 define id=1..N。

## 路由契约

| 路由 | 说明 |
|------|------|
| `POST /wf/{action}` | 全转发 facade（40+ action） |
| `GET /health` | 健康检查（返回 engine/store） |
| `POST /api/reset` | memory 模式重建状态 + 重载种子；mysql 模式回 ok |
| `GET /api/stats` | demo 专用两键计数：`todoCount` / `instanceCount`，**两键都按 operator 过滤**。HTTP 侧 operator 恒为缺省 `user1`——`demo/cmd/main` 交给 `App::handle` 的 query_string 是空串，且 wasm 路由不剥 `?` 后缀（带 `?…` 会整串当 path ⇒ `99999999 unknown path`）。要全库口径打 `POST /wf/processInstance/stats/overview`（`data.total`），换人口径打 `processInstance/page` + `operator`。 |
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

脚本头两个可覆盖变量（换主机/换端口、换 python 解释器的唯一手段，脚本内 `BASE=${BASE:-…}` /
`PY=${PY:-…}`）：

```bash
LISTEN_ADDR=127.0.0.1:8093 moon run --target wasm demo/cmd/main   # demo 挪端口
BASE=http://127.0.0.1:8093 bash scripts/smoke_t2.sh               # 冒烟跟着挪
```

demo 部署后 CI 亦自动跑 T2 门禁（数字 id 全链路，防雪花精度假绿复发，D-M5-3）。

## 一致性驱动（stats 快照）

```bash
moon run --target wasm demo/cmd/consistency > moon.json
```

固定数据集（2 流程 / 6 实例 / 5 任务）驱动 15 个 stats action，输出与六语言逐字段比对的
快照（`consistency/moon.json`，口径见 jeeflow-hub）。
