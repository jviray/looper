#!/usr/bin/env bash

# nike.sh — just do it. Linear-driven AFK loop (v2 tracer: ONE issue, no parallelism).
#
# Run from inside the target repo (e.g. giftwiz). Pulls the highest-priority
# ready issue from Linear, claims it, runs a Claude Code agent in a docker
# container against a dedicated worktree/branch, lands the result (--merge or
# --pr), and reports everything back to Linear. The agent never sees Linear.
#
# Requires in .env next to this script: LINEAR_API_KEY, CLAUDE_CODE_OAUTH_TOKEN
# Requires on host: docker (nike-agent image built from ./Dockerfile), git, jq, curl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- args ---
MODE="merge" # merge | pr
MAX_TURNS=50
IMAGE="nike-agent"
while [ $# -gt 0 ]; do
  case "$1" in
    --merge) MODE="merge" ;;
    --pr) MODE="pr" ;;
    --max-turns) MAX_TURNS="$2"; shift ;;
    --image) IMAGE="$2"; shift ;;
    -h|--help)
      sed -n '3,11p' "$0"; exit 0 ;;
    *) echo "nike: unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# --- env ---
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a; source "$SCRIPT_DIR/.env"; set +a
fi
: "${LINEAR_API_KEY:?nike: LINEAR_API_KEY missing (looper/.env)}"
: "${CLAUDE_CODE_OAUTH_TOKEN:?nike: CLAUDE_CODE_OAUTH_TOKEN missing (looper/.env)}"

# --- Linear constants (team JFV; ids cached per JFV-24) ---
TEAM_ID="f76318db-288f-4436-bf57-3be9f8265835"
ME="07cd1852-11c8-48a1-be22-91e7cd8e8d07"
STATE_TODO="06e49894-e552-4431-802b-9d7d81daaded"
STATE_IN_PROGRESS="6441850a-228f-40a7-a2fb-657ed3be0fb9"
STATE_IN_REVIEW="1dd1cc35-208b-458c-850f-b9a06150e73f"
STATE_DONE="a6ad857c-055a-402d-b2a6-5638de12cfd3"

# --- target repo ---
REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "nike: run me from inside the target repo" >&2; exit 2; }
REPO_NAME="$(basename "$REPO_DIR")"
BASE_BRANCH="$(git -C "$REPO_DIR" symbolic-ref --short HEAD)"
NIKE_DIR="$(dirname "$REPO_DIR")/.nike/$REPO_NAME"
LOG_DIR="$NIKE_DIR/logs"
mkdir -p "$LOG_DIR"

docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || { echo "nike: image '$IMAGE' not found — docker build -t nike-agent $SCRIPT_DIR" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { echo "nike: $*" >&2; }

# lin <payload-file> <output-file> — POST GraphQL, die on transport/GraphQL errors
lin() {
  curl -s -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$1" > "$2" \
    || { echo "nike: Linear request failed (network)" >&2; exit 1; }
  if jq -e '.errors' "$2" >/dev/null 2>&1; then
    echo "nike: Linear GraphQL error:" >&2; jq -c '.errors' "$2" >&2; exit 1
  fi
}

# move_state <issue-uuid> <state-id> [unassign]
move_state() {
  if [ "${3:-}" = "unassign" ]; then
    jq -n --arg id "$1" --arg state "$2" \
      '{query:"mutation($id: String!, $state: String!) { issueUpdate(id: $id, input: { stateId: $state, assigneeId: null }) { success } }",
        variables:{id:$id,state:$state}}' > "$TMP/move.json"
  else
    jq -n --arg id "$1" --arg state "$2" \
      '{query:"mutation($id: String!, $state: String!) { issueUpdate(id: $id, input: { stateId: $state }) { success } }",
        variables:{id:$id,state:$state}}' > "$TMP/move.json"
  fi
  lin "$TMP/move.json" "$TMP/move_out.json"
  jq -e '.data.issueUpdate.success' "$TMP/move_out.json" >/dev/null
}

