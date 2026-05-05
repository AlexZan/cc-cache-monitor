#!/bin/sh
# cc-cache-monitor installer
# Patches ~/.claude/statusline-command.sh with the cache-health block.

set -e

STATUSLINE="$HOME/.claude/statusline-command.sh"
SETTINGS="$HOME/.claude/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAGMENT="$SCRIPT_DIR/statusline-cache.sh"
MARKER="cc-cache-monitor: cache health from session JSONL"

if [ ! -f "$FRAGMENT" ]; then
  echo "Error: cannot find $FRAGMENT" >&2
  echo "Run install.sh from inside the cloned repo." >&2
  exit 1
fi

mkdir -p "$HOME/.claude"

# Already installed?
if [ -f "$STATUSLINE" ] && grep -q "$MARKER" "$STATUSLINE" 2>/dev/null; then
  echo "cc-cache-monitor is already installed in $STATUSLINE"
  exit 0
fi

# Existing statusline: patch it
if [ -f "$STATUSLINE" ]; then
  BACKUP="${STATUSLINE}.bak.$(date +%s)"
  cp "$STATUSLINE" "$BACKUP"
  echo "Backed up existing statusline to $BACKUP"

  # Find the last printf line (the output line)
  if ! grep -q "^printf" "$STATUSLINE"; then
    echo "Error: could not find a 'printf' line in $STATUSLINE" >&2
    echo "Patch manually — paste statusline-cache.sh before your printf and add \"\$cache_str\" to its args." >&2
    exit 1
  fi

  # Inject the fragment before the printf, then patch the printf to include $cache_str
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

  # Append "$cache_str" as the last printf argument and add %s to the format
  # Matches the trailing quote/paren pattern of a printf call
  python3 - "${STATUSLINE}.new" <<'PYEOF' 2>/dev/null || sed -i 's|"\$rl7_str"|"\$rl7_str" "\$cache_str"|; 0,/printf '\''[^'\'']*/{s|\(printf '\''[^'\'']*\)'\''|\1%s'\''|}' "${STATUSLINE}.new"
import re, sys
p = sys.argv[1]
src = open(p).read()
# Find the last printf line
lines = src.splitlines(keepends=True)
for i in range(len(lines) - 1, -1, -1):
    line = lines[i]
    if line.lstrip().startswith("printf"):
        # Add %s to format string and "$cache_str" to args
        m = re.match(r'(\s*printf\s+)(["\'])(.*?)\2(.*)', line, re.DOTALL)
        if m:
            indent_kw, q, fmt, rest = m.groups()
            new_fmt = fmt + "%s"
            new_rest = rest.rstrip("\n").rstrip()
            if not new_rest.endswith('"$cache_str"'):
                new_rest = new_rest + ' "$cache_str"'
            lines[i] = f"{indent_kw}{q}{new_fmt}{q}{new_rest}\n"
        break
open(p, "w").write("".join(lines))
PYEOF

  mv "${STATUSLINE}.new" "$STATUSLINE"
  chmod +x "$STATUSLINE"
  echo "Patched $STATUSLINE"
else
  # No existing statusline: create a minimal one
  cat > "$STATUSLINE" <<'EOF'
#!/bin/sh
# Minimal Claude Code statusline created by cc-cache-monitor
input=$(cat)
EOF
  cat "$FRAGMENT" >> "$STATUSLINE"
  echo 'printf "%s" "${cache_str:- | cache --}"' >> "$STATUSLINE"
  chmod +x "$STATUSLINE"
  echo "Created minimal statusline at $STATUSLINE"

  if [ ! -f "$SETTINGS" ] || ! grep -q '"statusLine"' "$SETTINGS" 2>/dev/null; then
    echo ""
    echo "Add this to your $SETTINGS to enable the statusline:"
    echo '  "statusLine": { "type": "command", "command": "sh '"$STATUSLINE"'" }'
  fi
fi

echo ""
echo "Done. Statusline will refresh on the next Claude Code turn."
echo "Watch for: cache 99%  (healthy) | cache ⚠2% (3f)  (bug fired 3 times)"
