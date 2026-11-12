// ActionPermissionProvider —— action → 权限码映射（hub issues/248「权限码表归引擎、八栈统一」的 moon 腿）
//
// 语义权威＝java `com.mldong.jeeflow.spi.DefaultActionPermissionProvider`（放行／OR 两张表**逐条对齐**，
// 不许自创）；本腿的对照实现是 go `spi/action_permission.go`。
//
// 边界：引擎**不依赖任何鉴权框架**（sa-token / JWT / 中间件都是宿主框架的事），本 SPI 只提供
// "action → 权限码"这一份**元数据**；校验执行仍由集成方框架层完成。为什么这张表要抬进引擎：
// 现读十壳各抄一份（go 三壳 wf_permission.go／python 三壳 wf_permission.py／nestjs wf-permission.ts／
// laravel WfPermission.php／salvo wf_permission.rs／csharp WfEndpoints.cs），新 action 或粒度调整
// 要改十处＋引擎，且"只用引擎、自写集成层"的客户跨栈读出两套码。

///|
/// ActionPermissionProvider —— java `IActionPermissionProvider`／go `ActionPermissionProvider` 的同位。
/// `permission_codes` 返回 action 的权限码集合（**OR 语义**——任一持有即有权）；
/// 返回**空数组 = 放行**（登录即可，对应 boot3 端点无 `@SaCheckPermission` 注解）。
pub(open) trait ActionPermissionProvider {
  fn permission_codes(Self, String) -> Array[String]
}

///|
/// DefaultActionPermissionProvider —— 引擎内置默认件（java 同名类的逐条同款）。
/// 三档顺序与 java 一致：**放行 → OR → 默认派生 `wf:{action 的 / 换 :}`**。
pub(all) struct DefaultActionPermissionProvider {}

///|
pub fn DefaultActionPermissionProvider::new() -> DefaultActionPermissionProvider {
  DefaultActionPermissionProvider::{ }
}

///|
pub impl ActionPermissionProvider for DefaultActionPermissionProvider with fn permission_codes(
  _self,
  action,
) {
  default_action_permission_provider(action)
}

///|
/// OR 规则表（逐条对齐 java `DefaultActionPermissionProvider.OR_RULES`，**8 条**）。
/// issues/246／247 两枚新 action 定 B 案（owner 2026-11-04 拍）：**复用"办理"这枚码**，不另建菜单按钮种子。
/// 判据是既有惯例——transfer／removeTaskActor／candidatePage／latest 都没有 `sys_menu` 按钮行，
/// candidatePage／jumpAbleTaskNameList 就是走本表复用 execute；而撤回／撤会签的主体按引擎判据
/// 本来就必然是该行参与者（＝有办理权的人），拆出独立码实际给不出去，只会多一处存量库补种子的迁移。
/// issues/253 动态协办照同一惯例复用 execute（派生主体必然是主办行名册内的人）。
let or_permission_rules : Map[String, Array[String]] = Map([
  (
    "processDefine/detail",
    ["wf:processDefine:detail", "wf:processDesign:listByType"],
  ),
  (
    "processDefine/startAndExecute",
    ["wf:processDefine:startAndExecute", "wf:processDesign:listByType"],
  ),
  (
    "processDefine/getLastByName",
    [
      "wf:processDefine:detail", "wf:processDesign:listByType", "wf:processDefine:getLastByName",
    ],
  ),
  (
    "processTask/candidatePage",
    ["wf:processTask:execute", "wf:processTask:candidatePage"],
  ),
  ("processTask/jumpAbleTaskNameList", ["wf:processTask:execute"]),
  ("processTask/recall", ["wf:processTask:execute"]),
  ("processTask/revokeDynamicCountersign", ["wf:processTask:execute"]),
  ("processTask/aidant", ["wf:processTask:execute"]),
])

///|
/// 放行清单（逐条对齐 java `NO_PERM_ACTIONS`，**11 条**：登录即可、不配权限码）。
/// 统计三条（overview／trend／group）是 issues/103 的收口成果——普通用户分析页曾被默认规则
/// `wf:processInstance:stats:*` 拦下，六语言同款把它们归进放行表。
let no_permission_actions : Array[String] = [
  "processInstance/detail", "processInstance/highLight", "processInstance/approvalRecord",
  "processInstance/getAssigneeTextData", "processInstance/bizData", "processTask/detail",
  "processTask/addCandidate", "processTask/latest", "processInstance/stats/overview",
  "processInstance/stats/trend", "processInstance/stats/group",
]

///|
/// 三档判据的纯函数入口：`Ctx::permission_codes` 未注入提供者时的兜底，也是集成方可直调的出口
/// （java `DefaultActionPermissionProvider.permissionCodes` 的同位）。
pub fn default_action_permission_provider(action : String) -> Array[String] {
  if no_permission_actions.contains(action) {
    []
  } else {
    match or_permission_rules.get(action) {
      Some(codes) => copy_codes(codes)
      None => ["wf:\{replace_all_slash(action)}"]
    }
  }
}

///|
/// 内置 OR 表的名册（排序副本，**8 条**）——给集成层自检与门禁用，交出的是副本而非内部表。
pub fn action_permission_or_actions() -> Array[String] {
  let keys : Array[String] = []
  for k, _ in or_permission_rules {
    keys.push(k)
  }
  @model.sort_strings(keys)
  keys
}

///|
/// 内置放行清单的副本（**11 条**）。
pub fn action_permission_no_perm_actions() -> Array[String] {
  copy_codes(no_permission_actions)
}

///|
/// 内置默认件的元数据清单条目（类型名 + java FQCN 串）——与 `core/metadata` 的 HandlerRegistry
/// 里那一条（issues/184 R18「注册进清单」约定）同源，供集成层与前端设计器的 SPI 字典源取用。
pub fn action_permission_provider_meta() -> (String, String) {
  (
    "ActionPermissionProvider", "com.mldong.jeeflow.spi.DefaultActionPermissionProvider",
  )
}

///|
/// 按提供者取权限码（java `ServiceContext.find(IActionPermissionProvider)` 直调场景的同位）。
pub fn[T : ActionPermissionProvider] permission_codes_of(
  provider : T,
  action : String,
) -> Array[String] {
  provider.permission_codes(action)
}

///|
/// 把 action 里**所有** '/' 换成 ':'（java `action.replace('/', ':')`／go `replaceAllSlash` 的同位）。
/// ⚠️ 不用 `String::replace(old="/", new=":")`：本工具链代次实测它**只换第一枚**（多段 action
/// `processInstance/stats/custom` 会被读成 `wf:processInstance:stats/custom`，与参照实现不符）
/// ⇒ 逐字符重建（`StringBuilder()` 与 `engine.mbt` `resolve_bare_names` 同形）。
fn replace_all_slash(action : String) -> String {
  let out = StringBuilder()
  for c in action.to_array() {
    if c == '/' {
      out.write_char(':')
    } else {
      out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// 权限码数组拷贝——把内置表与调用方隔开（MoonBit 的 Array 可变，直发内部引用等于对外开放改表）。
fn copy_codes(codes : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for c in codes {
    out.push(c)
  }
  out
}

// ── 显式 extend（implicit_impl_as_method 弃办：impl 的方法不再被隐式提升为常规方法）──
// 由 scripts/moon_warn_w2.py 从编译器消息里生成；一行一个 (类型, trait)，可 diff 可复审。

///|
pub extend DefaultActionPermissionProvider with ActionPermissionProvider::{
  permission_codes,
}
