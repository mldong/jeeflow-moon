# jeeflow-moon 文档

> jeeflow 引擎的 **MoonBit 实现**——联邦第七个成员，对齐 Java 参考实现的行为语义：同一份 15 个 LogicFlow 共享流程、同一 `99999999` 错误信封、同一分页五键、同一状态机。
> 本目录（`docs/`）只放**用户文档**，并同步到 [jeeflow-doc 文档站语言指南](https://jeeflow-doc.mldong.com/languages/moon/)。

## 引擎定位

- **模块拆分**：`core`（引擎核心，仅 MoonBit 标准库，运行时零 registry 依赖）/ `facade`（40+ action 统一门面 + 出口契约层 + stats）/ `persist`（业务数据动态入库 ARCHIVE/SYNC）/ `repository-mysql`（纯 MoonBit 线上协议 MySQL 仓储 + 真事务模板）。`demo` 不发布（:8092 演示服务）。
- **发布通道**：mooncakes.io（`mldong/jeeflow-core` 等四模块，拓扑序 core → persist → repository-mysql → facade）。mooncakes 早期阶段强制 `0.x`（平台放开后首个版本即 1.0.0，不断号）。
- **当前版本**：以各模块 `moon.mod` 与 [CHANGELOG](./CHANGELOG.md) 为准（独立 0.x 线；活文档不手写版本号，防每次发版漂移）
- **全异步架构**：仓储 SPI / 引擎 / 门面全 `async fn`，单一事件循环零嵌套——MoonBit 无 `block_on`，其它语言的"同步 SPI + 桥接"形态在此不可移植。

## SDK 集成

| 文档 | 内容 |
|------|------|
| [快速开始（SDK 集成）](./getting-started.md) | 工具链安装、mooncakes 安装、最小装配、MySQL 仓储 |
| [引擎 API](./engine-api.md) | 40+ action 分组、出口契约层、会签门控、事件、stats |
| [流程定义格式](./flow-definition.md) | LogicFlow JSON、共享 flows、persistMode |
| [SPI 实现指南](./spi-guide.md) | 全异步 SPI 清单、Ctx 注册、MoonBit 特有注意点 |
| [业务数据入库（persist）](./persist.md) | ARCHIVE/SYNC、字段权限、表名安全 |
| [集成指南（工程向）](./integration.md) | 宿主应用嵌入要点（与 getting-started 互补） |
| [演示站（Demo）](./demo.md) | :8092 本地 demo、公网 `/moon-api`、T2 冒烟 |

## 相关

- **版本历史**：[CHANGELOG](./CHANGELOG.md)（0.1.0 起，独立 0.x 线完整递增）
- **引擎规范（契约唯一事实来源）**：[规范总览](https://jeeflow-doc.mldong.com/spec/)（01 数据模型 ~ 08 合规测试）
- **设计原理 / 通用指南**：[jeeflow-doc 文档站](https://jeeflow-doc.mldong.com/)
- **维护者向**（工具链口径 / T0–T2 测试 / 发版通道 / 设计决策 / 契约对照）：仓根 `MAINTAINING.md`（不入本目录、不上文档站）
