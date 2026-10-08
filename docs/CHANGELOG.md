# CHANGELOG

## 0.1.30（2026-10-08）

**issues/149：`DynamicTableWriter` 六法 async 化 ＋ `MysqlTableWriter` 真库实现 ⇒ persist 业务表写在本栈有落点，且能与 `wf_*` 同事务。**
四模块同号（core / persist / repository-mysql / facade）；**依赖面有一处新增**（见"依赖与发布"）。

- 病灶：`persist/persist.mbt` 六法是**同步** trait 方法，而本栈写真库只有 moonmysql 的 async 连接一条路
  （同步函数里发查询判 `Error: [4149]`），全仓又只有 `persist/writer_mem.mbt` 一支内存实现
  ⇒ `spec/12` §12.2「集成层若启用了 persist，那张业务表的写也在同一事务内」这一条在本栈**连可执行形状都没有**。
- 承重前提本轮先实测再动形（案 §4 原记"未实测"）：`async` 只需写在 **trait 声明**上；
  `pub impl Trait for T with fn …` 处**不重复写 async**（写了反而判 parse error），
  所以 `InMemoryTableWriter` 六支 impl 一字未改仍编译，`persist/interceptor.mbt` 六处
  `&DynamicTableWriter` 调用点也不需要 `?` 或 `await`——**`&Trait` 动态分派 async 方法成立**。
  唯一跟着改的是全仓唯一一个"在同步函数里调 writer"的位点 `put_state_field` → `async fn`。
  参照系＝同仓生产件 `core/spi/repository.mbt` 的 `ProcessRepository`（async trait ＋ repository-mysql 真库实现），
  所以这不是新发明的形状；案 §4 担心的"破坏性契约改动"实测不成立。
- 列探测归属裁决：**`columns()` 留在 writer**，只加 async，不并入 146 的 `DynamicMetaProviderFns`——
  参考实现 java `jeeflow-persist/.../DynamicTableWriter.java:20` 的 `filterColumns` 本就挂在 writer 上，
  `IDynamicMetaProvider` 管字段权限/显示元数据，两者在 java 并存 ⇒ 本栈现状即对齐，不留第二套元数据端口。
- 新实现 `repository-mysql/repo/persist_writer.mbt`：`MysqlTableWriter` **握调用方的 `MysqlRepository` 实例**，
  走它现成的 `open_or_tx()/close_conn()` ⇒ `execute_in_tx` 回调里业务表写与四张 `wf_*` 同连接同事务
  （直接复用 issues/144 定下的"句柄随实例走"，不自建第二套事务机制）；
  `MysqlTableWriter::detached()` 另起空事务槽＝每句自取连接 autocommit，**只作阳性对照夹具**，不是装配口。
  标识符只围 `information_schema` 取回的真列名、表名过 `is_table_name_safe`，值一律占位符；
  I_S 查询钉小写别名 `cname`（MySQL 8 列标签返大写那条已知坑）。
- 案 §5 四档真机读数（160 MySQL，`moon run --target wasm demo/cmd/t1_mysql`）：
  F149A ARCHIVE 一次（办结前零行→办结后恰一行、note/amount/apply_user_id 逐列反查、
  元数据里有而表里没有的 `ghost_col` 被真列探测剔除）；
  F149B SYNC 一次（发起 INSERT、办结仍是同一行⇒走 `update_by_key` 而非重复插入、`update_user` 变经办人、
  状态列 `task1_10` 经列探测落库）；
  F149C 覆盖面档（事务内**沿事务连接**读得到刚写的业务行＝非空转，中途抛错后 `wf_*` 与业务表双双零残留）；
  F149D 阳性对照（只把 writer 换成 `detached`、动作与判据一字不改 ⇒ 业务行活过回滚，
  证明 F149C 的判据在坏形状下真会报红）。
- 一处语义读数值得记下：归档行的 `create_user` 是**办结人**而不是发起人——ARCHIVE 的触发点就是办结那一次动作，
  引擎把当次 `exec.operator` 交给 `fill_system_fields`；java 侧 `fillSystemFields(data, insert)` 不带 user 形参、
  取环境当前用户，同一档。发起人由上下文列 `apply_user_id` 承载（C17 回落）。
- 内存实现三支（persist T0）**不回退**：`moon test --target wasm` 406/406 与改前同数。
- 依赖与发布：`repository-mysql` 与 `demo` 各新增一枚 `mldong/jeeflow-persist` 依赖 ⇒ 接力 import pin
  由 **7 枚变 9 枚**（persist 1 / repository-mysql 2 / facade 2 / demo 4），`bump-version.sh` 改不到它们；
  拓扑序不变（core → persist → repository-mysql → facade），新边落在序内。
- 栈内门禁：`moon check` 0 errors / 37 warnings（**零新增**，基线未漂）；
  T0 406/406；T1 `repository-mysql/smoke` ALL PASS；T1-F `demo/cmd/t1_mysql` ALL PASS。

## 0.1.29（2026-10-08）

**issues/148：委托 `enabled` 写侧归一——脏值落 0 建单，不再抛成 `99999999 非法id: abc`。四模块同号（core / persist / repository-mysql / facade）；无破坏性 API 变化（消费方零改动）。**

- 判据出处：`spec/06-facade.md` §4.5 条款 4「`enabled` 读写两侧分别定」——写侧**键缺失 ⇒ 1**、
  `"abc"` / `""` / `"1x"` / JSON null 等**不可解析 ⇒ 0 且不得抛**（条款点名的反例正是"toInt 直接抛"，
  即 Node 首版把门面打成 500 那种形状）；读侧仍**只有整数 1 生效**（issues/130 拍定，本轮未动）。
- 参考实现逐字对照 Java `JeeflowFacade.java:1557-1560`（`enabledArg == null ? 1 : toInt(enabledArg, 0)`），
  且 13 个集成壳对 `enabled` 零命中 ⇒ 这条归一属**引擎门面**职责，不该由宿主/壳兜。
- 施工面：`facade/actions_ext.mbt` 新增 `surrogate_enabled_arg`，`processSurrogate/save` 新建臂与
  `apply_surrogate_fields`（update 臂）共用；update 臂因此不再需要 raise 注解。
- ⚠ 改了**一条既有测试的期望值**（`facade/surrogate_autoapply_test.mbt`）：原断言"脏 enabled 必须被门面拒绝建单"，
  与条款 4 选的机制（落 0）相反；现改为"建单成功"，紧随其后的"脏值委托不产生任何待办"原样保留，防护意图未削。
  新增 `facade/surrogate_enabled_test.mbt` 两支黑盒用例（脏值档不抛且不并入、缺省与串化 `'1'` 档都=1 且都并入）。
- 栈内验证：`moon check` 0 errors；`moon test --target wasm` **406/406**；facade 包摘新件 102 / 带新件 104。
- 触发场景：mldong-moon（第 14 栈）进「13 栈同一套」工作流门禁，L2-18 写侧那腿（`runner.py` 载荷
  `enabled:"abc"`，跨栈 13 栈同一份，其余各栈都要求建单成功并回读 0）。

## 0.1.28（2026-10-07）

**issues/146：供数/回调族 SPI 全量 async 化 ＋ 动态表元数据端口 ＋ 事件监听器 async（站内信落点成立）。**
四模块同号待发（core / persist / repository-mysql / facade）；**有破坏性 API 变化**（见"破坏面"）。

- **缺口一（主线）**：`IUserProvider`、`IOrgUserProvider`（三法）、`IUserSearchProvider`（两法）、
  `biz_data_reader` 由同步闭包改 **async 闭包** ⇒ 宿主在闭包里现场查库。立法判据不是"java 那边签名
  同不同步"，而是"这一档 SPI 的真实现要不要做宿主 I/O"：moon 栈查库只有 async 一条路
  （moonmysql/moondb 全 async），同步形状等于逼集成方启动期快照——mldong-moon 插件 v1 的
  "41 用户预载进内存 Map、重启前新人看不见"就是这么被迫的（hub 报告 §10）。java 侧 provider 签名同步
  是 JVM 线程模型的产物、注入的是 Spring bean 现场查库；规范钉"宿主供数"这个行为，不钉签名形状
  （与 issues/145 同口径：各语言自定机制）。
  同批 async 化（同一判据）：拦截器 pre/post、assignment/decision/custom handler、事件监听器。
  **保持同步**（纯计算，异步化纯属折腾调用方）：`json_provider`、`expression_evaluator`、
  `id_generator`、`action_permission_provider`。
- **`*_sync` 便捷口**：`with_user_provider_sync` / `with_org_user_provider_sync` /
  `with_user_search_provider_sync` / `with_biz_data_reader_sync` / `register_event_listener_sync` /
  `register_interceptor_sync` / `register_assignment|decision|custom_handler_sync`，内部统一经
  `@spi.async_of_sync` 桥。存在理由＝本栈编译器把"标 async 但体内无 await"判 `unused_async`、
  把"只传播不 raise"的 raise 标注判 `unused_error_type`，且**没有可摘的抑制属性**（实测）：
  逐点写空转 async 会淹没警告闸，集中到一处桥后注册点零警告。
- **缺口二**：`persist` 增 `DynamicMetaProviderFns`（`load_table_meta : async (String) -> TableMeta?
  raise JeeflowError`）＋ `InMemoryMetaProvider::as_provider()` ＋
  `PersistPostInterceptor::make_from_provider(...)`，消费点 `load_meta` 每轮现查。
  **端口放在 persist 不放 core Ctx**：java 的 `IDynamicMetaProvider` 就定义在
  `jeeflow-persist/meta/`，消费点是 MetaTableWriter/Reader；core 里没有任何代码需要表元数据，
  挂到 Ctx 就是零消费者的死端口（案文"core/spi 增端口"是位置猜测，此处按参照实现的真实归属更正）。
