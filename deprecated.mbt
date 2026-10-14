///|
/// `derive(Debug)` also promotes `to_repr` to a regular method, which the
/// compiler warns about. These declarations keep the derived implementations
/// explicit so the build stays warning-clean.

///|
pub extend StdioSpec with @debug.Debug::{to_repr}

///|
pub extend HttpSpec with @debug.Debug::{to_repr}

///|
pub extend ServerKind with @debug.Debug::{to_repr}

///|
pub extend Server with @debug.Debug::{to_repr}

///|
pub extend Tool with @debug.Debug::{to_repr}

///|
pub extend Content with @debug.Debug::{to_repr}

///|
pub extend CallResult with @debug.Debug::{to_repr}

///|
pub extend ServerInfo with @debug.Debug::{to_repr}

///|
pub extend RpcError with @debug.Debug::{to_repr}

///|
pub extend RpcMessage with @debug.Debug::{to_repr}
