#!/bin/sh
# cc-cache-monitor installer
# Patches ~/.claude/statusline-command.sh with the cache health + waste tracker.
# Idempotent — re-run to upgrade. Replaces the old block in place.

set -e

STATUSLINE="$HOME/.claude/statusline-command.sh"
SETTINGS="$HOME/.claude/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENT="$SCRIPT_DIR/statusline-cache.sh"
BEGIN_MARKER="# cc-cache-monitor: BEGIN"
END_MARKER="# cc-cache-monitor: END"

if [ ! -f "$FRAGMENT" ]; then
  echo "Error: cannot find $FRAGMENT" >&2
  echo "Run install.sh from inside the cloned repo." >&2
  exit 1
fi

mkdir -p "$HOME/.claude"

# No statusline yet — create a minimal one
if [ ! -f "$STATUSLINE" ]; then
  cat > "$STATUSLINE" <<'EOF'
#!/bin/sh
# Minimal Claude Code statusline created by cc-cache-monitor
input=$(cat)
EOF
  cat "$FRAGMENT" >> "$STATUSLINE"
  echo 'printf "%s%s" "${cache_str}" "${waste_str}"' >> "$STATUSLINE"
  chmod +x "$STATUSLINE"
  echo "Created minimal statusline at $STATUSLINE"
  if [ ! -f "$SETTINGS" ] || ! grep -q '"statusLine"' "$SETTINGS" 2>/dev/null; then
    echo ""
    echo "Add this to your $SETTINGS to enable the statusline:"
    echo '  "statusLine": { "type": "command", "command": "sh '"$STATUSLINE"'" }'
  fi
  exit 0
fi

# Existing statusline — back up first
BACKUP="${STATUSLINE}.bak.$(date +%s)"
cp "$STATUSLINE" "$BACKUP"
echo "Backed up existing statusline to $BACKUP"

# Strip any prior cc-cache-monitor block (idempotent upgrade)
if grep -q "$BEGIN_MARKER" "$STATUSLINE"; then
  sed -i "/$BEGIN_MARKER/,/$END_MARKER/d" "$STATUSLINE"
  echo "Removed prior cc-cache-monitor block."
fi

if ! grep -q "^printf" "$STATUSLINE"; then
  echo "Error: could not find a 'printf' line in $STATUSLINE" >&2
  echo "Patch manually — paste statusline-cache.sh before your printf and add \"\$cache_str\" \"\$waste_str\" to the args." >&2
  exit 1
fi

# Inject fresh fragment immediately before the last printf
awk -v fragfile="$FRAGMENT" '
  BEGIN {
    while ((getline line < fragfile) > 0) frag = frag line "\n"
    close(fragfile)
  }
  /^printf/ && !injected {
    printf "%s", frag
    print ""
    injected = 1
  }
  { print }
' "$STATUSLINE" > "${STATUSLINE}.new"

# Patch the printf so its args end with "$cache_str" "$waste_str" (and the
# format string has matching %s tokens). Idempotent — strips any stale
# trailing "$cache_str"/"$waste_str" first, then re-adds in the canonical order.
PY_TMP=$(mktemp -t cc-cache-monitor-patcher.XXXXXX.py)
cat > "$PY_TMP" <<'PYEOF'
import re, sys
p = sys.argv[1]
src = open(p).read()
lines = src.splitlines(keepends=True)
for i in range(len(lines) - 1, -1, -1):
    line = lines[i]
    if not line.lstrip().startswith("printf"):
        continue
    m = re.match(r'(\s*printf\s+)(["\'])(.*?)\2(.*)', line, re.DOTALL)
    if not m:
        break
    indent_kw, q, fmt, rest = m.groups()
    rest = rest.rstrip("\n").rstrip()
    while True:
        new_rest = re.sub(r'\s+"\$(cache_str|waste_str)"$', '', rest)
        if new_rest == rest:
            break
        rest = new_rest
    arg_count = len([a for a in re.findall(r'"\$\w+"|\$\w+|\S+', rest) if a.strip()])
    target_specs = arg_count + 2
    while len(re.findall(r'%[^%]', fmt)) > target_specs:
        fmt = re.sub(r'%[^%]\Z', '', fmt)
    while len(re.findall(r'%[^%]', fmt)) < target_specs:
        fmt = fmt + '%s'
    new_rest = (rest + ' "$cache_str" "$waste_str"').lstrip()
    lines[i] = f"{indent_kw}{q}{fmt}{q} {new_rest}\n"
    break
open(p, "w").write("".join(lines))
PYEOF

if command -v python3 >/dev/null 2>&1; then
  python3 "$PY_TMP" "${STATUSLINE}.new"
else
  echo "Note: python3 not found — applied sed fallback for the printf patch." >&2
  sed -i 's|"\$rl7_str"|"\$rl7_str" "\$cache_str" "\$waste_str"|' "${STATUSLINE}.new"
fi
rm -f "$PY_TMP"

mv "${STATUSLINE}.new" "$STATUSLINE"
chmod +x "$STATUSLINE"
echo "Patched $STATUSLINE"
echo ""
echo "Done. Statusline will refresh on the next Claude Code turn."
echo "Watch for: cache 99% (healthy) | cache ⚠2% (3f) (bug fired) | wasted: 47.3M (lifetime)"
