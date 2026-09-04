# mooncakes.io 发版通道（jeeflow-moon，v1.0.0 起）

> 原则：**首次发版失败可重试、tag 可删重打，版本号严禁跳号**（1.0.0 起完整递增，不断号）。
> CI 不跑测试——本地 T0/T1/T2 已验口径不变。

## 凭据（两种通道）

| 通道 | 凭据 | 说明 |
|---|---|---|
| GitHub Actions（推荐） | repo secrets：`MOON_TOKEN` / `MOON_USERNAME` | push tag `v*` 自动触发 `.github/workflows/publish.yml`，按拓扑序 publish 4 模块 |
| 本地手动（**当前主通道**） | `$MOON_HOME/credentials.json`（`{"token":..., "username":...}`，`moon login` 生成） | 按下方顺序手动执行 |

> ⚠️ CI 工具链坑（2026-09-05 首发实测）：install 脚本对历史版本返回 403（0.1.20260827 已下架），
> 最新版 moon 又无法解析本仓 TOML moon.mod 的 import @版本（registry not found）。
> **CI 通道暂不可用，走本地 publish**；工具链兼容问题待上报 moonbitlang。

## 发布拓扑序（依赖向，每次发版固定）

```
core → persist → repository-mysql → facade
```

demo 模块不发布。

## GitHub Actions（推荐路径）

```bash
git push github master            # 代码先行
git tag v1.0.0 && git push github v1.0.0   # 触发 publish workflow
```

- 失败重试：Actions 页 Re-run；或本地删 tag 重打（`git tag -d v1.0.0 && git push github :refs/tags/v1.0.0 && git tag v1.0.0 && git push github v1.0.0`）。
- 版本号不变（仍 1.0.0），重试 publish 同版本号——mooncakes 对已存在版本会拒绝，
  若部分模块已发成功：仅重发失败模块（workflow 幂等按模块步进），**不要 bump 版本号来绕**。

## 本地手动（兜底）

```bash
export MOON_HOME=/g/dev-tools/moon PATH=/g/dev-tools/moon/bin:$PATH
cd core              && moon publish   # 1. mldong/jeeflow-core
cd ../persist        && moon publish   # 2. mldong/jeeflow-persist
cd ../repository-mysql && moon publish # 3. mldong/jeeflow-repository-mysql
cd ../facade         && moon publish   # 4. mldong/jeeflow-facade
```

## 回拉验证（发版后必做）

```bash
mkdir -p /tmp/pull-verify && cd /tmp/pull-verify
# 新建空模块 import 四包 @1.0.0 → moon install → moon build --target wasm → 冒烟
```

## 发版前 checklist（缺一不包）

1. `moon test --target wasm` 全绿（本地）
2. T1 smoke ALL PASS（连 160；`SKIP_MYSQL=1` 仅限无网开发机，发版机 fail）
3. `bash scripts/smoke_t2.sh` ALL PASS（demo 起着）
4. `node scripts/check-action-manifest.mjs` PASS
5. `consistency/moon.json` 与六语言逐字段比对（固定钟确定化）
6. 四模块 `moon.mod` version 一致且与 tag 一致
