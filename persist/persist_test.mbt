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
  let model = @parser.parse_model(model_json)
  let instance = @model.ProcessInstance::create(define_info, "user1", @json.FlowData::new())
  instance.state = state
  for k, v in variables {
    instance.variables.insert(k, v)
  }
  let exec = @exec.Execution::make(instance, model, define_info, "user1", @json.FlowData::new())
  match model.get_node(node_id) {
    Some(n) => exec.current_node = Some(n)
    None => ()
  }
  exec
}

///|
async test "persist: table name safety" {
  assert_true(@persist.is_table_name_safe("expense_record"))
  assert_true(!@persist.is_table_name_safe("wf_process_define"))
  assert_true(!@persist.is_table_name_safe("sys_user"))
  assert_true(!@persist.is_table_name_safe("bad-name"))
  assert_true(!@persist.is_table_name_safe(""))
}

///|
async test "persist: ARCHIVE writes once at end+agree, idempotent by instance (C16)" {
  let (_provider, writer, itc) = make_persist_fixture()
  let flow =
    $|{"name": "p", "displayName": "P", "type": "approval", "persistMode": "ARCHIVE", "relTableName": "expense", "postInterceptors": "com.mldong.jeeflow.persist.interceptor.PersistPostInterceptor",
    $|"nodes": [
    $|  {"id": "apply", "type": "snaker:task", "text": {"value": "A"}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
    $|], "edges": []}
  let vars : Map[String, Json] = Map([])
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
async test "persist: SYNC field permission filters read-only (C19) + state field" {
  let (_provider, writer, itc) = make_persist_fixture()
  // boss 节点声明 field.PERMISSION_f_note=1（只读）→ SYNC 的 UPDATE 腿不写穿 note。
  // apply（发起那一趟）不声明权限：java `:130-131` 让首次 INSERT 恒全量。
  let flow =
    $|{"name": "p", "displayName": "P", "type": "approval", "persistMode": "SYNC", "relTableName": "expense", "postInterceptors": "com.mldong.jeeflow.persist.interceptor.PersistPostInterceptor",
    $|"nodes": [
    $|  {"id": "apply", "type": "snaker:task", "text": {"value": "A"}},
    $|  {"id": "boss", "type": "snaker:task", "text": {"value": "B"},
    $|   "properties": {"field": {"PERMISSION_f_note": 1}}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
    $|], "edges": []}
  let vars : Map[String, Json] = Map([])
  vars["f_note"] = @json.string_of("发起时全量")
  vars["f_amount"] = @json.number_of(88L)
  let exec = make_persist_exec(flow, vars, state=10, node_id="apply")
  itc.intercept(exec)
  let row = writer.get_row_by_key("expense", "process_instance_id", exec.process_instance.instance_id)
  assert_true(row is Some(_))
  let r = row.unwrap()
  // ⚠⚠ 本轮（issues/150 X6）改掉的一条**既有测试期望值**，逐字交代：
  //   旧＝`assert_true(r.get("note") is None)` —— 首次 SYNC 那一趟也按节点权限过滤；
  //   新＝首次那一趟全量写（`note` 落库）。
  //   为什么旧的是错的，而不是实现错了：参考实现 java `PersistPostInterceptor.java:130-131` 传的是
  //     extractFields(instance, !exists ? null : fieldPerm, !exists || taskNode, !exists || taskNode)
  //   即权限过滤只作用于 UPDATE 腿，`!exists`（首次 INSERT＝java 的发起那一趟）恒不接权限。
  //   本仓旧实现连自己的注释（"start 首次 INSERT 例外全量"）都没兑现。
  //   C19「只读不写穿」的原意没有丢：它挪到下面第二趟（UPDATE 腿）钉住，且那才是 java 管的那一档。
  //   入口侧另有 issues/150 ① 的 `filter_args_by_node_permission`（提交值在进变量之前就按当前
  //   任务节点权限滤掉），真流程里只读字段根本进不了实例变量。
  assert_eq(cell_of(r.get("note")), "发起时全量")
  // 可编辑字段正常写入
  assert_eq(@json.as_i64(r.get("amount").unwrap()).unwrap(), 88L)
  // 状态字段 apply_10
  assert_eq(@json.as_i64(r.get("apply_10").unwrap()).unwrap(), 10L)
  // 第二趟＝换到 boss 节点（同一条链、另一个节点 ⇒ 层①标记不挡），该节点声明 note 只读：
  // UPDATE 腿不覆盖 note，可编辑的 amount 照写（C19 在 java 管的这一档成立）
  exec.current_node = exec.process_model.get_node("boss")
  exec.process_instance.variables.insert("f_note", @json.string_of("只读不该覆盖"))
  exec.process_instance.variables.insert("f_amount", @json.number_of(99L))
  itc.intercept(exec)
  let r2 = writer.get_row_by_key(
    "expense", "process_instance_id", exec.process_instance.instance_id
  ).unwrap()
  assert_eq(cell_of(r2.get("note")), "发起时全量")
  assert_eq(@json.as_i64(r2.get("amount").unwrap()).unwrap(), 99L)
}


///|
/// issues/146 缺口二：元数据以 async 端口注入时被谁消费、消费得对不对。
/// 判据三条：① 端口每轮都查（不是装配期快照）——运行期改元数据，下一轮立刻生效；
/// ② 未注册的表按既有语义报 Business；③ 权限过滤读的是端口返回的那份 meta。
fn cell_of(v : Json?) -> String {
  match v {
    Some(Json::String(s)) => s
    _ => "<非字符串>"
  }
}

async test "persist: 动态元数据端口 async 消费（改表结构免重启生效）" {
  let tables : Ref[Map[String, @persist.TableMeta]] = Ref(Map([]))
  let loads : Ref[Int] = Ref(0)
  let mk_meta = fn(note_permission : Int, with_extra : Bool) -> @persist.TableMeta {
    let m = @persist.TableMeta::make("expense", "报销")
    m.add_field(@persist.FieldMeta::make("process_instance_id", "BIGINT", "流程实例ID"))
    m.add_field(@persist.FieldMeta::make("amount", "DECIMAL", "金额"))
    if with_extra {
      let x = @persist.FieldMeta::make("extra", "VARCHAR(64)", "改后新增列")
      m.add_field(x)
    }
    let note = @persist.FieldMeta::make("note", "VARCHAR(200)", "备注")
    note.permission = note_permission
    m.add_field(note)
    m
  }
  tables.val["expense"] = mk_meta(2, false) // 首轮：note 可编辑
  let port : @persist.DynamicMetaProviderFns = {
    load_table_meta: async fn(name : String) raise @error.JeeflowError {
      loads.val += 1
      match tables.val.get(name) {
        Some(m) => Some(m)
        None => raise @error.Business("表元数据不存在: \{name}")
      }
    },
  }
  let writer = @persist.InMemoryTableWriter::new()
  let itc = @persist.PersistPostInterceptor::make_from_provider(port, writer)
  let flow =
    $|{"name": "p", "displayName": "P", "type": "approval", "persistMode": "SYNC", "relTableName": "expense", "postInterceptors": "com.mldong.jeeflow.persist.interceptor.PersistPostInterceptor",
    $|"nodes": [
    $|  {"id": "apply", "type": "snaker:task", "text": {"value": "A"}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
    $|], "edges": []}
  let vars : Map[String, Json] = Map([])
  vars["f_note"] = @json.string_of("第一版可见")
  vars["f_amount"] = @json.number_of(7L)
  let e1 = make_persist_exec(flow, vars, state=10, node_id="apply")
  itc.intercept(e1)
  let r1 = writer.get_row_by_key("expense", "process_instance_id", e1.process_instance.instance_id).unwrap()
  assert_true(r1.get("note") is Some(_)) // 元数据说可编辑 ⇒ 写穿
  // 运行期改元数据：note 转只读 + 新增 extra 列。夹具里两轮共用同一个实例键（走 upsert），
  // 所以判据是"新列写得进、被转只读的列不再被覆盖"——装配期快照的写法两样都做不到。
  tables.val["expense"] = mk_meta(1, true)
  let vars2 : Map[String, Json] = Map([])
  vars2["f_note"] = @json.string_of("改后不该覆盖")
  vars2["f_extra"] = @json.string_of("改后新增列可见")
  vars2["f_amount"] = @json.number_of(9L)
  let e2 = make_persist_exec(flow, vars2, state=10, node_id="apply")
  itc.intercept(e2)
  let r2 = writer.get_row_by_key("expense", "process_instance_id", e2.process_instance.instance_id).unwrap()
  assert_eq(cell_of(r2.get("extra")), "改后新增列可见") // 端口每轮现查 ⇒ 运行期新增列立刻生效
  assert_eq(cell_of(r2.get("note")), "第一版可见") // 转只读后不再被覆盖
  assert_eq(@json.as_i64(r2.get("amount").unwrap()).unwrap(), 9L)
  assert_true(loads.val >= 2) // 两轮各查一次，不是一次性预载
  // 负向：端口里没有的表 ⇒ 走引擎既有语义（Business），不静默建半行
  let ghost_flow =
    $|{"name": "p", "displayName": "P", "type": "approval", "persistMode": "SYNC", "relTableName": "no_such_table", "postInterceptors": "com.mldong.jeeflow.persist.interceptor.PersistPostInterceptor",
    $|"nodes": [
    $|  {"id": "apply", "type": "snaker:task", "text": {"value": "A"}},
    $|  {"id": "end", "type": "snaker:end", "text": {"value": "E"}}
    $|], "edges": []}
  let gv : Map[String, Json] = Map([])
  gv["f_amount"] = @json.number_of(1L)
  let e3 = make_persist_exec(ghost_flow, gv, state=10, node_id="apply")
  let raised_business = try {
    itc.intercept(e3)
    false
  } catch {
    @error.Business(_) => true
    _ => false
  }
  assert_true(raised_business)
}

