#!/bin/bash
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
APP="$PLUGIN_ROOT/AngryNavi.app"
APP_BINARY="$APP/Contents/MacOS/AngryNavi"
EVENTS_DIR="/tmp/angrynavi/events"
RESPONSES_DIR="/tmp/angrynavi/responses"
mkdir -p "$EVENTS_DIR" "$RESPONSES_DIR"
# Owner-only: event files hold Confidential tool input; response files are the
# permission-decision channel that hook.sh trusts unconditionally. Chmod on
# every fire so drift from earlier installs self-heals.
chmod 700 /tmp/angrynavi "$EVENTS_DIR" "$RESPONSES_DIR" 2>/dev/null || true

# Clean up stale event/response files older than 5 minutes
find "$EVENTS_DIR" "$RESPONSES_DIR" -type f -mmin +5 -delete 2>/dev/null || true

# Append a timestamped line to the debug log so "is the hook even firing in
# this session" is a one-line tail instead of process archaeology.  Best
# effort: never fail the hook over a logging error.
DEBUG_LOG="/tmp/angrynavi/debug.log"
navi_log() {
    printf '%s [pid=%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${PPID:-?}" "$*" >> "$DEBUG_LOG" 2>/dev/null || true
}
# Keep the log bounded (last 500 lines) so it can't grow without limit.
if [ -f "$DEBUG_LOG" ] && [ "$(wc -l < "$DEBUG_LOG" 2>/dev/null || echo 0)" -gt 1000 ]; then
    tail -n 500 "$DEBUG_LOG" > "$DEBUG_LOG.tmp" 2>/dev/null && mv "$DEBUG_LOG.tmp" "$DEBUG_LOG" 2>/dev/null || true
fi

# Install if needed (build.sh fetches the release for plugin.json's version
# and short-circuits when Navi.app's built-version marker already matches)
bash "$PLUGIN_ROOT/build.sh" >&2

# Launch the monitor app if not running (skip if NAVI_NO_AUTO_LAUNCH is set).
if [ -z "${NAVI_NO_AUTO_LAUNCH:-}" ] && [ ! -f "/tmp/angrynavi/no-auto-launch" ] && ! pgrep -x AngryNavi > /dev/null 2>&1; then
    open "$APP" &
    sleep 0.5
fi

# Feature flags: hooks check /tmp/angrynavi/features/<name> to skip work for
# disabled experimental features.  Flag files can be empty (boolean) or
# contain JSON config readable with feature_config().
FEATURES_DIR="/tmp/angrynavi/features"

# Read a JSON value from a feature flag file.  No current features use this
# yet — it's infrastructure for future configurable experimental features.
# Callers must use hardcoded flag names — no user input or dynamic values.
# Usage: feature_config <flag-name> <json-key> [default]
feature_config() {
    [[ "$1" =~ ^[a-z0-9-]+$ ]] || { echo "${3:-}"; return; }
    local file="$FEATURES_DIR/$1"
    [ -f "$file" ] && [ -s "$file" ] || { echo "${3:-}"; return; }
    python3 - "$file" "$2" "${3:-}" <<'PYEOF' 2>/dev/null || echo "${3:-}"
import json, sys
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
print(d.get(key, default))
PYEOF
}

# Capture the TTY of the Claude Code process so Navi can focus the right
# terminal tab.  The hook shell's own TTY shows "??" because stdin is piped,
# so we read the controlling terminal of the parent (Claude Code) process.
if [ -f "$FEATURES_DIR/terminal-focus" ]; then
    NAVI_TTY=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ' || echo "")
    if [ -n "$NAVI_TTY" ] && [ "$NAVI_TTY" != "??" ]; then
        export NAVI_TTY="/dev/$NAVI_TTY"
    else
        export NAVI_TTY=""
    fi
fi

# Export the Claude Code PID so parse_event.py can look up the session name
# from ~/.claude/sessions/<pid>.json.
if [ -f "$FEATURES_DIR/session-names" ]; then
    export NAVI_PPID="$PPID"
fi

# Timeout for PermissionRequest polling (seconds).  Also used by
# parse_event.py to set an "expires" timestamp on permission events
# so Navi knows when the buttons go stale.
export NAVI_HOOK_TIMEOUT=120

# Parse hook payload and write event file.
# Outputs: event_name<TAB>event_id
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export EVENTS_DIR
READ_RESULT=$(cat | python3 "$SCRIPT_DIR/parse_event.py")

EVENT=$(echo "$READ_RESULT" | cut -f1)
EVENT_ID=$(echo "$READ_RESULT" | cut -f2)

navi_log "fired event=${EVENT:-?} id=${EVENT_ID:-?} yolo=$([ -f "$FEATURES_DIR/yolo-mode" ] && echo on || echo off)"

# Track whether Navi responded so we can set NAVI_RESPONDED for potential
# future use.  We intentionally do NOT write a cancel file on exit — instead
# the card stays visible showing "Respond in terminal" and is dismissed by
# PostToolUse (approve) or Stop events (deny/move on).
NAVI_RESPONDED=false

case "$EVENT" in
    PermissionRequest)
        # Poll for response using wall clock time
        DEADLINE=$(($(date +%s) + NAVI_HOOK_TIMEOUT))
        while [ "$(date +%s)" -lt "$DEADLINE" ]; do
            if [ -f "$RESPONSES_DIR/$EVENT_ID" ]; then
                RESPONSE=$(cat "$RESPONSES_DIR/$EVENT_ID")
                rm -f "$RESPONSES_DIR/$EVENT_ID"
                case "$RESPONSE" in
                    approve)
                        NAVI_RESPONDED=true
                        navi_log "decision=allow id=$EVENT_ID"
                        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
                        exit 0
                        ;;
                    deny)
                        NAVI_RESPONDED=true
                        navi_log "decision=deny id=$EVENT_ID"
                        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}'
                        exit 0
                        ;;
                esac
            fi
            sleep 0.3
        done

        # Timeout — fall back to terminal prompt
        navi_log "decision=ask(timeout) id=$EVENT_ID"
        echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"ask"}}}'
        ;;

    *)
        ;;
esac
