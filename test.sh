#!/bin/bash
# Tests for telex, run in a throwaway room and fake home. Usage: ./test.sh
set -u
SRC="$(cd "$(dirname "$0")" && pwd -P)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" TELEX_DIR="$T/home/.telex"; unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CLAUDE_CODE_EXECPATH PI_SESSION_ID
mkdir -p "$HOME/.claude" "$HOME/.pi/agent" "$T/bin"; C="$SRC/telex"; LOG="$TELEX_DIR/telex.jsonl"
fails=0
count() { wc -l < "${1:-/dev/stdin}" | tr -d ' '; }          # lines in a file, or on stdin
rows() { jq -R -r "fromjson? | $1" "$LOG"; }                       # the room, lenient like telex itself
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fails=$((fails+1)); fi; }
unread() { "$C" read "$1" | grep -c '^--- from'; }

# fake claude and codex come first on PATH, so the tests never reach the real ones.
# The fake session list holds every Claude session linked in the room, minus $HOME/stopped, each with
# the status in $HOME/status-<id> (default idle). A fake headless turn logs itself and reads its mail.
cat > "$T/bin/claude" <<'EOF'
#!/bin/sh
case "$1" in
  agents) printf '['; sep=
    for s in $(jq -R -n -r 'inputs | fromjson? | select(.to == "telex" and .subject == "join") | .body
        | select(startswith("claude:")) | ltrimstr("claude:")' "$TELEX_DIR/telex.jsonl" 2>/dev/null | sort -u); do
      grep -qx "$s" "$HOME/stopped" 2>/dev/null && continue
      printf '%s{"sessionId":"%s","status":"%s"}' "$sep" "$s" "$(cat "$HOME/status-$s" 2>/dev/null || echo idle)"; sep=,
    done; echo ']' ;;
  auth) printf '{"loggedIn":%s}\n' "$(cat "$HOME/loggedin" 2>/dev/null || echo true)" ;;
  -p) echo "$(pwd -P) session=${CLAUDE_CODE_SESSION_ID:-} $*" >> "$HOME/wakes"   # env -i keeps HOME, USER, PATH, TELEX_DIR
      sleep 0.3; [ -f "$HOME/noread" ] || eval "${4##*Run: }" >/dev/null 2>&1
      echo "{\"session_id\":\"$3\"}" | perl -e 'alarm 3; exec @ARGV' "$TELEX_DIR/telex" listen >/dev/null 2>&1; echo $? >> "$HOME/hook-rc"   # the turn's Stop hook
      sleep "$(cat "$HOME/after" 2>/dev/null || echo 0)" ;;
esac
EOF
printf '#!/bin/sh\n[ "$1" = app-server ] && { echo "${CLAUDE_CODE_SESSION_ID:-none}" > "$HOME/daemon-env"; exit 0; }\necho push >> "$HOME/pushes"; [ -z "${FAKE_CODEX_WARN:-}" ] || echo "Warning: queued, but could not resume: $FAKE_CODEX_WARN" >&2; exit ${FAKE_CODEX_RC:-1}\n' > "$T/bin/codex"; chmod +x "$T/bin/claude" "$T/bin/codex"
# fake tailscale: this machine is 127.0.0.2, the other one ("m2host") 127.0.0.1, "theirs" is someone else's. Fake service managers only log.
cat > "$T/bin/tailscale" <<EOF
#!/bin/sh
[ -f "$T/ts-off" ] && exit 1
case "\$1 \$2" in "ip -4") case "\$3" in "") echo 127.0.0.2 ;; m2host|127.0.0.1) echo 127.0.0.1 ;; theirs) echo 127.0.0.9 ;; *) exit 1 ;; esac ;;
  "whois --json") if [ "\$3" = 127.0.0.9 ]; then echo '{"Node":{},"UserProfile":{"LoginName":"other@x"}}'
    elif [ "\$3" = 127.0.0.1 ] && [ "\$HOME" = "$T/m2" ] && [ -f "$T/whois" ]; then cat "$T/whois"
    else echo '{"Node":{},"UserProfile":{"LoginName":"me@x"}}'; fi ;; esac
EOF
printf '#!/bin/sh\necho "$(basename "$0") $*" >> "%s/svc"\n' "$T" | tee "$T/bin/launchctl" > "$T/bin/systemctl"; chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"

