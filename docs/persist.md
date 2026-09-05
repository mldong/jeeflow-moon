# 业务数据入库（persist）

> 独立模块 `mldong/jeeflow-persist`：流程运转时把业务数据动态写入业务表，无需业务方手写 SQL。
> 契约见 spec/09（通用入库插件）与 spec/10（元数据驱动动态写入）。

## 装配

```moonbit
let provider = @persist.InMemoryMetaProvider::new()
provider.register(my_table_meta)               // TableMeta：表 / 列 / 字段权限
let interceptor = @persist.PersistPostInterceptor::make(provider, my_writer)
ctx.register_interceptor(interceptor.as_interceptor())   // order=100 后置拦截器
```

- `DynamicTableWriter` 为 trait（写侧 SPI）：`InMemoryMetaProvider` 配内存实现即可跑 T0；
  生产由宿主注入真库 writer（MySQL 仓储线）。
- 流程 JSON 顶层 `"persistMode": "ARCHIVE" | "SYNC"` + `"relTableName": "业务表"` 触发。

## 两种模式

| 模式 | 触发点 | 行为 |
|------|--------|------|
| **ARCHIVE** | 结束 + FINISHED + 同意 | 一次**幂等** INSERT（键 `process_instance_id`，重复到达不重复写） |
| **SYNC** | 发起 / 每任务 / 结束 | 发起 INSERT → 任务 UPDATE（按目标节点 `field.PERMISSION_*` 过滤列）→ 结束定稿 UPDATE |

## 字段权限（PERMISSION_*）

任务节点 `field` 元数据声明 `PERMISSION_<列名>`（数字或字符串双格式键都识别），SYNC 模式
UPDATE 时只写当前办理人对目标节点有权限的列。

## 内建保障

- **幂等键**：ARCHIVE 重复触发不产生重复行。
- **状态列探测**：目标表有/无 `state`、`process_instance_id` 等列时行为对齐 java（探测失败报错传播，不静默）。
- **表名安全检查**：`relTableName` 白名单校验（元数据里注册过的表才允许写）。
- **系统字段**：creator/create_time 等系统列由拦截器统一落（同链重复触发防护）。

## 测试

persist 行为在 T0 覆盖（幂等性/权限键/状态列为**变异验证**——改坏实现测试必须红），
见 [测试指南](./testing.md)。
