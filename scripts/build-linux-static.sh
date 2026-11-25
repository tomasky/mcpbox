#!/usr/bin/env bash
#
# Build a fully static Linux `mcpbox` with musl.
#
# A glibc build records the build machine's symbol versions, so a binary built
# on a new runner refuses to start on an older distribution
# ("GLIBC_2.38 not found"). Linking against musl statically removes the whole
# class of problem: the result runs on any Linux of the same architecture.
#
# Usage:
#   scripts/build-linux-static.sh [output-path]
#
# TLS is the reason this script has to do more than swap the compiler. The
# MoonBit async runtime reaches OpenSSL through `dlopen`, and a fully static
# binary has no dynamic loader, so every HTTPS request in a released binary
# failed with TlsError("failed to load OpenSSL") while plain HTTP worked. The
# fix is to link a musl-built OpenSSL into the binary and answer `dlopen` /
# `dlsym` from the symbols already inside it.
#
# Usage:
#   scripts/build-linux-static.sh [output-path]
#
# Environment:
#   MCPBOX_MUSL_WORKDIR         scratch directory (default: a fresh temp dir)
#   MCPBOX_MUSL_OPENSSL_DIR     prebuilt musl OpenSSL prefix (lib/libssl.a,
#                               lib/libcrypto.a). Skips the OpenSSL build.
#   MCPBOX_OPENSSL_VERSION      version to download when building (default 3.5.4)
#   MCPBOX_OPENSSL_TARBALL      use this tarball instead of downloading
#   MCPBOX_OPENSSL_OPENSLLDIR   runtime CA store to bake in (default /etc/ssl)
#
# Requires: musl-tools (Debian/Ubuntu: `apt-get install musl-tools`), plus
# curl and perl when OpenSSL has to be built.
#
# OPENSSLDIR is baked into libcrypto and drives
# `SSL_CTX_set_default_verify_paths`, so it is set to `/etc/ssl` rather than
# this build tree: a path pointing at a scratch directory would leave every
# shipped binary unable to find any CA certificate.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/dist/mcpbox-linux-$(uname -m)}"
work="${MCPBOX_MUSL_WORKDIR:-$(mktemp -d)}"

say() { printf '%s\n' "$*"; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

command -v musl-gcc >/dev/null 2>&1 ||
  die "musl-gcc not found; install musl-tools (apt-get install musl-tools)"

openssl_version="${MCPBOX_OPENSSL_VERSION:-3.5.4}"
openssl_tls_check_host="${MCPBOX_TLS_CHECK_HOST:-mcp.context7.com}"
case "$(uname -m)" in
  x86_64 | amd64) openssl_target="linux-x86_64" ;;
  aarch64 | arm64) openssl_target="linux-aarch64" ;;
  *) die "unsupported architecture for a static build: $(uname -m)" ;;
esac
openssl_openssldir="${MCPBOX_OPENSSL_OPENSLLDIR:-/etc/ssl}"