# install from a download that is then deleted (uninstall at the end must give back these settings exactly)
echo '{"model":"m","permissions":{"allow":["Bash(ls:*)"]}}' > "$HOME/.claude/settings.json"; cp "$HOME/.claude/settings.json" "$T/settings.orig"
mkdir -p "$T/dl"; cp -R "$SRC/telex" "$SRC/skill" "$SRC/pi" "$T/dl/"; echo false > "$HOME/loggedin"
out="$("$T/dl/telex" install)"; rm -rf "$T/dl" "$HOME/loggedin"
check "install works without its download" "$([ -f "$TELEX_DIR/telex" ] && [ ! -L "$TELEX_DIR/telex" ] && echo '{}' | "$TELEX_DIR/telex" listen \
  && cat "$HOME/.claude/skills/telex/SKILL.md" "$HOME/.agents/skills/telex/SKILL.md" >/dev/null && echo yes)" "yes"
check "install adds the hooks and allow rules, keeps the rest" \
  "$(jq -c '[(.hooks.Stop|length), (.hooks.StopFailure|length), (.hooks.SessionStart|length), (.permissions.allow|length), .model]' "$HOME/.claude/settings.json")" '[1,1,1,3,"m"]'
check "install copies the Pi extension" "$(cmp -s "$SRC/pi/telex.ts" "$HOME/.pi/agent/extensions/telex.ts" && echo pi)" "pi"
check "install says how to sign in the CLI" "$(echo "$out" | grep -cF "\"$T/bin/claude\" auth login")" "1"
"$TELEX_DIR/telex" install >/dev/null; check "install again from the installed copy" "$?/$(jq '.hooks.Stop|length' "$HOME/.claude/settings.json")" "0/1"

"$C" read bob >/dev/null; CLAUDE_CODE_SESSION_ID=S-A "$C" read alice >/dev/null
check "send to someone new works, with a heads-up" "$("$C" send bob Carol.2 early bird | grep -c 'gets this when it first reads')" "1"
check "their mail waits until they first read" "$(unread Carol.2)" "1"
TMPDIR=/nonexistent "$C" send bob alice lock "x" >/dev/null 2>&1; check "lock does not depend on TMPDIR" "$?" "0"
"$C" send bob alice words this body has no quotes >/dev/null; check "unquoted body words are kept" "$("$C" read alice | grep -c '^this body has no quotes$')" "1"
CODEX_THREAD_ID=T-1 "$C" read cx >/dev/null
out="$("$C" send bob cx hi there 2>&1)"; rc=$?
check "failed Codex wake still counts as sent" "$rc/$(echo "$out" | grep -c 'Sent to cx')" "0/1"
mv "$LOG" "$LOG.keep"; "$C" send bob alice fresh room >/dev/null 2>&1; check "missing room file is recreated" "$?" "0"
mv "$LOG.keep" "$LOG"
"$C" send user alice hi there >/dev/null; "$C" send alice user Re:hi back >/dev/null
check "a first-time sender can get replies" "$(unread user)" "1"; "$C" read alice >/dev/null

BIG="$(perl -e 'print "it'"'"'s \"q\" ünï\n", "x" x 12000')"
for i in 1 2 3 4 5 6; do "$C" send bob alice "c$i" "$BIG" >/dev/null & done; wait
echo 'not json {' >> "$LOG"
check "concurrent sends stay whole" "$(rows 1 | count)" "$(( $(count "$LOG") - 1 ))"
check "bad line skipped, big mail read one per read" "$(unread alice)" "1"
while [ "$(unread alice)" -gt 0 ]; do :; done

for i in 1 2 3 4 5 6 7 8 9 10; do "$C" send bob alice "b$i" "$(perl -e 'print "y" x 3000')" >/dev/null; done
reads=0; total=0; while n="$(unread alice)"; [ "$n" -gt 0 ]; do reads=$((reads+1)); total=$((total+n)); done
check "bounded reads show all 10 in parts" "$total/$([ "$reads" -gt 1 ] && echo parts)" "10/parts"

"$C" send bob alice huge "$(perl -e 'print "z" x 40000')" >/dev/null
check "one 40 KB message shown whole" "$("$C" read alice | awk 'length($0)==40000' | count)" "1"

"$C" send bob alice away ping >/dev/null
check "the same session coming back gets waiting mail" "$(CLAUDE_CODE_SESSION_ID=S-A unread alice)" "1"

# listener: rings once Claude Code's own session list says the session is idle
hookin() { echo "{\"session_id\":\"$1\"}"; }
hookin NOPE | "$C" listen; check "listener: non-member exits" "$?" "0"
"$C" send bob alice ring x >/dev/null; hookin S-A | "$C" listen 2>/dev/null; check "listener: rings when mail waits and the session is idle" "$?" "2"
"$C" read alice >/dev/null
CLAUDE_CODE_SESSION_ID=S-B "$C" read bea >/dev/null; echo busy > "$HOME/status-S-B"         # checked at the end: it asks every 15 s
( hookin S-B | "$C" listen 2>/dev/null; echo "$? $SECONDS" > "$T/rang" ) & bea=$!
sleep 1; "$C" send bob bea held x >/dev/null
hookin S-B | "$C" listen; check "listener: only one runs" "$?" "0"
sleep 1.5; idle_at=$SECONDS; echo idle > "$HOME/status-S-B"
CLAUDE_CODE_SESSION_ID=S-X "$C" read xia >/dev/null; echo S-X > "$HOME/stopped"; echo false > "$HOME/loggedin"
"$C" send bob xia hi x >/dev/null; hookin S-X | "$C" listen 2>/dev/null; check "listener: exits when its session has stopped" "$?" "0"
rm "$HOME/loggedin"; : > "$HOME/stopped"; "$C" read xia >/dev/null