# comment_issue <issue-uuid> <markdown-file>
comment_issue() {
  jq -n --arg id "$1" --rawfile body "$2" \
    '{query:"mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }",
      variables:{input:{issueId:$id,body:$body}}}' > "$TMP/comment.json"
  lin "$TMP/comment.json" "$TMP/comment_out.json"
  jq -e '.data.commentCreate.success' "$TMP/comment_out.json" >/dev/null
}

# ---------------------------------------------------------------- frontier ---
log "querying frontier (team JFV, Todo + 'Ready for Agent' + unassigned + unblocked)"
jq -n --arg teamId "$TEAM_ID" \
  '{query:"query($teamId: ID!) { issues(first: 250, filter: { team: { id: { eq: $teamId } }, state: { type: { eq: \"unstarted\" } }, labels: { name: { eq: \"Ready for Agent\" } }, assignee: { null: true } }) { nodes { id identifier title priority inverseRelations { nodes { type issue { identifier state { type } } } } } } }",
    variables:{teamId:$teamId}}' > "$TMP/frontier.json"
lin "$TMP/frontier.json" "$TMP/frontier_out.json"

# every blocker completed/canceled; priority order (0 = none sorts last)
PICK="$(jq -r '.data.issues.nodes
  | map(select([.inverseRelations.nodes[] | select(.type == "blocks") | .issue.state.type]
               | all(. == "completed" or . == "canceled")))
  | sort_by(if .priority == 0 then 5 else .priority end)
  | .[0] // empty
  | "\(.id)\t\(.identifier)\t\(.title)"' "$TMP/frontier_out.json")"

if [ -z "$PICK" ]; then
  log "frontier is empty — nothing to do"
  exit 0
fi
UUID="$(printf '%s' "$PICK" | cut -f1)"
IDENT="$(printf '%s' "$PICK" | cut -f2)"
TITLE="$(printf '%s' "$PICK" | cut -f3-)"
BRANCH="agent/$IDENT"
WT="$NIKE_DIR/$IDENT"
log "picked $IDENT: $TITLE"

# ------------------------------------------------------------------- claim ---
jq -n --arg id "$UUID" --arg me "$ME" --arg state "$STATE_IN_PROGRESS" \
  '{query:"mutation($id: String!, $me: String!, $state: String!) { issueUpdate(id: $id, input: { assigneeId: $me, stateId: $state }) { success issue { assignee { id } } } }",
    variables:{id:$id,me:$me,state:$state}}' > "$TMP/claim.json"
lin "$TMP/claim.json" "$TMP/claim_out.json"
CLAIMED_BY="$(jq -r '.data.issueUpdate.issue.assignee.id // ""' "$TMP/claim_out.json")"
[ "$CLAIMED_BY" = "$ME" ] || { log "claim on $IDENT did not stick (got: $CLAIMED_BY)"; exit 1; }
log "claimed $IDENT (In Progress)"

# fail_back <one-line reason> [detail-file] — comment, return to Todo unassigned
fail_back() {
  { echo "**nike.sh: returning to frontier** — $1"
    if [ -n "${2:-}" ] && [ -s "${2:-}" ]; then echo; echo "---"; echo; cat "$2"; fi
  } > "$TMP/fail.md"
  comment_issue "$UUID" "$TMP/fail.md"
  move_state "$UUID" "$STATE_TODO" unassign
  log "$IDENT returned to Todo: $1"
}

# ------------------------------------------------------- fetch + render issue ---
jq -n --arg id "$IDENT" \
  '{query:"query($id: String!) { issue(id: $id) { identifier title description url state { name } labels { nodes { name } } comments(first: 50) { nodes { createdAt body user { displayName } } } } }",
    variables:{id:$id}}' > "$TMP/fetch.json"