- **缺口三**：监听器形状改 async、错误集从开放 `raise` 折成闭集 `raise @error.JeeflowError`
  ⇒ 监听器可 await 写库＝站内信这类写型副作用第一次有了落点。
  ⚠ **案文更正**：moon 引擎"无事件分发机制"不准确——9 支码、逐监听器兜底、列表广播、落库后 fire
  早在 issues/132 那轮就在（`core/event/event.mbt` + `core/engine/notify_events.mbt`）；
  真病灶是监听器同步 ⇒ 写不了库。时序口径：门面级没有事务模板包住整轮写（真库逐条 autocommit），
  故"落库后"与 boot4 的 afterCommit 在本栈等价；一旦引擎侧引入事务模板（issues/145 各栈欠账），
  fire 必须挪到 COMMIT 之后，T1-F 的 F146E 判据同步换。
- **破坏面**：`Ctx::with_user_provider` / `with_org_user_provider` / `with_user_search_provider` /
  `with_biz_data_reader` / `register_event_listener` / `register_interceptor(_pre)` /
  三类 handler 注册与 `find_*` 返回形状全变；`InterceptorFn.run` 变 async；
  `PersistPostInterceptor` 字段 `meta_provider` → `meta : DynamicMetaProviderFns`。
  现读消费者只有 mldong-moon 的 jeeflow 插件与本仓 demo/夹具，均已随版改完。
- **门禁读数（本轮现跑，wasm）**：`moon check --target wasm` **0 error**（87 tasks）；
  `moon test --target wasm` **Total tests: 404, passed: 404, failed: 0**；
  T1 `moon run --target wasm repository-mysql/smoke`（160 真库）**ALL PASS**；
  T1-F `moon run --target wasm demo/cmd/t1_mysql`（160 真库）**155 PASS ALL PASS**，含本轮新增两支：
  **F146** 供数 async——运行期新插入的用户行免重启即被解析（缺口一验收判据）+ 查无此人 None 不炸发起；
  **F146E** async 监听器 INSERT 进真库，码 1/3/2 三支从库里 `GROUP_CONCAT` 读回（缺口三落点成立）；
  T0 新增 **`persist: 动态元数据端口 async 消费`**（运行期改列权限/新增列 ⇒ 下一轮生效，缺口二）。
- **警告归因**（本仓闸门的口径是"0 error ＋ 涨了要归因"）：22 → 37。
  +8 `unused_error_type`＝只传播不 raise 的 async 支（7 支 `notify_*` + `@event.notify`）必须带闭集
  raise 标注，否则错误集塌成开放 `Error` 并外溢到调用方（实测 E4118 全在这条上）；
  +7 `unused_async`＝三条桥 + 内存实现的空转 async 闭包（MoonBit 无抑制属性）。
  新增来源已写进 `docs/spi-guide.md`「纯内存实现的便捷口」，后续轮次以此为基线。

## 0.1.27（2026-10-06）

**issues/144：事务句柄从进程级全局槽改挂仓储实例，并把"一个请求＝一个实例"做成有通道可走。**
四模块同号重发（core / persist / repository-mysql / facade，5 version ＋ 7 pin），demo 不发布。
本轮**有破坏性 API 变化**（见下"破坏面"），但 `execute_in_tx` 现读零生产调用点 ⇒ 实际受害者只有 smoke/T1-F。

- **病灶**（`repository-mysql/repo/tx.mbt` 原形状）：`let tx_conn : Ref[MysqlConn?]` 是**进程级**槽，
  `in_tx()` 判的是"进程里有没有事务"。本栈单线程事件循环 + 无 task-local ⇒ 并发请求在 await 点交错时
  互相看见对方的槽：B 进模板既不 BEGIN 也不 COMMIT、写并进 A 的事务；A 抛错回滚时
  **把 B 已经返回给调用方的确认写入一起抹掉**（案文 §2 X2，160 真库实测 `has400=0`）。
  头注释那句"环境连接即上下文绑定，对齐 contextvars/ALS"是误导源——那两者 task-scoped，全局 `Ref` 不是。
- **落地形态（owner 拍方案 b）**：`MysqlRepository` 加实例字段 `tx : Ref[(@client.MysqlConn?)]`，
  `open_or_tx`/`tx_active`/`current_tx_conn`/`close_conn` 一律读 `self`；`new_request()` 派生请求级实例
  （同 config、独立槽）；`execute_in_tx(op)` 上提到仓储实例并把**绑定后的实例**交给回调
  （这样"用错实例而静默走 autocommit"没有通道）；`MysqlTxTemplate` 保留为 spec/05 的命名位、改为持 repo 委派。
  **SPI 42 个方法签名零改动**——不选"每次仓储调用传句柄"那条的原因：那是动 spec/05 的八语言一致契约。
- **配套新增 `Ctx::for_request(repository, ext_repository)`**（core）：本栈结构体是**引用语义**
  （实测 `let b = a` 后写 `b` 的可变字段改到 `a`；`Map`/`Array` 赋值共享底层），而既有 `with_*` 全是
  "原地改 `self` 再返回 `self`" ⇒ 若照那个样式加 `with_repository`，请求 A 换的仓储全进程可见＝144 换载体重演。
  `for_request` 因此**新建注册表**、六个容器字段逐个 `copy()`，而闭包字段（尤其 `id_generator`）**按引用共享**——
  雪花 `worker_id` 固定、`sequence` 每毫秒归零，每请求新建生成器会在同一毫秒撞出同一个 id ⇒ 主键冲突。
  纪律随之立死：SPI 注册只允许启动期做。
- **⚠ 破坏面（三处）**：① `MysqlTxTemplate::make(MysqlConfig)` → `make(MysqlRepository)`；
  ② 自由函数 `current_tx_conn()` / `close_conn(conn)` → 仓储实例方法（`close_conn` 转私有；
  仓外 22 处 `@repo.close_conn(X)` 改 `X.close()`，顺带修掉"事务态下误关裸连接"的旧隐患）；
  ③ `pub(all) struct MysqlRepository` 多一个字段 ⇒ 外部用字面量 `MysqlRepository::{ config }` 构造者编译失败。
  现读**代码侧零消费者**（全生态唯一命中是一处文档提法：mldong-moon `doc/layering.md` §5 那句
  "参照 jeeflow-moon `MysqlTxTemplate`"，本轮已按修后形状改写；`moon-token` 四模块不依赖本仓）
  ⇒ 无实际受害者，但形状已破，按实写。
- **模板回调的错误集从闭集放开成开放 `raise`**（`execute_in_tx` 与 `MysqlTxTemplate` 同步）：
  本栈 `async fn` 不带 `raise` 注解即被推成开放效应，而 `Facade::flow` 正是这种形状 ⇒
  闭集签名下宿主**压根没法把一次门面动作包进事务**（编译期 4014/4118 直接拒）。
  模板对"抛什么错"本就不该挑：任何错都回滚、原样外抛。
- **钉出来的现状缺陷（不是本轮修）**：`Facade::flow` 把 raise 吞成 `{code,msg,data}` 信封 ⇒
  **宿主外包事务时动作内部失败不会触发回滚**，半完成实例照旧 `COMMIT`。已写成 `T1-F122` 反题桩（钉现状不是认可），
  契约侧对应 hub `jeeflow-doc/docs/spec/12-transaction.md` §12.2「宿主外包事务的两条硬义务」。
- **判据**（事务这件事第一次有行为门禁；判据本体在 spec/12 §12.4，各栈用自己的机制去过）：
  仓储级 `M6` 并发原子／`M7` 嵌套不重复 BEGIN／`M8` 归属边界两方向（T1）；
  门面级 `T1-F120` 原子档（四张表逐个反查 ＋ "不包事务就有残留"的阳性对照）／`T1-F121` 空转档
  （事务内写→同实例读得到、`new_request()` 另起连接读不到、回滚后无残留）／`T1-F122` 反题桩；
  `Ctx::for_request` 的三句 T0 判据。**三枚变异对照**都在副本树跑：去掉容器 `copy()` → T0 红；
  `repository` 改 mut＋原地改 → T0 红（这两枚恰是"最像现有 `with_*` 风格"的写法）；
  把 `open_or_tx` 改成每句自取连接（模拟 145-1 的 Java 空转形状）→ `T1-F120` 原子档当场红
  ⇒ **空转档抓得住别家栈的形状，不是只能抓自家**。
- **本版门禁**（2026-10-06 同窗现跑，台账旧读数不采信；真库走 160/`jeeflow` ＋ i137a 腿自建隔离库跑完 DROP）：
  T0 `moon test --target wasm` **403/403**（402→403，新增 `for_request` 那一格）；
  T1 `repository-mysql/smoke` **111→124 断言** ALL PASS；T1-F `demo/cmd/t1_mysql` **130→141 断言** ALL PASS；
  i137a 真库腿 ALL PASS；T2 `scripts/smoke_t2.sh` **ALL PASS**（demo 起着，:8092）；
  `check-action-manifest.mjs` **47/47 双向无差集**；`consistency/moon.json` **载荷逐字节等值**（本轮零行为变化面）；
  警告按两棵干净树（`git clone` HEAD ＋ 现树副本，各自清 `_build`）同窗对比 **21→21 同分布零新增**
  ——中途 +1 条 `deprecated_syntax`（回调闭包缺显式 `raise` 注解），补注解后归零。
  ⚠ 数警告不许用 `moon check --all`：**本机工具链无此 flag**，命令直接 Usage 报错而 grep 数到 0，是假绿灯。
  demo 另做本机 wasm 真跑（`JEEFLOW_DEMO_STORE=mysql`，两个 F 的变量名会被忽略并打警告）：
  `/health` 回 `store=mysql`、四次真实发起全 `code=0`、实例 id 跨请求递增（证明确实共享 id 生成器）。
