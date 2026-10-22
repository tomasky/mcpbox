#!/usr/bin/env bash
# Run only against an explicitly supplied, already-built binary. Never builds.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: bash tests/daemon.sh /absolute/path/to/mcpbox" >&2
  exit 2
fi
bin=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1")
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
export XDG_RUNTIME_DIR="$work/runtime"
export MCPBOX_CONFIG="$work/mcpbox.json"
mkdir -m 700 "$XDG_RUNTIME_DIR"
cleanup() {
  "$bin" stop all --quiet >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
python3 - "$MCPBOX_CONFIG" "$root" "$work" <<'PY'
import json, os, sys
config, root, work = sys.argv[1:]
with open(config, 'w') as f:
    json.dump({'mcpServers': {'fixture': {
        'command': sys.executable,
        'args': [os.path.join(root, 'tests/fixtures/daemon_server.py'), os.path.join(work, 'starts.jsonl')],
        'cwd': work,
    }}}, f)
PY

"$bin" list fixture -b >"$work/list" 2>"$work/progress"
grep -F '/**' "$work/list"
grep -F 'Echo the arguments back as JSON' "$work/list"
grep -F 'connecting' "$work/progress"
"$bin" call fixture.echo name=hello count=3 --raw --quiet >"$work/call" 2>"$work/quiet"
test ! -s "$work/quiet"
"$bin" list fixture --no-docs --quiet >"$work/bare"
if grep -Fq '/**' "$work/bare"; then echo 'unexpected docs' >&2; exit 1; fi
"$bin" list fixture --json >"$work/list.json" 2>"$work/json-stderr"
test ! -s "$work/json-stderr"
python3 - "$work" <<'PY'
import json, os, sys
work = sys.argv[1]
with open(os.path.join(work, 'starts.jsonl')) as f:
    starts = [json.loads(line) for line in f]
assert len(starts) == 1, starts  # list and call reused the same child
assert starts[0]['cwd'] == work
with open(os.path.join(work, 'call')) as f:
    assert json.load(f) == {'name': 'hello', 'count': 3}
with open(os.path.join(work, 'list.json')) as f:
    assert json.load(f)['servers'][0]['tools'][0]['name'] == 'echo'
PY

"$bin" stop fixture --json >"$work/stopped.json"
python3 - "$work" <<'PY'
import json, os, sys
work = sys.argv[1]
with open(os.path.join(work, 'stopped.json')) as f:
    assert json.load(f)['stopped'] == 1
with open(os.path.join(work, 'starts.jsonl')) as f:
    pid = json.loads(f.readline())['pid']
try:
    os.kill(pid, 0)
except ProcessLookupError:
    pass
else:
    raise AssertionError(f'stopped child {pid} is still alive')
PY

"$bin" list fixture -b --quiet >/dev/null
"$bin" stop all --json >"$work/stopped-all.json"
python3 - "$work" "$XDG_RUNTIME_DIR" <<'PY'
import json, os, sys, time
work, runtime = sys.argv[1:]
with open(os.path.join(work, 'starts.jsonl')) as f:
    assert len(f.readlines()) == 2
with open(os.path.join(work, 'stopped-all.json')) as f:
    assert json.load(f)['stopped'] == 1
endpoint = os.path.join(runtime, 'mcpbox/endpoint.json')
for _ in range(100):
    if not os.path.exists(endpoint):
        break
    time.sleep(.05)
assert not os.path.exists(endpoint), 'daemon endpoint survived stop all'
PY
echo 'daemon lifecycle checks passed'