lin "$TMP/fetch.json" "$TMP/issue.json"
jq -r '.data.issue
  | "# \(.identifier): \(.title)\n"
    + (if (.labels.nodes | length) > 0 then "Labels: \([.labels.nodes[].name] | join(", "))\n" else "" end)
    + "\n## Description\n\n\(.description // "_(no description)_")\n"
    + (if (.comments.nodes | length) > 0
       then "\n## Comments\n\n" + ([.comments.nodes | sort_by(.createdAt)[] | "### \(.user.displayName // "unknown") (\(.createdAt))\n\n\(.body)\n"] | join("\n"))
       else "" end)' "$TMP/issue.json" > "$TMP/issue.md"

# ---------------------------------------------------------------- worktree ---
if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  fail_back "leftover branch \`$BRANCH\` exists on the host — clean it up and retry"
  exit 1
fi
if [ -e "$WT" ]; then
  fail_back "leftover worktree at \`$WT\` — clean it up and retry"
  exit 1
fi
BASE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" worktree add -b "$BRANCH" "$WT" >/dev/null
log "worktree $WT (branch $BRANCH from $BASE_BRANCH@${BASE_SHA:0:7})"

# ------------------------------------------------------------------ prompt ---
git -C "$REPO_DIR" log --oneline -10 > "$TMP/commits.txt"
jq -rn --rawfile tpl "$SCRIPT_DIR/prompt.md" \
       --rawfile issue "$TMP/issue.md" \
       --rawfile commits "$TMP/commits.txt" \
       --arg branch "$BRANCH" \
  '$tpl | split("{{ISSUE}}") | join($issue)
        | split("{{COMMITS}}") | join($commits)
        | split("{{BRANCH}}") | join($branch)' > "$TMP/prompt.txt"

# ------------------------------------------------------------------- agent ---
STREAM_LOG="$LOG_DIR/$IDENT.jsonl"
ERR_LOG="$LOG_DIR/$IDENT.stderr.log"
log "launching agent (image $IMAGE, max $MAX_TURNS turns) — stream: $STREAM_LOG"

set +e
docker run --rm \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -v "$WT:$WT" \
  -v "$REPO_DIR/.git:$REPO_DIR/.git" \
  -v "$HOME/.claude/skills:/home/node/.claude/skills:ro" \
  -w "$WT" \
  "$IMAGE" \
  claude --dangerously-skip-permissions -p --output-format stream-json --verbose \
    --max-turns "$MAX_TURNS" "$(cat "$TMP/prompt.txt")" \
  2> "$ERR_LOG" \
  | tee "$STREAM_LOG" \
  | jq -r --unbuffered 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | "  agent> " + (.text | split("\n")[0])' 2>/dev/null
DOCKER_EXIT="${PIPESTATUS[0]}"
set -e
log "agent exited ($DOCKER_EXIT)"

# ------------------------------------------------------------------ verdict ---
jq -cs '[.[] | select(.type == "result")] | last // empty' "$STREAM_LOG" > "$TMP/result.json" 2>/dev/null || true
NCOMMITS="$(git -C "$WT" rev-list --count "$BASE_SHA"..HEAD)"

if [ ! -s "$TMP/result.json" ]; then
  head -c 2000 "$ERR_LOG" > "$TMP/err_excerpt.txt" || true
  fail_back "agent produced no result event (docker exit $DOCKER_EXIT)" "$TMP/err_excerpt.txt"
  [ "$NCOMMITS" -gt 0 ] || { git -C "$REPO_DIR" worktree remove --force "$WT"; git -C "$REPO_DIR" branch -D "$BRANCH" >/dev/null; }
  exit 1
fi

SUBTYPE="$(jq -r '.subtype // "unknown"' "$TMP/result.json")"
jq -r '.result // ""' "$TMP/result.json" > "$TMP/summary.md"

