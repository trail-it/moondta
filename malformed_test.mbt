///|
fn put_uint(b : Bytes, at : Int, value : UInt64, n : Int) -> Bytes {
  Bytes::makei(b.length(), i => {
    if i >= at && i < at + n {
      (value >> ((i - at) * 8)).to_byte()
    } else {
      b[i]
    }
  })
}

///|
fn find_tag(b : Bytes, tag : String) -> Int {
  b[:].find(@utf8.encode(tag)[:]).unwrap()
}

///|
test "bad maps, unknown types, corrupted labels and characteristics" {
  let b = encode(sample(118, Little))
  let map = find_tag(b, "<map>") + 5
  for
    (field, value) in [
      (0, 1UL),
      (1, 0UL),
      (2, 0xffffffffffffffffUL),
      (9, 100UL),
      (13, 123UL),
    ] {
    rejects(() => ignore(open(put_uint(b, map + field * 8, value, 8))))
  }
  let types = find_tag(b, "<variable_types>") + 16
  rejects(() => ignore(open(put_uint(b, types, 0, 2))))
  rejects(() => ignore(open(put_uint(b, types, 2046, 2))))
  let ch = find_tag(b, "<ch>") + 4
  rejects(() => ignore(open(put_uint(b, ch, 257, 4))))
  let lbl = find_tag(b, "<lbl>") + 4
  rejects(() => ignore(open(put_uint(b, lbl, 0x7fffffffUL, 4))))
  let offsets = lbl + 4 + 129 + 3 + 8
  rejects(() => ignore(open(put_uint(b, offsets, 0x7fffffffUL, 4))))
  let name = find_tag(b, "<varnames>") + 10
  rejects(() => ignore(open(put_uint(b, name, 255, 1))))
}

///|
test "strL references, payload kind, terminator and binary are distinguished" {
  let d : Dataset = {
    schema: Schema::new([Column::new("s", StrL)]),
    rows: [[Text("abc")]],
  }
  let b = encode(d)
  let data = find_tag(b, "<data>") + 6
  let unresolved = put_uint(b, data, 2, 2)
  let r = open(unresolved)
  rejects(() => ignore(r.read()))
  let gso = find_tag(b, "GSO")
  rejects(() => ignore(open(put_uint(b, gso + 15, 128, 1))))
  rejects(() => ignore(open(put_uint(b, gso + 23, 42, 1))))
  rejects(() => open(put_uint(b, gso + 21, 0, 1)).verify())
  let binary = put_uint(b, gso + 15, 129, 1)
  assert_eq(open(binary).read_rows(), [[Binary(b"abc\x00")]])
}

///|
test "reserved numeric codes and noncanonical missing patterns fail on row decode" {
  for storage in ([Byte, Int16, Int32, Float32, Float64] : Array[Storage]) {
    let row : Array[Value] = match storage {
      Float32 | Float64 => [Number(0.0)]
      _ => [Integer(0)]
    }
    let b = encode({
      schema: Schema::new([Column::new("x", storage)]),
      rows: [row],
    })
    let at = find_tag(b, "<data>") + 6
    let bad : UInt64 = match storage {
      Byte => 0x80
      Int16 => 0x8000
      Int32 => 0x80000000
      Float32 => 0x7f000001
      _ => 0x7fe0000000000001
    }
    let r = open(put_uint(b, at, bad, storage.width()))
    rejects(() => ignore(r.read()))
    rejects(() => r.verify())
  }
  let s = Schema::new([Column::new("x", Float64)])
  rejects(() => {
    ignore(
      encode({
        schema: s,
        rows: [[Number(0x7ff8000000000000UL.reinterpret_as_double())]],
      }),
    )
  })
  rejects(() => {
    ignore(
      encode({
        schema: s,
        rows: [[Number(0x7ff0000000000000UL.reinterpret_as_double())]],
      }),
    )
  })
}

///|
test "schema errors and exchange corruption are rejected" {
  rejects(() => {
    ignore(
      encode({
        schema: Schema::new([Column::new("double", Float64)]),
        rows: [],
      }),
    )
  })
  rejects(() => {
    ignore(
      encode({
        schema: Schema::new([Column::new("x", Byte), Column::new("x", Byte)]),
        rows: [],
      }),
    )
  })
  rejects(() => {
    ignore(
      encode({ schema: Schema::new([Column::new("x", Str(2046))]), rows: [], }),
    )
  })
  rejects(() => {
    ignore(encode({ schema: Schema::new([], version=117), rows: [], }))
  })
  let valid = sample(118, Little).to_exchange()
  guard valid is Object(obj) else { fail("exchange must be an object") }
  obj["moondta_exchange"] = 2
  rejects(() => ignore(from_exchange(valid)))
  obj["moondta_exchange"] = 1
  obj["rows"] = [[{ "binary": [256] }]]
  rejects(() => ignore(from_exchange(valid)))
  obj["rows"] = [[{ "number_bits": "10000000000000000" }]]
  rejects(() => ignore(from_exchange(valid)))
  obj["rows"] = [[{ "int": 1, "text": "two keys" }]]
  rejects(() => ignore(from_exchange(valid)))
}

