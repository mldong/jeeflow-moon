#!/usr/bin/env bash
# 按模块发布到 mooncakes：**已发过就跳过**，没发过才 publish。
#
# 为什么需要这一层（2026-09-26 v0.1.13 实发事故）：
#   publish.yml 里四个模块是同一条 workflow 顺序跑的，core 刚 publish 完几秒，
#   persist 的"包体校验"要从 registry 解析 `mldong/jeeflow-core@<新版本>`，
#   而**索引还没刷新** ⇒ `Failed to resolve registry dependency … no version satisfies`，
#   整条链卡在 persist；此时 core 已经在注册表里了，重跑又会撞"重复发布"。
#   ⇒ 每步前 `moon update` 拉新索引 + 查索引决定"发还是跳"，让整条链可重入。
#
# 索引布局（moon 0.1.x 实测）：$MOON_HOME/registry/index/user/<user>/<mod>.index，
# 每行一个 JSON 对象，`"name"` 与 `"version"` 在同一行（故可直接整行匹配）。
#
# 用法：publish-if-absent.sh <模块目录> <mooncakes 全名>
set -euo pipefail

dir="$1"
full="$2"                      # 例 mldong/jeeflow-core
user="${full%%/*}"
short="${full##*/}"

ver=$(sed -nE 's/^version = "([^"]+)".*/\1/p' "$dir/moon.mod" | head -1)
[ -n "$ver" ] || { echo "!! $dir/moon.mod 里读不到 version"; exit 1; }

# 上游模块刚发布，索引必须先刷新，否则本模块的包体校验解析不到它
moon update >/dev/null 2>&1 || echo "   （moon update 失败，用现有索引继续）"

idx="$HOME/.moon/registry/index/user/$user/$short.index"
if [ -f "$idx" ] && grep -q "\"name\":\"$full\".*\"version\":\"$ver\"" "$idx"; then
  echo "⏭  $full@$ver 已在注册表 ⇒ 跳过 publish（重入安全）"
  exit 0
fi

echo "📦 publish $full@$ver"
( cd "$dir" && moon publish )

# 失败时把"到底传上去了没"说清楚：mooncakes 对重复版本回 409，而 CLI 退出码不区分
if [ ! -f "$idx" ] || ! grep -q "\"name\":\"$full\".*\"version\":\"$ver\"" "$idx"; then
  moon update >/dev/null 2>&1 || true
  if [ -f "$idx" ] && grep -q "\"name\":\"$full\".*\"version\":\"$ver\"" "$idx"; then
    echo "   ✅ 复核索引：其实已发上去（CLI 报错在上传之后的环节）"
  else
    echo "   ❌ 索引里没有 $full@$ver —— 这次是真没发出去，看上面的 moon publish 输出"
    exit 1
  fi
fi
