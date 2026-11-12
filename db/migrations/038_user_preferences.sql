CREATE TABLE IF NOT EXISTS user_preferences (
  user_id INTEGER PRIMARY KEY REFERENCES "user" (id) ON DELETE CASCADE,
  time_zone TEXT,
  CHECK (time_zone IS NULL OR (length(time_zone) BETWEEN 1 AND 100))
);
