///|
/// A JSON-RPC 2.0 error object.
pub(all) struct RpcError {
  code : Int32
  message : String
  data : Json?
} derive(Debug)

///|
/// One decoded JSON-RPC message from a server.
pub(all) enum RpcMessage {
  /// The response to a request mcpbox sent.
  Response(Int32, Json?, RpcError?)
  /// A server-initiated request. mcpbox answers unknown methods politely
  /// rather than leaving the server waiting. The id is kept as raw JSON
  /// because the spec allows string ids for server requests.
  ServerRequest(Json, String, Json?)
  /// A server notification, such as a log line or `tools/list_changed`.
  Notification(String, Json?)
} derive(Debug)

///|
/// Build a JSON-RPC 2.0 request object. The `repr` keeps ids integral in the
/// encoded form instead of printing them as `1.0`.
pub fn rpc_request(id : Int32, method_name : String, params : Json?) -> Json {
  let fields : Map[String, Json] = {
    "jsonrpc": Json::string("2.0"),
    "id": Json::number(id.to_double(), repr=id.to_string()),
    "method": Json::string(method_name),
  }
  match params {
    Some(p) => fields["params"] = p
    None => ()
  }
  Json::object(fields)
}

///|
/// Build a JSON-RPC 2.0 notification: a request with no id, which the server
/// must not answer.
pub fn rpc_notification(method_name : String, params : Json?) -> Json {
  let fields : Map[String, Json] = {
    "jsonrpc": Json::string("2.0"),
    "method": Json::string(method_name),
  }
  match params {
    Some(p) => fields["params"] = p
    None => ()
  }
  Json::object(fields)
}

///|
/// Build the response to a server-initiated request, echoing its id.
pub fn rpc_result_response(id : Json, result : Json) -> Json {
  Json::object({ "jsonrpc": Json::string("2.0"), "id": id, "result": result })
}

///|
/// Build a JSON-RPC error response, echoing the request's id.
pub fn rpc_error_response(id : Json, code : Int32, message : String) -> Json {
  Json::object({
    "jsonrpc": Json::string("2.0"),
    "id": id,
    "error": Json::object({
      "code": Json::number(code.to_double(), repr=code.to_string()),
      "message": Json::string(message),
    }),
  })
}

///|
/// Decode one JSON-RPC message. Returns `None` for a well-formed object that
/// is neither a response nor a notification mcpbox cares about, so the caller
/// can simply skip it.
pub fn decode_rpc_message(json : Json) -> RpcMessage? raise McpError {
  guard json is Object(obj) else {
    raise fail("server sent a JSON value that is not an object")
  }
  let raw_id : Json? = obj.get("id")
  let int_id = match raw_id {
    Some(Number(n, ..)) => Some(n.to_int())
    _ => None
  }
  let rpc_method = match obj.get("method") {
    Some(String(m)) => Some(m)
    _ => None
  }
  let error = match obj.get("error") {
    Some(Object(e)) => {
      let code = match e.get("code") {
        Some(Number(n, ..)) => n.to_int()
        _ => 0
      }
      let message = match e.get("message") {
        Some(String(m)) => m
        _ => "unknown server error"
      }
      Some({ code, message, data: e.get("data"), })
    }
    _ => None
  }
  match (int_id, raw_id, rpc_method) {
    (Some(id), _, None) => Some(Response(id, obj.get("result"), error))
    (_, Some(id), Some(name)) =>
      Some(ServerRequest(id, name, obj.get("params")))
    (_, _, Some(name)) => Some(Notification(name, obj.get("params")))
    (_, _, None) =>
      if error is Some(_) {
        raise fail("server sent an error response without an id")
      } else {
        None
      }
  }
}
