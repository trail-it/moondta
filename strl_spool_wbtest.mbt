///|
test "a matching disk hash still compares the final bytes of a long object" {
  // Simulate a hash collision independently of the runtime's random hash seed.
  let first = Bytes::make(STREAM_BLOCK + 1, 0)
  let second = Bytes::makei(first.length(), i => {
    if i < STREAM_BLOCK {
      0
    } else {
      1
    }
  })
  let hash = second.hash().reinterpret_as_uint()
  let disk = @buffer.Buffer()
  let spool : StrLSpool = {
    endian: Little,
    heads: FixedArray::make(1, 0L),
    cache: FixedArray::make(1, None),
    size: 0L,
    file: {
      write_at: (pos, bytes) => {
        assert_eq(pos, disk.length().to_int64())
        disk.write_bytes(bytes[:])
      },
      read_at: (pos, n) => {
        Bytes::makei(n, i => {
          if pos == 0L && n == 32 && i >= 8 && i < 12 {
            (hash >> (8 * (i - 8))).to_byte()
          } else {
            disk.view()[pos.to_int() + i]
          }
        })
      },
    },
  }
  assert_eq(spool.intern(129, first, (1, 1)), (1, 1))
  assert_eq(spool.intern(129, second, (1, 2)), (1, 2))
  assert_eq(spool.intern(129, second, (2, 3)), (1, 2))
  assert_eq(spool.size, 2L * (32L + first.length().to_int64()))
}
