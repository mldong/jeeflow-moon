// 合规场景 c23–c31（issues/94 会签门控 + 08 全链 + jump 注入 + resume 表单分配人）+ submitType 矩阵

///|
async test "c23: parallel soft reject (submitType=20)" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "cs-parallel-soft", load_flow("05-countersign-parallel"))
  let iid = start_and_apply(engine, repo, did)
  let user_a = find_doing_for(repo, iid, "userA")
  let args = new_args()
  args.insert_i64("submitType", 20L)
  let _ = engine.execute_task_async(user_a.task_id, "userA", args)
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 10)
  let doing = repo.find_doing_tasks(iid, [])
  assert_eq(doing.length(), 2)
  assert_eq(inst.variables.get_str("countersignDisagreeFlag").unwrap(), "1")
  let all_tasks = repo.find_history_tasks(iid)
  for t in all_tasks {
    if t.actor_ids.contains("userA") {
      assert_eq(t.variables.get_str("countersignDisagreeFlag").unwrap(), "1")
    }
  }
}

///|
async test "c24: one vote veto finishes instance" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "cs-one-vote-veto", load_flow("13-countersign-one-vote-veto"))
  let iid = start_and_apply(engine, repo, did)
  let user_a = find_doing_for(repo, iid, "userA")
  let args = new_args()
  args.insert_i64("submitType", 20L)
  let _ = engine.execute_task_async(user_a.task_id, "userA", args)
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 20)
  let all_tasks = repo.find_history_tasks(iid)
  for t in all_tasks {
    if t.actor_ids.contains("userB") || t.actor_ids.contains("userC") {
      assert_eq(t.task_state, 99)
    }
    if t.actor_ids.contains("userA") {
      assert_eq(t.task_state, 20)
    }
  }
  assert_eq(inst.variables.get_str("countersignDisagreeFlag").unwrap(), "1")
}

///|
async test "c25: ratio expression merges at 2/4" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "cs-ratio", load_flow("07-countersign-ratio"))
  let iid = start_and_apply(engine, repo, did)
  let user_a = find_doing_for(repo, iid, "userA")
  let _ = engine.execute_task_async(user_a.task_id, "userA", new_args())
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 10)
  let doing = repo.find_doing_tasks(iid, [])
  assert_eq(doing.length(), 3)
  let user_b = find_doing_for(repo, iid, "userB")
  let _ = engine.execute_task_async(user_b.task_id, "userB", new_args())
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 20)
  let all_tasks = repo.find_history_tasks(iid)
  let mut abandon_count = 0
  for t in all_tasks {
    if t.task_state == 99 {
      abandon_count = abandon_count + 1
    }
  }
  assert_eq(abandon_count, 2)
}

///|
async test "c26: soft reject follow-up completes normally" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "cs-soft-followup", load_flow("05-countersign-parallel"))
  let iid = start_and_apply(engine, repo, did)
  let user_a = find_doing_for(repo, iid, "userA")
  let args = new_args()
  args.insert_i64("submitType", 20L)
  let _ = engine.execute_task_async(user_a.task_id, "userA", args)
  let user_b = find_doing_for(repo, iid, "userB")
  let _ = engine.execute_task_async(user_b.task_id, "userB", new_args())
  let user_c = find_doing_for(repo, iid, "userC")
  let _ = engine.execute_task_async(user_c.task_id, "userC", new_args())
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 20)
}

///|
async test "c27: executing abandoned task fails (negative)" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "cs-abandon-neg", load_flow("13-countersign-one-vote-veto"))
  let iid = start_and_apply(engine, repo, did)
  let user_a = find_doing_for(repo, iid, "userA")
  let user_b = find_doing_for(repo, iid, "userB")
  let user_b_id = user_b.task_id
  let args = new_args()
  args.insert_i64("submitType", 20L)
  let _ = engine.execute_task_async(user_a.task_id, "userA", args)
  let outcome = try? engine.execute_task_async(user_b_id, "userB", new_args())
  assert_true(outcome is Err(_))
}