# registration happens on send and read
CLAUDE_CODE_SESSION_ID=S-M "$C" send matilda alice hi there >/dev/null; "$C" send alice matilda re back >/dev/null
hookin S-M | "$C" listen 2>/dev/null; check "a first send makes the sender wakeable" "$?" "2"; "$C" read matilda >/dev/null
CLAUDE_CODE_SESSION_ID=S-W "$C" read wendy >/dev/null; "$C" send bob wendy hi x >/dev/null
hookin S-W | "$C" listen 2>/dev/null; check "a first read makes the reader wakeable" "$?" "2"; "$C" read wendy >/dev/null
"$C" read alice >/dev/null; "$C" send alice bob x y >/dev/null; "$C" send bob alice ping x >/dev/null
hookin S-A | "$C" listen 2>/dev/null; check "a terminal using alice's name leaves her wakes alone" "$?" "2"; "$C" read alice >/dev/null
CLAUDE_CODE_SESSION_ID=S-A2 "$C" read alice >/dev/null; "$C" send bob alice moved x >/dev/null
hookin S-A2 | "$C" listen 2>/dev/null; a2=$?; hookin S-A | "$C" listen 2>/dev/null; a1=$?
check "a newer session takes over the name" "$a2/$a1" "2/0"

# a takeover while the old session's listener runs: only the new owner is woken
CLAUDE_CODE_SESSION_ID=Z-OLD "$C" read zed >/dev/null
( hookin Z-OLD | "$C" listen > "$T/old.out" 2>&1; echo $? > "$T/old.rc" ) & old=$!
sleep 1.5; CLAUDE_CODE_SESSION_ID=Z-NEW "$C" read zed >/dev/null
( hookin Z-NEW | "$C" listen > "$T/new.out" 2>&1; echo $? > "$T/new.rc" ) & new=$!
sleep 1.5; "$C" send bob zed "for the new owner" x >/dev/null; wait "$old" "$new"
check "takeover: old listener goes quiet, new one rings" "$(cat "$T/old.rc")/$(grep -c 'New telex' "$T/old.out")/$(cat "$T/new.rc")" "0/0/2"
"$C" read zed >/dev/null

# an upgrade reaches a running listener: it carries on in the new code
CLAUDE_CODE_SESSION_ID=S-UP "$C" read upa >/dev/null
( hookin S-UP | "$TELEX_DIR/telex" listen > "$T/up.out" 2>&1; echo $? > "$T/up.rc" ) & up=$!
sleep 1.2; sed 's/New telex\./New telex (upgraded)./' "$TELEX_DIR/telex" > "$TELEX_DIR/telex.tmp"
chmod +x "$TELEX_DIR/telex.tmp"; mv "$TELEX_DIR/telex.tmp" "$TELEX_DIR/telex"
sleep 1.2; "$C" send bob upa hi x >/dev/null; wait "$up"
check "an upgrade reaches a running listener" "$(cat "$T/up.rc")/$(grep -c 'New telex (upgraded)\. Run: .* read upa' "$T/up.out")" "2/1"
cp "$C" "$TELEX_DIR/telex"; "$C" read upa >/dev/null

"$C" send bob telex x y >/dev/null 2>&1; a=$?; "$C" read telex >/dev/null 2>&1; b=$?
check "telex is not a usable name" "$a/$b" "1/1"

# a stopped Claude session gets headless turns, in its own folder, until its mail is read; a running one is left to its listener
mkdir -p "$T/proj" "$HOME/.claude/projects/p"; echo '{"cwd":"'"$T/proj"'"}' > "$HOME/.claude/projects/p/S-STOP.jsonl"
FAKE_LOG="$HOME/wakes"; : > "$FAKE_LOG"; echo S-STOP > "$HOME/stopped"
CLAUDE_CODE_SESSION_ID=S-STOP "$C" read sleepy >/dev/null
out="$(CLAUDE_CODE_SESSION_ID=S-SENDER "$C" send bob sleepy hi there)"
"$C" send bob sleepy again x >/dev/null; sleep 1.5
check "stopped session gets one turn, in its folder, as itself, and reads" \
  "$(count "$FAKE_LOG")/$(grep -c "^$(realpath "$T/proj") session= -p --resume S-STOP New telex\. Run: .*read sleepy" "$FAKE_LOG")/$(echo "$out" | grep -c 'started a turn')/$(unread sleepy)" "1/1/1/0"
