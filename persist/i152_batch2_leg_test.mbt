// issues/150 ③／X4 + issues/151 X3 + X5/X6/X8 的分腿测试（v0.1.32 那一批的判据）。
// 夹具全用内存档（InMemoryTableWriter + InMemoryMetaProvider），列匹配这一档由
// `filter_editable` 消费元数据来验；writer 侧（真库 information_schema）的同一条尺子
// 在 demo/cmd/t1_mysql/persist149.mbt 的 T1 腿里验（要真库才看得见真列名）。

///|
/// 本文件的夹具（test 包共享顶层命名空间 ⇒ 名字一律带 b2_ 前缀，不与 persist_test.mbt 撞车）
fn b2_fixture() -> (@persist.InMemoryMetaProvider, @persist.InMemoryTableWriter, @persist.PersistPostInterceptor) {
  let provider = @persist.InMemoryMetaProvider::new()
  let meta = @persist.TableMeta::make("orders", "订单")
  meta.add_field(@persist.FieldMeta::make("process_instance_id", "BIGINT", "流程实例ID"))
  meta.add_field(@persist.FieldMeta::make("apply_user_id", "BIGINT", "申请人"))
  meta.add_field(@persist.FieldMeta::make("merchant_name", "VARCHAR(100)", "商户名"))
  meta.add_field(@persist.FieldMeta::make("amount", "DECIMAL", "金额"))
  meta.add_field(@persist.FieldMeta::make("remark", "VARCHAR(200)", "备注"))
  // ⚠ `tf_` 那一档不是"多一张 tf_ 列"：java `extractFields:200-202` 把 `tf_xxx` 去前缀后
  // 当业务列 `xxx` 写（与 `f_xxx` 同键，谁在变量表里靠后谁胜）。这里给一列只有 tf_ 能写到的
  // `audit_note`，好把 X6 那一档（非任务节点连 tf_ 也不写）钉死。
  meta.add_field(@persist.FieldMeta::make("audit_note", "VARCHAR(200)", "任务档备注"))
  meta.add_field(@persist.FieldMeta::make("apply_10", "INT", "申请节点状态"))
  meta.add_field(@persist.FieldMeta::make("end_20", "INT", "结束定稿状态"))
  provider.register(meta)
  let writer = @persist.InMemoryTableWriter::new()
  (provider, writer, @persist.PersistPostInterceptor::make(provider, writer))
}

///|
/// 一个 SYNC 流程：apply(任务) → notice(记录类 custom) → boss(任务) → end。
/// 三处 persist 触发点各验一档（首次 INSERT／记录类不覆盖／定稿）。
let b2_sync_flow : String = $|{"name": "orders_flow", "displayName": "订单", "type": "approval",
  $|"persistMode": "SYNC", "relTableName": "orders",
  $|"postInterceptors": "com.mldong.jeeflow.persist.interceptor.PersistPostInterceptor",
  $|"nodes": [
  $|  {"id": "apply", "type": "snaker:task", "text": {"value": "A"}},
  $|  {"id": "notice", "type": "snaker:custom", "text": {"value": "N"}, "properties": {"clazz": "x.Y"}},
  $|  {"id": "boss", "type": "snaker:task", "text": {"value": "B"}},
  $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
  $|], "edges": []}

///|
fn b2_exec(
  node_id : String,
  variables : Map[String, Json],
  state~ : Int = 10,
  submit_type~ : Int? = None
) -> @exec.Execution raise {
  let define_info : @model.ProcessDefine = {
    id: 1L,
    name: "p",
    display_name: "P",
    define_type: "approval",
    state: 1,
    content: "{}",
    version: 1,
    create_time: None,
    create_user: None,
    update_time: None,
    update_user: None,
  }
  let model = @parser.parse_model(b2_sync_flow)
  let args = @json.FlowData::new()
  match submit_type {
    Some(st) => args.insert_i64("submitType", st.to_int64())
    None => ()
  }
  let instance = @model.ProcessInstance::create(define_info, "user1", @json.FlowData::new())
  instance.state = state
  for k, v in variables {
    instance.variables.insert(k, v)
  }
  let exec = @exec.Execution::make(instance, model, define_info, "user1", args)
  exec.current_node = model.get_node(node_id)
  exec
}

///|
fn b2_row(writer : @persist.InMemoryTableWriter, exec : @exec.Execution) -> Map[String, Json] {
  writer.get_row_by_key("orders", "process_instance_id", exec.process_instance.instance_id).unwrap()
}

