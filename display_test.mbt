///|
test "preview renders numbers, labelled missing, binary, escaped controls and Unicode truncation" {
  let schema = Schema::new(
    [
      Column::new("回答", Byte, value_labels="answer"),
      Column::new("score", Float64),
      Column::new("memo", StrL),
      Column::new("blob", StrL),
    ],
    label="调查",
    sort_order=[1],
    value_labels=[
      {
        name: "answer",
        entries: [
          { value: 1, text: "是", },
          { value: 2147483622, text: "拒绝回答", },
        ],
      },
    ],
  )
  let reader = open(
    encode({
      schema,
      rows: [
        [Integer(1), Number(1.5), Text("中文😀尾部"), Binary(b"\x00\xff")],
        [Missing(1), Number(-0.0), Text("a\n|\u001b"), Binary(b"")],
      ],
    }),
  )
  let preview = reader.preview(max_chars=3)
  assert_true(preview.contains("1 (\"是\")"))
  assert_true(preview.contains(".a (\"拒绝回…\")"))
  assert_true(preview.contains("| 1.5 |"))
  assert_true(preview.contains("| -0 |"))
  assert_true(preview.contains("中文😀…"))
  assert_true(preview.contains("a\\n\\|…"))
  assert_true(preview.contains("<binary 2 bytes>"))
  assert_true(!reader.preview(labels=false).contains("拒绝回答"))
  let dictionary = reader.describe()
  assert_true(dictionary.contains("调查"))
  assert_true(dictionary.contains("| .a | \"拒绝回答\" |"))
  assert_true(dictionary.contains("strL"))
  assert_true(reader.preview(offset=2).contains("Rows 2–2 of 2"))
  rejects(() => ignore(reader.preview(offset=3)))
  rejects(() => ignore(reader.preview(max_chars=0)))
}
