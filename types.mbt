///|
/// The mcpbox version, kept in sync with `moon.mod` and `npmjs/package.json`.
/// It is also what the client reports to servers during `initialize`.
pub let version : String = "0.1.4"

///|
/// The MCP revision mcpbox advertises first. Servers that predate it answer
/// with the revision they do support, and mcpbox accepts whatever comes back:
/// the wire format is unchanged across the revisions in use.
pub let protocol_version : String = "2025-06-18"

///|
/// How mcpbox reaches a stdio server: a child process that speaks
/// newline-delimited JSON-RPC on its standard input and output.
pub(all) struct StdioSpec {
  command : String
  args : Array[String]
  env : Map[String, String]
  cwd : String
} derive(Debug)

///|
/// A Streamable HTTP endpoint, with any static headers the server needs.
pub(all) struct HttpSpec {
  url : String
  headers : Map[String, String]
} derive(Debug)

///|
/// The transport half of a server definition.
pub(all) enum ServerKind {
  Stdio(StdioSpec)
  Http(HttpSpec)
} derive(Debug)

///|
/// One configured MCP server.
pub(all) struct Server {
  name : String
  kind : ServerKind
  /// A short human note: the config's `description`, or the file it came from.
  note : String
} derive(Debug)

///|
/// A tool advertised by a server's `tools/list`.
pub(all) struct Tool {
  name : String
  title : String
  description : String
  input_schema : Json
} derive(Debug)

///|
/// One block of a tool result. The first two kinds are the ones every client
/// understands; the rest are kept verbatim so nothing is silently dropped.
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
} derive(Debug)

///|
/// The result of a `tools/call`.
pub(all) struct CallResult {
  content : Array[Content]
  is_error : Bool
  structured : Json?
} derive(Debug)

///|
/// What a server reports about itself during `initialize`.
pub(all) struct ServerInfo {
  name : String
  version : String
  protocol_version : String
  instructions : String
} derive(Debug)
