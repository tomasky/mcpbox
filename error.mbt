///|
/// The single error type the library raises. Everything user-facing — a bad
/// config, an unreachable server, a failed tool — arrives here as a message
/// that the CLI prints as-is.
pub(all) suberror McpError {
  McpError(String)
}

///|
/// Raise a `McpError` with a formatted message.
pub fn fail(message : String) -> McpError {
  McpError(message)
}

///|
/// Render any MoonBit error as a one-line message. An `McpError` already
/// carries a human sentence, so it is unwrapped rather than printed with its
/// constructor name attached.
fn error_text(error : Error) -> String {
  match error {
    McpError(message) => message
    _ => error.to_string()
  }
}
