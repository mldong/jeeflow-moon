// audit8 R78（甲档）——元数据腿的列名匹配禁做「分隔符归一」，允许只折大小写。
// 条文＝规范 10 §5.1；基准＝java jeeflow-persist/.../meta/{TableMeta.java:41-44,
// MetaTableReader.java:125,MetaTableWriter.java:186} 全用 equalsIgnoreCase（只折大小写）。
// 本栈旧形状：column_names_equal 默认档走 normalize_column()（去下划线＋折大小写）⇒ 驼峰键能命中蛇形列；
// 且元数据腿五处调用（meta_reader.mbt:82/:95/:149、meta_writer.mbt:69/:71）全不传 strict~ ⇒ 恒宽松。

///|
fn r78_meta() -> @persist.TableMeta {
  let meta = @persist.TableMeta::make("biz_r78", "R78 表")
  meta.add_field(@persist.FieldMeta::make("merchant_name", "VARCHAR(64)", "商户"))
  meta
}

///|
fn r78_pair() -> (@persist.InMemoryTableWriter, @persist.MetaTableWriter) {
  let provider = @persist.InMemoryMetaProvider::new()
  provider.register(r78_meta())
  let writer = @persist.InMemoryTableWriter::new()
  (writer, @persist.MetaTableWriter::make(writer, provider.as_provider()))
}

///|
async test "r78 负向 表单键与元数据列只差分隔符则元数据腿必判不匹配" {
  // spec10 §5.1：merchant_name 这一列不得被驼峰键 merchantName 填上
  let (writer, mw) = r78_pair()
  let data : Map[String, Json] = Map([("merchantName", @json.string_of("驼峰值"))])
  let _ = mw.insert("biz_r78", data)
  let rows = writer.get_table_rows("biz_r78")
  assert_true(rows.length() >= 1)
  assert_true(rows[0].get("merchant_name") is None)
}

///|
async test "r78 阳性对照 只差大小写仍要取到值" {
  // 防过度收紧：java 档允许折大小写
  let (writer, mw) = r78_pair()
  let data : Map[String, Json] = Map([("MERCHANT_NAME", @json.string_of("大写形"))])
  let _ = mw.insert("biz_r78", data)
  let cell = writer.get_table_rows("biz_r78")[0].get("merchant_name")
  assert_true(cell == Some(@json.string_of("大写形")))
}

///|
async test "r78 回归 列名逐字相符照常落值" {
  let (writer, mw) = r78_pair()
  let data : Map[String, Json] = Map([("merchant_name", @json.string_of("逐字值"))])
  let _ = mw.insert("biz_r78", data)
  let cell = writer.get_table_rows("biz_r78")[0].get("merchant_name")
  assert_true(cell == Some(@json.string_of("逐字值")))
}

///|
test "r78 档位单点 strict 档禁归一但折大小写 默认宽松档保持不动" {
  // 默认宽松档留给业务表那条轴（spec09 §列匹配），本卡不许越界改掉它
  let row : Map[String, Json] = Map([("company_name", @json.string_of("v"))])
  assert_true(@persist.find_data_key(row, "companyName", strict=true) is None)
  assert_true(@persist.find_data_key(row, "COMPANY_NAME", strict=true) == Some("company_name"))
  assert_true(@persist.find_data_key(row, "companyName") == Some("company_name"))
}

///|
async test "r78 读侧判据 assemble 的邻列误读与逐字回显两向" {
  // 咬 meta_reader.mbt:82/:95 两处。两向配对防"负向断言空转"：
  //   ① 行里只有驼峰键 ⇒ merchant_name 这一列绝不允许被回显成驼峰键的值（宽松档正是这么错的）
  //   ② 行里是逐字蛇形键 ⇒ 必须回显到值（证明①不是因为键名整个对不上而空转成立）
  let reader = r78_reader()
  let meta = r78_meta()
  let camel_row : Map[String, Json] = Map([("merchantName", @json.string_of("驼峰值"))])
  let out_camel = reader.assemble(meta, camel_row)
  assert_true(out_camel.get("merchant_name") != Some(@json.string_of("驼峰值")))
  let snake_row : Map[String, Json] = Map([("merchant_name", @json.string_of("逐字值"))])
  let out_snake = reader.assemble(meta, snake_row)
  assert_true(out_snake.get("merchant_name") == Some(@json.string_of("逐字值")))
}

///|
fn r78_reader() -> @persist.MetaTableReader {
  let provider = @persist.InMemoryMetaProvider::new()
  provider.register(r78_meta())
  let writer = @persist.InMemoryTableWriter::new()
  @persist.MetaTableReader::make(provider.as_provider(), x10_reader(writer))
}

// ── 甲′补的两枚：直通闸本身（T1-F F149F 的真库红就是它造成的）──
// 元数据声明过蛇形列 ⇒ 旧写法用**宽松** find_field 判"有没有被声明"，驼峰幂等键被判成
// "已声明所以不用直通"，而字段消费腿在 strict 下又没写这一列 ⇒ 两不管＝静默丢列（真库里落 NULL）。
// java 的 findField 只折大小写，不做分隔符归一 ⇒ 直通闸必须同尺。
///|
fn r78_idem_meta() -> @persist.TableMeta {
  let meta = @persist.TableMeta::make("biz_r78_idem", "R78 幂等键表")
  meta.add_field(@persist.FieldMeta::make("process_instance_id", "BIGINT", "流程实例id"))
  meta.add_field(@persist.FieldMeta::make("merchant_name", "VARCHAR(64)", "商户"))
  meta
}

///|
async test "r78 甲′ 直通闸 驼峰幂等键不被声明判据吞掉" {
  let provider = @persist.InMemoryMetaProvider::new()
  provider.register(r78_idem_meta())
  let writer = @persist.InMemoryTableWriter::new()
  let mw = @persist.MetaTableWriter::make(writer, provider.as_provider())
  let data : Map[String, Json] = Map([
    ("processInstanceId", @json.number_of(990995L),
    ), ("merchantName", @json.string_of("驼峰商户")),
  ])
  let _ = mw.insert("biz_r78_idem", data)
  let rows = writer.get_table_rows("biz_r78_idem")
  assert_true(rows.length() >= 1)
  // 两个驼峰键都没被元数据腿消费（strict 禁归一）⇒ 必须整把直通出去，不许静默丢
  assert_true(rows[0].get("processInstanceId") == Some(@json.number_of(990995L)))
  assert_true(rows[0].get("merchantName") == Some(@json.string_of("驼峰商户")))
}

///|
async test "r78 甲′ 直通闸阳性对照 逐字相符的键由字段消费、不重复直通" {
  let provider = @persist.InMemoryMetaProvider::new()
  provider.register(r78_idem_meta())
  let writer = @persist.InMemoryTableWriter::new()
  let mw = @persist.MetaTableWriter::make(writer, provider.as_provider())
  let data : Map[String, Json] = Map([
    ("process_instance_id", @json.number_of(990996L),
    ), ("apply_user_id", @json.string_of("u1")),
  ])
  let _ = mw.insert("biz_r78_idem", data)
  let row = writer.get_table_rows("biz_r78_idem")[0]
  // 幂等键由字段腿写进列（值一把），直通不把它覆盖成第二把键；apply_user_id 未声明 ⇒ 直通
  assert_true(row.get("process_instance_id") == Some(@json.number_of(990996L)))
  assert_true(row.get("apply_user_id") == Some(@json.string_of("u1")))
}
