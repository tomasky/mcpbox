///|
/// mcpbox — carry MCP tools into scripts, CLIs and agents.
///
/// The package is a small MCP client runtime plus the `mcpbox` command line.
/// `main_cli` is the executable entry point; the types, config loader and
/// `Session` API below it are usable as a library.

///|
/// Entry point for the `mcpbox` executable. A failure is reported once, on
/// stderr, and turns into a non-zero exit status.
pub async fn main_cli() -> Unit {
  let args = @env.args()
  let code = try {
    run(args)
    0
  } catch {
    error => {
      @stdio.stderr.write("mcpbox: \{error_text(error)}\n") catch {
        _ => ()
      }
      1
    }
  }
  mcpbox_exit(code)
}
