TZIF fixtures copied from the host IANA zoneinfo database.
America/New_York covers the 2026 spring gap and autumn overlap.
Asia/Shanghai covers a fixed UTC+08:00 schedule.
These binary fixtures make DST tests independent of the CI host's timezone data.
Production schedules read the installed /usr/share/zoneinfo files (tzdata).
