#!/usr/bin/env bash
# 跑 moon test 并把「条数」当真凭据——不是只看退出码。
#
# 为什么要有这道闸：`moon test` exit 0 只说明"跑起来的那些没红"，不说明"该跑的都在跑"。
# 本仓踩过 wasm-gc 档静默丢弃 async 用例而 exit 0 的形状（引擎方法全链 async，
# 真丢就是丢核心路径），所以权威读数＝聚合行 `Total tests: N, passed: N, failed: 0.` 里的 N。
# N 低于下限＝有用例没被收集 ⇒ 红，哪怕 moon 自己说成功。
#
# 下限为什么取"floor"而不是"== 现值"：换代／加用例都会让 N 前进，钉死等号会让每次
# 正常演进都打断别人；floor 只拦"掉档"。掉到多少算掉档＝改这里（现值见 CI 日志那行读数）。
#
# 用法：bash scripts/test-with-floor.sh <wasm|native> <min>
# 退出码：0＝退出码 0 且 failed=0 且 Total tests ≥ min；非 0＝任一不成立（红因打印在最后一行）。
set -uo pipefail

target="${1:?用法: test-with-floor.sh <wasm|native> <min>}"
min="${2:?缺条数下限}"
command -v moon >/dev/null 2>&1 || {
  echo "FAIL: 找不到 moon（工具链前提不成立，不是本闸的读数）" >&2
  exit 2
}

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
moon test --target "$target" --no-render 2>&1 | tee "$log"
code=${PIPESTATUS[0]}

total="$(sed -n 's/^Total tests: \([0-9][0-9]*\),.*/\1/p' "$log" | tail -1)"
failed="$(sed -n 's/.*, failed: \([0-9][0-9]*\)\..*/\1/p' "$log" | tail -1)"

if [ "$code" -ne 0 ]; then
  echo "FAIL[$target]: moon test 退出码 $code"
  exit 1
fi
if [ -z "$total" ]; then
  echo "FAIL[$target]: 输出里没有 'Total tests:' 聚合行＝没有读数，不能算跑过"
  exit 1
fi
if [ "${failed:-x}" != "0" ]; then
  echo "FAIL[$target]: failed=$failed（非 0）"
  exit 1
fi
if [ "$total" -lt "$min" ]; then
  echo "FAIL[$target]: Total tests=$total < 下限 $min ⇒ 有用例没被收集"
  exit 1
fi
echo "OK[$target]: Total tests=$total failed=0（≥ 下限 $min）"
