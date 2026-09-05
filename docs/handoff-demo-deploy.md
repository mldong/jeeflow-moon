# jeeflow-moon demo 上线托管机 · 交接提示词（新会话直接粘贴）

你在 mldong-hub 工作区（G:\mldong-bot\mldong-hub），任务：**把 jeeflow-moon 的 moon demo 容器部署上线到托管机 jeeflow-demo.mldong.com 并打通 /moon-api**。这是 jeeflow MoonBit 引擎（第 7 语言）收尾的最后一步，前面全部已完成。

## 已完成（勿重做）

- jeeflow-moon 仓（github.com/mldong-moon → `git@github.com:mldong/jeeflow-moon.git`，master 已全推，最新 commit 0cc0674）：M0-M5 全链。45 action manifest 与 Java 双向无差集；T0 116 用例 wasm 全绿；T1 MySQL 冒烟 wasm→160 ALL PASS；T2 demo 冒烟 ALL PASS；**mooncakes.io 四模块 0.1.0 已发布**（core/persist/repository-mysql/facade，本地 publish 通道；版本线见 docs/decisions-log.md D-M5-1：平台强制 0.x，放开后首版即 1.0.0 不跳号）。
- jeeflow-ui：/moon-api 代理 + MoonBit Tab + ?lang=moon 分段（commit 3ef8008 **已 push**）。本地联调全通（发起→待办→同意→state=20）。
- jeeflow-doc：文档站已上线 https://jeeflow-doc.mldong.com/languages/moon/（Release workflow 修了漏 checkout jeeflow-moon）。
- mldong-hub：bump-version/release-checklist/sync-schema 已增 moon（f8ea100）；jeeflow-integrations VERSIONS.md 已登记（ad67df7）——这两个 commit 在本地未 push。
- 用户已追认全部代决策（decisions-log D-M0-1..D-M5-1）。

## 当前卡点（唯一未完成）

**✅ 已解决（2026-09-05 接手会话）**：根因是宿主机 docker **18.09.1** 默认 seccomp 白名单拦截 MoonBit native
异步运行时启动期的现代 syscall（EPERM 被吞 → 事件循环永久等待 → 不监听）。定位路径：托管机 A/B 对照
（`--security-opt seccomp=unconfined` 下 health 立即通、默认 seccomp 照旧卡死）+ strace（卡死进程仅纯
`epoll_wait(4,...)` 空转，无重试）+ fd 表（仅 listener socket + eventpoll + 自管道）。修复：workflow
`docker run` 加 `--security-opt seccomp=unconfined`（仅 moon 容器），决策记录 docs/decisions-log.md D-M5-2。
原始排查记录保留如下备查。

---

### 原卡点存档

moon demo 容器化部署，CI workflow `jeeflow-moon/.github/workflows/demo-deploy.yml` 连跑 5 轮修复后：**docker build 成功、镜像 load 到托管机成功、容器 Up（端口 16086→8092），但容器内进程不监听 TCP、docker logs 0 字节、health 超时**。

### 失败演进史（每轮已修，勿重复踩）

