///|
fn sample(version : Int, endian : Endian) -> Dataset {
  let columns = [
    Column::new("字节", Byte, label="编码", value_labels="状态"),
    Column::new("small", Int16),
    Column::new("large", Int32),
    Column::new("single", Float32),
    Column::new("double_value", Float64, format="%td"),
    Column::new("name", Str(12)),
    Column::new("longtext", StrL),
    Column::new("blob", StrL),
  ]
  let schema = Schema::new(
    columns,
    version~,
    endian~,
    label="中文数据集",
    timestamp="07 Nov 2026 12:34",
    sort_order=[1],
    value_labels=[
      {
        name: "状态",
        entries: [
          { value: 1, text: "是", },
          { value: 2147483647, text: "未知", },
        ],
      },
    ],
    characteristics=[
      {
        variable: "_dta",
        name: "note1",
        data: @utf8.encode("数据说明\u0000"),
      },
    ],
  )
  let rows : Array[Array[Value]] = [
    [
      Integer(-127),
      Integer(-32767),
      Integer(-2147483647),
      Number(-1.25),
      Number(-0.0),
      Text("中文😀"),
      Text("长文本"),
      Binary(b"\x00\xff\x80"),
    ],
    [
      Integer(100),
      Integer(32740),
      Integer(2147483620),
      Number(1.5),
      Number(24000.0),
      Text("abcdefghijkl"),
      Text(""),
      Binary(b""),
    ],
  ]
  for tag in 0..<=26 {
    rows.push([
      Missing(tag),
      Missing(tag),
      Missing(tag),
      Missing(tag),
      Missing(tag),
      Text(""),
      Text("重复"),
      Binary(b"a\x00b"),
    ])
  }
  { schema, rows, }
}

///|
test "118/119 both endians, all numeric types/missings, UTF8, binary strL, labels" {
  for version in [118, 119] {
    for endian in ([Little, Big] : Array[Endian]) {
      let data = sample(version, endian)
      let bytes = encode(data)
      let reader = open(bytes)
      assert_eq(reader.read(), data)
      assert_eq(reader.row_count(), 29)
      assert_eq(reader.read_rows(offset=1, limit=1, columns=[5, 0]), [
        [Text("abcdefghijkl"), Integer(100)],
      ])
      let selected = reader.select([5, 0], offset=1, limit=2)
      assert_eq(selected.schema.sort_order, [2])
      assert_eq(open(encode(selected)).read(), selected)
      assert_eq(reader.select([5]).schema.sort_order, [])
      let wire = data.to_exchange()
      let restored = from_exchange(@json.parse(wire.stringify()))
      assert_eq(encode(restored), bytes)
      match restored.rows[0][4] {
        Number(n) => assert_eq(n.reinterpret_as_uint64(), 0x8000000000000000UL)
        _ => fail("number expected")
      }
    }
  }
}

///|
test "empty dataset and empty rows" {
  let empty : Dataset = { schema: Schema::new([]), rows: [], }
  assert_eq(open(encode(empty)).read(), empty)
  let schema = Schema::new([Column::new("x", Float64)])
  let no_rows : Dataset = { schema, rows: [], }
  assert_eq(open(encode(no_rows)).read(), no_rows)
}

///|
test "Stata official files may have a newline after logical EOF" {
  let original = encode(sample(118, Little))
  for suffix in [b"\n", b"\r\n"] {
    let b = Bytes::from_iter(original.iter().concat(suffix.iter()))
    assert_eq(open(b).read(), open(original).read())
  }
  let garbage = Bytes::from_iter(original.iter().concat(b"garbage".iter()))
  rejects(() => ignore(open(garbage)))
}

///|
fn rejects(f : () -> Unit raise DtaError) -> Unit raise {
  try f() catch {
    _ => ()
  } noraise {
    _ => fail("expected DtaError")
  }
}

///|
test "reject truncated input at every byte boundary" {
  let bytes = encode({
    schema: Schema::new([Column::new("x", Float64)]),
    rows: [[Number(1.0)]],
  })
  for len in 0..<bytes.length() {
    rejects(() => ignore(open(bytes[:len].to_owned())))
  }
}

///|
test "reject wrong shapes, numeric overflow, invalid missing, UTF8 widths" {
  let schema = Schema::new([Column::new("x", Byte)])
  for
    row in (
      [[Integer(101)], [Integer(-128)], [Missing(27)], [Number(2.0)], []] :
      Array[Array[Value]]) {
    rejects(() => ignore(encode({ schema, rows: [row], })))
  }
  let string_schema = Schema::new([Column::new("x", Str(2))])
  rejects(() => {
    ignore(encode({ schema: string_schema, rows: [[Text("中")]], }))
  })
  rejects(() => {
    ignore(encode({ schema: string_schema, rows: [[Text("\u0000")]], }))
  })
  let reader = open(encode(sample(118, Little)))
  rejects(() => ignore(reader.read_rows(offset=-1)))
  rejects(() => ignore(reader.read_rows(limit=30)))
  rejects(() => ignore(reader.read_rows(columns=[0, 0])))
  rejects(() => ignore(reader.read_rows(columns=[8])))
}

///|
test "reader metadata copies do not invalidate row decoding" {
  let reader = open(encode(sample(118, Little)))
  let schema = reader.schema()
  schema.columns.clear()
  schema.value_labels[0].entries.clear()
  assert_eq(reader.read_rows(limit=1)[0].length(), 8)
  assert_eq(reader.schema().value_labels[0].entries.length(), 2)
}
