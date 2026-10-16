///|
/// mcpbox executable entry point. All real work lives in `kupas/mcpbox`.

///|
async fn main {
  // The CLI reports user-facing errors itself. Anything that escapes is either
  // an already-reported failure or a closed output pipe (for example
  // `mcpbox list | head`), neither of which deserves a stack-trace-like dump.
  @lib.main_cli() catch {
    _ => ()
  }
}