- **发布链终局**（三条通道同打在 tag `v0.1.27`＝`c3a204b` 上）：publish run `37429601910` 四步
  `Publish core / persist / repository-mysql / facade` 逐步 `success`（`Validate channel only` 按预期 skipped
  ⇒ 判发布看 job steps 不看 workflow 总结论）；`moon update` 后注册表索引四件末行全 `"version":"0.1.27"`；
  消费者视角 `bash scripts/pull_verify.sh 0.1.27` ⇒ `PULL-VERIFY OK`，装到的那三代依赖为
  `async 0.22.4 / moondb 0.2.0 / moonmysql 0.7.3`；Demo Deploy run `37429601852`（check/test 双档各
  `Total tests: 403, passed: 403, failed: 0` → 镜像构建/上传/装载重启 → 服务端 `T2 SMOKE ALL PASS`）；
  sync-cn run `37429602025` success。三笔实现 commit `631ac5c`／`fda5ef5`／`c3a204b` 逐个
  `git merge-base --is-ancestor … v0.1.27` 为真——"已落地"与"已发版"是两个状态，后者要 tag 祖先证明。

- **未做**（hub `jeeflow-hub/issues/145` 的 145-6 保留）：引擎/门面自身**零接线**（`core/`＋`facade/` 内
  `execute_in_tx|for_request` 零命中，原子性目前依赖宿主外包并按 spec/12 检查出口 code）；
  SPI 的 `InterceptorFn.run`／`event_listeners`／`DynamicTableWriter` 全是**同步**形状，
  而同步函数调 async 判 4149 ⇒ 本栈拦截器与监听器碰不到数据库，"业务规则与流程同事务"缺的是 SPI async 形状
  （跨栈立法，不随本版做）。native 档 Windows 结构性编不了（R8），native 验证归 CI。

## 0.1.26（2026-10-02）

**摘掉 vendored——上游 `moonbitstack/moonmysql@0.7.3` 把 client 的 wasm 放开了。** 代次从 0.1.25 前进一格，
四模块（core / persist / repository-mysql / facade）同号重发，接力 import pin 同步（5 version＋7 pin）。
本轮**零行为变化**：改动本身是把一份"本仓拷贝"换回它对应的那份注册表原件。

- **代码侧只有 2 行 ＋ 一次删目录**（`3f3928f`）：
  `repository-mysql/moon.mod` pin `moonbitstack/moonmysql@0.7.2 → @0.7.3`（全仓唯一声明处）；
  `repo/moon.pkg` 的 import 由本仓 `vendored/moon_mysql_client` 改指 `"moonbitstack/moonmysql/client" @client`
  ——**别名不变** ⇒ `repo/conn.mbt`（5 处）/`repo/repository.mbt`（2 处）/`repo/tx.mbt`（3 处）
  里那 10 处 `@client.MysqlConn` 一个字都没改；
  `repository-mysql/vendored/moon_mysql_client/` 整目录删除，**净删 703 行 / 24.4 KB**
  （`conn.mbt` 547＋`driver.mbt` 134＋`extend_driver.mbt` 7＋`moon.pkg` 15）。
  其中 `extend_driver.mbt` 是**必须一并删**的那枚：本仓当年因 `implicit_impl_as_method` 弃办、
  又受"逐字节原样拷贝"纪律约束不能改 vendored，才另立这 7 行 `pub extend MysqlDriver with @moondb.Driver::{…}`；
  上游 0.7.2 起已把同一条声明写进 `client/driver.mbt` 尾部 12 行，留着就是重复 extend。
- **vendoring 的理由消失**：§4 **D-M0-2 作废、由 D-M0-2′ 取代**。上游 2026-10-01 10:47 UTC 把
  `client/moon.pkg` 的 `supported_targets` 从 `"native"` 改成 `"+native+wasm"`。摘前逐字节核过同源：
  vendored `conn.mbt` 与 0.7.3 那份**完全相同**，`driver.mbt` = 上游那份减去尾部 extend 块；
  0.7.2→0.7.3 的包体差异只有 `client/moon.pkg` 一行＋根 `moon.pkg`/`README.md` 文案，**`.mbt` 零差异**
  ⇒ 真机门禁在这里是回归判据而不是变化判据。
- **顺带结掉一条历史欠账**：MAINTAINING §1 挂着的那条"**混代是真的**"（vendored client 拷自 0.4.0、
  registry codec 已到 0.7.2，两者同跑而 `moon check` 测不到，判据只能落在真机协议路径）从此不成立——
  client 与 codec 同源同代。戒律换形而不撤销：**以后每次 bump moonmysql 都是 client＋codec 一起动**，
  T1 仓储级与 T1-F 门面级必须在同一窗口跑，报告里写清消费的 moonmysql 代次。
- **不在支持面（别把这次解锁读错）**：browser wasm 仍不支持——上游 README 写明 wasm 执行需 host 提供
  TCP socket 绑定（moonrun 实测过）。本仓 T1 口径一字不变：`--target wasm` + moonrun → 160:3306。
- **本版门禁**（2026-10-02 真仓改前/改后同窗口背靠背，moon 0.1.20260920 / moonc v0.10.14，
  真库用专用库 `jeeflow_moon_t1`）：`moon check --target wasm --no-render` **0 error**，
  警告按 `[E码] 类别` 分组的**指纹与改前 diff 为空**（22 条：E0053×10 E0020×4 E0024×4 E0027×2 E0002×1 E0067×1）；
  T0 `moon test --target wasm` **402/402**（与改前同数）；T1 **111 断言** `T1 ALL PASS (wasm → 160)`；
  T1-F **130 断言** `T1-F ALL PASS`；**i137a 真库腿 ALL PASS**（该腿是 10-02 `e271d77` 才立的，
  方案文档写它时还没有，本轮补跑；隔离库 `jeeflow_moon_i137a` 自建自删）；
  `consistency` 载荷**等值**；T2 `smoke_t2.sh` **7/7**（demo 起 :8092，`/health` 身份指纹
  `{"engine":"jeeflow-moon","store":"memory"}`，测完按 PID 杀干净）。
  native 档 Windows 结构性编不了（R8），native 验证归 CI。
- **一条目标号纠偏（给下一轮看）**：立项文档 `jeeflow-hub/docs/moon-摘vendored-moonmysql0.7.3-方案.md`
  写的是 `bump-version.sh 0.1.25`，而 0.1.25 已在 10-02 05:53 被批三（issues/137）发掉——registry 索引
  四件 `created_at=2026-10-02T05:53`、HEAD `529846a` 即那笔 bump commit 且与远程 `0 0`。照抄必然 409，
  更阴的是 `pull_verify.sh 0.1.25` 会回拉到**摘 vendored 之前**那一代还全绿，把物证做成假证。⇒ 本轮 0.1.26。
- **发布链终局（2026-10-02，UTC 10:46–10:49 实测留痕）**：bump commit `810d381`（12 处＝5 version＋7 pin）
  上打轻量 tag `v0.1.26` ⇒ master 快进 `529846a..810d381` ＋ **单 tag 推**（严禁 `--tags` 全量推）。
  **publish** run `36997325872`：`Publish core / persist / repository-mysql / facade` **逐步 success**
  （判发布看 job steps，不看 workflow 总结论）。`moon update` 后注册表索引四件末行全 `0.1.26`
  （created_at 10:46:48 / 10:46:53 / 10:46:57 / 10:47:01），**其中 `jeeflow-repository-mysql` 的 deps
  已写成 `moonbitstack/moonmysql: 0.7.3`**——摘 vendored 在发布元数据层留了名。
  消费者侧 `bash scripts/pull_verify.sh 0.1.26` ⇒ `PULL-VERIFY OK`（正向 `processInstance/page` `code=0`
  含分页五键；负向 `processInstance/no_such_action` `code=99999999`），并打印"用户实际装到的那一代"：
  `async 0.22.4 / moondb 0.2.0 / moonmysql 0.7.3`——这一行就是本轮的物证。
  **Demo Deploy** run `36997325910` success：镜像由不再 vendored 的 tag 重建，落到 160 后
  服务端 `T2 SMOKE ALL PASS (instanceId=2105973316048134144)` ＋ `✅ Moon demo deployed (port 16086->8092)`
  ⇒ 方案 §6 决策点 C（演示站要不要换代）随 tag 的自动通道一并兑现，不需要另触发。
  **sync-cn** run `36997325879` success ⇒ Gitee/GitCode 同步到同一代次。

## 0.1.25（2026-10-02）· **本节为补记**

> 补记说明：0.1.25 发版当时**没有写 CHANGELOG**，本节是 10-02 随 0.1.26 轮回头补的。
> 内容与读数不靠回忆——进版清单按 `git log v0.1.24..v0.1.25` 逐笔核（12 笔＝11 进版＋1 bump，
> 34 files +2624/−57），发布链读数按 `gh` 现查 run id 与 `moon update` 后的注册表索引，
> 门禁读数有两处互证：该轮 bump commit 里留痕的现跑读数，与本轮（0.1.26）**改前基线在同一棵树上独立复现**。

**批三（issues/137）＋ 115 第 47 个 action 落地。** 代次从 0.1.24 前进一格，四模块同号重发，
接力 pin 一次改 12 处＝5 version＋7 pin，tag 打在 bump 之后（`529846a`）。

- **门面出口不再漏内部原文**（issues/137 §3-1，`207b3e5`）：出口层加判别式 `is_foreign_detail()`
  （命名对应 java `isForeignDetail`；**moon 的错误变体本身就是档位**，所以判据收敛成"`Internal` ⇒ true"一条，
  没有移植 java 那套运行时类型族启发式），命中则对外 msg 逐字＝`INTERNAL_FAILURE_MSG = "流程处理失败"`，
  原文改由扩展后的 `detail()` 进门面日志。承重前提是先追清再动手的：`core/error/error.mbt:46`
  的 `Internal(msg) => "内部错误: \{msg}"` 确实会把原文搬进 `message()`，经 `facade.mbt:48` 顶层 catch
  落到 `{code:99999999, msg:<原文>}`——变异 M1 实测出的是**带主机与账号的凭据串**。
  有意例外一处：`actions_ext.mbt:556` 的 bizData 腿把第三方原文拼进了**契约档**（`Business`），
  出口判别式按"是不是 `Internal`"判、挡不住这种形状 ⇒ 只能在构造点收口，改成 java 基准同文 `业务数据读取失败`。