///|
async test "c28: 08 full chain hard assertions (#94 round 2)" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "cs-seq-08", load_flow("08-countersign-sequential-approve"))
  let iid = start_and_apply(engine, repo, did)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 1)
  assert_true(tasks[0].actor_ids == ["userA"])
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 10)
  let user_a = find_doing_for(repo, iid, "userA")
  let _ = engine.execute_task_async(user_a.task_id, "userA", new_args())
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 1)
  assert_true(tasks[0].actor_ids == ["userB"])
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 10)
  let user_b = find_doing_for(repo, iid, "userB")
  let _ = engine.execute_task_async(user_b.task_id, "userB", new_args())
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 1)
  assert_true(tasks[0].actor_ids == ["leader"])
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 10)
  let leader = find_doing_for(repo, iid, "leader")
  let _ = engine.execute_task_async(leader.task_id, "leader", new_args())
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 0)
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 20)
}

///|
async test "c29: jump to end injects flag (no countersign gate on jump)" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "cs-jump-flag", load_flow("13-countersign-one-vote-veto"))
  let iid = start_and_apply(engine, repo, did)
  let user_a = find_doing_for(repo, iid, "userA")
  let args = new_args()
  args.insert_i64("submitType", 20L)
  let _ = engine.execute_and_jump_to_end_async(user_a.task_id, "userA", args)
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 45)
  assert_eq(inst.variables.get_str("countersignDisagreeFlag").unwrap(), "1")
  let all_tasks = repo.find_history_tasks(iid)
  for t in all_tasks {
    if t.task_id == user_a.task_id {
      assert_eq(t.variables.get_str("countersignDisagreeFlag").unwrap(), "1")
    }
  }
}

///|
test "c30: parse_cc_actors three shapes" {
  let arr = @json.array_of([@json.string_of("2086772715431137280"), @json.string_of("1686404946814533633")])
  let out = @engine.parse_cc_actors(Some(arr))
  assert_true(out == ["2086772715431137280", "1686404946814533633"])
  let s = @json.string_of(" u1 , u2 ,, ")
  let out2 = @engine.parse_cc_actors(Some(s))
  assert_true(out2 == ["u1", "u2"])
  assert_true(@engine.parse_cc_actors(None).is_empty())
  assert_true(@engine.parse_cc_actors(Some(@json.null_json())).is_empty())
  assert_true(@engine.parse_cc_actors(Some(@json.empty_array())).is_empty())
  assert_true(@engine.parse_cc_actors(Some(@json.string_of("  "))).is_empty())
}

///|
async test "c31: form field assignee on resume (L3 S11-B)" {
  let repo = @mem.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.AtomicIdGenerator::new(1L)
  let ctx2 = ctx.with_id_generator(fn() { gen.next_id() }).with_user_provider(compliance_user_provider)
  // 注册 7 内置 handler（rust register_builtin_assignment_handlers 同款）
  let base : @itl.OrgAssignBase = { user: Some(compliance_user_provider), org: None }
  ctx2.register_assignment_handler(
    "com.mldong.jeeflow.interceptor.impl.OperatorAssignmentHandler",
    @itl.operator_assignment_handler(),
  )
  ctx2.register_assignment_handler(
    "com.mldong.jeeflow.interceptor.impl.FormFieldAssigneeHandler",
    @itl.form_field_assignee_handler(),
  )
  let engine = @engine.Engine::make(ctx2)
  let flow = $|  {"name": "s11b", "displayName": "S11B", "type": "approval",
$|   "nodes": [
$|     {"id": "start", "type": "snaker:start", "text": {"value": "Start"}},
$|     {"id": "apply", "type": "snaker:task", "text": {"value": "Apply"},
$|      "properties": {"assignee": "applicant"}},
$|     {"id": "approver", "type": "snaker:task", "text": {"value": "Approver"},
$|      "properties": {"assignmentHandler": "com.mldong.jeeflow.interceptor.impl.FormFieldAssigneeHandler"}},
$|     {"id": "end", "type": "snaker:end", "text": {"value": "End"}}
$|   ],
$|   "edges": [
$|     {"id": "e1", "sourceNodeId": "start", "targetNodeId": "apply"},
$|     {"id": "e2", "sourceNodeId": "apply", "targetNodeId": "approver"},
$|     {"id": "e3", "sourceNodeId": "approver", "targetNodeId": "end"}
$|   ]}
$|  
  let did = save_flow_define(repo, "s11b", flow)
  let args = new_args()
  args.insert_str("f_approver", "u0011")
  let inst = engine.start_async(did, "applicant", args)
  let tasks = repo.find_doing_tasks(inst.instance_id, [])
  for t in tasks {
    if t.actor_ids.contains("applicant") {
      let _ = engine.execute_task_async(t.task_id, "applicant", new_args())
      break
    }
  }
  let after = repo.find_doing_tasks(inst.instance_id, [])
  let mut has_u0011 = false
  for t in after {
    if t.actor_ids.contains("u0011") {
      has_u0011 = true
    }
  }
  assert_true(has_u0011)
}

