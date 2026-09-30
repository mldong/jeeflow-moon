# 流程定义格式

## LogicFlow JSON

流程定义为 **LogicFlow JSON**（与联邦共享同一格式，16 个流程各语言一份副本）：

- 节点 8 种类型（`type` 串按 `snaker:` 前缀那一档，规范 `spec/02` §3 的表）：
  `snaker:start` / `snaker:task`（申请与审批都是它，靠 `assignee`/`performType` 区分）/
  `snaker:decision` / `snaker:fork` / `snaker:join` / `snaker:end` /
  `snaker:custom`（记录类，见下）/ `snaker:subprocess`。
  ⚠️ 旧版本文这里写的 apply/approve/countersign 是**业务叫法不是类型键**，照它们写 `type`
  会落进未知档（节点被记日志后跳过），别照那一行写定义。
- 决策/分支边标签在 `text.value`，路由表达式在 `properties.expr`。
- 每个流程第一个任务节点 = apply，`assignee="applicant"` → 解析为发起人（引擎级特殊值）。

## 记录类节点 `snaker:custom`（issues/142 A 批 · spec/02 §6.1／§6.2）

`snaker:custom` 是**记录类**：引擎执行 `clazz` 处理器 → 落一条 `task_state=20` 的历史行
（**真落库**，`wf_process_task` 里查得到）→ 令牌沿出边继续流转。它不解析参与者、不产生待办，
也不 fire `PROCESS_TASK_START`（码 3 的事实是「新待办产生」）。

MoonBit 没有反射，java 那句 `Class.forName(clazz)` 在本栈无从谈起 ⇒ 与 Python/C# 同策
**按名注册**，键＝定义里 `properties.clazz` 的原样串（共享夹具里就是 JVM 类名）：

```moonbit
ctx.register_custom_handler(
  "com.mldong.jeeflow.test.TestCustomHandler",
  fn(_e) { @json.string_of("ok") },   // 返回值写进流程变量
)
```

- 返回 `@json.null_json()` ⇒ 引擎一个键都不写；返回有值 ⇒ 按节点 `val` 指定的键写，
  `val` 缺省/空串用 `custom_return_val`（逐字对齐 java `FlowConst.CUSTOM_RETURN_VAL`）。
- **`clazz` 没配 / 为空串 / 注册表里查不到** ⇒ 各记一条可诊断日志后**照常落历史行并继续流转**，
  严禁打断建单（spec/04「节点属性配错不该把流程炸掉」同哲学）；两档日志分开，分别可诊断。
- 处理器**自身**执行失败（闭包里 raise）不在这条豁免内：属业务错误，照旧外抛。
- 留痕行的两列**必写**、两列**不写**（§6.2 第 1bis 条）：`operator`＝当前操作人、`finish_time`
  ＝落库时刻（`doneList`/`approvalRecord` 按这两列取数）；`update_time`/`update_user` 留 NULL
  （记录类没有「办理」那一次更新），`expire_time` 也留 NULL（custom 属性字典没有 expireTime）。

其余 custom 属性：`methodName` / `args`——本栈按名注册后它们只是「节点配置」，由处理器自己
从 `exec.current_node` 读，引擎不做方法反射。

## 任务类零参与者照样建单（spec/02 §6.1 表第一行／§6.2 第 3 条）

`assignee`/`assignmentHandler` 解析不出人时，引擎建**一行 `actor_ids` 为空的 DOING 待办**并停在
这里，**不**兜底挂给当前操作人，也**不**像旧形状那样「一行不建、令牌沿出边跑掉」（那等于库里
查不到实例到过哪个节点）。这一行谁也办不动是设计如此——它的价值是「实例停在哪」可查，
且仍能被 `transfer`／`nextNodeOperator` 救活。会签（`performType=1`）逐成员建行，名册为空时
天然 0 行，不落在这一档。

> ⚠️ 与规范 `spec/02` §4 的已知分叉：本栈 `resolve_assignee` 会把 `candidateUsers` **折进参与者
> 集合**，而规范写的是「不生成 actor，供 candidatePage 选人」。改动面涉及所有把 candidateUsers
> 当预分配处理人用的存量流程 ⇒ 另批裁定，现状由
> `core/engine/i142_custom_record_leg_test.mbt` 按实得形状钉住。`candidateGroups` 不折进参与者。

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

- 16 个共享流程（id=1..N 按文件名字典序）**唯一编辑源**在 `jeeflow-java/jeeflow-core/src/test/resources/flows/`。
- 本仓 `flows/` 是**入库副本**，demo/test 启动时由本仓解析器读取；维护者机器上 java 兄弟目录存在时，启动即**精确镜像**（全量复制 + 删孤儿）同步进本仓。
- 改流程只改 java 编辑源 → 跑一次任意语言 demo/test 触发镜像 → 逐仓 commit `flows/`（禁止只增不删）。

## assignee 解析

| assignee 写法 | 语义 |
|---------------|------|
| `applicant` | 发起人（实例 operator） |
| `u_*` 变量 | 从流程变量解析用户 |
| 内置 handler | 7 个，按 Java 全限定类名注册（applicant / 部门主管×主职 / 表单字段 / 角色取人） |
| `f_*` 表单字段 | 发起表单字段取人（resume 合并变量可达，对齐） |
| 抄送 `f_ccActors` / `tf_ccActors` | 数组/字符串双形态解析（对齐 Go） |