///|
async test "b2 X3: 驼峰表单键落进下划线真列（宽松档），严格档则不落" {
  let (_p, writer, itc) = b2_fixture()
  let vars : Map[String, Json] = Map([])
  vars["f_merchantName"] = @json.string_of("宽松档命中")
  vars["f_amount"] = @json.number_of(66L)
  // ① 宽松档（缺省）：meta 列 merchant_name ← data 键 merchantName
  let exec = b2_exec("apply", vars)
  itc.intercept(exec)
  let r = b2_row(writer, exec)
  assert_eq(cell_of(r.get("merchant_name")), "宽松档命中")
  assert_true(r.get("merchantName") is None) // 落库的键必须是真列名，不是表单驼峰键
  // ② 阳性对照：同一份变量在严格档下不命中 ⇒ 列不落（这正是 X3 之前的默认行为）
  let (_p2, writer2, itc2) = b2_fixture()
  let strict = itc2.with_strict_columns(true)
  let exec2 = b2_exec("apply", vars)
  strict.intercept(exec2)
  let r2 = b2_row(writer2, exec2)
  assert_true(r2.get("merchant_name") is None)
  assert_eq(@json.as_i64(r2.get("amount").unwrap()).unwrap(), 66L) // 逐字对上的列照写
  // ③ 归一函数本体的三档等价（java normalizeColumn：转小写 + 去下划线）
  assert_true(@persist.column_names_equal("merchantName", "merchant_name"))
  assert_true(@persist.column_names_equal("MERCHANT_NAME", "merchant_name"))
  assert_true(!@persist.column_names_equal("merchantName", "merchant_name", strict=true))
  assert_true(@persist.column_names_equal("MerchantName", "merchantName", strict=true))
}

///|
async test "b2 X3: 两键归一到同一列时按 data 插入序第一个胜出（确定性规则）" {
  let keys : Map[String, Json] = Map([])
  keys["merchantName"] = @json.string_of("第一个")
  keys["merchant_name"] = @json.string_of("第二个")
  match @persist.find_data_key(keys, "merchant_name") {
    Some(k) => assert_eq(k, "merchantName")
    None => assert_true(false)
  }
  // 反装顺序 ⇒ 另一个键胜出：规则是"遍历序 + 命中即停"，不是按字典序挑
  let keys2 : Map[String, Json] = Map([])
  keys2["merchant_name"] = @json.string_of("第一个")
  keys2["merchantName"] = @json.string_of("第二个")
  match @persist.find_data_key(keys2, "merchant_name") {
    Some(k) => assert_eq(k, "merchant_name")
    None => assert_true(false)
  }
}

///|
async test "b2 X4: 同链同节点第二次触发不落库，换节点照常" {
  let (_p, writer, itc) = b2_fixture()
  let vars : Map[String, Json] = Map([])
  vars["f_amount"] = @json.number_of(88L)
  let exec = b2_exec("apply", vars)
  itc.intercept(exec)
  assert_eq(@json.as_i64(b2_row(writer, exec).get("amount").unwrap()).unwrap(), 88L)
  // 同一条链里 apply 再触发一次（层①标记挡住）⇒ 变量改了也不写
  exec.process_instance.variables.insert("f_amount", @json.number_of(777L))
  itc.intercept(exec)
  assert_eq(@json.as_i64(b2_row(writer, exec).get("amount").unwrap()).unwrap(), 88L)
  // 换到 boss 节点（不同节点）⇒ 放行，值写进去。这条同时钉住"层①是节点级不是流程级"
  exec.current_node = exec.process_model.get_node("boss")
  itc.intercept(exec)
  assert_eq(@json.as_i64(b2_row(writer, exec).get("amount").unwrap()).unwrap(), 777L)
  // 标记串逐字与 java 同形（__persist_executed_{实例ID}_{节点ID}）
  let key = "__persist_executed_\{exec.process_instance.instance_id}_apply"
  assert_true(exec.args.get(key) is Some(_))
}

