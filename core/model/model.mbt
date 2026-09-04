// jeeflow-core/model —— M1 移植自 rust jeeflow-core/src/model.rs（1076 行）
// 8 枚举：DefineState/InstanceState/TaskState/TaskType/PerformType/CountersignType/SubmitType(+FilterOp)
// 8 聚合根/行模型：ProcessDefine/ProcessInstance/ProcessTask/ProcessDesign/ProcessDesignHis/ProcessSurrogate/CcInstance/TaskActor
// 分页与用户：PageQuery/PageResult[T]/QueryFilter/TaskRow/InstanceRow/DefineRow/UserInfo
// 契约锚点：方案 §4 C1–C3（id 双收/字符串化）、C22（分页五键）