- **实例级 `expire_time` 按定义级表达式求值**（issues/137 A §3-4，`973d224`，两处写点），
  并新增**真库腿** `demo/cmd/i137a_mysql`（`e271d77`）：这一列必须真过 160 那台 MySQL 的
  `wf_process_instance.expire_time DATETIME(3)` 再读回来，判据一律取库里的值。
  修前形状是原串搬运（把 `"2h"` 直接塞进 datetime 参数），160 实测 `@@sql_mode` 含 `STRICT_TRANS_TABLES`
  ⇒ 服务端直接拒（`ERROR 1292`）、整条发起 INSERT 失败；**内存仓不校验这一列，T0 全绿照不出来**。
  该腿只允许指向自建隔离库（`JEFFLOW_DB_NAME` 未设或指向 `jeeflow`/`jeeflow_test` 等共享库即 fail，不 connect 不 DELETE）。
- **删除腿收口为「原值 ∪ trim 值」两形并集**（issues/137 §3-6，`54ed4d9`）；
  **相对档前缀判非负**（issues/137 D，`924fcae`：新增 `parse_int_non_negative`，一处裁四档）；
  **相对档前缀统一 trim**（issues/137 E，`c282971`：裁在调用点，判负单点不掺和）；
  §3-11 过期注释随批（`e2b6147`：误配档是八栈一致落穿，本栈不再是"与 Java 的故意差异"方）。
- **门面第 47 个 action `processTask/removeTaskActor`**（issues/115 §3-8，`efc6e49`）——
  引擎自有扩展，内置版无对应端点（只有按行 id 删的 `/wf/processTaskActor/remove`）。
- **坏 JSON 出口只给 java 逐字基准文案**（issues/139＋137-G，`6384f27`），底层原文走 `detail()` 落日志；
  文档侧两笔：`974620b` 批一 A6 补 native 目标说明、`2ab1e34` 发布后措辞归位。
- **本版门禁**（该轮 bump commit 留痕，wasm 档——本仓 `preferred_target = "wasm"`，
  wasm-gc 会静默丢 async 用例还 exit 0）：T0 `moon test --target wasm` **402/402**；
  T1 `repository-mysql/smoke` **`T1 ALL PASS (wasm → 160)`**（专用库 `jeeflow_moon_t1`）；
  T1-F `demo/cmd/t1_mysql` **130 PASS / `T1-F ALL PASS`**。
  独立复现：0.1.26 轮在**摘 vendored 之前**的同一棵树上取改前基线 ⇒ check **0 error / 22 条警告**
  （指纹 E0053×10 E0020×4 E0024×4 E0027×2 E0002×1 E0067×1）、T0 **402/402**、T1 **111 断言**、
  T1-F **130 断言**、`consistency` 载荷等值、T2 **7/7**——两处读数一致。
- **发布链读数**（`gh` 现查 ＋ `moon update` 后索引）：publish run **36970936645** success、
  Demo Deploy run **36970936742** success、sync-cn run **36970936789** success；
  注册表索引四件 `0.1.25` 的 `created_at=2026-10-02T05:53`（本轮再读仍在，且
  `jeeflow-repository-mysql@0.1.25` 的 deps 写的是 `moonbitstack/moonmysql: 0.7.2`——那一代还带 vendored）。
- **⚠️ 两处归属纠偏**（AGENTS §6.7 第 ① 条：「已落地」与「已发版」是两个状态）：
  bump commit message 把 **142 内存仓水合**、**143 §3-5 边落穿日志腿**、**§3-9** 一并列为"v0.1.24 之后进版"，
  现跑 `git merge-base --is-ancestor` 判：142 水合两笔（`8bb6a2d`、`5ab9dc0`）**已在 v0.1.24 内**；
  "落穿/未知档"形状在 v0.1.24 的树里已有 6 个文件命中，且 `v0.1.24..v0.1.25` 区间内
  **没有任何一笔**的 subject 归属 143 或 §3-9。⇒ 0.1.25 的真实进版以本节上面几条为准。
  同一条偏高表述也写在 `jeeflow-hub/RELEASE.md` §三 的旧行里（"…＋ 142 内存仓水合"），
  该行已随 0.1.26 换代改成"只记当前代＋实读凭据"。

## 0.1.24（2026-09-30 深夜）

**截止夜文档收尾攒下的源码侧欠账，一次清掉。** 代次从 0.1.23 前进一格，四模块
（core / persist / repository-mysql / facade）同号重发，接力 import pin 同步（`moon_dep_bump.py`
命中 12 处＝5 version＋7 pin）。

- **四处历史注释纠偏**（09-30 文档收尾批登记为「明确未做」的第 ① 条，当时不改的理由就是
  `core` / `repository-mysql` 属已发布模块、动源码＝重发注册表 ⇒ 攒到这一版一起做）：
  - `core/json/json.mbt` 「见 `docs/decisions-log.md` D-M5-3」→ 改指仓根 `MAINTAINING.md` §4 代决策；
  - `core/memory/memory.mbt` 「见 `docs/m1-progress.md`」→ 同上（那两个文件早已并入 §4 与 CHANGELOG，
    注释却还指着它们，公开 clone 的人按图索骥必然 404）；
  - `repository-mysql/smoke/smoke.mbt` 「见 `docs/decisions-log.md` D-M2-2」→ 同上；
  - `core/engine/compliance_test.mbt` 段标题「15 flows 驱动」→ **16 flows**，并注明
    c23–c31 在 `compliance2_test.mbt`（`c01–c22` 在本文件，合起来才是 31 个场景）。
  四行全是单行子串替换，**逐文件行尾约定字节级不变**（`json.mbt` 纯 LF、`memory.mbt` 全 CRCRLF、
  `smoke.mbt` 与 `compliance_test.mbt` 各自的混存比例前后一致）——本仓 `.mbt` 行尾不统一，
  批量转换会造出全文件 diff，所以只允许"不碰换行符"的改法。
- **demo 的存储模式静默回落改成点名警告**（`226ab60` 已在 master，随本版**第一次进镜像**）：
  `App::create()` 对"拼错名 `JEFFLOW_DEMO_STORE`（两个 F）"和"值不是逐字 `memory`/`mysql`"
  各打一行 `警告：…`；线上 `:8092` 演示镜像此前是 v0.1.23 的静默版。
- **本版门禁**（2026-09-30 23:5x 实测，真库用**专用新库** `jeeflow_moon_t1`，按 §2 T1 姿势现建现导）：
  `moon check` **0 error**（20 条既有结构性误报）；T0 **352/352**；T1 仓储级 **111 断言**
  `T1 ALL PASS (wasm → 160)`；T1-F 门面级 **130 断言** `T1-F ALL PASS`；T2 冒烟 **7/7**
  （种子 in-progress 16/16 / finished 9/9 / surrogates 8/8）；manifest **46/46** 与 Java 实查双向无差集；
  `consistency` 载荷**逐字节等值**（3091B，按载荷比不按文件字节比）。
- **发布链终局**：tag push run 36740635875 四步 publish **逐步** success（判发布看 job steps，
  不看 workflow 总结论），registry 索引四件 `0.1.24` 全命中，`pull_verify.sh 0.1.24` 消费者实下载
  正负两支 OK；Demo Deploy run 36740635879 success（服务端 T2 `ALL PASS` +
  `✅ Moon demo deployed (port 16086->8092)`）⇒ **demo 的存储模式警告自此在线上生效**；
  sync-cn run 36740636340 success ⇒ Gitee/GitCode 同步同一代次。
  ⚠️ 顺带纠一处台账漂移：§4 D-M6-1 那句"T1-F 门面级 **104 格**"是当时的读数，
  141/142/134/130 几轮加格后现行是 **130**——历史句不回写，但本版读数以这里为准。

## 0.1.23 文档收尾批（2026-09-30 夜，**只改文档，未发版**）

新手模拟盲测（子智能体从公开 clone 起步）反馈的第二轮。注册表仍 `0.1.23`，模块源码零改动 ⇒
`moon.mod` 不动；本批只落 GitHub master。每条都实测过才写。

- **B2 静默陷阱**：`docs/demo.md` / `docs/integration.md` 里的 `JEFFLOW_DEMO_STORE` 是拼错的变量名，
  代码读的是 `JEEFLOW_DEMO_STORE`（两个 E）。照文档写 ⇒ 整条变量被忽略、banner 仍 `store=memory`、
  `POST /api/reset` 照样回 `code=0`。两处改对，并加「两套前缀」警告：demo 侧 `JEEFLOW_*`
  （`JEEFLOW_DEMO_STORE` / `JEEFLOW_TZ_OFFSET`），MySQL 连接侧才是 `JEFFLOW_DB_*`；
  `App::create()` 只认逐字 `Some("mysql")`，其余（含非法值）走 `_` 臂静默回落。
- **B3 装配示例不可编译**：三处示例缺三项从未写进文档的前置——包别名要写进**消费者自己的**
  `cmd/main/moon.pkg`（`moon.mod` 只解模块依赖、不解析名）、`args` 是 `Map[String, Json]`、
  `flow` 是 `async`（`async fn main raise` 还要 `moon add moonbitlang/async`，否则报
  「Cannot use `async fn main`: package moonbitlang/async is not imported」）。
  `getting-started.md`「5 分钟上手」重写成**逐字跑通**的完整模块（`moon new` + 3 条 `moon add` +
  两个文件），实测输出 `{"code":99999999,"msg":"流程定义不存在: 1"}`，并把这个信封写成
  「内存仓储出厂为空」的证据；`IUserProvider` 签名逐字 `raise @error.JeeflowError`（裸 `raise`、
  整个不写 `raise` 各撞一次 Expr Type Mismatch，两条报错原文都记进文档）。README 消费段换成同一
  形状；`integration.md` 的富装配块显式标注「装配形状图、非可粘贴代码」。
  ⇒ 三份文档的示例现在都能编译，且是从 `moon new` 出的干净工程里 `moon run` 出来的，不是推的。
