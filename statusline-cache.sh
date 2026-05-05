# cc-cache-monitor: cache health from session JSONL
# Computes hit rate from the most recent assistant message's usage field
# and counts flush events (hit_rate < 50%) across the session.
# Outputs to $cache_str — append " %s" + "$cache_str" to your printf.
session_id=$(echo "$input" | jq -r '.session_id // empty')
cache_str=""
if [ -n "$session_id" ]; then
  jsonl=$(find ~/.claude/projects -maxdepth 3 -name "${session_id}.jsonl" -type f 2>/dev/null | head -1)
  if [ -n "$jsonl" ] && [ -f "$jsonl" ]; then
    cache_data=$(jq -s '
      [.[] | select(.message.usage) | .message.usage] as $usages
      | ($usages | last) as $last
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
                | select($t > 0 and ($r * 100 / $t) < 50)] | length)
            }
        end
    ' "$jsonl" 2>/dev/null)
    if [ -n "$cache_data" ] && [ "$cache_data" != "null" ]; then
      hit=$(echo "$cache_data" | jq -r '.hit')
      flushes=$(echo "$cache_data" | jq -r '.flushes')
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
    fi
  fi
fi
