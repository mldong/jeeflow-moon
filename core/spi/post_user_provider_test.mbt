// issues/259：独立可选 PostUserProvider 的 async/sync 注册与请求派生语义。

///|
test "post provider: 默认未注册" {
  let ctx : @spi.Ctx[Int, Int] = @spi.Ctx::new(1, 2)
  assert_true(ctx.post_user_provider is None)
}

///|
async test "post provider: async/sync 两种注册口共用同一 find_by_post 形状" {
  let calls : Array[String] = []
  let lookup : (String) -> Array[String] raise @error.JeeflowError = code => {
    calls.push(code)
    ["\{code}-u1", "\{code}-u2"]
  }
  let sync_provider : @spi.PostUserProviderFnsSync = {
    find_by_post: lookup,
  }
  let sync_ctx : @spi.Ctx[Int, Int] = @spi.Ctx::new(1, 2).with_post_user_provider_sync(sync_provider)
  let sync_fn = sync_ctx.post_user_provider.unwrap().find_by_post
  assert_true(sync_fn("syncPost") == ["syncPost-u1", "syncPost-u2"])

  let async_provider : @spi.PostUserProviderFns = {
    find_by_post: @spi.async_of_sync(lookup),
  }
  let async_ctx : @spi.Ctx[Int, Int] = @spi.Ctx::new(1, 2).with_post_user_provider(async_provider)
  let async_fn = async_ctx.post_user_provider.unwrap().find_by_post
  assert_true(async_fn("asyncPost") == ["asyncPost-u1", "asyncPost-u2"])
  assert_true(calls == ["syncPost", "asyncPost"])
}

///|
async test "post provider: for_request 携带闭包且共享同一查询状态" {
  let calls : Array[String] = []
  let provider : @spi.PostUserProviderFnsSync = {
    find_by_post: code => {
      calls.push(code)
      ["member"]
    },
  }
  let base : @spi.Ctx[Int, Int] = @spi.Ctx::new(1, 101).with_post_user_provider_sync(provider)
  let derived = base.for_request(2, 202)
  let derived_fn = derived.post_user_provider.unwrap().find_by_post
  let base_fn = base.post_user_provider.unwrap().find_by_post
  assert_true(derived_fn("d1") == ["member"])
  assert_true(base_fn("b1") == ["member"])
  assert_true(calls == ["d1", "b1"])
}
