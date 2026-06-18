#!/bin/bash
# Lightweight hook that captures tool_use_id before PermissionRequest fires.
# PermissionRequest payloads lack tool_use_id, but PreToolUse has it.
# Gated behind the auto-dismiss feature flag.
set -euo pipefail
[ -f /tmp/angrynavi/features/auto-dismiss ] || exit 0
mkdir -p /tmp/angrynavi/pretooluse || true
chmod 700 /tmp/angrynavi /tmp/angrynavi/pretooluse 2>/dev/null || true
python3 -c "
import sys, json, os, re, tempfile
d = json.load(sys.stdin)
sid = d.get('session_id', '')
tuid = d.get('tool_use_id', '')
if sid and tuid and '/' not in sid and '..' not in sid and re.match(r'^[A-Za-z0-9_-]{1,256}$', tuid):
    target = '/tmp/angrynavi/pretooluse/' + sid + '.latest'
    fd, tmp = tempfile.mkstemp(dir='/tmp/angrynavi/pretooluse')
    with os.fdopen(fd, 'w') as f:
        f.write(tuid)
    os.rename(tmp, target)
" || true
