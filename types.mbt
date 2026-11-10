///|
/// The mcpbox version, kept in sync with `moon.mod` and `npmjs/package.json`.
/// It is also what the client reports to servers during `initialize`.
pub let version : String = "0.1.7"

///|
/// The MCP revision mcpbox advertises first. Servers that predate it answer
/// with the revision they do support, and mcpbox accepts whatever comes back:
/// the wire format is unchanged across the revisions in use.
pub let protocol_version : String = "2025-06-18"

///|
/// How mcpbox reaches a stdio server: a child process that speaks
/// newline-delimited JSON-RPC on its standard input and output.
#derive(Debug)
pub(all) struct StdioSpec {
  command : String
  args : Array[String]
  env : Map[String, String]
  cwd : String
}

///|
/// A Streamable HTTP endpoint, with any static headers the server needs.
#derive(Debug)
pub(all) struct HttpSpec {
  url : String
  headers : Map[String, String]
}

///|
/// The transport half of a server definition.
#derive(Debug)
pub(all) enum ServerKind {
  Stdio(StdioSpec)
  Http(HttpSpec)
}

///|
/// One configured MCP server.
#derive(Debug)
pub(all) struct Server {
  name : String
  kind : ServerKind
  /// A short human note: the config's `description`, or the file it came from.
  note : String
}

///|
/// A tool advertised by a server's `tools/list`.
#derive(Debug)
pub(all) struct Tool {
  name : String
  title : String
  description : String
  input_schema : Json
}

///|
/// One block of a tool result. The first two kinds are the ones every client
/// understands; the rest are kept verbatim so nothing is silently dropped.
#derive(Debug)
pub(all) enum Content {
  /// Plain text, the common case.
  Text(String)
  /// An image, as a MIME type and base64 data.
  Image(String, String)
  /// Audio, as a MIME type and base64 data.
  Audio(String, String)
  /// A resource embedded by the server, kept as its raw JSON.
  EmbeddedResource(Json)
  /// Any future content kind, kept verbatim.
  Unknown(Json)
}

///|
/// The result of a `tools/call`.
#derive(Debug)
pub(all) struct CallResult {
  content : Array[Content]
  is_error : Bool
  structured : Json?
}

///|
/// What a server reports about itself during `initialize`.
#derive(Debug)
pub(all) struct ServerInfo {
  name : String
  version : String
  protocol_version : String
  instructions : String
}
