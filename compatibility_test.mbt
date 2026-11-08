///|
test "writer shares strL content across rows and columns without mixing text and binary" {
  for version in [118, 119] {
    for endian in [Endian::Little, Endian::Big] {
      let data : Dataset = {
        schema: Schema::new(
          [Column::new("a", StrL), Column::new("b", StrL)],
          version~,
          endian~,
        ),
        rows: [
          [Text("abc"), Binary(b"abc\x00")],
          [Binary(b""), Text("")],
          [Binary(b"abc\x00"), Text("abc")],
          [Binary(b""), Binary(b"xyz")],
        ],
      }
      let bytes = encode(data)
      // Four distinct objects: text abc, binary abc+NUL, empty binary, xyz.
      // Empty text uses the null reference and emits no object.
      let start = find_tag(bytes, "<strls>") + 7
      let end = find_tag(bytes, "</strls>")
      assert_eq(end - start, 4 * 20 + 4 + 4 + 0 + 3)
      let reader = open(bytes)
      assert_eq(reader.read_rows(), data.rows)
      reader.verify(batch_size=1)
      assert_eq(encode(data), bytes)
      assert_eq(open(encode(reader.select([1, 0]))).read_rows(), [
        [Binary(b"abc\x00"), Text("abc")],
        [Text(""), Binary(b"")],
        [Text("abc"), Binary(b"abc\x00")],
        [Binary(b"xyz"), Binary(b"")],
      ])
    }
  }
}

///|
test "timestamp calendar validation, space-padded day and leap centuries" {
  for
    timestamp in [
      "", " 7 Nov 2026 00:00", "07 Nov 2026 23:59", "29 Feb 2000 12:34", "29 Feb 2024 12:34",
    ] {
    let data : Dataset = { schema: Schema::new([], timestamp~), rows: [], }
    assert_eq(open(encode(data)).schema().timestamp, timestamp)
  }
  for
    timestamp in [
      "xxxxxxxxxxxxxxxxx", "29 Feb 1900 12:34", "29 Feb 2026 12:34", "31 Apr 2026 12:34",
      "00 Nov 2026 12:34", "07 Nov 0000 12:34", "07 Nov 2026 24:00", "07 Nov 2026 23:60",
      "07 Xxx 2026 12:34", "07 Nov 2026 12-34", "7 Nov 2026 12:34",
    ] {
    rejects(() => {
      ignore(encode({ schema: Schema::new([], timestamp~), rows: [], }))
    })
  }
}

///|
test "lazy strL decoding keeps unrelated columns readable and verify checks unused payloads" {
  let data : Dataset = {
    schema: Schema::new([Column::new("id", Int32), Column::new("s", StrL)]),
    rows: [[Integer(3), Text("abc")]],
  }
  let bytes = encode(data)
  let gso = find_tag(bytes, "GSO")
  let broken = put_uint(bytes, gso + 20, 255, 1)
  let reader = open(broken)
  assert_eq(reader.read_rows(columns=[0]), [[Integer(3)]])
  rejects(() => ignore(reader.read_rows(columns=[1])))
  rejects(() => reader.verify())
  let row = find_tag(bytes, "<data>") + 6
  // Remove the reference while leaving the invalid object in the pool.
  let unused = open(put_uint(broken, row + 4, 0, 8))
  assert_eq(unused.read_rows(), [[Integer(3), Text("")]])
  rejects(() => unused.verify())
  rejects(() => reader.verify(batch_size=0))
}

///|
test "shared text and binary strL references survive selection across batches" {
  for version in [118, 119] {
    let data : Dataset = {
      schema: Schema::new(
        [Column::new("a", StrL), Column::new("b", StrL)],
        version~,
      ),
      rows: [[Text("中文😀"), Binary(b"\x00\xff")], [Text(""), Text("")]],
    }
    let bytes = encode(data)
    let first = find_tag(bytes, "<data>") + 6
    let modified = Bytes::makei(bytes.length(), i => {
      if i >= first + 16 && i < first + 32 {
        bytes[i - 16]
      } else {
        bytes[i]
      }
    })
    let reader = open(modified)
    let expected : Array[Value] = [Text("中文😀"), Binary(b"\x00\xff")]
    assert_eq(reader.read_rows(), [expected, expected])
    assert_eq(reader.read_rows(offset=1, limit=1), [expected])
    reader.verify(batch_size=1)
    assert_eq(open(encode(reader.select([1, 0]))).read_rows()[1], [
      Binary(b"\x00\xff"),
      Text("中文😀"),
    ])
  }
}
