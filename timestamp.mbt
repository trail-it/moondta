///|
fn timestamp_number(t : String, start : Int, end : Int) -> Int raise DtaError {
  let mut result = 0
  for i in start..<end {
    if t[i] < '0' || t[i] > '9' {
      invalid(0, "timestamp contains a nonnumeric date or time")
    }
    result = result * 10 + t[i].to_int() - 48
  }
  result
}

///|
fn validate_timestamp(t : String) -> Unit raise DtaError {
  if t == "" {
    return
  }
  if t.length() != 17 ||
    t[2] != ' ' ||
    t[6] != ' ' ||
    t[11] != ' ' ||
    t[14] != ':' {
    invalid(0, "timestamp must be empty or dd Mon yyyy hh:mm")
  }
  let month = match t[3:6].to_owned() {
    "Jan" => 1
    "Feb" => 2
    "Mar" => 3
    "Apr" => 4
    "May" => 5
    "Jun" => 6
    "Jul" => 7
    "Aug" => 8
    "Sep" => 9
    "Oct" => 10
    "Nov" => 11
    "Dec" => 12
    _ => raise Invalid(offset=0, message="invalid timestamp month")
  }
  let day = timestamp_number(t, if t[0] == ' ' { 1 } else { 0 }, 2)
  let year = timestamp_number(t, 7, 11)
  let hour = timestamp_number(t, 12, 14)
  let minute = timestamp_number(t, 15, 17)
  let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  let days = match month {
    2 => if leap { 29 } else { 28 }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
  if year == 0 || day < 1 || day > days || hour > 23 || minute > 59 {
    invalid(0, "timestamp date or time is out of range")
  }
}