///|
async test "b2 X5: 系统列 putIfAbsent／apply_user_id 优先／列名可配／None 禁用" {
  let cfg = @persist.SystemFields::make_default()
  // ① 插入档：业务自带的 create_time / create_user 不被覆写（putIfAbsent）
  let d1 : Map[String, Json] = Map([])
  d1["create_time"] = @json.string_of("2020-01-01 00:00:00")
  d1["apply_user_id"] = @json.number_of(1001L)
  @persist.fill_system_fields_with(cfg, d1, "user9", true)
  assert_eq(cell_of(d1.get("create_time")), "2020-01-01 00:00:00")
  // ② 用户列优先取 apply_user_id（java resolveDefaultUser:231-234），不是 operator
  assert_eq(@json.as_i64(d1.get("create_user").unwrap()), Some(1001L))
  assert_eq(@json.as_i64(d1.get("update_user").unwrap()), Some(1001L))
  // ③ is_deleted 缺省填 0
  assert_eq(@json.as_i64(d1.get("is_deleted").unwrap()), Some(0L))
  // ④ 更新档：update_time 覆写、update_user 仍 putIfAbsent、create_* 不动
  let d2 : Map[String, Json] = Map([])
  d2["update_time"] = @json.string_of("2020-01-01 00:00:00")
  d2["update_user"] = @json.string_of("已有")
  @persist.fill_system_fields_with(cfg, d2, "user9", false)
  assert_true(cell_of(d2.get("update_time")) != "2020-01-01 00:00:00")
  assert_eq(cell_of(d2.get("update_user")), "已有")
  assert_true(d2.get("create_time") is None)
  assert_true(d2.get("is_deleted") is None)
  // ⑤ 列名可配 + None 禁用 + 无操作人回落 default_user_value
  let custom : @persist.SystemFields = {
    create_time_col: Some("add_time"),
    create_user_col: Some("creator"),
    update_time_col: None,
    update_user_col: Some("editor"),
    is_deleted_col: None,
    default_user_value: "robot",
  }
  let d3 : Map[String, Json] = Map([])
  @persist.fill_system_fields_with(custom, d3, "", true)
  assert_true(d3.get("create_time") is None)
  assert_true(d3.get("update_time") is None)
  assert_true(d3.get("is_deleted") is None)
  assert_true(d3.get("add_time") is Some(_))
  assert_true(cell_of(d3.get("add_time")) != "")
  assert_eq(cell_of(d3.get("editor")), "robot")
  assert_eq(cell_of(d3.get("creator")), "robot") // operator 空 + 无 apply_user_id ⇒ 回落
}

///|
async test "b2 X5/X6: 定稿腿只写状态+上下文，业务列（f_ 与 tf_ 两档）都不覆盖" {
  let (_p, writer, itc) = b2_fixture()
  let vars : Map[String, Json] = Map([])
  vars["f_amount"] = @json.number_of(88L)
  vars["f_remark"] = @json.string_of("第一版")
  vars["tf_audit_note"] = @json.string_of("任务档第一版")
  let exec = b2_exec("apply", vars)
  itc.intercept(exec)
  let r1 = b2_row(writer, exec)
  assert_eq(@json.as_i64(r1.get("amount").unwrap()), Some(88L))
  assert_eq(cell_of(r1.get("remark")), "第一版")
  // tf_ 去前缀落业务列（这里只有它能写到 audit_note，故用这列验"任务档确实写"这一半）
  assert_eq(cell_of(r1.get("audit_note")), "任务档第一版")
  assert_eq(@json.as_i64(r1.get("apply_10").unwrap()), Some(10L))
  // 定稿：结束节点 + FINISHED(20)（SYNC 走 update 腿）
  exec.current_node = exec.process_model.get_node("end")
  exec.process_instance.state = 20
  exec.process_instance.variables.insert("f_amount", @json.number_of(999L))
  exec.process_instance.variables.insert("f_remark", @json.string_of("不该覆盖"))
  exec.process_instance.variables.insert("tf_audit_note", @json.string_of("不该覆盖"))
  exec.args.insert_i64("submitType", 1L)
  itc.intercept(exec)
  let r2 = b2_row(writer, exec)
  assert_eq(@json.as_i64(r2.get("amount").unwrap()), Some(88L)) // 非任务节点不写业务字段
  assert_eq(cell_of(r2.get("remark")), "第一版")
  assert_eq(cell_of(r2.get("audit_note")), "任务档第一版") // X6：tf_ 这一档也不再写
  assert_eq(@json.as_i64(r2.get("end_20").unwrap()), Some(20L)) // 定稿状态列写了
}

///|
async test "b2 X8: custom 记录类不是任务节点（不写 f_／tf_，不写 DOING）" {
  let (_p, writer, itc) = b2_fixture()
  let vars : Map[String, Json] = Map([])
  vars["f_amount"] = @json.number_of(88L)
  vars["tf_audit_note"] = @json.string_of("任务档第一版")
  let exec = b2_exec("apply", vars)
  itc.intercept(exec)
  // 记录类节点触发（execPost 在这一档是"节点执行完"，不是"有人办理"）
  exec.current_node = exec.process_model.get_node("notice")
  exec.process_instance.variables.insert("f_amount", @json.number_of(777L))
  exec.process_instance.variables.insert("tf_audit_note", @json.string_of("记录类不该写"))
  itc.intercept(exec)
  let r = b2_row(writer, exec)
  assert_eq(@json.as_i64(r.get("amount").unwrap()), Some(88L)) // 按非任务节点处理 ⇒ 不覆盖
  assert_eq(cell_of(r.get("audit_note")), "任务档第一版") // 上一趟的值仍在
  // 状态列：记录类节点写的是实例当前态（java `:137` 非任务那一支），不是 DOING(10) 专属腿；
  // 本表没有 notice 列 ⇒ 列探测滤掉，不新增状态列（这条同时挡住"给记录类编状态"的走偏）。
  assert_true(r.get("notice") is None)
}
