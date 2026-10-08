// issues/151 X10 —— spec/10 的 storageType 五档在 moon 侧的分腿判据（v0.1.33 那一批）。
// 全内存档（InMemoryTableWriter + InMemoryMetaProvider）：这里验的是**元数据变换本身**
// （EXPAND 展开/反展开、JSON 串/回解、子表递归与外键、直通与不重复平铺）；
// 真库落点（列名对不上被滤、AUTO_INCREMENT 交库自增）由 demo/cmd/t1_mysql 的 F149F 验。

///|
fn x10_obj(entries : Array[(String, Json)]) -> Json {
  @json.object_of(entries)
}

///|
/// 主表 orders：merchant_name 直写、address 展成三列、extra 存 JSON 串、
/// items 走 ONE2MANY（外键 order_id）、top 走 ONE2ONE（外键 top_order_id）。
/// ⚠ ONE2ONE 的外键**刻意不回落** `id`：内存 writer 会把 `row["id"]` 覆写成它自己的计数
/// （真库 writer 不会——真库那档由 F149F 验），所以这里显式给一个不会被覆写的列名。
fn x10_fixture() -> (
  @persist.InMemoryMetaProvider,
  @persist.InMemoryTableWriter,
  @persist.MetaTableWriter,
) {
  let provider = @persist.InMemoryMetaProvider::new()
  let main = @persist.TableMeta::make("orders", "订单")
  main.add_field(@persist.FieldMeta::make("process_instance_id", "BIGINT", "实例ID"))
  main.add_field(@persist.FieldMeta::make("apply_user_id", "VARCHAR(64)", "申请人"))
  main.add_field(@persist.FieldMeta::make("merchant_name", "VARCHAR(64)", "商户"))
  main.add_field(@persist.FieldMeta::make(
    "address", "VARCHAR(64)", "地址",
    name="address",
    storage_type=@persist.Expand,
    expand_fields=Map([("province", "province"), ("city", "city"), ("detail", "detail_addr")]),
  ))
  main.add_field(@persist.FieldMeta::make("extra", "TEXT", "附加", storage_type=@persist.Json))
  main.add_field(@persist.FieldMeta::make(
    "items", "VARCHAR(64)", "明细",
    storage_type=@persist.One2Many,
    target_table="biz_item",
    foreign_key="order_id",
  ))
  main.add_field(@persist.FieldMeta::make(
    "top", "VARCHAR(64)", "抬头",
    storage_type=@persist.One2One,
    target_table="biz_top",
    foreign_key="top_order_id",
  ))
  provider.register(main)
  let writer = @persist.InMemoryTableWriter::new()
  let mw = @persist.MetaTableWriter::make(writer, provider.as_provider())
  (provider, writer, mw)
}

///|
/// 行读取端口：直接架在内存 writer 的行上（真库侧的同一对端口由宿主 DevQueryApi 供）。
/// 纯内存读 ⇒ 经 `@spi.async_of_sync` 桥，注册点零警告（同 persist.mbt 的 `as_provider`）。
fn x10_reader(w : @persist.InMemoryTableWriter) -> @persist.DynamicTableReaderFns {
  let one : (@persist.TableKeyQuery) -> Map[String, Json]? raise @error.JeeflowError = fn(
    q,
  ) { w.get_row_by_key(q.table, q.column, q.value) }
  let many : (@persist.TableKeyQuery) -> Array[Map[String, Json]] raise @error.JeeflowError = fn(
    q,
  ) {
    let out : Array[Map[String, Json]] = []
    for row in w.get_table_rows(q.table) {
      match row.get(q.column) {
        Some(v) =>
          match @json.as_i64(v) {
            Some(n) => if n == q.value { out.push(row) }
            None => ()
          }
        None => ()
      }
    }
    out
  }
  { row_by_key: @spi.async_of_sync(one), rows_by_key: @spi.async_of_sync(many) }
}
///|
fn x10_main_data(iid : Int64) -> Map[String, Json] {
  let data : Map[String, Json] = Map([])
  data["process_instance_id"] = @json.number_of(iid)
  data["apply_user_id"] = @json.string_of("boss1")
  data["merchant_name"] = @json.string_of("甲公司")
  data["address"] = x10_obj([
    ("province", @json.string_of("浙")),
    ("city", @json.string_of("杭")),
    ("detail", @json.string_of("A 路 1 号")),
  ])
  data["extra"] = x10_obj([("tag", @json.string_of("急"))])
  data["items"] = @json.array_of([
    x10_obj([("item_name", @json.string_of("行一")), ("qty", @json.number_of(2L))]),
    x10_obj([("item_name", @json.string_of("行二"))]),
  ])
  data["top"] = x10_obj([("title", @json.string_of("抬头一"))])
  data
}

