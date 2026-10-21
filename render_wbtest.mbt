///|
/// Whitebox tests for argument coercion and target parsing.

///|
fn json_field(json : Json, key : String) -> Json {
  match json {
    Object(obj) => obj.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

///|
test "coerce_value follows the schema type" {
  assert_eq(
    coerce_value("5", Some(parse_jsonc("{\"type\":\"integer\"}"))).stringify(),
    "5",
  )
  assert_eq(
    coerce_value("1.5", Some(parse_jsonc("{\"type\":\"number\"}"))).stringify(),
    "1.5",
  )
  assert_eq(
    coerce_value("true", Some(parse_jsonc("{\"type\":\"boolean\"}"))).stringify(),
    "true",
  )
  assert_eq(
    coerce_value("hi", Some(parse_jsonc("{\"type\":\"string\"}"))).stringify(),
    "\"hi\"",
  )
}

///|
test "coerce_value falls back to a string when parsing fails" {
  assert_eq(
    coerce_value("abc", Some(parse_jsonc("{\"type\":\"integer\"}"))).stringify(),
    "\"abc\"",
  )
  assert_eq(
    coerce_value("maybe", Some(parse_jsonc("{\"type\":\"boolean\"}"))).stringify(),
    "\"maybe\"",
  )
}

///|
test "coerce_value splits arrays on commas" {
  let schema = parse_jsonc(
    "{\"type\":\"array\",\"items\":{\"type\":\"integer\"}}",
  )
  assert_eq(coerce_value("1, 2, 3", Some(schema)).stringify(), "[1,2,3]")
}

///|
test "coerce_value parses object JSON and falls back" {
  let schema = parse_jsonc("{\"type\":\"object\"}")
  assert_eq(coerce_value("{\"a\":1}", Some(schema)).stringify(), "{\"a\":1}")
  assert_eq(coerce_value("nope", Some(schema)).stringify(), "\"nope\"")
}

///|
test "coerce_value without a schema stays a string" {
  assert_eq(coerce_value("5", None).stringify(), "\"5\"")
}

///|
test "coerce_value keeps non-finite numeric tokens as strings" {
  let number = Some(parse_jsonc("{\"type\":\"number\"}"))
  let integer = Some(parse_jsonc("{\"type\":\"integer\"}"))
  for token in ["Infinity", "-Infinity", "NaN", "nan"] {
    assert_eq(coerce_value(token, number).stringify(), "\"" + token + "\"")
    assert_eq(coerce_value(token, integer).stringify(), "\"" + token + "\"")
  }
}

///|
test "coerce_value accepts finite exponent notation" {
  assert_eq(
    coerce_value("1e3", Some(parse_jsonc("{\"type\":\"number\"}"))).stringify(),
    "1000",
  )
}

///|
test "build_arguments never emits non-finite JSON numbers" {
  let schema = parse_jsonc(
    "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\"}}}",
  )
  let args = build_arguments(["n=Infinity"], schema)
  assert_eq(json_field(args, "n").stringify(), "\"Infinity\"")
  let encoded = args.stringify()
  assert_true(encoded.contains("\"Infinity\""))
  assert_false(encoded.contains(":Infinity"))
}

///|
test "build_arguments preserves an explicit JSON null" {
  let schema = parse_jsonc(
    "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"string\"}}}",
  )
  let args = build_arguments(["n:=null"], schema)
  assert_eq(json_field(args, "n").stringify(), "null")
}

///|
test "parse_options keeps literal values after the separator" {
  let opts = parse_options([
    "call", "s.t", "--json", "--", "", "--output", "--timeout", "5",
  ])
  assert_true(opts.json)
  assert_eq(opts.timeout_ms, 30000)
  assert_eq(opts.positional.length(), 6)
  assert_eq(opts.positional[2], "")
  assert_eq(opts.positional[3], "--output")
  assert_eq(opts.positional[4], "--timeout")
  assert_eq(opts.positional[5], "5")
}

///|
test "parse_seconds rejects non-finite and non-positive timeouts" {
  for value in ["0", "-1", "Infinity", "-Infinity", "NaN", "0.0001", "abc"] {
    let failed = try {
      ignore(parse_seconds(value))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
  assert_eq(parse_seconds("0.5"), 500)
  assert_eq(parse_seconds("30"), 30000)
}

///|
test "build_arguments coerces known keys and accepts raw JSON" {
  let schema = parse_jsonc(
    "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"integer\"},\"m\":{\"type\":\"object\"},\"s\":{\"type\":\"string\"}}}",
  )
  let args = build_arguments(["n=3", "m:={\"a\":1}", "s=hi"], schema)
  assert_eq(json_field(args, "n").stringify(), "3")
  assert_eq(json_field(args, "m").stringify(), "{\"a\":1}")
  assert_eq(json_field(args, "s").stringify(), "\"hi\"")
}

///|
test "build_arguments rejects a pair with no separator" {
  let failed = try {
    ignore(build_arguments(["nope"], Json::object(Map([]))))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "build_arguments rejects an empty key" {
  let failed = try {
    ignore(build_arguments(["=1"], Json::object(Map([]))))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "split_target splits on the first dot" {
  assert_eq(split_target("srv.tool", false), ("srv", "tool"))
  assert_eq(split_target("a.b.c", false), ("a", "b.c"))
}

///|
test "split_target allows a bare tool for an ad-hoc server" {
  assert_eq(split_target("tool", true), ("adhoc", "tool"))
}

///|
test "split_target rejects a bare tool without an ad-hoc server" {
  let failed = try {
    ignore(split_target("tool", false))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "shell_split honours quotes" {
  assert_eq(shell_split("npx -y foo").join("|"), "npx|-y|foo")
  assert_eq(shell_split("sh -c \"echo hi\"").join("|"), "sh|-c|echo hi")
  assert_eq(shell_split("a 'b c' d").join("|"), "a|b c|d")
}
