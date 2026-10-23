# Fakes for the watch tests. Source this file after `d` is set to an empty temp folder.
# It creates a fake glab, herdr, pmset, and nc in $d/bin, the fixtures folder $d/mock, and the git
# repo $d/app with a GitLab origin, and exports the variables for them.

# Fake glab: `api <path>` prints $MOCK_DIR/<fixture>.json. With --paginate, the other pages
# <fixture>_p<N>.json follow. If the file does not exist, it prints {} for an MR,
# {"approved_by": []} for approvals, and [] for a list.
# MOCK_FAIL is a path pattern: a matching call writes $MOCK_FAIL_MSG on stderr and fails. With
# MOCK_FAIL_TIMES=N, only the first N matching calls fail. $MOCK_DIR/fails counts them.
# MOCK_NOAUTH=1 makes `auth status` fail.
mkdir -p "$d/bin" "$d/mock"
cat >"$d/bin/glab" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_LOG"
if [ "$1" = auth ]; then [ -z "${MOCK_NOAUTH:-}" ]; exit; fi
[ "$1" = api ] || { echo "unexpected glab call: $*" >&2; exit 2; }
if [ -n "${MOCK_FAIL:-}" ]; then
  case "$2" in $MOCK_FAIL)
    n=$(($(cat "$MOCK_DIR/fails" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$MOCK_DIR/fails"
    if [ "$n" -le "${MOCK_FAIL_TIMES:-$n}" ]; then echo "$MOCK_FAIL_MSG" >&2; exit 1; fi ;;
  esac
fi
if [ "$2" = graphql ]; then
  iid=
  for a; do case $a in iid=*) iid=${a#iid=} ;; esac; done
  f="$MOCK_DIR/gql_$iid.json"
  if [ ! -f "$f" ]; then
    echo '{"data": {"currentUser": {"username": "me"}, "project": {"mergeRequest": null}}}'; exit
  fi
  cat "$f"
  # Like glab: a response with errors also goes to stderr, and the exit code is 1.
  msg=$(jq -r '[.errors[]?.message] | join("; ")' "$f")
  if [ -n "$msg" ]; then echo "glab: $msg" >&2; exit 1; fi
  exit
fi
iid=$(echo "$2" | cut -d/ -f4 | cut -d'?' -f1)
case "$2" in
  user) f=user ;;
  projects/group%2Fsub%2Fapp) f=project ;;
  todos\?*) f=todos ;;
  users/1/events\?*) f=events ;;
  projects/7/merge_requests\?author_username=*) echo "own MRs call: $2" >&2; exit 2 ;;
  projects/7/merge_requests\?state=opened\&*) f=opened ;;
  projects/7/merge_requests\?*) f=commented ;;
  projects/*/merge_requests/*/notes/*/award_emoji\?*) f=award_note_$(echo "$2" | cut -d/ -f6) ;;
  projects/*/merge_requests/*/award_emoji\?*) f=award_mr_$iid ;;
  projects/group%2Fsub%2Fapp/merge_requests/*/discussions\?*) f=discussions_$iid ;;
  projects/group%2Fsub%2Fapp/merge_requests/*) f=mr_$iid ;;
  projects/7/merge_requests/*/approvals) f=approvals_$iid ;;
  projects/7/merge_requests/*/notes\?*) f=notes_$iid ;;
  projects/7/pipelines\?*) f=pipelines ;;
  projects/7/merge_requests/*) f=mr_$iid ;;
  *) echo "unexpected glab api path: $2" >&2; exit 2 ;;
esac
if [ -f "$MOCK_DIR/$f.json" ]; then
  cat "$MOCK_DIR/$f.json"
  case " $* " in *" --paginate "*) cat "$MOCK_DIR/${f}_p"[0-9].json 2>/dev/null || true ;; esac
  exit
fi
case "$f" in
  mr_*) echo '{}' ;;
  approvals_*) echo '{"approved_by": []}' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$d/bin/glab"
# Fake herdr: appends its arguments to $d/herdr.log. If $d/herdr.fail exists, it exits 1.
# The tests must never reach the real herdr.
unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_SOCKET_PATH
cat >"$d/bin/herdr" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$d/herdr.log"
if [ -e "$d/herdr.fail" ]; then echo "herdr: server_not_running" >&2; exit 1; fi
EOF
chmod +x "$d/bin/herdr"
# Fake pmset and nc: full wake, and the network is up.
printf '#!/bin/sh\necho "Current System Capabilities are: CPU Graphics Audio Network"\n' \
  >"$d/bin/pmset"
printf '#!/bin/sh\nexit 0\n' >"$d/bin/nc"
chmod +x "$d/bin/pmset" "$d/bin/nc"
export PATH="$d/bin:$PATH" MOCK_LOG="$d/calls.log" MOCK_DIR="$d/mock" XDG_STATE_HOME="$d/state"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$d/gitconfig"
git config --global init.defaultBranch main

git init -q "$d/app"
git -C "$d/app" remote add origin https://gitlab.example.com/group/sub/app.git
echo '{"id": 1, "username": "me"}' >"$d/mock/user.json"
echo '{"id": 7, "default_branch": "dev/x"}' >"$d/mock/project.json"

fixture() { printf '%s\n' "$2" >"$d/mock/$1.json"; }