async test "x10: storageType 名称/数字双解析（spec/10 §2.1）" {
  assert_true(@persist.storage_type_of(@json.string_of("JSON")) == @persist.Json)
  assert_true(@persist.storage_type_of(@json.string_of("one2many")) == @persist.One2Many)
  assert_true(@persist.storage_type_of(@json.number_of(2L)) == @persist.Expand)
  assert_true(@persist.storage_type_of(@json.number_of(4L)) == @persist.One2One)
  assert_true(@persist.storage_type_of(@json.string_of("3")) == @persist.Json)
  // 未知值/缺省 ⇒ Normal，不报错（spec/09 §4.6「未知值不炸」同档）
  assert_true(@persist.storage_type_of(@json.string_of("没这个档")) == @persist.Normal)
  assert_true(@persist.storage_type_of(@json.number_of(99L)) == @persist.Normal)
}

///|
async test "x10 写侧: EXPAND 落多列／JSON 落串／子表按外键递归并继承 apply_user_id" {
  let (_p, writer, mw) = x10_fixture()
  let pk = mw.insert("orders", x10_main_data(5001L))
  assert_true(pk != 0L)
  let row = writer.get_row_by_key("orders", "process_instance_id", 5001L)
  assert_true(row is Some(_))
  let r = row.unwrap()
  assert_true(r.get("address") is None)   // 展开后不再有 address 这一列
  assert_true(cell_of(r.get("province")) == "浙")
  assert_true(cell_of(r.get("city")) == "杭")
  assert_true(cell_of(r.get("detail_addr")) == "A 路 1 号")   // expandFields 允许改名
  // JSON 档落的是串（不是嵌套对象）——否则 MySQL 的 TEXT 列收到对象会被 writer 按 stringify 兜底，
  // 读侧也就无从判断"这列本来是 JSON"
  assert_true(@json.as_str(r.get("extra").unwrap()).unwrap_or("").contains("\"tag\""))
  // 子表：两条明细，外键＝主表主键，apply_user_id 自主表继承（spec/10 §5 子表系统用户字段）
  let items = writer.get_table_rows("biz_item")
  assert_eq(items.length(), 2)
  for _, it in items {
    assert_true(@json.as_i64(it.get("order_id").unwrap()) == Some(pk))
    assert_true(cell_of(it.get("apply_user_id")) == "boss1")
  }
  assert_true(cell_of(items[0].get("item_name")) == "行一")
  assert_true(@json.as_i64(items[0].get("qty").unwrap()) == Some(2L))
  // ONE2ONE 一条
  let tops = writer.get_table_rows("biz_top")
  assert_eq(tops.length(), 1)
  assert_true(cell_of(tops[0].get("title")) == "抬头一")
}

///|
async test "x10 读侧: 反展开／JSON 回解／子表组装，且展开列不重复平铺（spec/10 §6）" {
  let (provider, writer, mw) = x10_fixture()
  let pk = mw.insert("orders", x10_main_data(5002L))
  let reader = @persist.MetaTableReader::make(
    provider.as_provider(),
    x10_reader(writer),
  )
  let got = reader.read_by_process_instance("orders", 5002L)
  assert_true(got is Some(_))
  let row = got.unwrap()
  // 主键取的是**主表的 id 列**（不是幂等键），子表外键也正是它 ⇒ 这里按 pk 读回
  assert_true(pk != 0L)
  let addr = row.get("address")
  assert_true(addr is Some(_))
  assert_true(cell_of(@json.get(addr.unwrap(), "province")) == "浙")
  assert_true(cell_of(@json.get(addr.unwrap(), "detail")) == "A 路 1 号")
  // 展开列不再顶层平铺
  assert_true(row.get("province") is None)
  assert_true(row.get("detail_addr") is None)
  // JSON 档回解成对象
  assert_true(cell_of(@json.get(row.get("extra").unwrap(), "tag")) == "急")
  // 子表组装：数组 / 对象
  let items = @json.as_array(row.get("items").unwrap())
  assert_true(items is Some(_))
  assert_eq(items.unwrap().length(), 2)
  assert_true(cell_of(@json.get(items.unwrap()[1], "item_name")) == "行二")
  assert_true(cell_of(@json.get(row.get("top").unwrap(), "title")) == "抬头一")
  // 未消费的上下文列原样带出（键小写）
  assert_true(row.get("process_instance_id") is Some(_))
  assert_true(row.get("merchant_name") is Some(_))
  // 无记录 ⇒ None（不猜空对象）
  assert_true(reader.read_by_process_instance("orders", 9999L) is None)
}

