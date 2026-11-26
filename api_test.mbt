///|
test "public library example" {
  let schema = @dta.Schema::new(
    [
      @dta.Column::new("id", @dta.Int32),
      @dta.Column::new("备注", @dta.StrL, label="访谈记录"),
    ],
    label="示例",
  )
  let dataset : @dta.Dataset = {
    schema,
    rows: [
      [@dta.Integer(1), @dta.Text("中文😀")],
      [@dta.Missing(1), @dta.Text("")],
    ],
  }
  let bytes = @dta.encode(dataset)
  let reader = @dta.open(bytes)
  assert_eq(reader.column_count(), 2)
  assert_eq(reader.column_indices(["备注", "id"]), [1, 0])
  assert_eq(reader.row_count(), 2)
  reader.verify(batch_size=1)
  assert_true(reader.preview().contains("中文😀"))
  assert_true(reader.describe().contains("访谈记录"))
  assert_eq(reader.read_rows(offset=1, limit=1, columns=[0]), [
    [@dta.Missing(1)],
  ])
  assert_eq(@dta.encode(@dta.from_exchange(dataset.to_exchange())), bytes)
  let lines : Array[String] = []
  reader.export_jsonl(line => lines.push(line), batch_size=1)
  assert_eq(lines.length(), 3)
  let input = lines.iter()
  assert_eq(@dta.encode(@dta.from_jsonl(() => input.next())), bytes)
  let selected = reader.column_indices(["备注"])
  let offsets = []
  let values = []
  reader.each_batch(
    (start, batch) => {
      offsets.push(start)
      for row in batch {
        values.push(row[0])
      }
    },
    columns=selected,
    batch_size=1,
  )
  assert_eq(offsets, [0, 1])
  assert_eq(values, [@dta.Text("中文😀"), @dta.Text("")])
}

///|
fn test_file() -> (@dta.ScratchFile, Array[Byte]) {
  let data = []
  let file : @dta.ScratchFile = {
    read_at: (pos, n) => Bytes::makei(n, i => data[pos.to_int() + i]),
    write_at: (pos, bytes) => {
      let mut i = pos.to_int()
      for b in bytes {
        if i == data.length() {
          data.push(b)
        } else {
          data[i] = b
        }
        i += 1
      }
    },
  }
  (file, data)
}

///|
test "streamed output matches the public encoder including strL and endianness" {
  let schema = @dta.Schema::new([
    @dta.Column::new("text", @dta.StrL),
    @dta.Column::new("data", @dta.StrL),
  ])
  let dataset : @dta.Dataset = {
    schema,
    rows: [
      [@dta.Text("中文"), @dta.Binary(b"abc\x00")],
      [@dta.Text("abc"), @dta.Text("中文")],
      [@dta.Binary(b"abc\x00"), @dta.Binary(b"")],
      [@dta.Binary(b""), @dta.Text("")],
    ],
  }
  let lines = []
  @dta.open(@dta.encode(dataset)).export_jsonl(line => lines.push(line))
  for version in [118, 119] {
    for endian in [@dta.Little, @dta.Big] {
      let input = lines.iter()
      let (output, bytes) = test_file()
      let (scratch, _) = test_file()
      @dta.write_jsonl(
        () => input.next(),
        output.write_at,
        scratch~,
        version~,
        endian~,
      )
      let expected = @dta.encode({
        ..dataset,
        schema: { ..schema, version, endian, },
      })
      assert_eq(Bytes::from_array(bytes), expected)
    }
  }
}

///|
test "stream writes a header-only DTA and propagates short scratch reads" {
  let lines = []
  let empty : @dta.Dataset = { schema: @dta.Schema::new([]), rows: [], }
  @dta.open(@dta.encode(empty)).export_jsonl(line => lines.push(line))
  let empty_source = lines.iter()
  let scratch : @dta.ScratchFile = {
    read_at: (_, _) => fail("unexpected scratch read"),
    write_at: (_, _) => fail("unexpected scratch write"),
  }
  let (output, bytes) = test_file()
  @dta.write_jsonl(() => empty_source.next(), output.write_at, scratch~)
  assert_eq(Bytes::from_array(bytes), @dta.encode(empty))
  let data : @dta.Dataset = {
    schema: @dta.Schema::new([@dta.Column::new("s", @dta.StrL)]),
    rows: [[@dta.Text("abc")]],
  }
  let more = []
  @dta.open(@dta.encode(data)).export_jsonl(line => more.push(line))
  let source = more.iter()
  let short : @dta.ScratchFile = {
    read_at: (_, _) => b"",
    write_at: (_, _) => (),
  }
  try {
    @dta.write_jsonl(() => source.next(), (_, _) => (), scratch=short)
    abort("expected a short-read error")
  } catch {
    e => assert_true(e.to_string().contains("short strL scratch read"))
  }
}