// ── submitType 8 值矩阵（每值 ≥1 正向 + 关键负向；引擎路径级）──

///|
test "submitType matrix: from_code 8 values + invalid" {
  assert_eq(@model.SubmitType::from_code(0L).unwrap() is Apply, true)
  assert_eq(@model.SubmitType::from_code(1L).unwrap() is Agree, true)
  assert_eq(@model.SubmitType::from_code(2L).unwrap() is Reject, true)
  assert_eq(@model.SubmitType::from_code(3L).unwrap() is Rollback, true)
  assert_eq(@model.SubmitType::from_code(4L).unwrap() is Jump, true)
  assert_eq(@model.SubmitType::from_code(5L).unwrap() is ReApply, true)
  assert_eq(@model.SubmitType::from_code(6L).unwrap() is RollbackToOperator, true)
  assert_eq(@model.SubmitType::from_code(20L).unwrap() is CountersignDisagree, true)
  assert_true(@model.SubmitType::from_code(99L) is None)
}

///|
async test "submitType 2: reject → jump to end, state=45" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "st2", load_flow("01-simple"))
  let iid = start_and_apply(engine, repo, did)
  let task = find_doing_for(repo, iid, "leader")
  let _ = engine.execute_and_jump_to_end_async(task.task_id, "leader", new_args())
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 45)
}

///|
async test "submitType 3/6: rollback → first task node re-created for initiator" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "st3", load_flow("02-multi-task"))
  let iid = start_and_apply(engine, repo, did)
  let leader = find_doing_for(repo, iid, "leader")
  let _ = engine.execute_task_async(leader.task_id, "leader", new_args())
  // manager 处 submitType=3 退回上一步（首任务节点 = apply → 重新给 applicant）
  let manager = find_doing_for(repo, iid, "manager")
  let _ = engine.execute_and_jump_async(manager.task_id, "manager", new_args(), None)
  let tasks = repo.find_doing_tasks(iid, [])
  assert_true(!tasks.is_empty())
  assert_true(tasks[0].actor_ids.contains("applicant"))
}

///|
async test "submitType 4: jump to named task node" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "st4", load_flow("02-multi-task"))
  let iid = start_and_apply(engine, repo, did)
  let leader = find_doing_for(repo, iid, "leader")
  let _ = engine.execute_and_jump_async(leader.task_id, "leader", new_args(), Some("task3"))
  let tasks = repo.find_doing_tasks(iid, [])
  assert_eq(tasks.length(), 1)
  assert_true(tasks[0].actor_ids.contains("boss"))
}

///|
async test "submitType 0/1/5: plain execute default path" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "st105", load_flow("02-multi-task"))
  let iid = start_and_apply(engine, repo, did)
  let leader = find_doing_for(repo, iid, "leader")
  let args = new_args()
  args.insert_i64("submitType", 0L)
  let _ = engine.execute_task_async(leader.task_id, "leader", args)
  let manager = find_doing_for(repo, iid, "manager")
  let args = new_args()
  args.insert_i64("submitType", 1L)
  let _ = engine.execute_task_async(manager.task_id, "manager", args)
  let boss = find_doing_for(repo, iid, "boss")
  let args = new_args()
  args.insert_i64("submitType", 5L)
  let _ = engine.execute_task_async(boss.task_id, "boss", args)
  let inst = repo.find_instance_by_id(iid).unwrap()
  assert_eq(inst.state, 20)
}

///|
async test "submitType negative: non-actor execute rejected (99999999 path)" {
  let (engine, repo) = make_compliance_engine()
  let did = save_flow_define(repo, "stneg", load_flow("01-simple"))
  let iid = start_and_apply(engine, repo, did)
  let task = find_doing_for(repo, iid, "leader")
  let outcome = try? engine.execute_task_async(task.task_id, "intruder", new_args())
  match outcome {
    Ok(_) => assert_true(false)
    Err(e) => assert_eq(e.code(), @error.ERR_BUSINESS)
  }
}
