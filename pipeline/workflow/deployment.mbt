///|
fn parse_deployment_environment(
  value : @yaml.Yaml?,
) -> (String, String) raise InvalidWorkflow {
  guard value is Some(value) else { return ("", "") }
  let (name, url) = match value {
    Map(fields) => {
      check_fields(fields, ["name", "url"], "job.environment")
      (
        template_string(fields.get("name"), "job.environment.name").unwrap_or(
          "",
        ),
        match fields.get("url") {
          None => ""
          Some(_) =>
            template_string(fields.get("url"), "job.environment.url").unwrap_or(
              "",
            )
        },
      )
    }
    _ => (template_string(Some(value), "job.environment").unwrap_or(""), "")
  }
  guard !name.is_empty() && name.length() <= 512 && url.length() <= 2048 else {
    raise InvalidWorkflow("invalid deployment environment name or URL")
  }
  for value in [name, url] {
    ignore(
      schedule_template(
        value,
        {
          "github": {},
          "inputs": {},
          "vars": {},
          "needs": {},
          "matrix": {},
          "strategy": {},
        },
        validate_output=true,
      ),
    )
  }
  (name, url)
}
