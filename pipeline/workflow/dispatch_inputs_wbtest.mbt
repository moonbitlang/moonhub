///|
let typed_dispatch_source : String =
  #|on:
  #|  workflow_dispatch:
  #|    inputs:
  #|      message:
  #|        description: Message to print
  #|        required: true
  #|        default: hello
  #|      enabled:
  #|        type: boolean
  #|        default: false
  #|      count:
  #|        type: number
  #|        default: 2.5
  #|      target:
  #|        type: choice
  #|        options: [staging, production]
  #|        default: staging

///|
test "dispatch input schema preserves names types and typed defaults" {
  let trigger = triggers(typed_dispatch_source)
  assert_true(trigger.dispatch)
  assert_eq(trigger.inputs.length(), 4)
  let message = trigger.inputs.filter(input => input.name == "message")[0]
  assert_eq(message.description, "Message to print")
  assert_eq(message.kind, "string")
  assert_true(message.required)
  assert_eq(message.default, Some(Json::string("hello")))
  assert_true(message.options.is_empty())
  let resolved = resolve_dispatch_inputs(trigger.inputs, Map([]))
  assert_eq(resolved.get("message"), Some(Json::string("hello")))
  assert_eq(resolved.get("enabled"), Some(Json::boolean(false)))
  assert_eq(resolved.get("count"), Some(Json::number(2.5)))
  assert_eq(resolved.get("target"), Some(Json::string("staging")))
  let restored : DispatchInput = @json.from_json(ToJson::to_json(message))
  assert_eq(ToJson::to_json(restored), ToJson::to_json(message))
  assert_true(triggers("on: push").inputs.is_empty())
  assert_true(
    triggers("on: {workflow_dispatch: {inputs: {}}}").inputs.is_empty(),
  )
}

///|
test "dispatch form strings normalize once into typed values" {
  let supplied : Map[String, Json] = {
    "message": "${{ secrets.UNTRUSTED }}",
    "enabled": "true",
    "count": " -2.5e2 ",
    "target": "production",
  }
  let resolved = resolve_dispatch_inputs(
    triggers(typed_dispatch_source).inputs,
    supplied,
  )
  assert_eq(
    resolved.get("message"),
    Some(Json::string("${{ secrets.UNTRUSTED }}")),
  )
  assert_eq(resolved.get("enabled"), Some(Json::boolean(true)))
  assert_eq(resolved.get("count"), Some(Json::number(-250.0)))
  assert_eq(resolved.get("target"), Some(Json::string("production")))
  let typed : Map[String, Json] = { "enabled": true, "count": 0 }
  let resolved = resolve_dispatch_inputs(
    triggers(typed_dispatch_source).inputs,
    typed,
  )
  assert_eq(resolved.get("enabled"), Some(Json::boolean(true)))
  assert_eq(resolved.get("count"), Some(Json::number(0.0)))
}

///|
test "omitted optional dispatch inputs have type appropriate empty values" {
  let inputs = triggers(
      "on: {workflow_dispatch: {inputs: {text: {}, flag: {type: boolean}, count: {type: number}, target: {type: choice, options: [one, two]}}}}",
    ).inputs
  let resolved = resolve_dispatch_inputs(inputs, Map([]))
  assert_eq(resolved.get("text"), Some(Json::string("")))
  assert_eq(resolved.get("flag"), Some(Json::boolean(false)))
  assert_eq(resolved.get("count"), Some(Json::number(0.0)))
  assert_eq(resolved.get("target"), Some(Json::string("")))
  let inputs = triggers(
      "on: {workflow_dispatch: {inputs: {flag: {type: boolean, required: true}, count: {type: number, required: true}}}}",
    ).inputs
  let resolved = resolve_dispatch_inputs(inputs, { "flag": false, "count": 0 })
  assert_eq(resolved.get("flag"), Some(Json::boolean(false)))
  assert_eq(resolved.get("count"), Some(Json::number(0.0)))
}

