# 流程定义格式

## LogicFlow JSON

流程定义为 **LogicFlow JSON**（与联邦共享同一格式，15 个流程各语言一份副本）：

- 节点 8 种类型：start / end / apply（申请节点）/ approve（审批）/ countersign（会签）/ decision（互斥分支）/ fork / join。
- 决策/分支边标签在 `text.value`，路由表达式在 `properties.expr`。
- 每个流程第一个任务节点 = apply，`assignee="applicant"` → 解析为发起人（引擎级特殊值）。

## persistMode（业务数据动态入库）

流程 JSON 顶层两个键驱动 persist 拦截器：

```json
{
  "persistMode": "ARCHIVE",
  "relTableName": "biz_leave"
}
```

- **ARCHIVE**：结束 + FINISHED + 同意 → 幂等 INSERT（键 `process_instance_id`）。
- **SYNC**：发起 INSERT → 任务 UPDATE（按目标节点 `field.PERMISSION_*` 字段权限过滤）→ 结束定稿。
- 详见 [业务数据入库（persist）](./persist.md)。

## 共享 flows 与镜像机制

- 15 个共享流程（id=1..N 按文件名字典序）**唯一编辑源**在 `jeeflow-java/jeeflow-core/src/test/resources/flows/`。
- 本仓 `flows/` 是**入库副本**，demo/test 启动时由本仓解析器读取；维护者机器上 java 兄弟目录存在时，启动即**精确镜像**（全量复制 + 删孤儿）同步进本仓。
- 改流程只改 java 编辑源 → 跑一次任意语言 demo/test 触发镜像 → 逐仓 commit `flows/`（禁止只增不删）。

## assignee 解析

| assignee 写法 | 语义 |
|---------------|------|
| `applicant` | 发起人（实例 operator） |
| `u_*` 变量 | 从流程变量解析用户 |
| 内置 handler | 7 个，按 Java 全限定类名注册（applicant / 部门主管×主职 / 表单字段 / 角色取人） |
| `f_*` 表单字段 | 发起表单字段取人（resume 合并变量可达，对齐 issues/71） |
| 抄送 `f_ccActors` / `tf_ccActors` | 数组/字符串双形态解析（对齐 Go issues/56） |
