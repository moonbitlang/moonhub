///|
fn cron_field(
  source : String,
  minimum : Int32,
  maximum : Int32,
) -> Array[Int32] raise InvalidWorkflow {
  let values : Array[Int32] = []
  for item in source.split(",") {
    let pieces = item.split("/").collect()
    guard pieces.length() <= 2 else {
      raise InvalidWorkflow("invalid cron step")
    }
    let parse : (StringView) -> Int32 raise InvalidWorkflow = text => {
      guard !text.is_empty() &&
        text.iter().all(c => c.is_ascii_digit()) &&
        text.length() <= 2 else {
        raise InvalidWorkflow("cron requires numeric fields")
      }
      let mut n = 0
      for c in text {
        n = n * 10 + c.to_int() - 48
      }
      n
    }
    let step = if pieces.length() == 2 { parse(pieces[1]) } else { 1 }
    guard step >= 1 && step <= maximum + 1 else {
      raise InvalidWorkflow("invalid cron step")
    }
    let range = pieces[0].split("-").collect()
    let (first, last) = if pieces[0] == "*" {
      (minimum, maximum)
    } else if range.length() == 2 {
      (parse(range[0]), parse(range[1]))
    } else if range.length() == 1 {
      let n = parse(range[0])
      (n, if pieces.length() == 2 { maximum } else { n })
    } else {
      raise InvalidWorkflow("invalid cron range")
    }
    guard first >= minimum && last <= maximum && first <= last else {
      raise InvalidWorkflow("cron field out of range")
    }
    let mut n = first
    while n <= last {
      if !values.contains(n) {
        values.push(n)
      }
      n += step
    }
  }
  guard !values.is_empty() else { raise InvalidWorkflow("empty cron field") }
  values
}

///|
pub fn cron_matches(
  source : String,
  minute : Int32,
  hour : Int32,
  day : Int32,
  month : Int32,
  weekday : Int32,
) -> Bool raise InvalidWorkflow {
  let fields = source.split(" ").filter(s => !s.is_empty()).collect()
  guard fields.length() == 5 && source.length() <= 128 else {
    raise InvalidWorkflow("schedule requires five cron fields")
  }
  let minutes = cron_field(fields[0].to_owned(), 0, 59)
  let hours = cron_field(fields[1].to_owned(), 0, 23)
  let days = cron_field(fields[2].to_owned(), 1, 31)
  let months = cron_field(fields[3].to_owned(), 1, 12)
  let weekdays = cron_field(fields[4].to_owned(), 0, 7)
  // Standard cron ORs restricted day-of-month/day-of-week fields.
  let day_matches = days.contains(day)
  let week_matches = weekdays.contains(weekday) ||
    (weekday == 0 && weekdays.contains(7))
  minutes.contains(minute) &&
  hours.contains(hour) &&
  months.contains(month) &&
  (if fields[2] != "*" && fields[4] != "*" {
    day_matches || week_matches
  } else {
    day_matches && week_matches
  })
}

///|
fn parse_schedules(
  value : @yaml.Yaml?,
) -> Array[Schedule] raise InvalidWorkflow {
  guard value is Some(value) else { return [] }
  guard value is Array(items) && !items.is_empty() && items.length() <= 16 else {
    raise InvalidWorkflow("schedule requires 1 to 16 cron entries")
  }
  items.map(item => {
    let fields = yaml_as_obj(item, "on.schedule")
    check_fields(fields, ["cron", "timezone"], "on.schedule")
    let cron = required_string(fields.get("cron"), "on.schedule.cron")
    ignore(cron_matches(cron, 0, 0, 1, 1, 0))
    let timezone = match fields.get("timezone") {
      None => "UTC"
      Some(value) => required_string(Some(value), "on.schedule.timezone")
    }
    guard timezone.length() <= 100 &&
      !timezone.has_prefix("/") &&
      !timezone.contains("..") &&
      timezone
      .iter()
      .all(c => {
        c.is_ascii_alphabetic() ||
        c.is_ascii_digit() ||
        ['/', '_', '-', '+'].contains(c)
      }) else {
      raise InvalidWorkflow("on.schedule.timezone requires an IANA zone name")
    }
    { cron, timezone, }
  })
}

///|
pub struct Schedule {
  cron : String
  timezone : String
}

///|
fn cron_at(
  cron : String,
  wall : @time.PlainDateTime,
) -> Bool raise InvalidWorkflow {
  let weekday = match wall.weekday() {
    Monday => 1
    Tuesday => 2
    Wednesday => 3
    Thursday => 4
    Friday => 5
    Saturday => 6
    Sunday => 0
  }
  cron_matches(
    cron,
    wall.minute(),
    wall.hour(),
    wall.day(),
    wall.month(),
    weekday,
  )
}

///|
// Compare wall-clock minutes, choosing the first occurrence of an overlap.
// At a forward transition, all skipped matching minutes fire once at its end.
pub fn Schedule::matches(
  self : Schedule,
  second : Int64,
  zone : @time.Zone,
) -> Bool raise {
  let now = @time.ZonedDateTime::from_unix_second(second, zone~)
  let wall = now.to_plain_date_time()
  if @time.ZonedDateTime::from_plain(wall, zone~, disambiguation=Earlier).to_unix_second() !=
    second {
    return false
  }
  if cron_at(self.cron, wall) {
    return true
  }
  let before = @time.ZonedDateTime::from_unix_second(second - 60L, zone~).to_plain_date_time()
  let gap = (wall.to_unix_second() - before.to_unix_second()) / 60L
  if gap > 1L && gap <= 1441L {
    for offset in 1L..<gap {
      if cron_at(self.cron, before.add_minutes(offset)) {
        return true
      }
    }
  }
  false
}
