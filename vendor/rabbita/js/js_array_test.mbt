///|
#cfg(target="js")
test "JsArray mutation and missing values" {
  let values : @js.JsArray[Int32] = @js.JsArray::new()
  debug_inspect(values.length(), content="0")
  debug_inspect(values.get(0), content="None")
  values.push(10)
  values.set(2, 30)
  debug_inspect(values.length(), content="3")
  debug_inspect(values.get(0), content="Some(10)")
  debug_inspect(values.get(1), content="None")
  debug_inspect(values.get(2), content="Some(30)")
  debug_inspect(values.iter().collect(), content="[Some(10), None, Some(30)]")
  debug_inspect(values.pop(), content="Some(30)")
  debug_inspect(values.pop(), content="None")
  debug_inspect(values.pop(), content="Some(10)")
  debug_inspect(values.pop(), content="None")
}

///|
#cfg(target="js")
test "JsArray collapses undefined and checked casts validate elements" {
  let values : @js.JsArray[@js.Value] = @js.JsArray::new()
  let missing : @js.Value = @js.Object::new().get("missing")
  values.push(missing)
  assert_true(values.get(0) is None)
  let ints : @js.JsArray[Int32]? = @js.Cast::into(
    @js.Value::from_json_string("[1, 2, 3]"),
  )
  assert_true(ints is Some(ints) && ints.length() == 3)
  let invalid : @js.JsArray[Int32]? = @js.Cast::into(
    @js.Value::from_json_string("[1, \"two\"]"),
  )
  assert_true(invalid is None)
}

///|
#cfg(target="js")
test "panic JsArray rejects a negative index" {
  let values : @js.JsArray[Int32] = @js.JsArray::new()
  values.set(-1, 1)
}
