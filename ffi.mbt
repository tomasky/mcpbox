///|
/// FFI bindings for the native shims in `stub.c`.

///|
/// Terminate the process with the given status. Used once the CLI has printed
/// its result so scripts and agents see a meaningful exit code.
pub extern "C" fn mcpbox_exit(code : Int32) = "mcpbox_exit"

///|
#borrow(path)
extern "C" fn mcpbox_private_directory(path : Bytes) -> Bool = "mcpbox_private_directory"

///|
extern "C" fn mcpbox_is_tty(fd : Int32) -> Bool = "mcpbox_is_tty"

///|
#borrow(path)
extern "C" fn mcpbox_daemon_lock(path : Bytes) -> Int32 = "mcpbox_daemon_lock"

///|
extern "C" fn mcpbox_close_fd(fd : Int32) -> Unit = "mcpbox_close_fd"

///|
extern "C" fn mcpbox_signal_child(pid : Int32, signal_number : Int32) -> Unit = "mcpbox_signal_child"
