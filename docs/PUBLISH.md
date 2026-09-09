# mooncakes.io 发版通道（jeeflow-moon，v1.0.0 起）

> 原则：**首次发版失败可重试、tag 可删重打，版本号严禁跳号**（1.0.0 起完整递增，不断号）。
> CI 不跑测试——本地 T0/T1/T2 已验口径不变。

## 凭据（两种通道）

| 通道 | 凭据 | 说明 |
|---|---|---|
| GitHub Actions（推荐） | repo secrets：`MOON_TOKEN` / `MOON_USERNAME` | push tag `v*` 自动触发 `.github/workflows/publish.yml`，按拓扑序 publish 4 模块 |
| 本地手动（**当前主通道**） | `$MOON_HOME/credentials.json`（`{"token":..., "username":...}`，`moon login` 生成） | 按下方顺序手动执行 |

> ⚠️ CI 工具链坑（2026-09-04 首发连挂 5 轮 → 2026-09-05 定位修复；2026-09-09 复测精读后更正）：
> 1. **钉版下载 403**：脚本 host `cli.moonbitlang.com` 对显式版本路径一律 403（`binaries/0.1.20260827/*`
>    与 `cores/core-0.1.20260827.tar.gz` 实测完整 GET 403，响应体为 S3 原生 `AccessDenied`，
>    **服务端持久策略而非 CDN 瞬断**，换浏览器 UA 同样 403），仅 `latest` 别名可装——钉版本号的安装方式
>    在当前服务端策略下不可用。另：`www.moonbitlang.com` 同名路径此前记的「200」是 **Docusaurus 404 页**
>    （28944B HTML "Page Not Found"，latest/显式同内容），**并非产物**，不可作为钉版本通道；
> 2. **9/4 晚的 latest 是坏构建**：含"TOML moon.mod import @版本解析（registry not found）"缺陷，
>    后被官方撤回；2026-09-05 实测 latest 已回到 `0.1.20260827`（d0aaa07，与本地发版工具链同构建）；
> 3. **09-09 latest 前移 `0.1.20260904`**（v0.1.5 两次 attempt 均被当时存在的守卫拦截——工具链
>    下载两次都 100% 成功，失败点纯是版本断言；此前「CDN 403 卡原始 run」为本地复现误判，已推翻）。
> **09-09 策略定调（owner）**：latest 是向前别名、正常只前进（出 bug 也是修完升版本号，不回退），
> 版本守卫会在每次编译器正常更新时永久拦死发版，代价不值——**去掉 `EXPECTED_MOON_VERSION`
> 守卫，装 latest 直接发版**（owner 口径：不强校验版本，若最新编译器把既有代码判错——
> 如 0.1.20260904 的旧式泛型写法 parse error，见 0d23278——本地升级同款编译器复现、
> 按错误信息修/适配后 re-run 即可），install 步保留 `moon version` 输出
> 进 run log 留痕本次实际编译器。原 9/4 事故风险（坏构建上线）由「坏构建会被官方 yank/升版
> 修复」兜住；若真发出版本异常，mooncakes 侧按模块回滚重发（版本号不变）。
> 另加 `validate_only` 手动入参做通道自检（装工具链+依赖+native 构建跳过 publish）。

## 发布拓扑序（依赖向，每次发版固定）

```
core → persist → repository-mysql → facade
```

demo 模块不发布。

## GitHub Actions（推荐路径）

```bash
git push origin master            # 代码先行（本 clone 的 GitHub remote 名为 origin）
git tag v1.0.0 && git push origin v1.0.0   # 触发 publish workflow
```

- 失败重试：Actions 页 Re-run；或本地删 tag 重打（`git tag -d v1.0.0 && git push origin :refs/tags/v1.0.0 && git tag v1.0.0 && git push origin v1.0.0`）。
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
