#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
# Pass the path as an argument; JSON escaping makes it a literal Lua string.
python3 - "$project_dir" <<'PY'
import json, subprocess, sys
root = sys.argv[1]
for test in ('session_test.lua', 'runtime_test.lua', 'mission_control_test.lua'):
    path = json.dumps(root + '/tests/' + test, ensure_ascii=False)
    result = subprocess.run(['hs', '-c', 'local r=dofile(' + path + '); assert(r.passed); return "PASS ' + test + ' " .. r.assertions'], capture_output=True, text=True)
    print(result.stdout.strip())
    if result.returncode or 'PASS ' + test not in result.stdout:
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
PY