- **B5 MAINTAINING §5 表**：整列既不是 wire 名也不是内部方法名（`define_page` 这类 snake_case 实测
  一律 `99999999 未知 action`），改成 wire 名列 + 一句「snake_case 一律打回」；`processTask` 计数
  9→10 与 `scripts/action-manifest.json` 对齐（上轮只改了 `engine-api.md`，这张表漏改），补 `transfer`。
- **漂移数字清零**：共享流程 **15→16**（`ls flows/*.json` = 16，八语言仓均 16，demo 种子
  `in-progress 16/16`）共 9 处；`spi-guide.md` trait 方法数 24→**29** / 14→**13**（数
  `core/spi/repository.mbt` 的 `async fn` 得）；README T0 行 `22 compliance scenarios`→
  **31（c01–c31）**；`docs/index.md` 规范范围 01~08→**01~11**（文档站实有 `09-persist` /
  `10-persist-meta` / `11-events`，而同目录 `docs/persist.md` 正在引 spec/09、spec/10 —— 自家文档
  互相打脸）；`spi-guide.md` 的「D-M0~D-M5」→「D-M0~D-M6-2」（同文件上一行就写着 D-M6-2）。
- **要脑补的前置补进文档**：一个端口只能起一个 demo（第二次 `moon run` 报「通常每个套接字地址…
  只允许使用一次」），换端口 `LISTEN_ADDR=127.0.0.1:8093`；冒烟跟着挪 `BASE=http://127.0.0.1:8093`
  （`scripts/smoke_t2.sh` 的 `BASE`/`PY` 两个可覆盖变量此前全仓零处提及）；`moon update` 从
  「缺了它 `moon install` 会失败」降级为「索引陈旧时补一步」（Quickstart 全程不用 `moon install`，
  原口径无从对照）；新增「注册表 latest 可能落后 `moon.mod` 一代」一句。
- **`/api/stats` 口径写实**：两键**都按 operator 过滤**，且 HTTP 侧 operator 恒为缺省 `user1`
  （`demo/cmd/main` 交给 `App::handle` 的 query_string 是空串）。实测 `{"todoCount":0,
  "instanceCount":4}` 对 `stats/overview.total=25` ⇒ 全库口径必须去 `processInstance/stats/overview`，
  别把 `instanceCount` 读成全库实例数。
- **N9 待办列表补例**：`docs/engine-api.md` 此前只有 `startAndExecute` 一对示例，`todoList` 的调用
  形状只藏在 `scripts/smoke_t2.sh:18`。补一组 demo 实测真实值（五键齐、三枚雪花 id 已字符串化、
  `ext` / `instanceExt` / `taskFormData` 齐、`recordCount=5 / totalPage=3` 是 `pageSize=2` 下的真读数），
  四个 JSON 块逐个 `JSON.parse` 过。
- **跨仓引用不再让人扑空**：`MAINTAINING.md` 顶部加「跨仓引用怎么读」——「方案 §x.y」=
  `jeeflow-hub/docs/moonbit-engine-implementation-plan.md`（即 `action-manifest.json` 的
  `sources.plan`）、issues 台账在 `jeeflow-hub/issues/`、`consistency/` 只发布本语言一份快照、
  以及历史注释里的 `docs/decisions-log.md` / `docs/m1-progress.md` 已不存在（内容并入 §4 与本文件）。
  **代码注释本体未改**：`core` / `repository-mysql` 是已发布模块，动注释就要重发注册表，超出
  「文档收尾」边界 ⇒ 登记为后续批次；本轮 `demo/`（未发布模块）也未动。
- **B2 顺手在代码里堵死（超出"只改文档"半步，已单独说明）**：`demo/app.mbt` 的 `App::create()`
  原来对拼错的 `JEFFLOW_DEMO_STORE` 和非法值都走 `_` 臂静默回落 memory。现在两条各打一行
  `警告：…` 点名原因，且只认逐字 `memory` / `mysql`。四种组合逐条真跑过：拼错名 ⇒ 警告 +
  `store=memory`；`Mysql` ⇒ 警告 + `store=memory`；`memory` ⇒ 无警告；`mysql` ⇒ 走到 mysql 臂、
  横幅 `store=mysql`。`demo` 是**未发布模块**（`publish.yml` 只发 core/persist/repository-mysql/
  facade 四件）⇒ 零注册表成本，代次仍 v0.1.23；但线上 `:8092` 镜像按 v0.1.23 构建、那一版仍静默，
  要下一次 tag 才带上 ⇒ 文档里把这条标成「v0.1.23 之后的 master 才有」，并保留旧行为的留痕描述。
  **（后续：这一版 tag 就是本节下面的 0.1.24，警告已随它上线；上面那句是当时的状态描述，保留不改。）**
  已发布模块（`core` / `repository-mysql`）的注释仍**一字未动**，见上一条的后续批次登记。
- **门禁**：`moon check` 0 error；T0 352/352；T2 冒烟对 `:8095` 实例 7/7（种子 in-progress 16/16）；
  文档示例的编译/运行验证走独立消费者工程（`moon new` 出来的，不在本仓工作树内，不污染门禁）。

## 0.1.23（2026-09-30）

**盲测报告 §5 五条建议落地 + 它牵出的内存仓读侧真缺陷**。报告阅后即焚，本节与下面四笔 commit 是唯一留档。

- `158c080` 文档五条（默认只改文档、不动代码）：
  ① **`/api/stats` 路由口径**——实测复核报告结论成立：无参通（`operator` 缺省 user1），
     带 `?operator=` 返回 `99999999 unknown path`；根因是 `demo/cmd/main/main.mbt` 把含查询串的
     `req.path` 整串交给 `App::handle`（wasm 侧不剥 `?`）。三处文档（demo.md / integration.md /
     engine-api.md）改成实测形态并注明限制 ⇒ 消灭唯一一个"照抄即失败"。
  ② 删漂移数字：`119 用例` → 以实跑读数为准；`现 0.1.14` → 指向各模块 `moon.mod` 与本 CHANGELOG。
  ③ `engine-api.md` action 分组表与 `scripts/action-manifest.json` 对名
     （`start_and_execute`→`startAndExecute`、`up_and_down`→`upAndDown`、`get_last_by_name`→
     `getLastByName`、`taskDetail`→`detail`、补 `transfer`；processTask 9→10），
     并补一组 `startAndExecute` 请求/响应**成对** JSON 示例（取 demo 实测真实值）。
  ④ `smoke_t2.sh` 头注释补前置：依赖 curl + python。
  ⑤ （可选·代码）demo 启动横幅加 `(GET /health)`。
- `8bb6a2d` **内存仓读侧真缺陷**（142 A 批「零参与者照样建单」暴露的既有缺口）：
  `find_task_by_id` / `find_history_tasks` 不水合参与者 ⇒ 办理与办结守卫拿**建单时**的旧空集合
  误判，demo 种子 `define=14 op=leader` 报 `99999999 权限不足`（09-29 盲测 16/16 → 09-30 15/16）。
  按 java「actor 表即参与者唯一事实源」补水合，新增 2 格。
- `5ab9dc0` 同族缺口收口：六条任务读路统一到单一 `hydrated_task` 判据点（含
  `page_todo_tasks` 的**过滤前**水合——那才是"待办漏人"的真位置），新增 3 格。
  `get_all_tasks` 的弱口径（仅 `actor_ids` 为空才回填）**保持不动**：它只喂 stats、不在守卫/列表
  路径，改它会动 stats 读数，超出本缺口范围，留 owner。
- `946897e` **补记本文件欠的八代（0.1.15–0.1.22）**：②那条"指向 CHANGELOG"的修法，当时指向的是
  最新条目还停在 0.1.14 的本文件 ⇒ 指引会把读者引到落后 8 代的值。账补齐，指向才成立。
- **本版门禁**：T0 **352/352**（349+3）、T2 冒烟 7/7 ALL PASS、demo 种子 in-progress 16/16 /
  finished 9/9 / surrogates 8/8；`moon check` 0 error，20 条 warning 全是既有结构性误报，
  改动文件零新增警告。
- **判红能力自证**（不是"改后绿"就算数）：副本内把 `hydrated_task` 改成不水合（单点覆盖六条读路）
  ⇒ 判红 5 格——本版 3 格（`page_todo_tasks` 报 `0 != 1`）+ 8bb6a2d 的 2 格（报 `99999999 != 0`），
  而对照组（lisi 命中 / wangwu 零行 / taskC 真空）不红 ⇒ 新格确有判红能力、非恒绿。
- ⚠️ 本版 tag 打在「五模块 `version` + 7 处接力 import pin 全部同步」之后（0.1.22 的 tag 落点缺陷不再复现）。

## 0.1.22（2026-09-30）

**issues/141 抄送轮 + issues/142 记录类与归属值普查 A/B 两批**（八栈同批，随 1.8.36 家族发布）。

- `2d2afb4` **G6 办理腿 `tf_ccActors` 数组形态修复**：此前只吃 `get_str`（仅 `Json::String`），
  数组 `["userB","userC"]` 取不到人 ⇒ 不建 cc 行也不 fire 码 4，而同一份定义在其余栈却建。
  现两形态等价（走与发起腿同一个 `parse_cc_actors`）。补 5 格；**改前数组三格实测 FAILED**。
  另 137-B：`reject_task` / `create_history_task` 确认零调用者，补 2 格直调与主路径逐列一致并注释留档。
- `b4b6ade` G1/G2：抄送分页归属条件必填；cc 写侧判重＝幂等空操作（对齐 java `3d1fc98`）。
- `007e58c` G10：空抄送人不建 cc 行（对齐 java `5fbd5ac`，spec 06 §2.10 四条逐条落）。
- `da6d878` **142 A 批**：记录类（`snaker:custom`）独立执行腿 + **任务类零参与者照样建单**
  （对齐 java `a596886`/`33ba48f`，spec 02 §6.1/§6.2 四条逐条落）。