: > "$FAKE_LOG"; : > "$HOME/stopped"; "$C" send bob sleepy running x >/dev/null; sleep 0.5
check "running session is left to its listener" "$(count "$FAKE_LOG")" "0"
printf '{"cwd":"%s"}\n{"cwd":"%s"}\n' "$T/moved-away" "$T/proj" > "$HOME/.claude/projects/p/S-MV.jsonl"      # the folder was renamed mid-session
CLAUDE_CODE_SESSION_ID=S-MV "$C" read mvx >/dev/null; echo S-MV > "$HOME/stopped"; : > "$FAKE_LOG"
"$C" send bob mvx hi x >/dev/null; sleep 1.5
check "a session whose first folder is gone is woken in its last one" "$(grep -c "^$(realpath "$T/proj") session= -p --resume S-MV" "$FAKE_LOG")/$(unread mvx)" "1/0"
# /clear or compaction moves a conversation to a new session id; the new transcript says where it came from
mk() { mkdir -p "$HOME/.claude/projects/$1"; printf '{"type":"derived-from","v":1,"sessionId":"%s","sessions":[{"type":"claude_code_session","id":"%s","via":"%s"}]}\n{"cwd":"%s"}\n' "$2" "$3" "$4" "$T/proj" > "$HOME/.claude/projects/$1/$2.jsonl"; }
link() { grep "\"from\":\"$1\",\"to\":\"telex\"" "$LOG" | tail -1 | grep -o 'claude:[^"]*'; }
woke() { : > "$FAKE_LOG"; CLAUDE_CODE_SESSION_ID="$2" "$C" read "$1" >/dev/null; perl -e "alarm 10; exec @ARGV" "$C" send bob "$1" hi x >/dev/null; sleep 1.5; grep -o -- '--resume [^ ]*' "$FAKE_LOG" | cut -c10- | tr '\n' ' '; link "$1"; }
mk p S-C1 S-C0 launch; mk p S-C2 S-C1 clear; printf 'S-C1\nS-C2\n' > "$HOME/stopped"
check "after /clear, mail to the old session wakes the new one, which takes the name" "$(woke cl1 S-C1)" "S-C2 claude:S-C2"
mk p S-H2 S-H1 clear; mk p S-H3 S-H2 compact; echo '{}' > "$HOME/.claude/projects/p/S-H1.jsonl"; printf 'S-H1\nS-H2\nS-H3\n' > "$HOME/stopped"
check "a chain of clears is followed to its end" "$(woke ch1 S-H1)" "S-H3 claude:S-H3"
mk p S-SF S-SF compact; echo S-SF > "$HOME/stopped"
check "a compaction record pointing at itself is not a successor" "$(woke sf1 S-SF)" "S-SF claude:S-SF"
echo '{}' > "$HOME/.claude/projects/p/S-R1.jsonl"; mk p S-R2 S-R1 resume; mk p2 S-O2 S-R1 clear; printf 'S-R1\nS-R2\nS-O2\n' > "$HOME/stopped"
check "a /resume record, or one in another project folder, is not a successor" "$(woke rs1 S-R1)" "S-R1 claude:S-R1"
echo '{}' > "$HOME/.claude/projects/p/S-U1.jsonl"; mk p S-U2 S-U1 clear; echo S-U1 > "$HOME/stopped"
check "a running new session gets the name and no headless turn" "$(woke un1 S-U1)" "claude:S-U2"
: > "$HOME/stopped"; : > "$FAKE_LOG"
mkdir -p "$T/locked"; chmod 000 "$T/locked"; echo '{"cwd":"'"$T/locked"'"}' > "$HOME/.claude/projects/p/S-LK.jsonl"
CLAUDE_CODE_SESSION_ID=S-LK "$C" read lkx >/dev/null; echo S-LK > "$HOME/stopped"; out="$("$C" send bob lkx hi x 2>/dev/null)"; chmod 755 "$T/locked"
check "a drive that cannot start is not reported as started" "$(echo "$out" | grep -c 'Could not wake lkx')/$(echo "$out" | grep -c 'started a turn')" "1/0"
: > "$HOME/stopped"; : > "$FAKE_LOG"
echo S-STOP > "$HOME/stopped"; echo false > "$HOME/loggedin"
out="$("$C" send bob sleepy nologin x)"; out="$out$("$C" send bob sleepy nologin2 x)"; sleep 0.5
check "without a CLI sign-in every send only reports" "$(count "$FAKE_LOG")/$(echo "$out" | grep -c "isn't running")" "0/2"
rm "$HOME/loggedin"
mkdir -p "$T/oldbin"; printf '#!/bin/sh\ncase "$1" in agents) echo "unknown command" >&2; exit 1 ;; auth) echo "{\\"loggedIn\\":true}" ;; -p) echo started >> "$HOME/wakes" ;; esac\n' > "$T/oldbin/claude"
chmod +x "$T/oldbin/claude"; : > "$FAKE_LOG"
out="$(PATH="$T/oldbin:$PATH" "$C" send bob sleepy oldcli x)"; sleep 0.5
check "an unanswerable running check starts no turn and says so" "$(count "$FAKE_LOG")/$(echo "$out" | grep -c "Couldn't check")/$(echo "$out" | grep -c 'was stopped')" "0/1/0"
: > "$FAKE_LOG"            # Codex kills a command's whole process group when it ends
( perl -e 'setpgrp(0, 0); exec @ARGV' sh -c '"$1" send bob sleepy detached x >/dev/null; kill -9 -$$' _ "$C"; true ) 2>/dev/null; sleep 1.5
check "the turn survives its launcher's process group being killed" "$(count "$FAKE_LOG")" "1"
"$C" read sleepy >/dev/null

