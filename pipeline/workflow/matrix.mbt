///|
fn matrix_scalar(value : @yaml.Yaml) -> Json raise InvalidWorkflow {
  match value {
    String(text) => {
      guard !text.contains("${{") else {
        raise InvalidWorkflow("matrix values must be literal scalars")
      }
      Json::string(text)
    }
    Integer(n) => Json::number(n.to_double())
    Real(_, repr~) =>
      @json.parse(repr) catch {
        _ => raise InvalidWorkflow("invalid matrix number")
      }
    Boolean(b) => Json::boolean(b)
    Null => Json::null()
    _ => raise InvalidWorkflow("matrix axes support scalar values only")
  }
}

///|
fn matrix_entries(
  value : @yaml.Yaml?,
  ctx : String,
) -> Array[Map[String, Json]] raise InvalidWorkflow {
  guard value is Some(value) else { return [] }
  guard value is Array(items) && items.length() <= 256 else {
    raise InvalidWorkflow(ctx + " requires at most 256 entries")
  }
  items.map(item => {
    let fields = yaml_as_obj(item, ctx)
    guard !fields.is_empty() && fields.length() <= 16 else {
      raise InvalidWorkflow(ctx + " requires 1 to 16 scalar fields")
    }
    let row : Map[String, Json] = Map([])
    for key, value in fields {
      guard valid_identifier(key) else {
        raise InvalidWorkflow("invalid matrix key")
      }
      row[key] = matrix_scalar(value)
    }
    row
  })
}

///|
fn expand_matrix(
  value : @yaml.Yaml,
) -> Array[Map[String, Json]] raise InvalidWorkflow {
  let fields = yaml_as_obj(value, "strategy.matrix")
  let axes = fields
    .iter()
    .filter(entry => entry.0 != "include" && entry.0 != "exclude")
    .collect()
  guard axes.length() <= 16 else {
    raise InvalidWorkflow("matrix exceeds 16 axes")
  }
  let mut rows : Array[Map[String, Json]] = if axes.is_empty() {
    []
  } else {
    [Map([])]
  }
  let axis_names : Array[String] = []
  for (name, axis) in axes {
    guard valid_identifier(name) &&
      !axis_names.any(key => key.to_lower() == name.to_lower()) else {
      raise InvalidWorkflow("invalid or duplicate matrix axis")
    }
    axis_names.push(name)
    guard axis is Array(items) && !items.is_empty() && items.length() <= 256 else {
      raise InvalidWorkflow("matrix axes require 1 to 256 values")
    }
    guard rows.length() * items.length() <= 256 else {
      raise InvalidWorkflow("matrix exceeds 256 combinations")
    }
    let next : Array[Map[String, Json]] = []
    for row in rows {
      for item in items {
        let row = row.copy()
        row[name] = matrix_scalar(item)
        next.push(row)
      }
    }
    rows = next
  }
  let excluded = matrix_entries(fields.get("exclude"), "matrix.exclude")
  for entry in excluded {
    guard entry.keys().all(key => axis_names.contains(key)) else {
      raise InvalidWorkflow("matrix.exclude contains unknown axis")
    }
  }
  rows = rows.filter(row => {
    !excluded.any(entry => {
      entry.iter().all(field => row.get(field.0) == Some(field.1))
    })
  })
  // Includes merge into compatible original combinations only. Standalone
  // include entries must not become candidates for subsequent include merging.
  let original = rows.map(row => row.copy())
  for entry in matrix_entries(fields.get("include"), "matrix.include") {
    let mut matched = false
    for i, base in original {
      if axis_names.all(key => {
          entry.get(key) is None || entry.get(key) == base.get(key)
        }) {
        matched = true
        for key, value in entry {
          rows[i][key] = value
        }
      }
    }
    if !matched {
      rows.push(entry.copy())
    }
    guard rows.length() <= 256 else {
      raise InvalidWorkflow("matrix exceeds 256 combinations")
    }
  }
  guard !rows.is_empty() else {
    raise InvalidWorkflow("matrix produces no jobs")
  }
  rows
}

///|
fn expand_job(
  id : String,
  value : @yaml.Yaml,
  env : Map[String, String],
  defaults : RunDefaults,
  contents_read : Bool,
) -> Array[Job] raise InvalidWorkflow {
  let fields = yaml_as_obj(value, "jobs." + id)
  guard fields.get("strategy") is Some(strategy) else {
    return [parse_job(id, value, env, defaults, contents_read)]
  }
  let strategy = yaml_as_obj(strategy, "strategy")
  check_fields(strategy, ["matrix", "fail-fast", "max-parallel"], "strategy")
  let fail_fast = match strategy.get("fail-fast") {
    None => true
    Some(Boolean(b)) => b
    _ => raise InvalidWorkflow("strategy.fail-fast requires a literal boolean")
  }
  let max_parallel = match strategy.get("max-parallel") {
    None => 256
    Some(Integer(n)) if n > 0L && n <= 256L => n.to_int()
    _ => raise InvalidWorkflow("strategy.max-parallel requires 1 to 256")
  }
  guard strategy.get("matrix") is Some(matrix) else {
    raise InvalidWorkflow("strategy requires a static matrix")
  }
  let rows = expand_matrix(matrix)
  rows.mapi((index, matrix) => {
    let fields = fields.copy()
    ignore(fields.remove("strategy"))
    let context : Map[String, Json] = {
      "matrix": ToJson::to_json(matrix),
      "strategy": {
        "job-index": index,
        "job-total": rows.length(),
        "fail-fast": fail_fast,
        "max-parallel": max_parallel,
      },
    }
    for key in ["name", "runs-on"] {
      if fields.get(key) is Some(value) {
        fields[key] = match value {
          String(text) => @yaml.String(scheduling_template(text, context))
          Array(items) if key == "runs-on" =>
            @yaml.Array(
              items.map(item => {
                match item {
                  String(text) =>
                    @yaml.String(scheduling_template(text, context))
                  _ => raise InvalidWorkflow("runs-on requires strings")
                }
              }),
            )
          _ => value
        }
      }
    }
    // Step display names have scheduling context too; executable text remains
    // a runtime template, never recursively interpolated from matrix values.
    if fields.get("steps") is Some(Array(steps)) {
      fields["steps"] = @yaml.Array(
        steps.map(step => {
          let step = yaml_as_obj(step, "step").copy()
          if step.get("name") is Some(String(name)) {
            step["name"] = @yaml.String(scheduling_template(name, context))
          }
          @yaml.Map(step)
        }),
      )
    }
    let job = parse_job(id, @yaml.Map(fields), env, defaults, contents_read)
    {
      ..job,
      id: id + "[" + (index + 1).to_string() + "]",
      name: if fields.contains("name") {
        job.name
      } else {
        id +
        " (" +
        matrix
        .values()
        .map(value => schedule_string(value))
        .collect()
        .join(", ") +
        ")"
      },
      matrix,
      strategy: {
        "job-index": ToJson::to_json(index),
        "job-total": ToJson::to_json(rows.length()),
        "fail-fast": Json::boolean(fail_fast),
        "max-parallel": ToJson::to_json(max_parallel),
      },
      matrix_group: id,
      fail_fast,
      max_parallel,
    }
  })
}
