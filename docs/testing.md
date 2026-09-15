# 测试指南（T0/T1/T2 + 构建目标维度）

## 工具链（机器无关）

```bash
# MOON_HOME 指向你自己的工具链安装目录，安装方式见 toolchain.md（Windows/Lunix 分列）
export MOON_HOME=<your-moon-home> PATH=$MOON_HOME/bin:$PATH
```

## T0 仓内快测（必绿门槛）

```bash
moon test --target wasm          # 全 workspace（119+ 用例：合规场景/submitType 矩阵/事件时机/出口纪律/persist）
```

- async 测试 = 黑盒 `_test.mbt` + 包 `moon.pkg` 的 `import { "moonbitlang/async" } for "test"`（D-M0-1）。
- 负向纪律（R5）：关键行为配变异验证——改坏实现→测试必须红→还原。

## T1 MySQL 冒烟（wasm 本机 → 开发服务器）

前置（首次跑或换库时）——建库 → 导入建表 → 再跑 smoke，缺库缺表 smoke 会直接失败：

```bash
# 1. 建库（默认库名 jeeflow，可自定）
mysql -h <DB_HOST> -uroot -p -e "CREATE DATABASE IF NOT EXISTS jeeflow CHARACTER SET utf8mb4"

# 2. 导入建表 DDL（仓内副本；编辑源在 jeeflow-java，勿手改）
mysql -h <DB_HOST> -uroot -p jeeflow < repository-mysql/schema/schema-mysql.sql

# 3. 设连接 env 后跑 smoke
JEFFLOW_DB_HOST=192.168.1.160 JEFFLOW_DB_USER=root JEFFLOW_DB_PWD=... \
  moon run --target wasm repository-mysql/smoke
```

- 连接全部走 env：`JEFFLOW_DB_HOST/PORT/USER/PWD/NAME`（默认 `192.168.1.160:3306`、`root`、空密码、`jeeflow`）；
  `192.168.1.160` 是开发内网口径，按你实际环境覆盖——开发服务器与凭据基准见宿主仓库 jeeflow-hub `AGENTS.md`，凭据本身不入本仓。
- 覆盖：分页五键 / hydrate 参与人+变量+DATETIME / m_ LIKE 真实走 SQL /
  事务回滚无半完成实例 / 并发办理幂等（§6.2 语义级）。
- 数据纪律（R6）：define/instance 全走 9xxxxx 段，测前测后自清理；
  `SKIP_MYSQL=1` 开发机跳过；**发版机连不上 MySQL = fail 不是 skip**。
- 正式口径另需开发服务器 native 双跑（docker debian:bookworm + build-essential 独立容器，O4）。

## T2 demo 冒烟

```bash
moon run --target wasm demo/cmd/main          # :8092（memory 默认）
bash scripts/smoke_t2.sh                       # 发起→待办→办理→完成→高亮→负向
```

jeeflow-ui 联调：`?lang=moon` 分段 / `/moon-api` 代理（apps/demo）。

## 已知坑（写测试前必读）

1. **`moon test` 的 wasm 运行器在 Windows 上 socket/fs 读会挂死**（D-M2-2）——
   IO 相关验证写 `moon run` 可执行，别放 `_test.mbt`。
2. async test 仅黑盒 `_test.mbt` + `for "test"` 导入可行；白盒 `_wbtest.mbt` 不解锁（D-M0-1）。
3. `Array::sort/sort_by` 对 String 在 wasm 排序结果错误——用 `@model.sort_strings/sort_i64/sort_int`（D-M3-2）。
4. 断言用 `assert_eq/assert_true`（无裸 `assert`、无 `!` 后缀）。