# mail that lands during a headless turn gets the next one; turns that never read stop after three
CLAUDE_CODE_SESSION_ID=S-D "$C" read dora >/dev/null; echo S-D > "$HOME/stopped"; echo 1 > "$HOME/after"; : > "$FAKE_LOG"
"$C" send bob dora first x >/dev/null; sleep 0.8; out="$("$C" send bob dora follow-up x)"; sleep 3
check "a follow-up during a headless turn gets the next turn" "$(count "$FAKE_LOG")/$(echo "$out" | grep -c 'started')/$(unread dora)" "2/0/0"
rm "$HOME/after"; CLAUDE_CODE_SESSION_ID=S-CAP "$C" read cap >/dev/null; echo S-CAP > "$HOME/stopped"; touch "$HOME/noread"; : > "$FAKE_LOG"
"$C" send bob cap x y >/dev/null; sleep 2
check "headless turns stop after three" "$(count "$FAKE_LOG")" "3"
rm "$HOME/noread"; "$C" read cap >/dev/null; : > "$HOME/stopped"
check "a headless turn's Stop hook exits at once" "$(sort -u "$HOME/hook-rc" | tr '\n' ' ')" "0 "

# pushed wakes go out when unread mail goes from none to some, or when the last real wake is over 10 minutes old
CODEX_THREAD_ID=T-2 "$C" read cx2 >/dev/null; : > "$HOME/pushes"
for i in 1 2 3; do FAKE_CODEX_RC=0 "$C" send bob cx2 "b$i" x >/dev/null; done
check "a burst to Codex gives one push" "$(count "$HOME/pushes")" "1"
"$C" read cx2 >/dev/null; FAKE_CODEX_RC=0 "$C" send bob cx2 after-read x >/dev/null
check "after a read, the next send pushes again" "$(count "$HOME/pushes")" "2"
touch -t 202001010000 "$TELEX_DIR/.wake-T-2"; FAKE_CODEX_RC=0 "$C" send bob cx2 stale x >/dev/null
check "waiting mail with a stale wake is woken again" "$(count "$HOME/pushes")" "3"
"$C" read cx2 >/dev/null
CODEX_THREAD_ID=T-3 "$C" read cx3 >/dev/null; FAKE_CODEX_RC=0 FAKE_CODEX_WARN="thread already has an active writer (code -32600)" "$C" send cxs cx3 open x | grep -c 'Could not wake' > "$T/aw"; rm -f "$TELEX_DIR/.wake-T-3"; "$C" read cx3 >/dev/null; out="$(CLAUDE_CODE_SESSION_ID=S-C FAKE_CODEX_RC=0 FAKE_CODEX_WARN=1 "$C" send cxs cx3 hi x)"
check "a Codex queue that warns is not a wake (but an active writer is); the daemon starts without our session" \
  "$(cat "$T/aw")/$(echo "$out" | grep -c 'Could not wake cx3')/$([ -e "$TELEX_DIR/.wake-T-3" ] && echo wake || echo none)/$(cat "$HOME/daemon-env")" "0/1/none/none"
"$C" read cx3 >/dev/null

