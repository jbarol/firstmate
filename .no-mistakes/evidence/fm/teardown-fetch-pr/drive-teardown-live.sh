#!/usr/bin/env bash
# Drives the real bin/fm-teardown.sh in marked lab homes against real git remotes:
# a local git daemon, a TCP black hole that never answers, and an HTTP 401 server.
# Real: teardown, git, tmux (private socket). Stubbed only as fleet isolation so the
# operator's pool/daemon are never touched: treehouse, gh-axi, gh, no-mistakes.
set -u
REPO=$PWD
TOP=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-td.XXXXXX")" && pwd -P)  # lab homes must be canonical paths
CFG="$TOP/gitconfig"
printf '[user]\n\tname = lab\n\temail = lab@example.invalid\n[init]\n\tdefaultBranch = main\n' > "$CFG"
export GIT_CONFIG_GLOBAL="$CFG" GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX
FAILS=0; N=0
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$TOP"; }
trap cleanup EXIT

mkdir -p "$TOP/stub" "$TOP/served" "$TOP/base"
cat > "$TOP/stub/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/treehouse.log"
exit 0
SH
cat > "$TOP/stub/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
cp "$TOP/stub/gh-axi" "$TOP/stub/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TOP/stub/no-mistakes"
chmod +x "$TOP"/stub/*
PATH="$TOP/stub:$PATH"; export PATH
git -C "$REPO" archive 30d6d15ec07e1efaeb3c795f0a24e817251d0718 bin | tar -x -C "$TOP/base"

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

DPORT=$(free_port)
git daemon --export-all --base-path="$TOP/served" --listen=127.0.0.1 --port="$DPORT" --reuseaddr --enable=receive-pack >/dev/null 2>&1 &
PIDS+=($!)
HOLE=$(free_port); HOLELOG="$TOP/hole.log"
python3 - "$HOLE" "$HOLELOG" <<'PY' &
import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(16)
keep=[]
while True:
    c,_=s.accept(); keep.append(c); open(sys.argv[2],"a").write("connected\n")
PY
PIDS+=($!)
AUTH=$(free_port)
python3 - "$AUTH" <<'PY' >/dev/null 2>&1 &
import http.server,sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(401); self.send_header("WWW-Authenticate",'Basic realm="lab"'); self.send_header("Content-Length","0"); self.end_headers()
http.server.HTTPServer(("127.0.0.1",int(sys.argv[1])),H).serve_forever()
PY
PIDS+=($!)
sleep 1

# new_case <name> <mode>: lab home + served origin + project clone + task worktree + real tmux window
new_case() {
  NAME=$1; MODE=$2
  LAB="$TOP/lab-$NAME"
  "$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
  ORIGIN="$TOP/served/$NAME.git"
  git init -q --bare "$ORIGIN"; git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git clone -q "$ORIGIN" "$TOP/seed-$NAME" 2>/dev/null
  git -C "$TOP/seed-$NAME" commit -q --allow-empty -m baseline
  git -C "$TOP/seed-$NAME" push -q origin main
  rm -rf "$TOP/seed-$NAME"
  P="$LAB/projects/demo"; WT="$LAB/wt"
  git clone -q "git://127.0.0.1:$DPORT/$NAME.git" "$P"
  git -C "$P" config remote.origin.pushurl "$ORIGIN"
  git -C "$P" remote set-head origin main 2>/dev/null
  git -C "$P" worktree add -q -b fm/task-x1 "$WT" main
  git -C "$WT" commit -q --allow-empty -m seed-empty
  echo work > "$WT/feature.txt"; git -C "$WT" add feature.txt; git -C "$WT" commit -q -m "task work"
  touch "$LAB/state/.last-watcher-beat"
  printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$WT" "project=$P" \
    "kind=ship" "mode=$MODE" "spawn_gen=live-$NAME" > "$LAB/state/task-x1.meta"
  TD=$("$REPO/bin/fm-lab-home.sh" tmux-dir "$LAB")
  TMUX_TMPDIR="$TD" tmux new-session -d -s firstmate -n fm-task-x1 'sleep 600' 2>/dev/null
}
# land_elsewhere <branch>: push task commits to origin from a separate clone
land_elsewhere() {
  local o="$TOP/other-$NAME"
  git clone -q "$ORIGIN" "$o"
  git -C "$o" fetch -q "$P" fm/task-x1
  git -C "$o" push -q origin "FETCH_HEAD:refs/heads/$1"
  rm -rf "$o"
  [ -n "$(git -C "$WT" log --oneline HEAD --not --remotes --)" ] || echo "FIXTURE ERROR: refs already show work"
}
# drive [script] [args...]: run teardown, set RC/ELAPSED/OUT
drive() {
  local script=$REPO/bin/fm-teardown.sh start
  if [ "${1:-}" = base ]; then script=$TOP/base/bin/fm-teardown.sh; shift; fi
  start=$(python3 -c 'import time;print(time.time())')
  OUT=$(FM_HOME="$LAB" TMUX_TMPDIR="$TD" "$script" task-x1 "$@" </dev/null 2>&1); RC=$?
  ELAPSED=$(python3 -c "import time;print(round(time.time()-$start,1))")
}
cleanup_case() {
  TMUX_TMPDIR="$TD" tmux kill-server 2>/dev/null
  "$REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  rm -rf "$LAB"
}
check() { # check <desc> <cmd...>
  local d=$1; shift
  if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; FAILS=$((FAILS+1)); fi
}
has() { printf '%s' "$OUT" | grep -qF -- "$1"; }
hasnt() { ! has "$1"; }
ref() { git -C "$P" rev-parse --verify -q "$1" >/dev/null; }
noref() { ! ref "$1"; }
window_gone() { ! TMUX_TMPDIR="$TD" tmux list-windows -a -F '#W' 2>/dev/null | grep -qx fm-task-x1; }
window_alive() { ! window_gone; }
isallowed() { [ "$RC" = 0 ] && [ ! -e "$LAB/state/task-x1.meta" ] && [ -s "$LAB/treehouse.log" ] && hasnt REFUSED; }
isrefused() { [ "$RC" != 0 ] && has REFUSED && [ -d "$WT" ] && [ -e "$LAB/state/task-x1.meta" ] && window_alive; }
show() { echo "  exit=$RC elapsed=${ELAPSED}s"; printf '%s\n' "$OUT" | sed 's/^/  | /' | grep -E 'REFUSED|Could not refresh|error' | sed "s#$TOP#<lab>#g"; }
head_s() { echo; N=$((N+1)); echo "== S$N: $1"; }

head_s "BEFORE the fix (base commit): landed from another clone with stale refs is refused"
new_case s-base local-only; land_elsewhere release; drive base; show
check "base script refuses (reproduces the bug)" isrefused
cleanup_case

for m in local-only direct-PR no-mistakes; do
  head_s "AFTER the fix, mode=$m: landed on non-default branch from another clone, no manual fetch"
  new_case "s-land-$m" "$m"; land_elsewhere release
  check "tracking ref absent beforehand" noref refs/remotes/origin/release
  drive; show
  check "teardown completes, slot returned, record cleared" isallowed
  check "endpoint tmux window closed" window_gone
  cleanup_case
done

head_s "Remote unreachable (path gone): refuses and names the remote"
new_case s-dead local-only; land_elsewhere release
git -C "$P" remote set-url origin "$TOP/missing.git"; drive; show
check "refused, nothing destroyed" isrefused
check "names origin" has "Could not refresh remote: origin"
cleanup_case

head_s "Same failure in direct-PR mode names the remote"
new_case s-dead-pr direct-PR; land_elsewhere release
git -C "$P" remote set-url origin "$TOP/missing.git"; drive; show
check "refused, nothing destroyed" isrefused
check "names origin" has "Could not refresh remote: origin"
cleanup_case

head_s "Hung remote (real TCP black hole): cut at 30s, refuses, leaves no process"
new_case s-hang local-only; land_elsewhere release; : > "$HOLELOG"
git -C "$P" remote set-url origin "git://127.0.0.1:$HOLE/x.git"; drive; show
check "fetch really reached the hung remote" test -s "$HOLELOG"
check "refused, nothing destroyed" isrefused
check "names origin" has "Could not refresh remote: origin"
check "elapsed is about the 30s bound (29-45s)" python3 -c "import sys;sys.exit(0 if 29<=$ELAPSED<=45 else 1)"
sleep 1
check "no surviving git process for that remote" sh -c "! pgrep -f 'git.*127.0.0.1:$HOLE' >/dev/null"
cleanup_case

head_s "Password-protected remote under a real terminal: no prompt, refuses fast"
new_case s-auth local-only; land_elsewhere release
git -C "$P" remote set-url origin "http://127.0.0.1:$AUTH/x.git"
start=$(python3 -c 'import time;print(time.time())')
OUT=$(FM_HOME="$LAB" TMUX_TMPDIR="$TD" python3 - "$REPO/bin/fm-teardown.sh" <<'PY'
import os,pty,select,struct,fcntl,termios,time,signal,sys
pid,fd=pty.fork()
if pid==0:
    os.execv(sys.argv[1],[sys.argv[1],"task-x1"])
fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack("HHHH",40,120,0,0))
buf=b"";end=time.time()+25
while time.time()<end:
    r,_,_=select.select([fd],[],[],0.5)
    if r:
        try: d=os.read(fd,4096)
        except OSError: break
        if not d: break
        buf+=d
    else:
        p,_=os.waitpid(pid,os.WNOHANG)
        if p: pid=0; break
if pid:
    try:
        p,_=os.waitpid(pid,os.WNOHANG)
        if p==0 and time.time()>=end:
            os.kill(pid,signal.SIGKILL); buf+=b"\nHUNG-WAITING-FOR-INPUT\n"
    except ChildProcessError: pass
sys.stdout.write(buf.decode(errors="replace"))
PY
); RC=1
ELAPSED=$(python3 -c "import time;print(round(time.time()-$start,1))"); show
check "did not wait for a password" hasnt HUNG-WAITING-FOR-INPUT
check "no password prompt shown" hasnt "Username for"
check "refused and names origin" has "Could not refresh remote: origin"
check "work kept" test -d "$WT"
cleanup_case

head_s "One remote dead, work proven on the other: teardown completes"
new_case s-mixed-ok local-only; land_elsewhere release
git init -q --bare "$TOP/deadfork.git"; git -C "$P" remote add fork "$TOP/deadfork-missing.git"; drive; show
check "completes" isallowed
cleanup_case

head_s "Work nowhere, fork dead, origin live: refuses naming only the fork"
new_case s-mixed-no local-only
git -C "$P" remote add fork "$TOP/deadfork-missing.git"; drive; show
check "refused, nothing destroyed" isrefused
check "names fork" has "Could not refresh remote: fork"
check "does not blame origin" hasnt "fork, origin"
cleanup_case

head_s "Both remotes dead: refusal names both"
new_case s-both local-only
git -C "$P" remote add fork "$TOP/deadfork-missing.git"; git -C "$P" remote set-url origin "$TOP/missing.git"; drive; show
check "names both" has "Could not refresh remote: fork, origin"
check "refused" isrefused
cleanup_case

head_s "Refresh succeeds but commits are on no remote: still refuses, reports no failure"
new_case s-unlanded local-only
drive; show
check "refused, nothing destroyed" isrefused
check "no refresh-failure note" hasnt "Could not refresh"
cleanup_case

head_s "Landed commits plus uncommitted file: refuses, no network, file kept"
new_case s-dirty local-only; land_elsewhere release; echo unsaved > "$WT/unsaved.txt"; drive; show
check "refused, nothing destroyed" isrefused
check "uncommitted file kept" test -f "$WT/unsaved.txt"
check "no refresh ran" noref refs/remotes/origin/release
cleanup_case

head_s "Remote dropped a branch, fetch.prune=true: refresh keeps the tracking ref"
new_case s-prune local-only
git -C "$P" config fetch.prune true
git -C "$ORIGIN" update-ref refs/heads/dropped refs/heads/main
git -C "$P" fetch -q origin
git -C "$ORIGIN" update-ref -d refs/heads/dropped
drive; show
check "refused (work not landed)" isrefused
check "dropped branch ref still there" ref refs/remotes/origin/dropped
cleanup_case

head_s "Commits held only by the no-mistakes gate remote: refuses, gate never fetched"
new_case s-gate local-only
git init -q --bare "$TOP/gate-$$.git"
git -C "$P" remote add no-mistakes "$TOP/gate-$$.git"
git -C "$WT" push -q "$TOP/gate-$$.git" fm/task-x1
drive; show
check "refused, nothing destroyed" isrefused
check "no gate tracking ref created" noref refs/remotes/no-mistakes/fm/task-x1
cleanup_case

head_s "No remote at all: refuses without error noise"
new_case s-noremote local-only
git -C "$P" remote remove origin; drive; show
check "refused, nothing destroyed" isrefused
check "no refresh-failure note" hasnt "Could not refresh"
cleanup_case

head_s "Work the refs already show: teardown makes no refresh (remote would hang it)"
new_case s-reach local-only; : > "$HOLELOG"
git -C "$WT" push -q "$ORIGIN" fm/task-x1
git -C "$P" fetch -q origin
git -C "$P" remote set-url origin "git://127.0.0.1:$HOLE/x.git"; drive; show
check "completes" isallowed
check "hung remote never contacted by the landed-work check" test ! -s "$HOLELOG"
cleanup_case

head_s "--force with a hung remote still discards as the captain authorized"
new_case s-force local-only; : > "$HOLELOG"
git -C "$P" remote set-url origin "git://127.0.0.1:$HOLE/x.git"; drive --force; show
check "completes" test "$RC" = 0
echo "  note: black-hole connections during --force: $(wc -l < "$HOLELOG" | tr -d ' ')"
cleanup_case

echo; echo "SCENARIOS=$N CHECK_FAILURES=$FAILS"
exit "$FAILS"
