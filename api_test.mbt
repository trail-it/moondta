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
  assert_eq(reader.row_count(), 2)
  reader.verify(batch_size=1)
  assert_true(reader.preview().contains("中文😀"))
  assert_true(reader.describe().contains("访谈记录"))
  assert_eq(reader.read_rows(offset=1, limit=1, columns=[0]), [
    [@dta.Missing(1)],
  ])
  assert_eq(@dta.encode(@dta.from_exchange(dataset.to_exchange())), bytes)
}
