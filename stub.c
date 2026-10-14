/*
 * A single POSIX shim: mcpbox needs a real process exit status so that a
 * failed command is visible to scripts and agents. The MoonBit runtime has no
 * portable exit, and `abort` is for bugs rather than expected failures.
 */

#include <moonbit.h>
#include <stdlib.h>

MOONBIT_FFI_EXPORT
void mcpbox_exit(int32_t code) {
  exit((int)code);
}