///|
async test "x10 边界: 无元数据回落基础 writer／更新档不动子表（spec/10 §3·§5）" {
  let (_p, writer, mw) = x10_fixture()
  // ① 没配元数据的表 ⇒ 整批委托基础 writer（address 原样落，不展开）
  let raw = x10_main_data(5003L)
  let _ = mw.insert("no_meta_table", raw)
  let r0 = writer.get_row_by_key("no_meta_table", "process_instance_id", 5003L)
  assert_true(r0 is Some(_))
  assert_true(r0.unwrap().get("address") is Some(_))
  assert_true(r0.unwrap().get("province") is None)
  assert_true(writer.get_table_rows("biz_item").is_empty())   // 无元数据 ⇒ 不认得子表语义
  // ② 正常主表先落一行，再走更新档：NORMAL 列改得到、子表**不参与**中途更新
  let pk = mw.insert("orders", x10_main_data(5004L))
  assert_eq(writer.get_table_rows("biz_item").length(), 2)
  let upd : Map[String, Json] = Map([])
  upd["process_instance_id"] = @json.number_of(5004L)
  upd["merchant_name"] = @json.string_of("改过的商户")
  upd["items"] = @json.array_of([x10_obj([("item_name", @json.string_of("不该新增"))])])
  mw.update_by_key("orders", upd, "process_instance_id", 5004L)
  let r1 = writer.get_row_by_key("orders", "process_instance_id", 5004L).unwrap()
  assert_true(cell_of(r1.get("merchant_name")) == "改过的商户")
  assert_eq(writer.get_table_rows("biz_item").length(), 2)   // 子表一条没加、没删
  assert_true(pk != 0L)
}

///|
/// 真库形状档：主表行的 `id` 以**数字串**回来（宿主普遍把 bigint 字符串化防雪花掉精度，
/// mldong 框架 `generic_row_to_json` 正是这一档）。判据＝子表真按解析出来的 Int64 外键去查了
/// （`seen` 收到 70001L）且 `items` 键出现。
/// ⚠ 这条**不是**修出来的判据：`@json.as_i64`（`core/json/json.mbt:61-81`）本就 Number/Str 双收，
/// v0.1.33 的实现已经对；本轮 10-08 装配到框架侧时我误把它当成"只认数字档"的缺口，动手加了
/// `row_int64`，变异对照（把取数改成 Number-only）才证伪——多余的那版已回退。
/// 缺的是**夹具形状**：原有 x10 读侧测试的 id 是数字档，串档这条腿没人钉，故补这一支；变异对照实测：把取数改成 Number-only 后这条红（`0 != 1`），改回即绿——
/// 判据是承重的，实现本来就是对的。补这一支（测试-only，
/// 不改任何发布件的行为；代次仍 0.1.33，随下一次发版一起进包）。
async test "x10 读侧: 主表 id 是数字串时子表仍按外键组装（真库 bigint 串档）" {
  let (provider, _w, _mw) = x10_fixture()
  let seen : Array[Int64] = []
  let main_row : Map[String, Json] = Map([])
  main_row["id"] = @json.string_of("70001")
  main_row["merchant_name"] = @json.string_of("串 id 商户")
  let one : (@persist.TableKeyQuery) -> Map[String, Json]? raise @error.JeeflowError = fn(q) {
    if q.table == "orders" { Some(main_row) } else { None }
  }
  let many : (@persist.TableKeyQuery) -> Array[Map[String, Json]] raise @error.JeeflowError = fn(
    q,
  ) {
    if q.table == "biz_item" { seen.push(q.value) }
    []
  }
  let reader = @persist.MetaTableReader::make(
    provider.as_provider(),
    { row_by_key: @spi.async_of_sync(one), rows_by_key: @spi.async_of_sync(many) },
  )
  let got = reader.read_by_process_instance("orders", 5099L)
  assert_true(got is Some(_))
  let row = got.unwrap()
  // 主键从串 "70001" 解出来，且原样交给外键查询（不是 0、不是没查）
  assert_eq(seen.length(), 1)
  assert_eq(seen[0], 70001L)
  assert_true(row.get("items") is Some(_))
  assert_true(row.get("top") is None)   // biz_top 档本次行源没给 ⇒ 不硬造空对象
}