- `084581e` 更正 1bis 注释对条文「两列写、一列不写」的误读（A 批复核）。
- `fa11e4b` **142 B 批**：任务参与者归属值**写侧**归一（spec 06 §2.11，判据单点
  `@model.normalize_actors`：逐元素 trim、空串/纯空白丢弃、同次调用折叠）+ §9.2 第二批删除位
  trim + 门面 `updateCCStatus` 补 trim。
- ⚠️ **本版 tag 落点有缺陷**：`v0.1.22` 只指向 bump 那笔（`71efa67`），而接力 import pin 的修复
  `46cf274` 在 tag **之后** ⇒ 该 tag 与按 tag 取件的元数据不含 pin 修复。教训入流程：
  **tag 必须在"五模块 version + 四份接力 pin 全部同步"之后打**。
- ⚠️ A 批的「零参与者照样建单」把内存仓一条**既有读侧缺口**暴露出来（办理守卫拿建单时旧集合 ⇒
  demo 种子 `define=14` 报 99999999）。该缺口不在本版修，见 0.1.23。

## 0.1.21（2026-09-29）

**issues/138 `ccList` 行形状对齐 boot2 基准**。

- `ec8583b`：cc 命中后输出**实例行**（`id←pi.id` / `operator←流程发起人` / `variable`、`create_*`
  同实例行），退掉原先 `cc.actor_id AS operator` 与 `NULL AS variable` 两处形状偏差；
  内存腿与 SQL 腿共用 `instance_row_of` 收敛为一把尺子。
- `817553e`：五模块 version + 四份接力 import pin 同步对齐（本版起 pin 同步随 bump 一起做）。

## 0.1.20（2026-09-29）

**issues/127 / 132 事件代码腿**。

- `07bfaac`：A 套码表 5-9 落地 + `notify_events` 直传载荷键（`instanceId` 为硬要求）+
  抄送腿事件入引擎。覆盖面按 132 收口轮改判：`4` 与 `2` 的相对次序不进契约（新 §11.9），
  覆盖面收窄到 `executeProcessTask`。
- `aadb910`：五模块 version + 四份接力 import pin 同步对齐。

## 0.1.19（2026-09-29）

**issues/134 撤回实例态守卫**。

- `7768364`：撤回校验实例状态——非进行中(10) 一律拒，内部码 **20010009**（案 A，基准 boot2）。
- `69660d1`：补镜像 `issues/126` 的串行会签到期夹具（漂移门禁报 moon 缺这一份）；`moon test` 208/208 绿。
- `524e8e0`：五模块 version + 四份接力 import pin 同步对齐。

## 0.1.18（2026-09-28）

**issues/126 任务行 `expire_time` 真算** + CI/镜像/文档一轮治理。

- `d38f5d0`：`expire_time` 五处写点按节点表达式真算（案 A，基准＝boot2），新增 `expire_time.mbt` 求值器。
- `3591094`：**demo 镜像改多阶段**（对齐 jeeflow-go 先例：小底座 + 二进制 + flows），
  ~1GB 砍到 ~90MB，`scp` 传镜像不再是部署瓶颈；运行层沿用 `ubuntu:22.04` 保 glibc 行为一致。
- `d5756c7` / `52d9f64`：CI 增持续集成（master push 跑检查/构建/测试，wasm + native 双档）；
  **部署触发面收回 tag + 手动**——验收未规定触发时机，不自行扩；`check-test` 前置门保留（绿了才部署）。
  mysql 冒烟（T1/T1-F）需真库，不进 CI 链路。
- 文档口径三条：`552b7cc` 对齐过期读数（T0 131/119→179 今晨实跑）、
  `9293f54` 与 `1994b2a` **去掉 README 里写死的测试条数/夹具份数与具体版本号**
  （owner 口径：活文档不手写会漂移的数字，安装说明用 latest 表述）。

## 0.1.17（2026-09-28）

**只发 facade 的接力 pin 对齐版**——本版存在的唯一理由是记录一个 publish 机理卡点。

- `f3cd4f0`：`moon publish` 的包体校验**从 registry 取依赖源码、不吃本仓源码** ⇒ 本地 `moon check`
  全绿、CI 却 4021。判"某版本在不在"要用 `moon add` 实取，别看退出码、也别信 `/api/v3` 与 `/docs`
  两个探针（都会骗人）。四模块同链顺序发还会被**索引刷新滞后**卡住 ⇒ publish 必须可重入。

## 0.1.16（2026-09-28）

**issues/131 串行会签簿记搬到任务变量**。

- `d995870`：会签进度簿记从实例变量改到**任务变量** `operatorList_{node}`（数组），对齐 Java 参考实现。
- `d32c244`：bump。

## 0.1.15（2026-09-28）

**issues/129 `operator` 空串与缺键同档**（两层修法）+ 一处文档反写更正。

- `cb4ed0d`：第一层门面归一化 + 第二层归属谓词列空值兜底（哨兵），全走内存仓通道。
  洞的来源：160 三档并排探针里 moon 的洞在第一层——门面把 `{"operator":""}` 当真实值往下传，
  仓储拿空串比对归属列 ⇒「我的列表」悄悄变 0 行（java/go/python/node/csharp 是丢掉条件读全库，
  同案另一种形状）。按拍板：空串/全空白/缺键三档一律回落 demo 缺省 user1。
  夹具刻意做成**非对称**（四出口 user1=2 / other=1 / 全库=3）——空仓上"空串档==缺省档"恒真，
  那种夹具等于没测。
- `c6e234b`：**更正上一节的结论**——moonmysql 声明不是死依赖、摘不掉（详见 0.1.14 节内更正）。
- `a799600`：回拉验证固化为 `scripts/pull_verify.sh`（消费者视角正负两支 + 依赖代次读数）。

## 0.1.14（2026-09-26）

**本版无行为变化**：只换 registry 依赖代次——`moonbitlang/async 0.20.3 → 0.22.4`、
`moonbitstack/moondb 0.1.8 → 0.2.0`、`moonbitstack/moonmysql 0.4.0 → 0.7.2`。
pin 写在各 `*/moon.mod`，**随本版发布后** `moon add mldong/jeeflow-*@0.1.14` 才会带上新代次
（0.1.13 那份元数据仍钉旧版本，这也是本版值得单独发的唯一理由）。

- 三个 bump **逐个做，每步以全工程 `moon check` 当验收人**：三次读数都是 **0 error / 11 warning**
  （那 11 条就是 0.1.13 里逐条证伪过不可摘的结构性误报，一条没多）。
- 门禁：T0 168/168、T1 仓储级 111 格、T1-F 门面级 104 格（两者真机 160）、T2 ALL PASS、
  action manifest 46/46、`consistency/moon.json` **载荷逐字节等值**（md5 `a74cb69323870759bb30ff330d940bd3`）。
- 两个防假绿的对照：① 物化版本读 `.mooncakes/<org>/<mod>/moon.mod` 的 `version` 实值，
  证"pin 真生效"；② 比快照按**载荷**比、不按文件字节比——本工具链 `moon run` 的 stdout
  末尾多吐一个 `\n`，按字节数比会误报成"输出变了"。
- 对外形状零变化：HTTP 出口、46 个 action、SPI 签名、错误码与 0.1.13 一致。
- **依赖面事实（本节曾写错、同日实测更正）**：`repository-mysql` 声明的 moonmysql **不是死依赖，摘不掉**。
  vendored 的只有 client 两文件（绕上游 `supported_targets="native"`，见 MAINTAINING §4 D-M0-2），
  **协议编解码那半（root codec）仍走注册表**——`vendored/moon_mysql_client/` 里 **75 处
  `@moonmysql.*`、27 个不同符号**（`ServerKind`/`QuoteMode`/`parse_handshake`/`build_handshake_response`/`parse_err` …）。
  副本实测：删掉声明 ⇒ `moon check` 报 `Cannot find import 'moonbitstack/moonmysql' in …/vendored/moon_mysql_client`。
  要真摘得把 codec 一并 vendored，那是独立一轮。⇒ 连带一条该盯的：**本版是混代**
  （vendored client 拷自 0.4.0 + registry codec 0.7.2 同时在跑），`moon check` 测不到它，
  判据在真机协议路径：T1 111 格 + T1-F 104 格全绿（收口后同窗口复跑再验一次，0 FAIL）。
  详见 MAINTAINING §1「依赖版本」。
- 本机 Windows 的 `moon build --target native` 仍编不过 async 的 C 臂（MSVC-only，
  `thread_pool.c` / `fs.c` / `event_bus.c` 三处 `#error`），**0.20.3 起即如此**——
  它既不是本版的回退证据，native 通道的真验证在 CI（Linux）。

## 0.1.13（2026-09-26）

**本版无行为变化**：整版内容是把引擎适配到**新工具链（moon 0.1.20260920 / moonc v0.10.14）**
——从"能编译"推到 **0 error**、警告 629 → 11。剩下的 11 条（8 `unused_trait_bound`
+ 3 `unused_error_type`）已逐条证伪"可摘"：它们是"只看函数体、不看调用链"的结构性误报，
摘掉要么编译不过（效果不参与函数子类型），要么只是把告警搬到另一行；
条目级静音在本工具链无可用机制。证据与四种试法记在 MAINTAINING §1.3。
判据侧一字未改（T0 168 格、T1 仓储级 111 格、T1-F 门面级 104 格全绿；
`consistency/moon.json` 逐字节不变）。
CI 侧的连带收获：`Native Probe` 此前在 latest 上是红的，崩因是诊断渲染器（ariadne）
在**打印 warning** 时 panic —— 与本仓代码无关，`--no-render` 即可解耦（已写进 MAINTAINING）。

采用的新形状（都带"为什么"，写在 MAINTAINING §1.3）：

- `impl Trait for T` 的方法不再被隐式提升为常规方法 ⇒ 全仓补 48 条
  `pub extend T with Trait::{…}`；vendored 两文件保持逐字节原样，
  extend 落在同包的本仓自有新文件 `vendored/moon_mysql_client/extend_driver.mbt`。
