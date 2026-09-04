// M0 spike④：泛型约束引擎骨架 + 闭包字段 ServiceContext —— 编译通过即 spike 达成
//（方案 §5 M0 spike ④ / §3.2 / §3.4.3：MoonBit 无 dyn，大 SPI 走泛型参数，小 SPI 走闭包字段）
// 本文件是 M0 spike 产物，M1 移植 rust spi.rs/context.rs 时以此验证过的形态展开。
//
// 关键验证点：
//   1. core 模块零 registry 依赖下 `async fn` 可声明（async 是语言级特性，不依赖 moonbitlang/async）
//   2. trait 方法可 async + raise（显式 Self 第一参，对齐 moondb Driver / async Reader 范式）
//   3. 泛型约束形态：struct 裸类型参数 `Ctx[R, E]` + 方法级约束 `fn[R : ProcessRepository]`（moondb Pool[D : Driver] 同款）
//   4. 闭包字段形态 `((String) -> UserInfo raise JeeflowError)?` 可注入

// ── 最小错误类型（正式版 M1 落在 core/error）──
pub suberror JeeflowError {
  Missing(String)
} derive(Debug)

// ── 最小模型载体（正式版 M1 落在 core/model）──
pub(all) struct UserInfo {
  user_id : String
  real_name : String
}

// ── 大 SPI：仓储 trait，方法全 async（方案 §2.3 全异步 SPI）──
pub(open) trait ProcessRepository {
  async fn find_user_by_id(Self, Int) -> UserInfo raise JeeflowError
  async fn save_marker(Self, Int) -> Unit raise JeeflowError
}

pub(open) trait ProcessExtRepository {
  async fn find_ext(Self, Int) -> String raise JeeflowError
}

// ── 闭包字段形态的小 SPI 注入载体（ServiceContext 的 M0 形态）──
pub struct Ctx[R, E] {
  repository : R
  ext_repository : E
  // 小 SPI 全部闭包字段（对齐 rust Box<dyn> 惯用法，避免泛型爆炸）
  user_provider : ((String) -> UserInfo raise JeeflowError)? // IUserProvider.getUser
  id_generator : (() -> Int)? // IIdGenerator.next_id
  clock : (() -> String)? // IClock（MoonBit 特有：core 无墙钟）
}

pub fn[R, E] Ctx::new(repository : R, ext_repository : E) -> Ctx[R, E] {
  { repository, ext_repository, user_provider: None, id_generator: None, clock: None }
}

pub fn[R, E] Ctx::with_user_provider(
  self : Ctx[R, E],
  provider : (String) -> UserInfo raise JeeflowError
) -> Ctx[R, E] {
  { ..self, user_provider: Some(provider) }
}

// ── 泛型约束的引擎骨架：全 async 方法直接 await 仓储 async 方法 ──
pub struct Engine[R, E] {
  ctx : Ctx[R, E]
}

pub fn[R, E] Engine::new(ctx : Ctx[R, E]) -> Engine[R, E] {
  { ctx, }
}

pub async fn[
  R : ProcessRepository,
  E : ProcessExtRepository,
] Engine::run(self : Engine[R, E], id : Int) -> String raise JeeflowError {
  let user = self.ctx.repository.find_user_by_id(id)
  let ext = self.ctx.ext_repository.find_ext(id)
  let real_name = match self.ctx.user_provider {
    Some(get_user) => {
      let info = (get_user)(user.real_name)
      info.real_name
    }
    None => user.real_name
  }
  ignore(self.ctx.id_generator)
  ignore(self.ctx.clock)
  "\{real_name}/\{ext}"
}