///|
test "deterministic byte mutations produce data or checked errors, never traps" {
  let original = encode(sample(119, Big))
  let mut seed : UInt = 123456789
  for _ in 0..<600 {
    seed = seed * 1664525U + 1013904223U
    let at = (seed % original.length().reinterpret_as_uint()).reinterpret_as_int()
    seed = seed * 1664525U + 1013904223U
    let mutated = Bytes::makei(original.length(), i => {
      if i == at {
        (seed >> 24).to_byte()
      } else {
        original[i]
      }
    })
    ignore(open(mutated).read()) catch {
      _ => ()
    }
  }
}

///|
test "verification checks unreferenced text and last-batch references" {
  let data : Dataset = {
    schema: Schema::new([Column::new("s", StrL)]),
    rows: [[Text("shared")], [Text("shared")], [Binary(b"\\xff")]],
  }
  let bytes = encode(data)
  let at = find_tag(bytes, "<data>") + 6
  let reader = open(bytes)
  reader.verify(batch_size=1)
  reader.verify(batch_size=2)
  let dangling = put_uint(bytes, at + 16, 91UL, 2)
  rejects(() => open(dangling).verify(batch_size=2))
  let orphan = put_uint(put_uint(bytes, at, 0UL, 8), at + 8, 0UL, 8)
  let corrupted = put_uint(orphan, find_tag(orphan, "shared"), 255UL, 1)
  let r = open(corrupted)
  assert_eq(r.read_rows(), [[Text("")], [Text("")], [Binary(b"\\xff")]])
  rejects(() => r.verify())
}

///|
test "typed documents validate version and row shape at import" {
  let schema = Schema::new([Column::new("n", Int32)])
  let doc = Dataset::{ schema, rows: [[Integer(1)]], }.to_exchange()
  guard doc is Object(fields) else { abort("expected test document") }
  fields["moondta_exchange"] = 1.5
  rejects(() => ignore(from_exchange(doc)))
  fields["moondta_exchange"] = 1
  for row in ([[], [{ "int": 1 }, { "int": 2 }], { "int": 3 }] : Array[Json]) {
    fields["rows"] = [row]
    rejects(() => ignore(from_exchange(doc)))
  }
  fields["rows"] = []
  assert_eq(from_exchange(doc).rows, [])
}

///|
test "seekable projection and corruption keep absolute byte offsets above 2 GiB" {
  let count = 600000000
  let original = encode({
    schema: Schema::new([Column::new("id", Int32)]),
    rows: [[Integer(0)]],
  })
  let data = find_tag(original, "<data>") + 6
  let map = find_tag(original, "<map>") + 5
  let extra = (count - 1).to_int64() * 4L
  let last = data.to_int64() + extra
  let length = original.length().to_int64() + extra
  let mut header = put_uint(
    original,
    find_tag(original, "<N>") + 3,
    count.to_uint64(),
    8,
  )
  for field in 10..<14 {
    let pos = map + field * 8
    let mut value = 0UL
    for j in 0..<8 {
      value = value | (original[pos + j].to_uint64() << (j * 8))
    }
    header = put_uint(header, pos, value + extra.reinterpret_as_uint64(), 8)
  }
  let scratch : ScratchFile = {
    read_at: (_, _) => fail("unexpected index read"),
    write_at: (_, _) => fail("unexpected index write"),
  }
  for corrupt in [false, true] {
    let reader = open_stream(
      length,
      (pos, n) => {
        assert_true(n <= 65536)
        Bytes::makei(n, i => {
          let at = pos + i.to_int64()
          if at < data.to_int64() {
            header[at.to_int()]
          } else if at >= last + 4L {
            original[(at - extra).to_int()]
          } else if corrupt && at == last + 3L {
            b'\x80'
          } else if !corrupt && at == last {
            b'\x58'
          } else {
            b'\x00'
          }
        })
      },
      scratch~,
    )
    let lines = []
    if corrupt {
      try {
        reader.export_jsonl(s => lines.push(s), offset=count - 2)
        abort("expected reserved minimum")
      } catch {
        @dta.InvalidFile(offset~, message~) => {
          assert_eq(offset, last)
          assert_eq(message, "integer uses reserved minimum")
        }
        e => raise e
      }
      assert_eq(lines.length(), 2)
    } else {
      reader.export_jsonl(s => lines.push(s), offset=count - 2)
      assert_eq(lines[1], "[{\"int\":0}]\n")
      assert_eq(lines[2], "[{\"int\":88}]\n")
    }
  }
}
