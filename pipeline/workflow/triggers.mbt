///|
pub struct EventFilters {
  branches : Array[String]
  branches_ignore : Array[String]
  tags : Array[String]
  tags_ignore : Array[String]
  paths : Array[String]
  paths_ignore : Array[String]
}

///|
pub struct Triggers {
  schedules : Array[Schedule]
  dispatch : Bool
  inputs : Array[DispatchInput]
  reusable : Bool
  call_inputs : Array[DispatchInput]
  call_outputs : Map[String, String]
  push : Bool
  pull_request : Bool
  release : Bool
  release_types : Array[String]
  repository_dispatch : Bool
  dispatch_types : Array[String]
  workflow_run : Bool
  workflow_names : Array[String]
  workflow_run_filters : EventFilters
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
  for
    pair in [
      ("branches", "branches-ignore"),
      ("tags", "tags-ignore"),
      ("paths", "paths-ignore"),
    ] {
    guard !(fields.contains(pair.0) && fields.contains(pair.1)) else {
      raise InvalidWorkflow("\{ctx}: cannot combine \{pair.0} and \{pair.1}")
    }
  }
  {
    branches: filter_patterns(fields, "branches", ctx),
    branches_ignore: filter_patterns(fields, "branches-ignore", ctx),
    tags: filter_patterns(fields, "tags", ctx),
    tags_ignore: filter_patterns(fields, "tags-ignore", ctx),
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
        "on requires push, pull_request, workflow_dispatch, schedule or release",
      )
  }
  guard !fields.is_empty() else {
    raise InvalidWorkflow("on requires a trigger")
  }
  check_fields(
    fields,
    [
      "push", "pull_request", "workflow_dispatch", "schedule", "release", "repository_dispatch",
      "workflow_run", "workflow_call",
    ],
    "on",
  )
  let call_options = match fields.get("workflow_call") {
    None | Some(Null) => Map([])
    Some(value) => yaml_as_obj(value, "on.workflow_call")
  }
  check_fields(call_options, ["inputs", "outputs"], "on.workflow_call")
  let call_inputs = parse_call_inputs(call_options.get("inputs"))
  let call_outputs = parse_call_outputs(call_options.get("outputs"))
  let dispatch_options = match fields.get("workflow_dispatch") {
    None | Some(Null) => Map([])
    Some(value) => yaml_as_obj(value, "on.workflow_dispatch")
  }
  check_fields(dispatch_options, ["inputs"], "on.workflow_dispatch")
  let inputs = parse_dispatch_inputs(dispatch_options.get("inputs"))
  let release_options = match fields.get("release") {
    None | Some(Null) => Map([])
    Some(value) => yaml_as_obj(value, "on.release")
  }
  check_fields(release_options, ["types"], "on.release")
  let release_types = activity_types(
    release_options,
    "on.release",
    ["released"],
    ["released", "published"],
  )
  let dispatch_options = match fields.get("repository_dispatch") {
    None | Some(Null) => Map([])
    Some(value) => yaml_as_obj(value, "on.repository_dispatch")
  }
  check_fields(dispatch_options, ["types"], "on.repository_dispatch")
  let dispatch_types = activity_types(
    dispatch_options,
    "on.repository_dispatch",
    [],
    [],
  )
  let workflow_options = match fields.get("workflow_run") {
    None | Some(Null) => Map([])
    Some(value) => yaml_as_obj(value, "on.workflow_run")
  }
  check_fields(
    workflow_options,
    ["workflows", "types", "branches", "branches-ignore"],
    "on.workflow_run",
  )
  ignore(
    activity_types(workflow_options, "on.workflow_run", ["completed"], [
      "completed",
    ]),
  )
  let workflow_names = activity_types(
    workflow_options,
    "on.workflow_run",
    [],
    [],
    key="workflows",
  )
  if fields.contains("workflow_run") && workflow_names.is_empty() {
    raise InvalidWorkflow("on.workflow_run requires workflow names")
  }
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
        [
          "branches", "branches-ignore", "tags", "tags-ignore", "paths", "paths-ignore",
        ]
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
          [
            "opened", "reopened", "synchronize", "ready_for_review", "edited", "closed",
          ].contains(event)
        }) else {
        raise InvalidWorkflow(
          "on.pull_request.types requires supported activity types",
        )
      }
    }
    filters[event] = event_filters(options, ctx)
  }
  {
    schedules: parse_schedules(fields.get("schedule")),
    dispatch: fields.contains("workflow_dispatch"),
    inputs,
    reusable: fields.contains("workflow_call"),
    call_inputs,
    call_outputs,
    push: fields.contains("push"),
    pull_request: fields.contains("pull_request"),
    release: fields.contains("release"),
    release_types,
    repository_dispatch: fields.contains("repository_dispatch"),
    dispatch_types,
    workflow_run: fields.contains("workflow_run"),
    workflow_names,
    workflow_run_filters: event_filters(workflow_options, "on.workflow_run"),
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
  tag~ : Bool = false,
) -> Bool {
  let f = self.push_filters
  if tag {
    self.push &&
    (
      !(f.tags.is_empty() && f.tags_ignore.is_empty()) ||
      (f.branches.is_empty() && f.branches_ignore.is_empty())
    ) &&
    (f.tags.is_empty() || ordered_patterns(f.tags, branch)) &&
    !f.tags_ignore.any(pattern => filter_match(pattern, branch))
  } else {
    self.push &&
    (
      !(f.branches.is_empty() && f.branches_ignore.is_empty()) ||
      (f.tags.is_empty() && f.tags_ignore.is_empty())
    ) &&
    f.matches(branch, paths)
  }
}

///|
pub fn Triggers::matches_pull_request(
  self : Triggers,
  event : String,
  branch~ : String = "",
  paths~ : Array[String]? = None,
) -> Bool {
  self.pull_request &&
  (if self.pull_request_types.is_empty() {
    ["opened", "reopened", "synchronize"].contains(event)
  } else {
    self.pull_request_types.contains(event)
  }) &&
  self.pull_request_filters.matches(branch, paths)
}

///|
fn activity_types(
  fields : Map[String, @yaml.Yaml],
  ctx : String,
  defaults : Array[String],
  allowed : Array[String],
  key~ : String = "types",
) -> Array[String] raise InvalidWorkflow {
  guard fields.get(key) is Some(value) else { return defaults }
  let values = yaml_as_string_list(Some(value), ctx + "." + key)
  let seen : Set[String] = Set([])
  guard value is Array(_) &&
    !values.is_empty() &&
    values.length() <= 64 &&
    values.all(v => {
      let valid = !v.is_empty() &&
        v.length() <= 100 &&
        !seen.contains(v) &&
        (allowed.is_empty() || allowed.contains(v))
      seen.add(v)
      valid
    }) else {
    raise InvalidWorkflow(
      ctx + "." + key + " requires unique supported activity names",
    )
  }
  values
}

///|
pub fn Triggers::matches_repository_dispatch(
  self : Triggers,
  event : String,
) -> Bool {
  self.repository_dispatch &&
  (self.dispatch_types.is_empty() || self.dispatch_types.contains(event))
}

///|
pub fn Triggers::matches_workflow_run(
  self : Triggers,
  name : String,
  branch : String,
) -> Bool {
  self.workflow_run &&
  self.workflow_names.contains(name) &&
  self.workflow_run_filters.matches(branch, None)
}
