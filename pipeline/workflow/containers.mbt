///|
fn parse_container(
  value : @yaml.Yaml,
  ctx : String,
) -> @actions.Container raise InvalidWorkflow {
  let fields = match value {
    String(image) => { "image": @yaml.String(image) }
    _ => yaml_as_obj(value, ctx)
  }
  check_fields(fields, ["image", "env", "ports", "options"], ctx)
  let image = template_string(fields.get("image"), ctx + ".image").unwrap_or("")
  guard image.contains("${{") || @actions.valid_container_image(image) else {
    raise InvalidWorkflow("invalid container image")
  }
  let env = yaml_to_string_map(fields.get("env"), ctx + ".env")
  let templates = [image]
  templates.append(env.values().collect())
  for text in templates {
    ignore(
      schedule_template(
        text,
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
  let ports : Array[String] = match fields.get("ports") {
    None => []
    Some(Array(items)) =>
      items.map(value => {
        match value {
          Integer(port) => port.to_string()
          String(port) => port
          _ =>
            raise InvalidWorkflow("container ports must be strings or integers")
        }
      })
    _ => raise InvalidWorkflow("container ports must be an array")
  }
  guard ports.length() <= 16 && ports.all(@actions.valid_container_port) else {
    raise InvalidWorkflow("invalid container port mapping")
  }
  let options = match fields.get("options") {
    None => []
    Some(_) => {
      let options = required_string(fields.get("options"), ctx + ".options")
      @actions.docker_options(options) catch {
        @actions.InvalidAction(message) => raise InvalidWorkflow(message)
      }
    }
  }
  { image, env, ports, options, }
}

///|
fn parse_containers(
  fields : Map[String, @yaml.Yaml],
) -> @actions.ContainerPlan? raise InvalidWorkflow {
  let job = fields
    .get("container")
    .map(value => parse_container(value, "job.container"))
  let services : Map[String, @actions.Container] = Map([])
  if fields.get("services") is Some(value) {
    for name, value in yaml_as_obj(value, "job.services") {
      guard valid_identifier(name) &&
        name.length() <= 63 &&
        !["localhost", "job", "host"].contains(name.to_lower()) else {
        raise InvalidWorkflow("invalid service alias")
      }
      services[name] = parse_container(value, "job.services." + name)
    }
    guard services.length() <= 8 else {
      raise InvalidWorkflow("a job supports at most eight services")
    }
  }
  if job is None && services.is_empty() {
    return None
  }
  let plan : @actions.ContainerPlan = { job, services, }
  guard @utf8.encode(ToJson::to_json(plan).stringify()).length() <= 65536 else {
    raise InvalidWorkflow("container plan exceeds 64 KiB")
  }
  Some(plan)
}