# The kernel UAPI headers (linux/*.h, asm/*.h) live in /usr/include, which is
# not on musl-gcc's default search path. Find the multiarch directory too:
# linux/types.h includes <asm/types.h>.
multiarch=""
for dir in /usr/include/*-linux-gnu; do
  if [ -d "$dir" ]; then
    multiarch="$dir"
    break
  fi
done
[ -n "$multiarch" ] || die "no /usr/include/*-linux-gnu directory found"

mkdir -p "$work"

# --- fortify shim ----------------------------------------------------------
# The MoonBit runtime is compiled against glibc headers and references the
# __*_chk fortify symbols. musl has no fortify, so supply them.
cat >"$work/fortify_shim.c" <<'EOF'
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
void *__memcpy_chk(void *d, const void *s, size_t n, size_t dn) { (void)dn; return memcpy(d, s, n); }
void *__memmove_chk(void *d, const void *s, size_t n, size_t dn) { (void)dn; return memmove(d, s, n); }
void *__memset_chk(void *d, int c, size_t n, size_t dn) { (void)dn; return memset(d, c, n); }
char *__strcpy_chk(char *d, const char *s, size_t dn) { (void)dn; return strcpy(d, s); }
char *__stpcpy_chk(char *d, const char *s, size_t dn) { (void)dn; return stpcpy(d, s); }
char *__strcat_chk(char *d, const char *s, size_t dn) { (void)dn; return strcat(d, s); }
char *__strncpy_chk(char *d, const char *s, size_t n, size_t dn) { (void)dn; return strncpy(d, s, n); }
char *__strncat_chk(char *d, const char *s, size_t n, size_t dn) { (void)dn; return strncat(d, s, n); }
int __sprintf_chk(char *s, int flag, size_t slen, const char *fmt, ...) { (void)flag; (void)slen; va_list ap; va_start(ap, fmt); int r = vsprintf(s, fmt, ap); va_end(ap); return r; }
int __vsprintf_chk(char *s, int flag, size_t slen, const char *fmt, va_list ap) { (void)flag; (void)slen; return vsprintf(s, fmt, ap); }
int __snprintf_chk(char *s, size_t n, int flag, size_t slen, const char *fmt, ...) { (void)flag; (void)slen; va_list ap; va_start(ap, fmt); int r = vsnprintf(s, n, fmt, ap); va_end(ap); return r; }
int __vsnprintf_chk(char *s, size_t n, int flag, size_t slen, const char *fmt, va_list ap) { (void)flag; (void)slen; return vsnprintf(s, n, fmt, ap); }
int __printf_chk(int flag, const char *fmt, ...) { (void)flag; va_list ap; va_start(ap, fmt); int r = vprintf(fmt, ap); va_end(ap); return r; }
int __vprintf_chk(int flag, const char *fmt, va_list ap) { (void)flag; return vprintf(fmt, ap); }
int __fprintf_chk(FILE *f, int flag, const char *fmt, ...) { (void)flag; va_list ap; va_start(ap, fmt); int r = vfprintf(f, fmt, ap); va_end(ap); return r; }
int __vfprintf_chk(FILE *f, int flag, const char *fmt, va_list ap) { (void)flag; return vfprintf(f, fmt, ap); }
EOF
musl-gcc -O2 -c "$work/fortify_shim.c" -o "$work/fortify_shim.o"
ar rcs "$work/libmbfortify.a" "$work/fortify_shim.o"
# --- OpenSSL (musl, static) ------------------------------------------------
# A glibc-built libssl.a cannot be linked into a musl binary and the distro
# packages are glibc builds, so OpenSSL is compiled from source here unless a
# prefix is supplied.
openssl_prefix="${MCPBOX_MUSL_OPENSSL_DIR:-}"
if [ -z "$openssl_prefix" ]; then
  openssl_prefix="$work/openssl-prefix"
  src="$work/openssl-$openssl_version"
  if [ ! -d "$src" ]; then
    tarball="${MCPBOX_OPENSSL_TARBALL:-}"
    if [ -z "$tarball" ]; then
      tarball="$work/openssl-$openssl_version.tar.gz"
      say "mcpbox: fetching OpenSSL $openssl_version"
      curl -fsSL -o "$tarball" \
        "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" ||
        die "could not download OpenSSL $openssl_version (set MCPBOX_OPENSSL_TARBALL)"
    fi
    tar -xzf "$tarball" -C "$work"
  fi
  say "mcpbox: building a static OpenSSL for musl (openssldir=$openssl_openssldir)"
  (
    cd "$src"
    make clean >/dev/null 2>&1 || true
    # CFLAGS carries the UAPI include paths for the same reason the compiler
    # driver below does: musl-gcc does not search /usr/include.
    CC=musl-gcc \
      CFLAGS="-idirafter /usr/include -idirafter $multiarch" \
      ./Configure "$openssl_target" \
      no-shared no-tests no-apps no-docs no-legacy no-engine \
      --prefix="$openssl_prefix" \
      --openssldir="$openssl_openssldir" >"$work/openssl-configure.log" 2>&1 ||
      die "OpenSSL configure failed; see $work/openssl-configure.log"
    make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" build_libs \
      >"$work/openssl-build.log" 2>&1 ||
      die "OpenSSL build failed; see $work/openssl-build.log"
    mkdir -p "$openssl_prefix/lib"
    cp libssl.a libcrypto.a "$openssl_prefix/lib/"
  )
fi
for lib in libssl.a libcrypto.a; do
  [ -f "$openssl_prefix/lib/$lib" ] ||
    die "$openssl_prefix/lib/$lib is missing; point MCPBOX_MUSL_OPENSSL_DIR at a musl OpenSSL prefix"
done

# --- dlopen shim -----------------------------------------------------------
# `moonbitlang/async` locates OpenSSL with dlopen("libssl.so.3") and resolves
# every entry point with dlsym. A static binary has no dynamic loader, so those
# calls can only fail; the shim reports success and answers dlsym from the
# symbols now linked into the binary.
#
# The name list is read from the async package itself rather than copied here,
# so a dependency upgrade cannot silently leave a function out: a name that is
# no longer exported fails this build instead of TLS at runtime.
async_c="$root/.mooncakes/moonbitlang/async/src/tls/openssl.c"
[ -f "$async_c" ] || die "$async_c is missing; run 'moon update' first"
python3 - "$async_c" "$openssl_prefix" "$work/openssl_shim.c" <<'PY'
import re
import subprocess
import sys

source, prefix, dest = sys.argv[1:]

# Macro definitions also start with IMPORT_FUNC, but their arguments are
# (ret, name, params); only entries of the big IMPORTED_OPEN_SSL_FUNCTIONS list
# are real functions.
required = set()
alternates = set()
for line in open(source):
    stripped = line.lstrip()
    if stripped.startswith("#define"):
        continue
    if not stripped.startswith(("IMPORT_FUNC(", "IMPORT_FUNC_WITH_ALT_NAMES(")):
        continue
    match = re.match(r"\s*IMPORT_FUNC(?:_WITH_ALT_NAMES)?\(\s*[^,]+,\s*(\w+)", line)
    if match:
        required.add(match.group(1))
    # Alternate spellings the loader may fall back to. OpenSSL 3.x turns some
    # of them into macros (`SSL_get_peer_certificate`), so they are not all
    # real symbols and only the primary name is mandatory.
    for alt in re.findall(r'"(\w+)"', line):
        alternates.add(alt)
# Resolved by name outside the macro list.
required.add("OpenSSL_version_num")

defined = set()
for lib in ("libssl.a", "libcrypto.a"):
    out = subprocess.run(
        ["nm", "-g", "--defined-only", f"{prefix}/lib/{lib}"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    for line in out.splitlines():
        parts = line.split()
        if parts:
            defined.add(parts[-1])

missing = sorted(required - defined)
if missing:
    sys.exit("OpenSSL is missing functions the async runtime asks for: " + ", ".join(missing))

# Available alternates are offered too; absent ones are simply never asked for.
names = sorted(required | (alternates & defined))
with open(dest, "w") as f:
    f.write("/* generated by scripts/build-linux-static.sh; do not edit */\n")
    f.write("#include <string.h>\n\n")
    for name in names:
        f.write(f"extern void {name}(void);\n")
    f.write("\nstatic const struct { const char *name; void *addr; } SYMS[] = {\n")
    for name in names:
        f.write(f'  {{ "{name}", (void *)&{name} }},\n')
    f.write("};\n\n")
    f.write(
        "void *dlopen(const char *filename, int flags) {\n"
        "  (void)filename;\n"
        "  (void)flags;\n"
        "  return (void *)1;\n"
        "}\n\n"
        "void *dlsym(void *handle, const char *name) {\n"
        "  (void)handle;\n"
        "  for (unsigned i = 0; i < sizeof(SYMS) / sizeof(SYMS[0]); i++) {\n"
        "    if (strcmp(SYMS[i].name, name) == 0) return SYMS[i].addr;\n"
        "  }\n"
        "  return 0;\n"
        "}\n"
    )
