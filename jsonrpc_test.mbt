///|
/// Blackbox tests for the JSON-RPC encoding and decoding.

///|
test "rpc_request encodes a JSON-RPC 2.0 request" {
  let json = @mcpbox.rpc_request(7, "tools/list", None)
  let decoded = @json.parse(json.stringify())
  match decoded {
    Object(obj) => {
      assert_eq(obj.get("jsonrpc"), Some(Json::string("2.0")))
      assert_eq(obj.get("id"), Some(Json::number(7.0)))
      assert_eq(obj.get("method"), Some(Json::string("tools/list")))
      assert_eq(obj.get("params"), None)
    }
    _ => abort("expected an object")
  }
}

///|
test "rpc_request carries params and keeps ids integral" {
  let json = @mcpbox.rpc_request(12, "tools/call", Some(Json::object(Map([]))))
  assert_true(json.stringify().contains("\"id\":12"))
  assert_true(json.stringify().contains("\"params\":{}"))
}

///|
test "rpc_notification has no id" {
  let json = @mcpbox.rpc_notification("notifications/initialized", None)
  let decoded = @json.parse(json.stringify())
  match decoded {
    Object(obj) => assert_eq(obj.get("id"), None)
    _ => abort("expected an object")
  }
}

///|
test "decode_rpc_message reads a response" {
  let json = @json.parse(
    "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"ok\":true}}",
  )
  match @mcpbox.decode_rpc_message(json) {
    Some(Response(id, result, error)) => {
      assert_eq(id, 3)
      assert_true(error is None)
      assert_eq(result.unwrap().stringify(), "{\"ok\":true}")
    }
    _ => abort("expected a response")
  }
}

///|
test "decode_rpc_message reads an error response" {
  let json = @json.parse(
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32601,\"message\":\"nope\"}}",
  )
  match @mcpbox.decode_rpc_message(json) {
    Some(Response(_, _, error)) => {
      let error = error.unwrap()
      assert_eq(error.code, -32601)
      assert_eq(error.message, "nope")
    }
    _ => abort("expected a response")
  }
}

///|
test "decode_rpc_message reads a notification" {
  let json = @json.parse(
    "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\"}",
  )
  match @mcpbox.decode_rpc_message(json) {
    Some(Notification(name, _)) => assert_eq(name, "notifications/message")
    _ => abort("expected a notification")
  }
}

///|
test "decode_rpc_message reads a server request with a string id" {
  let json = @json.parse(
    "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"ping\"}",
  )
  match @mcpbox.decode_rpc_message(json) {
    Some(ServerRequest(id, name, _)) => {
      assert_eq(id, Json::string("abc"))
      assert_eq(name, "ping")
    }
    _ => abort("expected a server request")
  }
}

///|
test "decode_rpc_message rejects a non-object" {
  let failed = try {
    ignore(@mcpbox.decode_rpc_message(Json::array([])))
    false
  } catch {
    _ => true
  }
  assert_true(failed)
}

///|
test "rpc_error_response echoes the id" {
  let json = @mcpbox.rpc_error_response(Json::string("abc"), -32601, "nope")
  let decoded = @json.parse(json.stringify())
  match decoded {
    Object(obj) => {
      assert_eq(obj.get("id"), Some(Json::string("abc")))
      assert_true(json.stringify().contains("-32601"))
    }
    _ => abort("expected an object")
  }
}
