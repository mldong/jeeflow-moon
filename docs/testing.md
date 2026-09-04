# 测试指南（T0/T1/T2 + 构建目标维度）

## 工具链（Git Bash）

```bash
export MOON_HOME=/g/dev-tools/moon PATH=/g/dev-tools/moon/bin:$PATH
```

## T0 仓内快测（必绿门槛）

```bash
moon test --target wasm          # 全 workspace（116+ 用例：合规场景/submitType 矩阵/事件时机/出口纪律/persist）
```

- async 测试 = 黑盒 `_test.mbt` + 包 `moon.pkg` 的 `import { "moonbitlang/async" } for "test"`（D-M0-1）。
- 负向纪律（R5）：关键行为配变异验证——改坏实现→测试必须红→还原。

## T1 MySQL 冒烟（wasm 本机 → 160）

```bash
JEFFLOW_DB_HOST=192.168.1.160 JEFFLOW_DB_USER=root JEFFLOW_DB_PWD=... \
  moon run --target wasm repository-mysql/smoke
```

- 覆盖：分页五键 / hydrate 参与人+变量+DATETIME / m_ LIKE 真实走 SQL /
  事务回滚无半完成实例 / 并发办理幂等（§6.2 语义级）。
- 数据纪律（R6）：define/instance 全走 9xxxxx 段，测前测后自清理；
  `SKIP_MYSQL=1` 开发机跳过；**发版机连不上 MySQL = fail 不是 skip**。
- 正式口径另需 160 native 双跑（docker debian:bookworm + build-essential 独立容器，O4）。

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