1. ubuntu:22.04 缺 git（moon update 克隆 registry index 需要）→ 已加
2. 缺 gcc/libc-dev（moon native 后端要 C 编译器链接；CI runner 自带而容器没有）→ 已加
3. 产物路径：workspace 模式下 moon build 产物在 **_build/** 非 target/ → find 已改双目录兜底
4. 容器缺 flows/ 种子（demo 启动 seed 需要 flows/*.json）→ 已 COPY flows /flows
5. demo 绑定 127.0.0.1 容器外不可达 → 已改 LISTEN_ADDR env 默认 0.0.0.0:8092
6. **当前症状**：容器 Up 稳定（无重启循环），`docker exec ... cat /proc/net/tcp` 只有表头（无 TCP 监听），`/proc/1/wchan` = do_epoll_wait（MoonBit async eventloop 在空转等待），docker logs 0 字节（println 未刷出——非 tty 时 libc 全缓冲，正常）。workdir /app，/flows 存在。

### 最新诊断实验（可能已有结果，先看）

最后一步在托管机跑了：
```bash
ssh jeeflow-doc.mldong.com "docker stop jeeflow-moon-demo; timeout 25 docker run --rm --network host jeeflow-moon-demo:latest 2>&1 | head -8; curl -s -m 4 http://127.0.0.1:8092/health"
```
（--network host 前台直跑，stdout 直通终端）——**结果未及读取**。先重跑这条看输出：
- 若有 "listening" 日志 + host 网络下 health 通 → 问题在 bridge 网络模式（不太可能），或 stdout 缓冲只是表象、真正问题在 -p 端口转发前的绑定——按输出继续定位。
- 若同样卡死无输出 → 进程级问题：怀疑 MoonBit native 后端 async fs（seed_memory 里 @fs.readdir/read_file）在裸容器环境的完成通知机制。验证法：给 main.mbt 加环境变量开关跳过 seed（如 JEEFLOW_DEMO_SKIP_SEED=1 时直接 listen），docker run -e 试；通了则 seed 的 native fs 是根因（可改 seed 为同步预读或在 Dockerfile 里预构建种子 JSON）。

### 其他备选排查方向

1. `docker exec` 进容器 `cat /proc/1/stack`（若内核允许）；`ls -la /proc/1/fd` 看 fd3 socket 类型。
2. 对比 CI：`moon run --target native demo/cmd/main` 在 GitHub runner 是通的（native-probe workflow，run 33935318025 全绿，health JSON 已返回）——**runner 与容器的环境差异**只有：stdout 是否 tty、netns、以及 moon run vs 裸二进制。可在 Dockerfile 临时加 `RUN timeout 8 /usr/local/bin/jeeflow-demo-bin; echo exit=$?` 于构建期复现。
3. 兜底方案 B（绕开 native）：容器内用 wasm 形态——`moon build --target wasm` + moonrun 宿主（apt 装 node 不行，moonrun 在工具链里自带）。rust 形态无需此路，moon 可以：CMD 改 `moonrun <wasm产物>`。wasm 形态本机 T2 已全验证过，行为等价。

## 部署完成后的收尾（必做）

1. nginx /moon-api/ 段**已加好并 reload**（/usr/local/openresty/nginx/site/jeeflow-demo.conf，指向 localhost:16086，备份 .bak-* 在同目录）——容器通了即自动生效，验证：
   `curl -s -X POST https://jeeflow-demo.mldong.com/moon-api/wf/processDefine/page -H 'Content-Type: application/json' -d '{"pageNum":1,"pageSize":2}'`
2. jeeflow-ui 前端：**已触发 Release 并部署完成**（run 33936075412 ✓）——但当时线上验证前端按钮无 MoonBit（旧缓存/构建在 moon-api 未通前？前端构建不依赖后端，若线上仍无 MoonBit Tab，`gh workflow run Release --ref master -R mldong/jeeflow-ui` 重跑一次）。
3. 线上回归：`https://jeeflow-demo.mldong.com/?lang=moon` 走发起→审批链路（与本地联调同矩阵）。
4. 成功后给 demo-deploy.yml 失败史补一条 commit message 或 docs 备注；同步 jeeflow-demo-deploy-plan.md 端口表加 moon 16086 行（G:\mldong-bot\mldong-hub\docs\jeeflow-demo-deploy-plan.md）。

## 关键资源

- 仓：G:\mldong-bot\mldong-hub\jeeflow-hub\jeeflow-moon（remote: origin=github SSH，已全推）
- workflow：.github/workflows/demo-deploy.yml（secrets DEPLOY_HOST/DEPLOY_SSH_KEY 已配置有效——scp/ssh 步骤均成功过）
- 托管机：ssh jeeflow-doc.mldong.com（root，本机 ssh config 已配 GCM）；demo 目录 /java_projects/jeeflow/demo/；nginx /usr/local/openresty/nginx/site/jeeflow-demo.conf（改后 nginx -t && nginx -s reload）
- moon demo 端口 16086（宿主）→ 8092（容器内）；rust 先例 16085→8091（workflow 模板来源 jeeflow-rust/.github/workflows/demo-deploy.yml）
- 本机起 demo 对照：`cd jeeflow-moon && export MOON_HOME=/g/dev-tools/moon PATH=/g/dev-tools/moon/bin:$PATH && moon run --target wasm demo/cmd/main`（:8092）
- 构建目标纪律（红线 R8）：本机一切含 async 的构建/测试用 --target wasm；native 只在 CI/160；绝不改 G:\dev-tools\moon 工具链
- 红线 R4：任何 git push / 对外发布动作已获用户本次授权（本次上线即用户指示"发吧"）；后续新动作 push 前仍需确认

## 环境注意

- Git Bash；moon 调用：`export MOON_HOME=/g/dev-tools/moon PATH=/g/dev-tools/moon/bin:$PATH`
- `moon test --target wasm` 本机可用（116 用例基线）；**勿用 moon test 跑带 socket/fs 的测试**（Windows 挂死，D-M2-2）
- gh CLI 已登录可用；服务器 ssh 用 `ssh jeeflow-doc.mldong.com`（不要用 160 的通道，demo 在另一台托管机）
