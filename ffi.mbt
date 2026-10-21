///|
/// FFI bindings for the native shims in `stub.c`.

///|
/// Terminate the process with the given status. Used once the CLI has printed
/// its result so scripts and agents see a meaningful exit code.
pub extern "C" fn mcpbox_exit(code : Int32) = "mcpbox_exit"