PY
musl-gcc -O2 -idirafter /usr/include -idirafter "$multiarch" \
  -c "$work/openssl_shim.c" -o "$work/openssl_shim.o"
ar rcs "$work/libmbfortify.a" "$work/openssl_shim.o"


# The x86-64 instruction set baseline is pinned instead of inherited from the
# host compiler. Newer Ubuntu images (such as GitHub's current ubuntu-latest)
# configure GCC to target x86-64-v3 by default, which assumes AVX2/BMI2; a
# binary built that way dies with SIGILL ("Illegal instruction") on any older
# x86-64 CPU. The release artifact must keep running on those machines. Other
# architectures keep their compiler's default: aarch64 gcc rejects the value
# -march=x86-64 outright, so the pin only applies on x86-64.
arch_flags=""
case "$(uname -m)" in
  x86_64 | amd64) arch_flags="-march=x86-64 -mtune=generic" ;;
esac

# --- compiler driver -------------------------------------------------------
cat >"$work/mcpbox-musl-gcc" <<EOF
#!/bin/sh
# -idirafter keeps musl's libc headers ahead of glibc's while still making the
# kernel UAPI headers reachable; -include limits.h supplies NAME_MAX, which
# glibc's <unistd.h> provides transitively and musl's does not.
common="$arch_flags -idirafter /usr/include -idirafter $multiarch -include limits.h"
for arg in "\$@"; do
  if [ "\$arg" = "-c" ]; then
    # shellcheck disable=SC2086
    exec musl-gcc \$common "\$@"
  fi