- 事务模板的"回滚 → 清态 → 关连接 → 外抛"由 `try/catch + raise` 改 **`errdefer`**
  （工具链声明 try/catch 将来不再捕获异步取消）。
- 弃办的 `fn meth(self : T, …)` ⇒ `fn T::meth(self : T, …)`；
  `try?`（已废）全部塌成 `try { 块 } catch { 臂 }`；SPI 闭包的 `Ok/Err` 双消费点
  改成 `try/catch` 或箭头闭包；`x |> _.f()` 偏应用改直接方法调用。
- 字符串：`substring(…)` ⇒ 切片 `s[a:b]`（38 处）；StringView 尾巴
  `.to_string()` ⇒ `.to_owned()`（42 处）；多行串不再裸用作函数体，改 `let` 绑定
  （`$|` 行逐字节未动——缩进参与内容）。
- Json：`x.value(k)` / `x.as_string()` 等弃办调用统一走本仓 `@json` 助手
  （`get`/`as_str`/`as_bool`/`as_f64`，并新增同形的 **`as_array`**）；助手体本身
  改成编译器建议的判形，一处收口。
- 清理：删死函数 `sql_escape_text`；6 个"体内不用 self"的方法补显式忽略；
  `moon.pkg` 里 3 条**只有测试在用**的 import 从常规块挪进 `for "test"` 块。

**两处对外形状的收敛（消费方需知）**：

1. `ProcessInstance::resume` / `ProcessTask::resume` ⇒ **`resume_from_interrupt`**
   （`resume` 是本工具链预留字）。这两个方法全仓 0 调用点，也不是跨栈契约名
   ——契约只钉 HTTP action 串与 JSON 形状。`App::handle` 的形参 `method` ⇒ `meth`。
2. 若干**从不抛错**的函数摘掉了 `raise` 声明（门面出口 `Facade::flow`、各 getter/助手）。
   这是"效果收窄"，对调用方源码兼容；且 `flow` 的语义本就是错误转
   `{code:99999999,msg}` 信封，不抛才诚实。

## 0.1.12（2026-09-26）

- **时间只有引擎一把钟（issues/120 附证）**：
  - `repository-mysql` 六条写路径的 SQL `NOW()` 全部改绑引擎钟（新增 `repo.now_v()`）——
    instance/task/design/surrogate 的 `update_time`、task_actor/cc_instance 的 `create_time`。
    `NOW()` 取的是**数据库会话时区**，而引擎写出的列是它自己那把钟；开发服务器 160 实测
    `@@session.time_zone=+08:00`（`NOW()` 比 `UTC_TIMESTAMP()` 晚 8 小时）⇒ 同一行
    `create_time`(引擎) 与 `update_time`(DB) 差 8 小时，`wf_process_task` 一行里
    `finish_time` 与 `update_time` 两个基准。外溢到读侧最实的一格是「抄送我的」列表：
    `wf_process_cc_instance.create_time` 会被 `page_cc_instances` SELECT 回并投影给前端。
  - `facade/stats.mbt` 的逾期判据基准由裸 `@model.epoch_secs()`（注入不了）改走
    `current_time_str()`（可注入），与同段的 `todayNew`、与写库列、与委托生效窗同一把钟。
  - **新增判据**：`facade/stats_clock_test.mbt` 3 格（注入钟 = 真实 UTC − 12h 铺 ±1h 真窗，
    使「读注入钟」与「读裸墙钟」给出不同答案，当场可分辨；每格都带阳性对照）；
    `repository-mysql/smoke` 新增 T1-I120 七格（六列 + 摘掉注入的对照组）。
    变异对照在副本做：把那一步换成模拟 DB +08:00 ⇒ `FAIL 实际=2026-09-26 01:59:18，注入串=2026-09-25 05:59:17`。
- **demo 时钟基准由环境变量注入（issues/120 §9 落地形状）**：`JEEFLOW_TZ_OFFSET`
  （东为正小时，支持 `8`/`+8`/`-5`/`5.5`/`+05:30`，上限 UTC+14；未配或非法 ⇒ 保持 UTC 并打印所选基准）。
  线上 demo 部署已带 `-e JEEFLOW_TZ_OFFSET=8`。本机 wasm 通道实测：配 `8` ⇒ 实例 `createTime`
  = `2026-09-26 06:11:08`（真实 UTC `2026-09-25 22:11:08` + 8h），未配/非法 ⇒ UTC。
- 顺带记三处读码/探针所得（详见 MAINTAINING.md D-M6-2）：官方 `moonbitlang/x/time` 的
  `Zone::from_tzif2` 吃真实 tzdata **不报错但静默给 `Z`**；`iceBear67/time` 的 wasm 臂是桩
  （时区返回 `"UTC"`、`current_date/time/epoch` 返回 0）；moondb 把 `DATETIME(3)` 投成 **Blob**，
  按文本比较读回会得 `<BLOB>`。

## 0.1.11（2026-09-24，补记）

- `1f23565` issues/124：变量出口统一到 `ext`——detail 加 `ext`（`ext` 豁免 camel，键保持下划线），
  同批摘掉出口 `variables`/`variable`；rust/moon 那格「行 ext 下划线、detail.variables 驼峰」的
  自相矛盾随 `variables` 下线消除。`240bf85` demo 种子带上业务/办理表单字段（`f_*`/`tf_*`）。

## 0.1.10（2026-09-23，补记）

- `ef53f64` 四模块 0.1.10；同仓依赖 pin 指向**已发布的 0.1.9**——`moon publish` 会把产出 zip
  解包再 `moon check`，这一步 vendored 的是 registry 上的依赖源码，pin 到未发布版本会在服务端
  4021（上一轮 4 模块只发出 2 个的原因）。

## 0.1.9（2026-09-23，补记）

- `fe2a61d` issues/123：委托四判据改由「作用域内最新一条」裁决（精确判否仍兜底全流程，对齐 Java `6feeae6`）。

## 0.1.8（2026-09-23）

- **121 文案统一**：`JeeflowError::Business` 的两格退回上一步错误删掉码数字前缀（`engine_ops.mbt` 6 处 raise），
  注释由"码写在 Business(msg) 前缀"更正为"对外 msg 用固定中文文案、不含引擎内部码"；
  测试断言由 `starts_with("20010007")` 改成**逐字相等**（前缀回到任何位置都会红，已做变异对照）。
- **发版通道修复（本轮关键）**：`mldong/jeeflow-*` 的依赖 pin 从 `0.1.0` 升到 `0.1.7`。
  `moon publish` 会把产出的 zip 解包再 `moon check` 一遍，这一步 **vendored 的是 registry 上的依赖源码**；
  而 `jeeflow-core@0.1.0` 是旧泛型语法 `fn sorted_ids[V](...)`，当前 moonc 只认 `fn[V] name(...)`
  ⇒ 2 个 Parse error 把 `repository-mysql`/`facade` 的发布卡死（上一轮 4 模块只发出 2 个的原因就在这里，
  不是我们代码的错）。修复后 `moon publish --dry-run` 服务端回 `202 Accepted`。
- `docs/getting-started.md` 与 `README.md` 的 `0.1.6` 字面量 → `0.1.8`（文档站 `sync:langs` 才投影对）。

## 0.1.7（2026-09-22）

- issues/121 P1/P2：建单写 `parent_task_id` / `isFirstTaskNode`；`submitType=3` 改血缘版退回上一步
  （复活血缘前驱行，参与者取该行办结人，首任务节点行取该行 `u_userId`）。
- **发布状态留痕**：本轮只有 `jeeflow-core` 与 `jeeflow-persist` 的 0.1.7 上了 mooncakes，
  `jeeflow-repository-mysql` / `jeeflow-facade` 因上述 vendored 语法错未发出（由 0.1.8 补齐）。

## 0.1.6（2026-09-19）

MySQL 依赖坐标迁移到 `moonbitstack/`（`repository-mysql` 模块，引擎核心未动）：

- **上游搬家**：mooncakes 把整套 moonorm 生态从个人空间迁到组织空间，本仓两个直接依赖随之改坐标——
  `Lfan-ke/moon-mysql@0.3.1` → `moonbitstack/moonmysql@0.4.0`（包名去连字符）、
  `Lfan-ke/moondb@0.1.7` → `moonbitstack/moondb@0.1.8`。旧坐标停在迁移前版本不再更新。
- **两者必须成对迁**：moonmysql 0.4.0 的公开签名直接在 `Value`/`Row`/`ExecResult`/`Driver` 上暴露
  moondb 类型，只迁一半会同时物化两套 moondb——实测两种半迁形态分别死于构建计划拒绝和 5 个
  类型不匹配编译错（详见 MAINTAINING.md §4 D-M6-1）。
- **升级性质＝纯改名**：逐字节核对——moondb 0.1.7→0.1.8 的 `.mbt` 差异仅注释里的包名拼写；
  moonmysql 根包 `pkg.generated.mbti` 除包名外零差异；client 两文件 148 行差异全部是
  `@moon_mysql.` → `@moonmysql.` 别名改名（归一后与新版逐字节相同）。**零行为变化，无 API 适配**。
- **vendored 解锁保留**：新版 `client/moon.pkg` 依旧声明 `supported_targets = "native"`，
  wasm 限制未放开，D-M0-2 的 vendored 解锁不能删；`conn.mbt`/`driver.mbt` 按既定升级策略
  从 0.4.0 逐字节原样重拷（sha256 已核），与上游的唯一偏差仍只在 vendored `moon.pkg`。
- **消费面**：`repository-mysql/moon.mod` + `query`/`repo`/`smoke` 三包导入 + vendored `moon.pkg`
  改坐标；`repo/conn.mbt` 头注释与 `moon.mod` description 同步包名写法。core/persist/facade/demo
  无 registry 依赖变化，`moon.work` 成员不变。
