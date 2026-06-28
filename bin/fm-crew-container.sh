#!/usr/bin/env bash
# Launch a claude crewmate INSIDE a container, with only the worktree, the
# firstmate communication dir (state/), the task's data dir (brief + report),
# and the project's shared git object store mounted in. This bounds an
# autonomous (--dangerously-skip-permissions) crewmate's blast radius to those
# mounts instead of the whole host.
#
# Usage (typed into the crewmate's tmux pane by fm-spawn.sh's launch template):
#   fm-crew-container.sh <worktree> <brief> <turnend>
#
# Runs ATTACHED (-it) so the pane is a transparent passthrough to the container
# TTY: fm-send.sh's `tmux send-keys` (steer/interrupt) and fm-watch.sh's
# `tmux capture-pane` (busy-signature, trust dialog, ghost-text) keep working
# UNCHANGED. claude is the container's foreground process, so when it exits
# (e.g. firstmate sends /exit) the container exits and the pane returns.
#
# Tunables (env):
#   FM_CREW_IMAGE  container image (default firstmate-crew:latest)
#   FM_CREW_NET    docker network (default bridge); set to an egress-allowlisted
#                  network for tighter exfiltration control
set -eu

WT=$1       # treehouse worktree: the crewmate's working copy
BRIEF=$2    # data/<id>/brief.md: the assignment, read inside the container
TURNEND=$3  # state/<id>.turn-ended: touched by the in-worktree Stop hook

IMAGE=${FM_CREW_IMAGE:-firstmate-crew:latest}
NET=${FM_CREW_NET:-bridge}

# A treehouse worktree is NOT self-contained: its .git is a *file* that points
# (by absolute path) at the project's shared object store + worktree metadata.
# Mount that common dir at the SAME absolute path so every internal git pointer
# resolves inside the container and commit/branch/push work.
GIT_COMMON=$(cd "$WT" && git rev-parse --git-common-dir)
GIT_COMMON=$(cd "$GIT_COMMON" && pwd -P)

WT_REAL=$(cd "$WT" && pwd -P)
# state/ holds the turn-end signal the watcher polls; mount at the same path so
# the Stop hook's `touch '<TURNEND>'` (an absolute host path) lands host-visibly.
STATE=$(cd "$(dirname "$TURNEND")" && pwd -P)
# data/<id> holds the brief (read) and, for scouts, report.md (written) -> rw.
TASK_DIR=$(cd "$(dirname "$BRIEF")" && pwd -P)
# Read the brief inside the container via its RESOLVED path: TASK_DIR is mounted
# at its pwd -P path, so FM_BRIEF must use the same (on macOS /tmp -> /private/tmp,
# so the raw arg path would not exist at the mount point).
BRIEF_REAL="$TASK_DIR/$(basename "$BRIEF")"

# Credentials: hand the container the minimum it needs. git identity + gh auth
# are only needed by ship/direct-PR tasks (push + PR); a scout needs neither.
# Container HOME (the non-root "node" user; see docker/crew/Dockerfile).
CHOME=/home/node
CRED=()
[ -f "$HOME/.gitconfig" ] && CRED+=(-v "$HOME/.gitconfig:$CHOME/.gitconfig:ro")
[ -d "$HOME/.config/gh" ] && CRED+=(-v "$HOME/.config/gh:$CHOME/.config/gh:ro")
[ -n "${GH_TOKEN:-}" ]    && CRED+=(-e "GH_TOKEN=$GH_TOKEN")

# Per-spawn temp home-config, shredded on exit. It always carries a minimal
# ~/.claude.json marking onboarding complete, so the interactive TUI skips the
# first-run theme/login wizard and actually uses the mounted token instead of
# prompting for a fresh OAuth login (verified: without this the TUI re-logs in).
CRED_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-crew-cred.XXXXXX")
cleanup() { rm -rf "$CRED_TMP"; }
trap cleanup EXIT INT TERM
# Mark onboarding complete AND pre-trust the worktree path (projects[<path>]
# .hasTrustDialogAccepted), so the only first-run gate left is the Bypass
# Permissions warning, which firstmate accepts at spawn (see harness-adapters).
if command -v jq >/dev/null 2>&1; then
  jq -n --arg wt "$WT_REAL" \
    '{hasCompletedOnboarding:true,lastOnboardingVersion:"2.0.19",numStartups:1,theme:"dark",projects:{($wt):{hasTrustDialogAccepted:true}}}' \
    > "$CRED_TMP/.claude.json"
else
  printf '%s\n' '{"hasCompletedOnboarding":true,"lastOnboardingVersion":"2.0.19","numStartups":1,"theme":"dark"}' \
    > "$CRED_TMP/.claude.json"
fi
CRED+=(-v "$CRED_TMP/.claude.json:$CHOME/.claude.json")

# Claude auth, in priority order. The logged-in session (file/Keychain) is
# preferred over a bare ANTHROPIC_API_KEY - this matches claude's own
# "No (recommended)" stance on stray env keys, and keeps an incidental
# ANTHROPIC_API_KEY in the firstmate env from hijacking a subscription login:
#   1. ~/.claude/.credentials.json   -> mount it (the Linux / file-based case).
#   2. macOS Keychain                -> extract the OAuth token into CRED_TMP and
#      mount it as the container's ~/.claude. The temp dir is shredded on exit.
#   3. ANTHROPIC_API_KEY in the env  -> last-resort fallback (claude will prompt
#      to confirm a stray key unless customApiKeyResponses is pre-approved).
# The temp dir holds a live token the (autonomous) container can read; that is
# the accepted trade-off of reusing the subscription login instead of a scoped
# API key. Mounted rw so claude can write a refreshed token during a long task.
if [ -f "$HOME/.claude/.credentials.json" ]; then
  CRED+=(-v "$HOME/.claude:$CHOME/.claude")
elif [ "$(uname)" = Darwin ] \
     && security find-generic-password -s "Claude Code-credentials" -w >/dev/null 2>&1; then
  mkdir -p "$CRED_TMP/.claude"
  security find-generic-password -s "Claude Code-credentials" -w \
    > "$CRED_TMP/.claude/.credentials.json"
  chmod 600 "$CRED_TMP/.claude/.credentials.json"
  CRED+=(-v "$CRED_TMP/.claude:$CHOME/.claude")
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  CRED+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
else
  echo "fm-crew-container: no Claude credentials found (log claude in on the" \
       "host, or set ANTHROPIC_API_KEY)" >&2
  exit 1
fi

# -it: attach the container TTY to this pane (the whole point - keeps tmux
#      supervision working). --rm: a dead pane leaves no orphan container.
# FM_BRIEF + cat-inside-container: the brief is read in the container shell, so
#      its (possibly large, quote-heavy) content never has to be escaped through
#      send-keys onto the host command line.
# Run (not exec) so the EXIT trap can shred the extracted credential after the
# crewmate exits; when claude exits, docker exits, and the pane returns.
docker run --rm -it \
  --network "$NET" \
  -w "$WT_REAL" \
  -e CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
  -e FM_BRIEF="$BRIEF_REAL" \
  -v "$WT_REAL:$WT_REAL" \
  -v "$GIT_COMMON:$GIT_COMMON" \
  -v "$STATE:$STATE" \
  -v "$TASK_DIR:$TASK_DIR" \
  "${CRED[@]}" \
  "$IMAGE" \
  bash -lc 'exec claude --dangerously-skip-permissions "$(cat "$FM_BRIEF")"'
