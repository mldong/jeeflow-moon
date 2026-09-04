// persist ARCHIVE/SYNC/权限/幂等 测试（C16/C19）

// ── persist ──

///|
fn make_persist_fixture() -> (@persist.InMemoryMetaProvider, @persist.InMemoryTableWriter, @persist.PersistPostInterceptor) {
  let provider = @persist.InMemoryMetaProvider::new()
  let meta = @persist.TableMeta::make("expense", "报销")
  meta.add_field(@persist.FieldMeta::make("process_instance_id", "BIGINT", "流程实例ID"))
  meta.add_field(@persist.FieldMeta::make("apply_user_id", "VARCHAR(64)", "申请人"))
  meta.add_field(@persist.FieldMeta::make("note", "VARCHAR(200)", "备注"))
  meta.add_field(@persist.FieldMeta::make("amount", "DECIMAL", "金额"))
  meta.add_field(@persist.FieldMeta::make("apply_10", "INT", "申请节点状态"))
  meta.add_field(@persist.FieldMeta::make("readonly_col", "VARCHAR(50)", "只读"))
  provider.register(meta)
  let writer = @persist.InMemoryTableWriter::new()
  (provider, writer, @persist.PersistPostInterceptor::make(provider, writer))
}

///|
fn make_persist_exec(model_json : String, variables : Map[String, Json], state~ : Int = 10, node_id~ : String = "apply") -> @exec.Execution raise {
  let define : @model.ProcessDefine = {
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
  let model = @parser.parse_model(model_json)
  let instance = @model.ProcessInstance::create(define, "user1", @json.FlowData::new())
  instance.state = state
  for k, v in variables {
    instance.variables.insert(k, v)
  }
  let exec = @exec.Execution::make(instance, model, define, "user1", @json.FlowData::new())
  match model.get_node(node_id) {
    Some(n) => exec.current_node = Some(n)
    None => ()
  }
  exec
}

///|
test "persist: table name safety" {
  assert_true(@persist.is_table_name_safe("expense_record"))
  assert_true(!@persist.is_table_name_safe("wf_process_define"))
  assert_true(!@persist.is_table_name_safe("sys_user"))
  assert_true(!@persist.is_table_name_safe("bad-name"))
  assert_true(!@persist.is_table_name_safe(""))
}

///|
test "persist: ARCHIVE writes once at end+agree, idempotent by instance (C16)" {
  let (_provider, writer, itc) = make_persist_fixture()
  let flow =
    $|{"name": "p", "displayName": "P", "type": "approval", "persistMode": "ARCHIVE", "relTableName": "expense",
    $|"nodes": [
    $|  {"id": "apply", "type": "snaker:task", "text": {"value": "A"}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
    $|], "edges": []}
  let vars : Map[String, Json] = Map::new()
  vars["f_note"] = @json.string_of("差旅")
  vars["f_amount"] = @json.number_of(100L)
  // 结束节点 + FINISHED + submitType=1 → INSERT
  let exec = make_persist_exec(flow, vars, state=20, node_id="end")
  exec.args.insert_i64("submitType", 1L)
  itc.intercept(exec)
  assert_true(writer.get_row_by_key("expense", "process_instance_id", exec.process_instance.instance_id) is Some(_))
  // 重放（跨请求重放/双触发）→ 幂等不再插入
  itc.intercept(exec)
  assert_eq(writer.get_table_rows("expense").length(), 1)
}

///|
test "persist: SYNC field permission filters read-only (C19) + state field" {
  let (_provider, writer, itc) = make_persist_fixture()
  // apply 节点 field.PERMISSION_note=1（只读）→ SYNC 任务节点不写 note
  let flow =
    $|{"name": "p", "displayName": "P", "type": "approval", "persistMode": "SYNC", "relTableName": "expense",
    $|"nodes": [
    $|  {"id": "apply", "type": "snaker:task", "text": {"value": "A"},
    $|   "properties": {"field": {"PERMISSION_f_note": 1}}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
    $|], "edges": []}
  let vars : Map[String, Json] = Map::new()
  vars["f_note"] = @json.string_of("应被过滤")
  vars["f_amount"] = @json.number_of(88L)
  let exec = make_persist_exec(flow, vars, state=10, node_id="apply")
  itc.intercept(exec)
  let row = writer.get_row_by_key("expense", "process_instance_id", exec.process_instance.instance_id)
  assert_true(row is Some(_))
  let r = row.unwrap()
  // 只读字段不写穿（权限过滤，C19）
  assert_true(r.get("note") is None)
  // 可编辑字段正常写入
  assert_eq(@json.as_i64(r.get("amount").unwrap()).unwrap(), 88L)
  // 状态字段 apply_10
  assert_eq(@json.as_i64(r.get("apply_10").unwrap()).unwrap(), 10L)
}