# rate limit → graceful stop (JFV-25 guardrail); issue back to frontier untouched
if grep -qiE 'usage limit|rate.?limit|limit (will )?reset|out of extra usage' "$TMP/summary.md" "$ERR_LOG"; then
  fail_back "Claude usage limit hit — loop stopped gracefully; run again after the limit resets"
  [ "$NCOMMITS" -gt 0 ] || { git -C "$REPO_DIR" worktree remove --force "$WT"; git -C "$REPO_DIR" branch -D "$BRANCH" >/dev/null; }
  log "rate limited — exiting"
  exit 0
fi

PROMISE="$(grep -oE '<promise>[^<]*</promise>' "$TMP/summary.md" | tail -1 || true)"
log "result: subtype=$SUBTYPE commits=$NCOMMITS promise=${PROMISE:-none}"

case "$PROMISE" in
  "<promise>DONE</promise>")
    if [ "$NCOMMITS" -eq 0 ]; then
      fail_back "agent promised DONE but made no commits" "$TMP/summary.md"
      git -C "$REPO_DIR" worktree remove --force "$WT"
      git -C "$REPO_DIR" branch -D "$BRANCH" >/dev/null
      exit 1
    fi
    ;;
  "<promise>BLOCKED:"*)
    fail_back "agent reported BLOCKED (worktree kept at \`$WT\`)" "$TMP/summary.md"
    exit 1
    ;;
  *)
    fail_back "agent run ended without a promise (subtype: $SUBTYPE; worktree kept if it has commits)" "$TMP/summary.md"
    [ "$NCOMMITS" -gt 0 ] || { git -C "$REPO_DIR" worktree remove --force "$WT"; git -C "$REPO_DIR" branch -D "$BRANCH" >/dev/null; }
    exit 1
    ;;
esac

# -------------------------------------------------------------------- land ---
{ echo "**nike.sh: agent finished** ($NCOMMITS commit(s) on \`$BRANCH\`). Agent summary:"
  echo; echo "---"; echo; cat "$TMP/summary.md"
} > "$TMP/relay.md"
comment_issue "$UUID" "$TMP/relay.md"

if [ "$MODE" = "pr" ]; then
  log "pushing $BRANCH and opening PR"
  git -C "$REPO_DIR" push -u origin "$BRANCH" >/dev/null
  PR_URL="$(cd "$REPO_DIR" && gh pr create --head "$BRANCH" --base "$BASE_BRANCH" \
    --title "$IDENT: $TITLE" --body-file "$TMP/summary.md")"
  printf '**nike.sh: PR opened** — %s\n' "$PR_URL" > "$TMP/pr.md"
  comment_issue "$UUID" "$TMP/pr.md"
  move_state "$UUID" "$STATE_IN_REVIEW"
  git -C "$REPO_DIR" worktree remove --force "$WT"
  log "$IDENT → In Review ($PR_URL); branch kept until PR merges"
  exit 0
fi

log "merging $BRANCH into $BASE_BRANCH"
if git -C "$REPO_DIR" merge --no-ff "$BRANCH" -m "nike: land $IDENT — $TITLE" >/dev/null 2>&1; then
  move_state "$UUID" "$STATE_DONE"
  git -C "$REPO_DIR" worktree remove --force "$WT"
  git -C "$REPO_DIR" branch -d "$BRANCH" >/dev/null
  log "$IDENT merged and Done — worktree/branch cleaned up"
else
  git -C "$REPO_DIR" merge --abort 2>/dev/null || true
  { echo "**nike.sh: merge conflict** landing \`$BRANCH\` into \`$BASE_BRANCH\`."
    echo "Branch and worktree kept for manual resolution: \`$WT\`"
  } > "$TMP/conflict.md"
  comment_issue "$UUID" "$TMP/conflict.md"
  move_state "$UUID" "$STATE_IN_REVIEW"
  log "$IDENT merge conflict → In Review; worktree kept at $WT"
  exit 1
fi
