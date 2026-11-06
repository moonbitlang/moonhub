///|
pub struct EventFilters {
  branches : Array[String]
  branches_ignore : Array[String]
  paths : Array[String]
  paths_ignore : Array[String]
}

///|
pub struct Triggers {
  dispatch : Bool
  inputs : Array[DispatchInput]
  push : Bool
  pull_request : Bool
  pull_request_types : Array[String]
  push_filters : EventFilters
  pull_request_filters : EventFilters
}

///|
fn filter_patterns(
  fields : Map[String, @yaml.Yaml],
  name : String,
  ctx : String,
) -> Array[String] raise InvalidWorkflow {
  guard fields.get(name) is Some(value) else { return [] }
  guard value is Array(items) else {
    raise InvalidWorkflow("\{ctx}.\{name} requires a list")
  }
  let patterns = items.map(item => required_string(Some(item), "\{ctx}.\{name}"))
  guard !patterns.is_empty() && patterns.length() <= 64 else {
    raise InvalidWorkflow("\{ctx}.\{name} requires 1 to 64 patterns")
  }
  guard name.has_suffix("-ignore") ||
    patterns.any(pattern => !pattern.has_prefix("!")) else {
    raise InvalidWorkflow("\{ctx}.\{name} requires a positive pattern")
  }
  for pattern in patterns {
    guard !(name.has_suffix("-ignore") && pattern.has_prefix("!")) else {
      raise InvalidWorkflow("\{ctx}.\{name} does not support negative patterns")
    }
    ignore(
      filter_tokens(pattern.strip_prefix("!").unwrap_or(pattern).to_owned()),
    )
  }
  patterns
}

///|
fn event_filters(
  fields : Map[String, @yaml.Yaml],
  ctx : String,
) -> EventFilters raise InvalidWorkflow {
  for pair in [("branches", "branches-ignore"), ("paths", "paths-ignore")] {
    guard !(fields.contains(pair.0) && fields.contains(pair.1)) else {
      raise InvalidWorkflow("\{ctx}: cannot combine \{pair.0} and \{pair.1}")
    }
  }
  {
    branches: filter_patterns(fields, "branches", ctx),
    branches_ignore: filter_patterns(fields, "branches-ignore", ctx),
    paths: filter_patterns(fields, "paths", ctx),
    paths_ignore: filter_patterns(fields, "paths-ignore", ctx),
  }
}

///|
fn parse_trigger(value : @yaml.Yaml?) -> Triggers raise InvalidWorkflow {
  let fields : Map[String, @yaml.Yaml] = match value {
    Some(String(name)) => Map([(name, @yaml.Null)])
    Some(Array(items)) => {
      let fields : Map[String, @yaml.Yaml] = Map([])
      for item in items {
        guard item is String(name) && !fields.contains(name) else {
          raise InvalidWorkflow("on requires unique trigger names")
        }
        fields[name] = @yaml.Null
      }
      fields
    }
    Some(Map(fields)) => fields
    _ =>
      raise InvalidWorkflow(
        "on requires push, pull_request or workflow_dispatch",
      )
  }
  guard !fields.is_empty() else {
    raise InvalidWorkflow("on requires a trigger")
  }
  check_fields(fields, ["push", "pull_request", "workflow_dispatch"], "on")
  let dispatch_options = match fields.get("workflow_dispatch") {
    None | Some(Null) => Map([])
    Some(value) => yaml_as_obj(value, "on.workflow_dispatch")
  }
  check_fields(dispatch_options, ["inputs"], "on.workflow_dispatch")
  let inputs = parse_dispatch_inputs(dispatch_options.get("inputs"))
  let filters : Map[String, EventFilters] = Map([])
  let mut pull_request_types : Array[String] = []
  for event in ["push", "pull_request"] {
    let ctx = "on." + event
    let options = match fields.get(event) {
      None | Some(Null) => Map([])
      Some(value) => yaml_as_obj(value, ctx)
    }
    check_fields(
      options,
      if event == "push" {
        ["branches", "branches-ignore", "paths", "paths-ignore"]
      } else {
        ["types", "branches", "branches-ignore", "paths", "paths-ignore"]
      },
      ctx,
    )
    if options.get("types") is Some(value) {
      pull_request_types = yaml_as_string_list(
        Some(value),
        "on.pull_request.types",
      )
      guard value is Array(_) &&
        !pull_request_types.is_empty() &&
        pull_request_types.all(event => {
          ["opened", "reopened", "synchronize"].contains(event)
        }) else {
        raise InvalidWorkflow(
          "on.pull_request.types requires supported activity types",
        )
      }
    }
    filters[event] = event_filters(options, ctx)
  }
  {
    dispatch: fields.contains("workflow_dispatch"),
    inputs,
    push: fields.contains("push"),
    pull_request: fields.contains("pull_request"),
    pull_request_types,
    push_filters: filters["push"],
    pull_request_filters: filters["pull_request"],
  }
}

///|
pub fn triggers(source : String) -> Triggers raise InvalidWorkflow {
  parse_trigger(yaml_as_obj(read_yaml(source), "workflow").get("on"))
}

///|
fn ordered_patterns(patterns : Array[String], value : String) -> Bool {
  let mut included = false
  for pattern in patterns {
    let negative = pattern.has_prefix("!")
    if filter_match(
        pattern.strip_prefix("!").unwrap_or(pattern).to_owned(),
        value,
      ) {
      included = !negative
    }
  }
  included
}

///|
fn EventFilters::matches(
  self : EventFilters,
  branch : String,
  paths : Array[String]?,
) -> Bool {
  guard (self.branches.is_empty() || ordered_patterns(self.branches, branch)) &&
    !self.branches_ignore.any(pattern => filter_match(pattern, branch)) else {
    return false
  }
  if self.paths.is_empty() && self.paths_ignore.is_empty() {
    return true
  }
  // An unavailable or bounded-out diff must never hide a relevant check.
  guard paths is Some(paths) else { return true }
  let pattern_size = [..self.paths, ..self.paths_ignore].fold(init=0L, (
    size,
    pattern,
  ) => size + pattern.length().to_int64())
  let path_size = paths.fold(init=0L, (size, path) => {
    size + path.length().to_int64() + 1L
  })
  // Bound aggregate automaton work as well as individual names and patterns.
  // Conservatively run rather than making a large diff suppress a check.
  if pattern_size * path_size > 8000000L {
    return true
  }
  paths.any(path => {
    (self.paths.is_empty() || ordered_patterns(self.paths, path)) &&
    !self.paths_ignore.any(pattern => filter_match(pattern, path))
  })
}

///|
pub fn Triggers::matches_push(
  self : Triggers,
  branch : String,
  paths~ : Array[String]? = None,
) -> Bool {
  self.push && self.push_filters.matches(branch, paths)
}

///|
pub fn Triggers::matches_pull_request(
  self : Triggers,
  event : String,
  branch~ : String = "",
  paths~ : Array[String]? = None,
) -> Bool {
  self.pull_request &&
  ["opened", "reopened", "synchronize"].contains(event) &&
  (
    self.pull_request_types.is_empty() ||
    self.pull_request_types.contains(event)
  ) &&
  self.pull_request_filters.matches(branch, paths)
}
