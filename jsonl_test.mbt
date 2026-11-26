///|
test "JSONL preserves projected schema and typed rows across batch boundaries" {
  let data = sample(119, Big)
  let reader = open(encode(data))
  let lines : Array[String] = []
  reader.export_jsonl(
    line => lines.push(line),
    columns=[2, 0],
    offset=1,
    limit=1,
    batch_size=1,
  )
  assert_eq(lines.length(), 2)
  let selected = reader.select([2, 0], offset=1, limit=1).to_exchange()
  guard selected is { "schema": schema, "rows": Array(rows), .. } else {
    abort("bad exchange")
  }
  assert_eq(@json.parse(lines[0]), {
    "moondta_jsonl": 1,
    "rows": 1,
    "schema": schema,
  })
  assert_eq(@json.parse(lines[1]), rows[0])
  for line in lines {
    assert_true(line.has_suffix("\n"))
  }
  let all : Array[String] = []
  reader.export_jsonl(line => all.push(line), batch_size=1)
  assert_eq(all.length(), data.rows.length() + 1)
  let empty : Array[String] = []
  reader.export_jsonl(
    line => empty.push(line),
    offset=reader.row_count(),
    limit=0,
  )
  assert_eq(empty.length(), 1)
}

///|
test "JSONL rejects options before emission and propagates sink failures" {
  let reader = open(encode(sample(118, Little)))
  let lines : Array[String] = []
  for (offset, limit, batch) in [(-1, 1, 1), (0, -1, 1), (0, 100, 1), (0, 1, 0)] {
    try {
      reader.export_jsonl(
        line => lines.push(line),
        offset~,
        limit~,
        batch_size=batch,
      )
      abort("expected invalid range")
    } catch {
      DtaError::Invalid(..) => ()
      _ => abort("unexpected error")
    }
  }
  try {
    reader.export_jsonl(line => lines.push(line), columns=[0, 0])
    abort("expected duplicate rejection")
  } catch {
    DtaError::Invalid(..) => ()
    _ => abort("unexpected error")
  }
  assert_eq(lines.length(), 0)
  let mut calls = 0
  try {
    reader.export_jsonl(
      _ => {
        calls += 1
        if calls == 2 {
          fail("sink unavailable")
        }
      },
      batch_size=1,
    )
    abort("expected sink failure")
  } catch {
    e => assert_true(e.to_string().contains("sink unavailable"))
  }
  assert_eq(calls, 2)
}
