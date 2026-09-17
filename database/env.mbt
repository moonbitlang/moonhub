///|
pub fn db_config_from_env() -> DbConfig {
  {
    path: match @env.get_env_var("DB_PATH") {
      Some(path) if !path.is_empty() => path
      _ => "moonhub.db"
    },
  }
}