- **验证**：T0 `moon test --target wasm` 119/119；T1 `moon run --target wasm repository-mysql/smoke`
  专用库 27 断言 ALL PASS（M1 分页五键 6 / M2 hydrate+全链 8 / M3 m_ LIKE 2 / M4 事务回滚 3 /
  M5 办理幂等 3 / I110 find_instance_by_id 水合 5）；负向两例错密码 `ServerError(1045, 28000)`、缺库
  `ServerError(1049, 42000)` 均 rc=1；T2 `smoke_t2.sh` ALL PASS，另跑 `store=mysql` 模式 demo 的
  HTTP 真 SQL 读路径（`/api/stats`、`processTask/todoList`）与不存在 define 发起负向；
  `check-action-manifest.mjs` 45 action 双向无差集；`consistency/moon.json` 逐字节未变。

发版：tag `v0.1.6` → publish.yml CI 发 mooncakes 四模块（core/persist/repository-mysql/facade）。

## 0.1.5（2026-09-09）

五语言引擎 SQL 仓 `find_instance_by_id` 不装 tasks 修复（`246d1ab`，
`repository-mysql/repo/repository.mbt`）：

- **`MysqlRepository::find_instance_by_id` 水合任务**：此前只查 `wf_process_instance`
  单表，`tasks` 硬编码 `[]`，门面 `processInstance/detail` 的 tasks/activeTaskList
  恒为空数组（T015 gate26 L2-12 门禁真根因）。对齐 Java `findTasksByInstanceId` /
  PHP `PdoProcessRepository` / C# `FindTasksInternalAsync`（聚合水合口径）：
  二次查 `wf_process_task`（复用 `find_history_tasks`：`ORDER BY id` + `hydrate_tasks`
  批查 actor_ids，事务内经 `open_or_tx` 复用环境连接，autocommit 独立连接语义不变）。
- **级联安全性**：`update_instance` 本就不级联任务（仅实例行 state/variable/update_time），
  水合后 withdraw 的逐任务 `update_task` 路径不变；memory 仓本就水合（基线正确，未动）；
  引擎核心会签语义未动。
- **T0**：`smoke.mbt` 新增 `t1_i110_hydrate`（T1 通道 `moon run --target wasm`，真实 160
  MySQL，9903xx 独立 id 段 + `clean_9x` 自清理）：引擎 `start_async` 发起 doing 实例
  → 断言 `find_instance_by_id` 水合任务非空 + 带 actor_ids，且门面 detail 消费
  （遍历 `inst.tasks` 组 tasks/activeTaskList）非空。
- **验证**：`moon test --target wasm` 119/119 绿（单测套件未动）；`moon run
  repository-mysql/smoke` T1 ALL PASS（M1–M5 + 新增 I110 五断言全过）；
  `moon check --target wasm` 全 workspace 无硬错误。

发版：tag `v0.1.5` → publish.yml CI 发 mooncakes 四模块（core/persist/repository-mysql/facade）。

## 0.1.4（2026-09-07）

instancePage/ccList 缺 operator 过滤修复（`f073134`，`core/memory/memory.mbt`）：

- **`page_instances` 补 `i.operator` 过滤**：此前全量构建 rows 不读 `query.operator()`，
  任意用户「流程实例」页可见所有人实例。新增 `operator_eq` helper（String 列版），
  实例 operator 即发起人（与 java `t.operator EQ` / `JeeflowFacade.java:254` 同源，
  spec 06-facade §2.5）。过滤在构建 rows 时执行，`recordCount` 为过滤后计数（分页教训）。
- **`page_cc_instances` 补 `cc.actor_id` 过滤**：此前遍历 `cc_instances` 全量构建，
  「抄送我的」页返回所有人抄送行。按 `cc.actor_id = operator`（java `:649` 同口径）。
- **repository-mysql 路径核查无需改**：`page_instances`/`page_cc_instances` 的 count/select
  本就有 `AND pi.operator=?` / `AND cc.actor_id=?`，与 memory/java 三方口径一致（无
  式「OR create_user」偏宽）。
- T0 119 用例全绿（新增 instancePage/ccList operator 正负向 + 无 operator 全量回归）；
  T1 wasm→160 mysql smoke **ALL PASS**（M1–M5，含 instancePage 分页五键 + operator 过滤回归）。
- 红线保持：`processSurrogate/page`（我的委托）无过滤是全语言现状（T003 矩阵不变量 7 依赖），
  未动；`page_todo_tasks`/`page_done_tasks` 行为不变（收口保持）。

发版：tag `v0.1.4` → publish.yml CI 发 mooncakes 四模块 + demo-deploy 公网 moon demo 重建；
公网双身份（张三/李四）instancePage 与 ccList 互不可见复核。

## 0.1.3（2026-09-06）

stats 一致性补跑抓出的 4 处偏差修复（均在 `facade/stats.mbt`；
T0 117/117 回归绿，与 java/rust 快照 15/15 逐字段全等）：

- **overview `total` 按 stateIn 门控**：此前统计窗口内全量实例（缺省不剔 99，
  `stateIn=[10]` 也不生效）；对齐 java「total = 六状态计数之和」。
- **`stuckApprover` 按 actor 关系逐人计数**：此前只数主 actor，漏会签/加签的
  额外 actor（task_actor 关系里的 u10 丢失）。
- **`durationBucket` 固定 4 桶全枚举**：此前只发非空桶；对齐 java 空桶也输出（count=0）。
- **分组平级行序确定化**：count DESC + key ASC（此前按插入序，平级序不稳定）。

新增一致性驱动 `demo/cmd/consistency`（固定数据集驱动 15 个 stats action，
输出 `consistency/moon.json` 快照，可复现）。

doneList 双缺陷修复（2026-09-06 夜班批，`298c1ce`）：

- **`page_done_tasks` 解析 instance→define**：此前 define 硬编码 None，
  行 `processDefineDisplayName` 恒 null（公网「我的已办」流程列整列「-」）。
- **新增 `done_operator_match` 按 `t.actor_id=我` 过滤**：此前不过滤混入他人任务
  （对齐 java `t.operator EQ` / spec 06-facade doneList；过滤在算 total 前执行，
  保证 recordCount=命中数）。T0 118 用例全绿（显示名非 null + operator 正负向 + 无过滤回归）。
- **repository-mysql doneList operator 收敛** `t.operator=?`（原
  `t.operator=? OR t.create_user=?` 过宽，对齐 java；T1 wasm→160 smoke ALL PASS）。

发版：tag `v0.1.3` → publish.yml CI 发 mooncakes 四模块（run 34046826425）+
demo-deploy 公网 moon demo 重建（run 34046826422）；公网复核「我的已办」流程列
非「-」且仅本人任务（API + 浏览器双证据）。

## 0.1.2（2026-09-05）

- **publish.yml CI 通道恢复**（D-M5-4）：装 latest + `EXPECTED_MOON_VERSION` 守卫 +
  `moon update` 前置 + `validate_only` 自检；tag `v0.1.2` 实战发版成功（run 33951631628）。
- **stats 口径收口**（D-M5-5）：overview 均值修 max 误用；stats 计数/时长 int 出参与契约
  §4.2 同口径；公网 `/moon-api` 部署 + UI `?lang=moon` 全链路验证。

## 0.1.1（2026-09-05）

- **雪花 id 精度修复**（D-M5-3）：Number→Int64/id 串转换改 repr 优先（5 处：core/json
  `as_i64`、facade/args `arg_actor_ids`、core/engine `parse_cc_actors`、facade/outbound
  `stringify_id_value`、repository-mysql `value_to_string`）；T0 增大整数精度回归至 117 用例；
  demo-deploy.yml 加 T2 冒烟门禁（数字 id 全链路防假绿）。

## 0.1.0（2026-09-05）

jeeflow 工作流引擎 MoonBit 实现（第 7 语言）首发版本。独立版本线（联邦"契约同代、发版分轨"）。

> 注：mooncakes.io 早期阶段强制 0.x（D-M5-1）；平台放开 1.x 后首个版本即 1.0.0，不跳号。

### 引擎核心（mldong/jeeflow-core@1.0.0）

- 全异步架构：仓储 SPI / 引擎 / 门面全 async fn，唯一事件循环零嵌套（对齐 spec/05）。
- DDD 聚合根 ProcessInstance/ProcessTask，状态机 spec/03 全集。
- 45 action 契约基线（与 java JeeflowFacade 实查双向无差集，manifest 固化）。
- LogicFlow 解析（8 节点类型）、会签门控（串行逐个/并行全齐/比例表达式/一票否决）、
  事件三型（TASK_CREATE 落库后 fire / INSTANCE_END 办结+拒绝双路 / CC_CREATE 逐人）。
- 7 内置 AssignmentHandler（注册名=java 全限定名）+ EnumDictRegistry 7 字典 + HandlerRegistry。
- MemoryRepository（T0）；Clock SPI（测试注固定钟确定化）；运行时零 registry 依赖。

### repository-mysql（mldong/jeeflow-repository-mysql@1.0.0）

- IProcessRepository 24 方法 + IProcessExtRepository 14 方法（moondb Driver + moon-mysql async conn）。
- m_ 三段式过滤解析、分页五键、NULL 安全行读取、DATETIME 文本归一、MysqlTxTemplate 真事务。
- vendored 解锁 moon-mysql client 的 native-only 限制（wasm 可连，决策 D-M0-2）。

### persist（mldong/jeeflow-persist@1.0.0）

- DynamicTableWriter trait + 内存实现；PersistPostInterceptor（ARCHIVE 幂等归档 / SYNC 同步演进 +
  字段权限 PERMISSION_* 双格式键 + 状态列探测）；表名安全检查。

### facade（mldong/jeeflow-facade@1.0.0）

- `flow(action, args)` 45 action 统一入口；出口强制层（camelCase + id 递归字符串化含复数数组 +
  时间归一）；stats 纯列聚合（overview/trend 4 桶/group 9 维）。

### demo（不发布）

- :8092 轻量服务：`POST /wf/{action}` 全转发 + health/stats/reset + CORS；
  8 具名用户 SPI；flows 种子 define id=1..N；memory/mysql 双存储。
- jeeflow-ui `/moon-api` 代理 + `?lang=moon` 分段。