# Pi: a Pi session links as pi:<id> even inside another agent; its extension asks _bell
PI_SESSION_ID=P-1 CLAUDE_CODE_SESSION_ID=S-OUTER "$C" read pia >/dev/null
check "a Pi worker inside a Claude session links as itself" "$(rows 'select(.subject=="join" and .from=="pia") | .body')" "pi:P-1"
a="$("$C" _bell pi:P-1)"; "$C" send bob pia hi x >/dev/null; b="$("$C" _bell pi:P-1)"; "$C" read pia >/dev/null; c="$("$C" _bell pi:P-1)"
check "_bell rings only while mail waits" "$([ -z "$a" ] && echo quiet)/$(echo "$b" | grep -c 'read pia$')/$([ -z "$c" ] && echo quiet)" "quiet/1/quiet"
PI_SESSION_ID=P-2 "$C" send old1 bob x y >/dev/null; PI_SESSION_ID=P-2 "$C" read new1 >/dev/null; "$C" send bob old1 hi x >/dev/null
check "a session that took a second name still rings for the first" "$("$C" _bell pi:P-2 | grep -c 'read old1$')" "1"
"$C" read old1 >/dev/null; "$C" read bob >/dev/null

# names ignore case
check "Bob and bob are one mailbox" "$("$C" send carol Bob hi x)/$(unread bob)" "Sent to bob./1"
uh() { "$C" send carol uh1 "$1" x | sed 's/.*reads)//'; }                # a sender sees mail piling up; a new name gets the same hint
check "a burst of 3 shows no hint, then 2, then 3 unread" "$(uh a)|$(uh b)|$(uh c)" ".| (2 unread, oldest 0 min).| (3 unread, oldest 0 min)."
age() { jq -cn --argjson s "$1" '{ts: (now - $s | todate), from: "x", to: "uh2", subject: "old", body: ""}' >> "$LOG"; "$C" send carol uh2 n x | grep -o 'oldest [^)]*'; "$C" read uh2 >/dev/null; }
check "the oldest one's age rounds down: min, h, days" "$(age 3540)/$(age 3600)/$(age 172000)/$(age 172800)" "oldest 59 min/oldest 1 h/oldest 47 h/oldest 2 days"

# read mail is not kept: each read compacts the log to links plus unread mail
"$C" read alice >/dev/null; "$C" send alice bob keep me >/dev/null; "$C" send bob alice drop me >/dev/null; "$C" read alice >/dev/null
check "read mail is gone" "$(rows 'select(.to=="alice") | .subject' | count)" "0"
check "others' unread mail is kept" "$(rows 'select(.to=="bob" and .subject=="keep") | .body')" "me"
check "links are kept" "$(rows 'select(.subject=="join" and .from=="alice") | .body' | tail -1)" "claude:S-A2"

wait "$bea"; read -r rc at < "$T/rang"
check "listener: holds while busy, rings once idle" "$rc/$([ "$at" -ge "$idle_at" ] && echo after)" "2/after"

# the `telex` command: linked into ~/.local/bin only when that exists, is on PATH, and holds nothing foreign
LB="$HOME/.local/bin"; mkdir -p "$LB"; : > "$HOME/stopped"
hint() { "$C" send bob "$1" h x >/dev/null; "$C" read "$1" | grep -o 'Reply: [^ ]*'; }                # the command an agent is told to type
"$C" install >/dev/null; check "not linked (not on PATH): full path in hints" "$([ -e "$LB/telex" ] || echo none)/$(hint nl1)" "none/Reply: ~/.telex/telex"
printf '#!/bin/sh\necho foreign\n' > "$LB/telex"; chmod +x "$LB/telex"
out="$(PATH="$LB:$PATH" "$C" install)"
check "a foreign telex in ~/.local/bin is left alone, full path kept" \
  "$(echo "$out" | grep -c 'left .*telex alone')/$("$LB/telex")/$(hint nl2)" "1/foreign/Reply: ~/.telex/telex"