///|
test "dispatch rejects missing required unknown and incorrectly typed inputs" {
  let inputs = triggers(
      "on: {workflow_dispatch: {inputs: {required: {required: true}, flag: {type: boolean}, count: {type: number}, target: {type: choice, options: [one, two]}}}}",
    ).inputs
  let invalid : Array[Map[String, Json]] = [
    {},
    { "required": "" },
    { "required": "ok", "unknown": "value" },
    { "required": "ok", "flag": "yes" },
    { "required": "ok", "flag": "TRUE" },
    { "required": "ok", "flag": 1 },
    { "required": "ok", "count": "NaN" },
    { "required": "ok", "count": "1e9999" },
    { "required": "ok", "count": "" },
    { "required": "ok", "count": false },
    { "required": "ok", "target": "other" },
    { "required": "ok", "target": "" },
    { "required": true },
    { "required": null },
    { "required": ["array"] },
    { "required": { "object": true } },
    { "required": "nul\u{0000}value" },
  ]
  for supplied in invalid {
    try ignore(resolve_dispatch_inputs(inputs, supplied)) catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ =>
        fail(
          "invalid dispatch input accepted: " +
          ToJson::to_json(supplied).stringify(),
        )
    }
  }
}

///|
test "dispatch rejects unsupported schemas and invalid defaults" {
  for
    definition in [
      "value: {type: environment}", "value: {type: unknown}", "value: {type: 1}",
      "value: {required: 'true'}", "value: {description: 1}", "value: {unknown: true}",
      "value: {type: choice}", "value: {type: choice, options: []}", "value: {type: choice, options: [same, same]}",
      "value: {type: choice, options: ['', other]}", "value: {type: choice, options: [1, other]}",
      "value: {options: [one]}", "value: {type: choice, options: [one], default: two}",
      "value: {type: boolean, default: yes}", "value: {type: number, default: .inf}",
      "value: {type: number, default: .nan}", "value: {default: null}", "value: {default: []}",
      "value: {default: {}}", "value: {default: true}", "value: {required: true, default: ''}",
      "__proto__: {}", "constructor: {}", "Value: {}, value: {}", "bad.name: {}",
      "1value: {}",
    ] {
    try
      ignore(
        triggers("on: {workflow_dispatch: {inputs: {" + definition + "}}}"),
      )
    catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("invalid dispatch schema accepted: " + definition)
    }
  }
}

///|
test "dispatch enforces 25 inputs and UTF8 payload byte limits" {
  let definitions = Array::makei(25, i => "value_" + i.to_string() + ": {}").join(
    ", ",
  )
  let inputs = triggers(
      "on: {workflow_dispatch: {inputs: {" + definitions + "}}}",
    ).inputs
  assert_eq(inputs.length(), 25)
  assert_eq(resolve_dispatch_inputs(inputs, Map([])).length(), 25)
  try
    ignore(
      triggers(
        "on: {workflow_dispatch: {inputs: {" + definitions + ", extra: {}}}}",
      ),
    )
  catch {
    InvalidWorkflow(message) => assert_true(message.contains("25"))
  } noraise {
    _ => fail("26 dispatch definitions accepted")
  }
  let single = triggers("on: {workflow_dispatch: {inputs: {text: {}}}}").inputs
  // {"text":"..."} adds eleven bytes to the encoded JSON object.
  let at_limit : Map[String, Json] = { "text": Json::string("x".repeat(65524)) }
  assert_eq(@utf8.encode(ToJson::to_json(at_limit).stringify()).length(), 65535)
  assert_eq(
    resolve_dispatch_inputs(single, at_limit).get("text"),
    at_limit.get("text"),
  )
  for text in ["x".repeat(65525), "字".repeat(21842)] {
    try
      ignore(resolve_dispatch_inputs(single, { "text": Json::string(text) }))
    catch {
      InvalidWorkflow(message) => assert_true(message.contains("65535"))
    } noraise {
      _ => fail("oversized UTF8 dispatch payload accepted")
    }
  }
}

///|
test "YAML numeric defaults normalize to valid JSON numbers" {
  for repr in ["+1.25", ".5", "1.", "01.25", "-0.5", "1e3"] {
    let definitions = triggers(
        "on: {workflow_dispatch: {inputs: {count: {type: number, default: " +
        repr +
        "}}}}",
      ).inputs
    let resolved = resolve_dispatch_inputs(definitions, Map([]))
    let restored = @json.parse(ToJson::to_json(resolved).stringify())
    assert_eq(restored, ToJson::to_json(resolved))
    assert_true(resolved.get("count") is Some(Number(_, ..)))
    ignore(@json.parse(ToJson::to_json(definitions).stringify()))
  }
}