done
# shellcheck disable=SC2086
exec musl-gcc \$common "\$@" -static -L$work -lmbfortify \
  -L$openssl_prefix/lib -lssl -lcrypto -lpthread
EOF
chmod +x "$work/mcpbox-musl-gcc"
ln -sf "$(command -v ar)" "$work/ar"

# --- build -----------------------------------------------------------------
say "mcpbox: building a static binary (musl, workdir $work)"
cd "$root"
MOON_CC="$work/mcpbox-musl-gcc" MOON_AR=ar \
  moon build --target native --release

bin="$root/_build/native/release/build/cmd/mcpbox/mcpbox.exe"
[ -f "$bin" ] || die "build did not produce $bin"

mkdir -p "$(dirname "$out")"
cp "$bin" "$out"
chmod 755 "$out"

# --- verify ----------------------------------------------------------------
say "mcpbox: wrote $out"
file "$out" || true
if ! file "$out" | grep -q "statically linked"; then
  die "$out is not statically linked"
fi
if ldd "$out" >/dev/null 2>&1; then
  die "$out is a dynamic executable"
fi

# A static binary cannot dlopen, so the TLS stack has to be inside the file.
# These checks are hermetic (no network) and cover the two ways TLS broke
# before: OpenSSL not linked, and OPENSSLDIR baked to a build directory that
# makes certificate verification fail on every user's machine.
# `nm | grep -q` would abort nm with SIGPIPE and, under `pipefail`, look like
# a failure, so the symbol table is collected once.
nm "$out" 2>/dev/null >"$work/symbols" || true
grep -q " T SSL_CTX_new$" "$work/symbols" ||
  die "$out does not contain a linked OpenSSL"
grep -q " T dlopen$" "$work/symbols" ||
  die "$out is missing the dlopen shim"
grep -aq "$openssl_openssldir" "$out" ||
  die "$out does not bake in the CA store $openssl_openssldir"

say "mcpbox: verified statically linked"

# Optional end-to-end TLS check. On by default because the failure it guards
# against (a released binary that cannot reach any HTTPS server) is silent
# otherwise; set MCPBOX_SKIP_TLS_CHECK=1 to build without network access.
if [ "${MCPBOX_SKIP_TLS_CHECK:-0}" != "1" ]; then
  if "$out" list adhoc --http-url "https://$openssl_tls_check_host/" --quiet \
    >/dev/null 2>"$work/tls-check.err"; then
    say "mcpbox: verified TLS handshake against $openssl_tls_check_host"
  elif grep -q "failed to load OpenSSL\|certificate verify failed" "$work/tls-check.err"; then
    die "TLS check failed: $(cat "$work/tls-check.err")"
  else
    # An unreachable host is not a TLS defect, so only the two errors above
    # fail the build.
    say "mcpbox: TLS check skipped, could not reach $openssl_tls_check_host"
  fi
fi
