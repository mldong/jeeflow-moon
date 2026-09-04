#!/usr/bin/env bash
# T2 demo 冒烟（对标 php smoke_test.php）：全链路 发起→待办→办理→完成→高亮→stats
# 前置：demo 已启动（moon run --target wasm demo/cmd/main，:8092）
set -e
BASE=${BASE:-http://127.0.0.1:8092}
B=$BASE/wf
jqf() { python -c "import json,sys; d=json.load(sys.stdin); $1"; }

echo "[1] health"
curl -s -m 5 "$BASE/health" | grep -q '"status":"ok"' && echo "  ok"

echo "[2] 发起 01-simple（applicant）"
IID=$(curl -s -m 5 -X POST "$B/processDefine/startAndExecute" -d '{"processDefineId":1,"operator":"applicant"}' | jqf "print(d['data']['processInstanceId'])")
[ -n "$IID" ] && echo "  instanceId=$IID"

echo "[3] leader 待办"
TASK=$(curl -s -m 5 -X POST "$B/processTask/todoList" -d '{"operator":"leader"}' | jqf "
rows=[r for r in d['data']['rows'] if r['processInstanceId']=='$IID']
print(rows[0]['id'] if rows else '')")
[ -n "$TASK" ] && echo "  taskId=$TASK"

echo "[4] leader 同意"
curl -s -m 5 -X POST "$B/processTask/execute" -d "{\"processTaskId\":$TASK,\"operator\":\"leader\",\"submitType\":1}" | grep -q '"code":0' && echo "  ok"

echo "[5] 实例 state=20"
curl -s -m 5 -X POST "$B/processInstance/detail" -d "{\"id\":$IID}" | jqf "assert d['data']['state']==20; print('  ok state=20')"

echo "[6] 高亮"
curl -s -m 5 -X POST "$B/processInstance/highLight" -d "{\"id\":$IID}" | grep -q '"nodeProgress"' && echo "  ok"

echo "[7] 未知 action → 99999999"
curl -s -m 5 -X POST "$B/nonsense" -d '{}' | grep -q '"code":99999999' && echo "  ok"

echo "T2 SMOKE ALL PASS (instanceId=$IID)"
