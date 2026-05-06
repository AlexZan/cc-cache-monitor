# cc-cache-monitor: BEGIN
# Cache health + lifetime waste tracker for Claude Code.
# Reads ~/.claude/projects/<project>/<session_id>.jsonl transcripts.
# Outputs $cache_str (per-turn hit rate + flush count) and $waste_str
# (lifetime input-token-equivalents lost to bug-induced flushes).
# Append both to your statusline printf: "$cache_str" "$waste_str".

# --- Per-turn cache health (current session) ---
session_id=$(echo "$input" | jq -r '.session_id // empty')
cache_str=""
if [ -n "$session_id" ]; then
  jsonl=$(find ~/.claude/projects -maxdepth 3 -name "${session_id}.jsonl" -type f 2>/dev/null | head -1)
  if [ -n "$jsonl" ] && [ -f "$jsonl" ]; then
    cache_data=$(jq -s '
      [.[] | select(.message.usage and .timestamp)] as $all
      | [$all[] | .message.usage] as $usages
      | [$all[]
          | .message.usage as $u
          | ($u.cache_read_input_tokens // 0) as $cr
          | ($u.cache_creation_input_tokens // 0) as $cw
          | ($u.input_tokens // 0) as $it
          | ($cr + $cw + $it) as $tot
          | select($tot > 0 and ($cr * 100 / $tot) >= 50)
          | $cw] as $healthy
      | (if ($healthy | length) > 0 then $healthy | min else 0 end) as $base
      | ($usages | last) as $last
      | (reduce ($all | sort_by(.timestamp))[] as $m (
          {w: 0, p: null};
          $m.message.usage as $u
          | ($u.cache_read_input_tokens // 0) as $cr
          | ($u.cache_creation_input_tokens // 0) as $cw
          | ($u.input_tokens // 0) as $it
          | ($cr + $cw + $it) as $tot
          | ($m.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $ts
          | (if .p == null then 999999 else ($ts - .p) end) as $gap
          | if $tot > 0 and ($cr * 100 / $tot) < 50 and $gap < 3600 and $cw > $base
            then {w: (.w + (($cw - $base) * 115 / 100 | floor)), p: $ts}
            else . + {p: $ts} end
        ) | .w) as $session_waste
      | if $last == null then null else
          ($last.cache_read_input_tokens // 0) as $cr
          | ($last.cache_creation_input_tokens // 0) as $cw
          | ($last.input_tokens // 0) as $it
          | ($cr + $cw + $it) as $tot
          | {
              hit: (if $tot > 0 then ($cr * 100 / $tot | floor) else -1 end),
              flushes: ([$usages[]
                | (.cache_read_input_tokens // 0) as $r
                | (.cache_creation_input_tokens // 0) as $w
                | (.input_tokens // 0) as $i
                | ($r + $w + $i) as $t
                | select($t > 0 and ($r * 100 / $t) < 50)] | length),
              session_waste: $session_waste
            }
        end
    ' "$jsonl" 2>/dev/null)
    if [ -n "$cache_data" ] && [ "$cache_data" != "null" ]; then
      hit=$(echo "$cache_data" | jq -r '.hit')
      flushes=$(echo "$cache_data" | jq -r '.flushes')
      session_waste=$(echo "$cache_data" | jq -r '.session_waste // 0')
      if [ "$hit" = "-1" ]; then
        cache_str=" | cache --"
      elif [ "$hit" -lt 50 ]; then
        cache_str=" | cache ⚠${hit}%"
      else
        cache_str=" | cache ${hit}%"
      fi
      if [ -n "$flushes" ] && [ "$flushes" -gt 0 ]; then
        cache_str="${cache_str} (${flushes}f)"
      fi
      if [ -n "$session_waste" ] && [ "$session_waste" -gt 0 ]; then
        if [ "$session_waste" -ge 1000000 ]; then
          sw_fmt=$(awk "BEGIN { printf \"%.1fM\", $session_waste/1000000 }")
        elif [ "$session_waste" -ge 1000 ]; then
          sw_fmt=$(awk "BEGIN { printf \"%.0fk\", $session_waste/1000 }")
        else
          sw_fmt="$session_waste"
        fi
        cache_str="${cache_str} | chat: ${sw_fmt}"
      fi
    fi
  fi
fi

# --- Lifetime waste tracker (across all sessions ever) ---
# Counts a flush as bug-induced when hit_rate < 50% AND gap to prior turn
# < 60 min (cache should have been alive per the paid 1h TTL). Cached
# per-file by mtime to avoid re-parsing unchanged JSONLs.
waste_str=""
WASTE_DIR="$HOME/.claude/cc-cache-monitor"
WASTE_FILE="$WASTE_DIR/waste-cache.json"
mkdir -p "$WASTE_DIR" 2>/dev/null
[ -f "$WASTE_FILE" ] || echo '{}' > "$WASTE_FILE"

cache_mtime=$(stat -c %Y "$WASTE_FILE" 2>/dev/null || echo 0)
newest_mtime=$(find ~/.claude/projects -maxdepth 4 -name "*.jsonl" -type f -printf '%T@\n' 2>/dev/null | sort -nr | head -1 | cut -d. -f1)

if [ -n "$newest_mtime" ] && [ "$newest_mtime" -le "$cache_mtime" ]; then
  waste_total=$(jq '[.[]?.waste // 0] | add // 0' "$WASTE_FILE" 2>/dev/null)
  waste_total=${waste_total:-0}
else
  WASTE_FLAT=$(jq -r 'to_entries[]? | "\(.key)\t\(.value.mtime)\t\(.value.waste)"' "$WASTE_FILE" 2>/dev/null)
  waste_total=0
  NEW_TSV=""
  TMP_LIST=$(mktemp)
  find ~/.claude/projects -maxdepth 4 -name "*.jsonl" -type f -printf '%p\t%T@\n' 2>/dev/null \
    | awk -F'\t' '{ printf "%s\t%d\n", $1, $2 }' > "$TMP_LIST"
  while IFS="$(printf '\t')" read -r path mtime; do
    [ -z "$path" ] || [ ! -f "$path" ] && continue
    cached_line=$(printf '%s\n' "$WASTE_FLAT" | awk -F'\t' -v p="$path" '$1 == p { print $2 "\t" $3; exit }')
    cached_mtime=$(printf '%s' "$cached_line" | cut -f1)
    cached_waste=$(printf '%s' "$cached_line" | cut -f2)
    if [ -n "$cached_mtime" ] && [ "$mtime" -le "$cached_mtime" ] && [ -n "$cached_waste" ]; then
      waste="$cached_waste"
    else
      waste=$(jq -s '
        [.[] | select(.message.usage and .timestamp)] as $all
        | [$all[]
            | .message.usage as $u
            | ($u.cache_read_input_tokens // 0) as $cr
            | ($u.cache_creation_input_tokens // 0) as $cw
            | ($u.input_tokens // 0) as $it
            | ($cr + $cw + $it) as $tot
            | select($tot > 0 and ($cr * 100 / $tot) >= 50)
            | $cw] as $healthy
        | (if ($healthy | length) > 0 then $healthy | min else 0 end) as $base
        | reduce ($all | sort_by(.timestamp))[] as $m (
            {w: 0, p: null};
            $m.message.usage as $u
            | ($u.cache_read_input_tokens // 0) as $cr
            | ($u.cache_creation_input_tokens // 0) as $cw
            | ($u.input_tokens // 0) as $it
            | ($cr + $cw + $it) as $tot
            | ($m.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $ts
            | (if .p == null then 999999 else ($ts - .p) end) as $gap
            | if $tot > 0 and ($cr * 100 / $tot) < 50 and $gap < 3600 and $cw > $base
              then {w: (.w + (($cw - $base) * 115 / 100 | floor)), p: $ts}
              else . + {p: $ts} end
          )
        | .w
      ' "$path" 2>/dev/null)
      [ -z "$waste" ] || [ "$waste" = "null" ] && waste=0
    fi
    waste_total=$((waste_total + waste))
    NEW_TSV="${NEW_TSV}${path}	${mtime}	${waste}
"
  done < "$TMP_LIST"
  rm -f "$TMP_LIST"
  printf '%s' "$NEW_TSV" | jq -Rsc '
    [split("\n")[] | select(length > 0) | split("\t")
                  | {key: .[0], value: {mtime: (.[1]|tonumber), waste: (.[2]|tonumber)}}]
    | from_entries
  ' > "$WASTE_FILE" 2>/dev/null
fi

if [ "$waste_total" -ge 1000000 ]; then
  waste_fmt=$(awk "BEGIN { printf \"%.1fM\", $waste_total/1000000 }")
elif [ "$waste_total" -ge 1000 ]; then
  waste_fmt=$(awk "BEGIN { printf \"%.0fk\", $waste_total/1000 }")
else
  waste_fmt="$waste_total"
fi
[ "$waste_total" -gt 0 ] && waste_str=" | lifetime: ${waste_fmt}"
# cc-cache-monitor: END