rm "$LB/telex"; PATH="$LB:$PATH" "$C" install >/dev/null
check "linked: hints and notices say telex, rule added, full-path rules kept" \
  "$(readlink "$LB/telex" | grep -c '/.telex/telex$')/$(hint nl3)/$(PI_SESSION_ID=P-NL "$C" read nl4 >/dev/null; "$C" send bob nl4 hi x >/dev/null; "$C" _bell pi:P-NL | grep -c 'Run: telex read nl4')/$(jq -r '[.permissions.allow[] | select(startswith("Bash(") and contains("telex"))] | length' "$HOME/.claude/settings.json")" \
  "1/Reply: telex/1/3"
"$C" read nl4 >/dev/null
CLAUDE_CODE_SESSION_ID=S-LNK "$C" read nl5 >/dev/null; echo S-LNK > "$HOME/stopped"; "$C" send bob nl5 hi x >/dev/null; for i in $(seq 50); do grep -q '"to":"nl5"' "$LOG" || break; sleep 0.1; done
check "headless turn finds telex through ~/.local/bin" "$(grep -c 'Run: telex read nl5' "$HOME/wakes")/$(unread nl5)" "1/0"
: > "$HOME/stopped"; : > "$FAKE_LOG"

# two machines over Tailscale: each has its own HOME, room and port, and a small server runs `_recv` per connection as launchd and systemd do
export M1="$HOME" M2="$T/m2"; mkdir -p "$M2/.telex"; B="$M2/.telex/telex"; A="$T/a-telex"
read -r P1 P2 P3 < <(perl -MIO::Socket::INET -e 'my @s = map { IO::Socket::INET->new(LocalAddr => "127.0.0.1", Listen => 1) } 1..3; print join(" ", map { $_->sockport } @s), "\n"')
port() { sed "s/^PORT=[0-9]*/PORT=$1/" "$SRC/telex" > "$2"; chmod +x "$2"; }
port "$P2" "$A"; port "$P1" "$B"                    # each sends to the other's port
serve() { perl -MIO::Socket::INET -e 'my $p = shift; $SIG{CHLD} = "IGNORE"; my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $p, Listen => 9, ReuseAddr => 1) or die;
  while (my $c = $s->accept) { next if fork; close $s; open STDIN, "<&", $c; open STDOUT, ">&", $c; open STDERR, ">&", $c; close $c; exec @ARGV }' "$@" & srv="${srv:-} $!"; disown; }
serve "$P1" env HOME="$M1" TELEX_DIR="$M1/.telex" /bin/bash "$A" _recv
serve "$P2" env HOME="$M2" TELEX_DIR="$M2/.telex" /bin/bash "$B" _recv
trap 'kill $srv 2>/dev/null; rm -rf "$T"' EXIT; sleep 0.5
onB() { env HOME="$M2" TELEX_DIR="$M2/.telex" "$@"; }
route() { LOG="$1/telex.jsonl" rows "select(.subject == \"join\" and .from == \"$2\") | .body" | tail -1; }
raw() { perl -MIO::Socket::INET -e '$SIG{PIPE} = "IGNORE"; my $s = IO::Socket::INET->new("127.0.0.1:$ARGV[0]") or die; print $s $ARGV[1]; shutdown $s, 1; print while <$s>' "$@"; }
CLAUDE_CODE_SESSION_ID=S-ANN "$A" read ann >/dev/null; onB CLAUDE_CODE_SESSION_ID=S-BEN "$B" read ben >/dev/null
out="$("$A" send ann ben@m2host hello 'first')"; got="$(onB "$B" read ben)"
check "first contact by name@host arrives, and the sender's machine is kept there" \
  "$(echo "$out" | grep -c 'Sent to ben')/$(echo "$got" | grep -c '^first$')/$(echo "$got" | grep -c 'from ann')/$(route "$M2/.telex" ann)" "1/1/1/ts:127.0.0.1"
onB CLAUDE_CODE_SESSION_ID=S-BEN "$B" send ben ann 'Re: hello' 'second' >/dev/null
check "a reply to a plain name goes back to its machine" "$("$A" read ann | grep -c '^second$')/$(route "$M1/.telex" ben)" "1/ts:127.0.0.1"
"$A" send ann ben 'plain again' 'third' >/dev/null
check "a plain name linked to another machine needs no name@host" "$(onB "$B" read ben | grep -c '^third$')" "1"
"$A" send ann ben p1 x >/dev/null; check "a remote sender gets the unread hint back" "$("$A" send ann ben p2 x)" "Sent to ben (2 unread, oldest 0 min)."; onB "$B" read ben >/dev/null
"$A" send ann ben@m2host quoting "it's \"q\" \$HOME \`id\` ; & * ünï
second line" >/dev/null
check "tricky bodies cross intact" "$(LOG="$M2/.telex/telex.jsonl" rows 'select(.subject == "quoting") | .body')" "it's \"q\" \$HOME \`id\` ; & * ünï
second line"
echo '{"from":"olga","to":"telex","subject":"join","body":"ssh:someone@127.0.0.1"}' >> "$LOG"; "$A" send ann olga v4 x >/dev/null
check "a v0.4 ssh link still reaches its machine" "$(grep -c '"to":"olga"' "$M2/.telex/telex.jsonl")/$(grep -c '"to":"olga"' "$LOG")" "1/0"
onB "$B" read ben >/dev/null; n="$(count "$M2/.telex/telex.jsonl")"; new() { echo $(( $(count "$M2/.telex/telex.jsonl") - n )); }
refused=; for w in '{"Node":{},"UserProfile":{"LoginName":"other@x"}}' '{"Node":{"Tags":["tag:srv"]},"UserProfile":{"LoginName":"me@x"}}' '' '{}'; do
  printf '%s' "$w" > "$T/whois"; refused="$refused$("$A" send ann ben@m2host hi x | grep -c '^Refused: ')"; done; rm "$T/whois"
check "callers on another account, tagged, or unknown are refused, nothing stored" "$refused/$(new)" "1111/0"
touch "$T/ts-off"; out="$("$A" send ann ben@m2host hi x)"; rm "$T/ts-off"
check "a machine that is not ours, or Tailscale off here: nothing is sent" \
  "$("$A" send ann ben@theirs hi x | grep -c '^Not sent: theirs')/$("$A" send ann ben@nowhere hi x | grep -c '^Not sent')/$(echo "$out" | grep -c '^Not sent')/$(new)" "1/1/1/0"
m='{"from":"web","to":"ben","subject":"s","body":"b"}'
raw "$P2" "POST / HTTP/1.1
Host: x

$m
" >/dev/null; raw "$P2" "$m" >/dev/null; raw "$P2" '{"from":"web","to":"ben"}
' >/dev/null; check "a web page's request, a cut-off line or a partial message stores nothing" "$(new)" "0"
port "$P3" "$T/c-telex"; out="$("$T/c-telex" send ann ben@m2host hi x)"
check "nobody listening there says so" "$(echo "$out" | grep -c "^Couldn't reach m2host; not sent (Connection refused)")" "1"
serve "$P3" true; sleep 0.3
check "no answer is not called sent" "$("$T/c-telex" send ann ben@m2host hi x)" "No confirmation from m2host; it may have arrived."
"$A" send zed ben@m2host hi x >/dev/null          # now zed lives on this machine, as the other one sees it
check "a recipient that lives elsewhere is refused, nothing stored, no forwarding" \
  "$("$A" send ann zed@m2host loop x | grep -c 'zed is not on this machine')/$(grep -c '"to":"zed"' "$M2/.telex/telex.jsonl")" "1/0"
: > "$FAKE_LOG"; echo S-NEW > "$HOME/stopped"; onB "$B" read ben >/dev/null
CLAUDE_CODE_SESSION_ID=S-NEW "$A" send newbie ben@m2host hello x >/dev/null
out="$(onB CLAUDE_CODE_SESSION_ID=S-BEN "$B" send ben newbie 'Re: hello' back)"; sleep 1.5
check "a sender that only sent is linked, and the reply wakes it" \
  "$(echo "$out" | grep -c 'new name')/$(grep -c -- '--resume S-NEW' "$FAKE_LOG")" "0/1"
: > "$HOME/stopped"; : > "$FAKE_LOG"
svc() { find "$HOME/Library/LaunchAgents" "$HOME/.config/systemd" -name 'telex*' 2>/dev/null | count; }
: > "$T/svc"; a="$("$C" install | grep -c 'listening for your other machines')"; b="$(svc)"; touch "$T/ts-off"
check "install starts the listener; without Tailscale it says this machine only" \
  "$a/$([ "$b" -gt 0 ] && echo files)/$(grep -cE 'bootstrap|enable' "$T/svc")/$("$C" install | grep -c 'this machine only')" "1/files/1/1"; rm "$T/ts-off"

touch "$HOME/telex" "$HOME/.lock"
check "uninstall refuses TELEX_DIR of / or home" "$(TELEX_DIR=/ "$C" uninstall 2>&1 >/dev/null | grep -c refusing)/$(TELEX_DIR="$HOME/" "$C" uninstall 2>&1 >/dev/null | grep -c refusing)/$([ -e "$HOME/telex" ] && echo kept)" "1/1/kept"
rm -f "$HOME/telex" "$HOME/.lock"; : > "$T/svc"
"$C" uninstall >/dev/null
check "uninstall stops the listener" "$(grep -cE '^(launchctl bootout gui/[0-9]+/telex|systemctl --user disable -q --now telex.socket)$' "$T/svc")" "1"
check "uninstall removes our link" "$([ -e "$LB/telex" ] || [ -L "$LB/telex" ] || echo gone)" "gone"
printf '#!/bin/sh\necho foreign\n' > "$LB/telex"; chmod +x "$LB/telex"; "$C" uninstall >/dev/null
check "uninstall leaves a foreign telex" "$("$LB/telex")" "foreign"
check "uninstall gives back the user's settings exactly" "$(jq -S . "$HOME/.claude/settings.json")" "$(jq -S . "$T/settings.orig")"
check "uninstall removes what install added, and the room" \
  "$(find "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.pi/agent/extensions" -name '*telex*' 2>/dev/null | count)/$([ -e "$TELEX_DIR" ] && echo left || echo gone)/$(svc)" "0/gone/0"

echo; [ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
