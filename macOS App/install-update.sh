#!/bin/sh
# All paths are positional arguments, never interpolated shell source.
set -u
pid="$1"; target="$2"; next="$3"; backup="$4"; log="$5"; ack="$6"
opener="${7:-/usr/bin/open}"; timeout="${8:-30}"
exec >>"$log" 2>&1
tries=0
while kill -0 "$pid" 2>/dev/null; do
  tries=$((tries + 1)); [ "$tries" -gt 60 ] && exit 1
  sleep 1
done
/bin/mv "$target" "$backup" || exit 1
if /bin/mv "$next" "$target" && "$opener" -n "$target" --args --update-ack "$ack"; then
  tries=0
  while [ "$tries" -lt "$timeout" ]; do
    if [ -f "$ack" ]; then
      echo 'Update opened successfully. Previous app retained at:' "$backup"
      exit 0
    fi
    tries=$((tries + 1)); sleep 1
  done
fi
# A startup PID file permits stopping a failed launch before restoring its bundle.
if [ -f "$ack.pid" ]; then
  newpid="$(cat "$ack.pid")"
  case "$newpid" in ''|*[!0-9]*) ;; *) kill "$newpid" 2>/dev/null || true ;; esac
fi
[ -e "$target" ] && /bin/mv "$target" "$next"
/bin/mv "$backup" "$target" || exit 1
"$opener" -n "$target"
echo 'Update failed; restored the previous app.'
exit 1
