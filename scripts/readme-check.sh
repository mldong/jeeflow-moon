#!/usr/bin/env bash
# README 围栏块门禁（包面腿的机器侧复现）：
#   1. 只按各模块 README 页面自己给的 `moon add` 清单装依赖（闸不自备依赖，否则测不到安装面）；
#   2. 把 README 里标了 `// cmd/main/<file>` 的程序块逐字抽进临时工程编译，
#      块后面紧跟的那段无语言围栏＝期望 stdout，逐行比对；
#   3. 顺带守 ⑨：每模块目录里必须有 LICENSE，且 README 的许可链接包内可达。
#
# 用法（仓根或任意目录皆可，脚本自己定位仓根）：
#   bash scripts/readme-check.sh                 # 四件已发布模块全跑（注册表面）
#   bash scripts/readme-check.sh facade persist   # 只跑指定模块
#   README_CHECK_WORK=/path/to/dir bash scripts/readme-check.sh   # 固定落点（默认 mktemp -d）
#   README_CHECK_MODE=local  bash scripts/readme-check.sh        # 工作树表面（见下）
#
# 两种表面（缺哪个都有一类问题看不见，所以两条腿都要挂）：
#   registry（默认）＝按页面给的 `moon add` 从注册表装已发布代次 ⇒ 验的是包面用户抄得到什么；
#   local＝在临时目录写一份 moon.work，把本仓四个模块目录挂成 workspace 成员 ⇒ 同一份示例
#          解析到**工作树源码**（本轮实测：成员命中后 `moon add` 仍写注册表 pin，但符号取自本地，
#          往本地副本加一个 `pub fn` 立刻可见）⇒ 验的是"这次提交要不要连带改 README"。
#
# 带 `// @readme-check: needs-env VAR` 的程序块：VAR 未设⇒只编译不运行（打 SKIP 读数），
# 设了⇒真跑并比对输出（repository-mysql 那一块要真 MySQL，CI 没有库，走编译档）。
#
# 退出码：0＝全部通过；非 0＝至少一格红（红因原样打印，别只看最后一行）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULES=("$@")
if [ ${#MODULES[@]} -eq 0 ]; then
  MODULES=(core persist repository-mysql facade)
fi
WORK="${README_CHECK_WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
MODE="${README_CHECK_MODE:-registry}"
# moon.work 的成员路径交给 moon 本体，Windows 上不吃 MSYS 的 /g/ 形式 ⇒ 取原生路径
ROOT_NATIVE="$(cd "$ROOT" && (pwd -W 2>/dev/null || pwd))"

# Windows 上 `python3` 常是商店占位 stub（command -v 找得到、跑起来啥也不输出）⇒ 用一条真指令验活
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 &&
      [ "$("$cand" -c 'import sys;sys.stdout.write("ok")' 2>/dev/null)" = "ok" ]; then
      PY="$cand"
      break
    fi
  done
fi
[ -n "$PY" ] || {
  echo "FAIL: 找不到可用的 python（README 解析腿的前提不成立，不是本闸的读数）" >&2
  exit 2
}
command -v moon >/dev/null 2>&1 || {
  echo "FAIL: 找不到 moon（工具链前提不成立，不是本闸的读数）" >&2
  exit 2
}

rc=0
echo "== readme-check：$($PY --version 2>&1) / $(moon version --all 2>&1 | head -1 | tr -d '\r') / 表面=$MODE =="

for mod in "${MODULES[@]}"; do
  readme="$ROOT/$mod/README.md"
  echo
  echo "── $mod ─────────────────────────────────────────"

  # ⑨ 的包内许可：LICENSE 文件在不在、README 里的许可链接指不指得到包内可达路径
  if [ ! -s "$mod/LICENSE" ]; then
    echo "FAIL[$mod]: 发布目录里没有 LICENSE（包面拿不到许可全文）"
    rc=1
  fi
  if [ -f "$readme" ] && grep -q "](\.\./LICENSE)" "$readme"; then
    echo "FAIL[$mod]: README 里还有 ../LICENSE（发布包根＝模块目录，那是死链）"
    rc=1
  fi

  d="$WORK/$mod"
  rm -rf "$d"
  mkdir -p "$d"
  PYTHONIOENCODING=utf-8 "$PY" "$ROOT/scripts/readme_extract.py" "$readme" "$d" || {
    echo "FAIL[$mod]: README 里没有可编译的 cmd/main 程序块（页面没教怎么跑）"
    rc=1
    continue
  }
  echo "  安装清单（页面原文）: $(tr '\n' ' ' <"$d/install.txt" | tr -d '\r')"

  proj="$d/proj"
  (
    set -e
    cd "$WORK/$mod"
    if [ "$MODE" = local ]; then
      {
        printf 'members = [\n  "./proj",\n'
        for m in core persist repository-mysql facade; do
          printf '  "%s",\n' "$ROOT_NATIVE/$m"
        done
        printf ']\n'
      } > moon.work
    fi
    moon new proj >/dev/null 2>&1
    cd proj
    rm -f proj.mbt proj_test.mbt proj_wbtest.mbt
    printf 'pub fn placeholder() -> Unit {}\n' > proj.mbt
    mkdir -p cmd/main
    while IFS= read -r spec; do
      [ -n "$spec" ] || continue
      echo "  \$ moon add $spec"
      moon add "$spec" >/dev/null
    done <"$d/install.txt"
    cp "$d/files/moon.pkg" cmd/main/moon.pkg
    cp "$d/files/main.mbt" cmd/main/main.mbt
  ) || {
    echo "FAIL[$mod]: 工程装配失败（多半是页面给的 moon add 清单不够或写错）"
    rc=1
    continue
  }

  needs_env=""
  [ -f "$d/needs_env" ] && needs_env="$(tr -d '\r\n' <"$d/needs_env")"
  run=1
  if [ -n "$needs_env" ] && [ -z "${!needs_env:-}" ]; then
    run=0
    echo "  SKIP run: 该块声明 needs-env $needs_env，当前未设⇒只编译"
  fi

  out="$d/stdout.txt"
  err="$d/stderr.txt"
  if [ "$run" -eq 1 ]; then
    (cd "$proj" && moon run --target wasm cmd/main) >"$out" 2>"$err"
  else
    (cd "$proj" && moon check --target wasm) >"$out" 2>"$err"
  fi
  code=$?
  if [ $code -ne 0 ]; then
    echo "FAIL[$mod]: 页面给的程序跑不起来（exit $code）"
    sed -n '1,25p' "$err" | tr -d '\r' | sed 's/^/    | /'
    rc=1
    continue
  fi
  if grep -q "Warning:" "$err"; then
    echo "FAIL[$mod]: 页面给的程序带告警（新手第一次抄就会看到它）"
    sed -n '1,15p' "$err" | tr -d '\r' | sed 's/^/    | /'
    rc=1
    continue
  fi

  if [ "$run" -eq 1 ] && [ -f "$d/expected.txt" ]; then
    if diff -u "$d/expected.txt" "$out" >"$d/diff.txt" 2>&1; then
      echo "  OK: 编译＋运行＋输出逐行对上页面（$(wc -l <"$out" | tr -d ' ') 行）"
    else
      echo "FAIL[$mod]: 实际输出与页面写的不一样"
      sed -n '1,20p' "$d/diff.txt" | tr -d '\r' | sed 's/^/    | /'
      rc=1
    fi
  else
    echo "  OK: 编译通过（$([ "$run" -eq 1 ] && echo '无期望输出块，未比对' || echo 'needs-env 未满足，未运行')）"
  fi
done

echo
echo "== 工作目录留在 $WORK （自己决定何时清）=="
[ $rc -eq 0 ] && echo "README-CHECK OK（${#MODULES[@]} 件模块：安装清单＋围栏块＋许可）"
exit $rc
