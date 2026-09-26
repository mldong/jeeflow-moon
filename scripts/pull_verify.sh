#!/usr/bin/env bash
# 回拉验证（消费者视角，MAINTAINING §3「回拉验证」的执行件）
#
# 在临时目录里新建一个**与本源仓库无关**的工程，只从 mooncakes 注册表装
# mldong/jeeflow-{core,persist,repository-mysql,facade}@<ver>，用发布出去的 API 跑：
#   正向 processInstance/page      ⇒ code=0 + 分页五键
#   负向 processInstance/no_such…  ⇒ code=99999999（出口纪律在发布物里仍然生效）
# 并打印解析到的第三方依赖代次（async/moondb/moonmysql）——发依赖换代那一版时，
# 这一行就是"用户装到的到底是哪一代"的证据。
#
# 为什么不能用 /tmp：MSYS 的 /tmp 与 Windows 侧临时目录不是一个地方（历史坑见 mldong-hub
# 记忆 windows-gitbash-mysql-traps），所以拿 python 的 tempfile 要目录。
#
# 用法：bash scripts/pull_verify.sh [版本号]     # 缺省读 core/moon.mod 的 version
#       KEEP=1 bash scripts/pull_verify.sh       # 保留临时工程供人工复跑
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PY:-$(command -v python || command -v python3)}"
# 版本号从 core/moon.mod 读。**相对路径 + 子 shell 里 cd**：Windows 版 python 看不见
# MSYS 的 /g/... 形状（会 FileNotFoundError），别把 $ROOT 拼进给 python 的参数。
VER="${1:-$(cd "$ROOT" && "$PY" -c "import re;print(re.search(r'^version\\s*=\\s*\"([^\"]+)\"', open('core/moon.mod',encoding='utf-8').read(), re.M).group(1))")}"
MODS="core persist repository-mysql facade"

command -v moon >/dev/null 2>&1 || { echo "!! moon 不在 PATH（本机见 mldong-hub AGENTS.md：MOON_HOME + /g/dev-tools/moon/bin）"; exit 1; }

# 临时目录也要归一成 /c/... 这种 bash 能用的形状：原生 python 给的是 C:\Users\...，
# 直接 cd 会因反斜杠被当字面量而失败（Linux 上这两步替换是空操作）。
WORK="$("$PY" -c "
import tempfile,re
p=tempfile.mkdtemp(prefix='jeeflow-moon-pull-').replace(chr(92),'/')
print(re.sub(r'^([A-Za-z]):', lambda m:'/'+m.group(1).lower(), p))")"
echo "== 临时工程：$WORK"
echo "== 待验版本：$VER"

cleanup() { [ -n "${KEEP:-}" ] || rm -rf "$WORK"; }
trap cleanup EXIT

cd "$WORK"
moon new pv >/dev/null
cd pv
for m in $MODS; do
  moon add "mldong/jeeflow-$m@$VER" >/dev/null
done
moon add moonbitlang/async >/dev/null   # async main 需要模块级声明（否则包级 import 报"global environment"）

mkdir -p cmd/main
cat > cmd/main/moon.pkg <<'PKG'
import {
  "mldong/jeeflow-core/error" @error,
  "mldong/jeeflow-core/id_gen" @id_gen,
  "mldong/jeeflow-core/json" @json,
  "mldong/jeeflow-core/memory" @memory,
  "mldong/jeeflow-core/model" @model,
  "mldong/jeeflow-core/spi" @spi,
  "mldong/jeeflow-facade" @facade,
  "moonbitlang/async",
}

pkgtype(kind: "executable")
PKG

cat > cmd/main/main.mbt <<'MBT'
let user_provider : (String) -> @model.UserInfo? raise @error.JeeflowError = (uid) => Some({
  user_id: uid,
  real_name: "回拉用户\{uid}",
  dept_id: "",
  dept_name: "",
  post_id: "",
  post_name: "",
})

// Json::Number 在新工具链是带 repr~ 的只读类型，不能直接构造 ⇒ 入参一律走 parse_json
fn args_of(s : String) -> Map[String, Json] raise @error.JeeflowError {
  match @json.parse_json(s) {
    Json::Object(m) => m
    _ => abort("入参不是 JSON 对象：\{s}")
  }
}

fn code_of(j : Json) -> Int64 { @json.get_i64(j, "code").unwrap_or(-1L) }

async fn main raise {
  let repo = @memory.MemoryRepository::new()
  let ctx = @spi.Ctx::new(repo, repo)
  let gen = @id_gen.DefaultIdGenerator::new(2L)
  let ctx = ctx.with_id_generator(fn() { gen.next_id() }).with_user_provider(user_provider)
  let f = @facade.Facade::make(ctx)

  let page = f.flow("processInstance/page", args_of("{\"pageNum\":1,\"pageSize\":5}"))
  println("  page 出口: \{@json.stringify(page)}")
  if code_of(page) != 0L { abort("正向失败：processInstance/page code=\{code_of(page)}") }
  match @json.get(page, "data") {
    Some(d) =>
      for k in ["pageNum", "pageSize", "recordCount", "totalPage", "rows"] {
        // 两个臂必须分行写：同行 `None => abort(..) Some(_) => ..` 会 E3002 Parse error
        match @json.get(d, k) {
          None => abort("分页缺键 \{k}")
          Some(_) => ()
        }
      }
    None => abort("page 出口缺 data")
  }

  let bogus = f.flow("processInstance/no_such_action", args_of("{}"))
  println("  未知 action 出口: \{@json.stringify(bogus)}")
  if code_of(bogus) != 99999999L { abort("负向失败：未知 action code=\{code_of(bogus)}，期望 99999999") }

  println("PULL-VERIFY OK（正向 code=0 含分页五键 / 负向 code=99999999）")
}
MBT

moon run cmd/main --target wasm --no-render

echo "== 解析到的第三方代次（用户实际装到的那一代）=="
for p in moonbitlang/async moonbitstack/moondb moonbitstack/moonmysql; do
  v="$("$PY" -c "
import re,sys,os
p=os.path.join('.mooncakes','$p','moon.mod')
print(re.search(r'^version\\s*=\\s*\"([^\"]+)\"', open(p,encoding='utf-8').read(), re.M).group(1) if os.path.exists(p) else '未拉取')")"
  printf '   %-28s %s\n' "$p" "$v"
done
