#!/usr/bin/env bash

# nike.sh — just do it. Linear-driven AFK loop (v2: parallel waves).
#
# Run from inside the target repo. Repeatedly pulls the highest-
# priority ready issues from Linear (first N by priority, --max N, default 2),
# claims each, runs a wave of Claude Code agents in docker containers (one
# worktree + agent/<ISSUE-ID> branch each), lands the survivors sequentially
# (--merge or --pr), and reports everything back to Linear. One failed agent
# never cancels the wave. Loops until the frontier is empty or a rate limit
# fires. The agents never see Linear.
#
# Requires in .env next to this script: LINEAR_API_KEY, CLAUDE_CODE_OAUTH_TOKEN
# Requires on host: docker (nike-agent image built from ./Dockerfile), git, jq, curl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- args ---
MODE="merge" # merge | pr
MAX_TURNS=50
MAX_PARALLEL=2
IMAGE="nike-agent"
while [ $# -gt 0 ]; do
  case "$1" in
    --merge) MODE="merge" ;;
    --pr) MODE="pr" ;;
    --max) MAX_PARALLEL="$2"; shift ;;
    --max-turns) MAX_TURNS="$2"; shift ;;
    --image) IMAGE="$2"; shift ;;
    -h|--help)
      sed -n '3,15p' "$0"; exit 0 ;;
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

# --- Linear constants (team-specific ids; see .env / README Retargeting) ---
: "${LINEAR_TEAM_ID:?nike: LINEAR_TEAM_ID missing (looper/.env)}"
: "${LINEAR_ME:?nike: LINEAR_ME missing (looper/.env)}"
: "${LINEAR_STATE_TODO:?nike: LINEAR_STATE_TODO missing (looper/.env)}"
: "${LINEAR_STATE_IN_PROGRESS:?nike: LINEAR_STATE_IN_PROGRESS missing (looper/.env)}"
: "${LINEAR_STATE_IN_REVIEW:?nike: LINEAR_STATE_IN_REVIEW missing (looper/.env)}"
: "${LINEAR_STATE_DONE:?nike: LINEAR_STATE_DONE missing (looper/.env)}"
TEAM_ID="$LINEAR_TEAM_ID"
ME="$LINEAR_ME"
STATE_TODO="$LINEAR_STATE_TODO"
STATE_IN_PROGRESS="$LINEAR_STATE_IN_PROGRESS"
STATE_IN_REVIEW="$LINEAR_STATE_IN_REVIEW"
STATE_DONE="$LINEAR_STATE_DONE"

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
# temp files are per-call (mktemp) — safe from parallel agent jobs
move_state() {
  local req; req="$(mktemp "$TMP/move.XXXXXX")"
  if [ "${3:-}" = "unassign" ]; then
    jq -n --arg id "$1" --arg state "$2" \
      '{query:"mutation($id: String!, $state: String!) { issueUpdate(id: $id, input: { stateId: $state, assigneeId: null }) { success } }",
        variables:{id:$id,state:$state}}' > "$req"
  else
    jq -n --arg id "$1" --arg state "$2" \
      '{query:"mutation($id: String!, $state: String!) { issueUpdate(id: $id, input: { stateId: $state }) { success } }",
        variables:{id:$id,state:$state}}' > "$req"
  fi
  lin "$req" "$req.out"
  jq -e '.data.issueUpdate.success' "$req.out" >/dev/null
}

# comment_issue <issue-uuid> <markdown-file>
comment_issue() {
  local req; req="$(mktemp "$TMP/comment.XXXXXX")"
  jq -n --arg id "$1" --rawfile body "$2" \
    '{query:"mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }",
      variables:{input:{issueId:$id,body:$body}}}' > "$req"
  lin "$req" "$req.out"
  jq -e '.data.commentCreate.success' "$req.out" >/dev/null
}

# fail_back <uuid> <ident> <one-line reason> [detail-file] — comment, return to Todo unassigned
fail_back() {
  local md; md="$(mktemp "$TMP/fail.XXXXXX")"
  { echo "**nike.sh: returning to frontier** — $3"
    if [ -n "${4:-}" ] && [ -s "${4:-}" ]; then echo; echo "---"; echo; cat "$4"; fi
  } > "$md"
  comment_issue "$1" "$md"
  move_state "$1" "$STATE_TODO" unassign
  log "[$2] returned to Todo: $3"
}

# cleanup_wt <wt> <branch> — best-effort; a leftover is caught at next selection
cleanup_wt() {
  git -C "$REPO_DIR" worktree remove --force "$1" 2>/dev/null || true
  git -C "$REPO_DIR" branch -D "$2" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------- agent ---
# run_agent <uuid> <ident> <base-sha> — background job: docker run + verdict.
# Success (ready to land) = touch $TMP/<ident>/land; summary at $TMP/<ident>/summary.md.
# Rate limit = touch $TMP/ratelimited (stops the loop after this wave).
run_agent() {
  local uuid="$1" ident="$2" base_sha="$3"
  local wt="$NIKE_DIR/$ident" branch="agent/$ident" itmp="$TMP/$ident"
  local stream_log="$LOG_DIR/$ident.jsonl" err_log="$LOG_DIR/$ident.stderr.log"

  set +e
  docker run --rm \
    -e CLAUDE_CODE_OAUTH_TOKEN \
    -v "$wt:$wt" \
    -v "$REPO_DIR/.git:$REPO_DIR/.git" \
    -v "$HOME/.claude/skills:/home/node/.claude/skills:ro" \
    -w "$wt" \
    "$IMAGE" \
    claude --dangerously-skip-permissions -p --output-format stream-json --verbose \
      --max-turns "$MAX_TURNS" "$(cat "$itmp/prompt.txt")" \
    2> "$err_log" \
    | tee "$stream_log" \
    | jq -r --unbuffered --arg tag "$ident" \
        'select(.type == "assistant") | .message.content[]? | select(.type == "text") | "  [\($tag)]> " + (.text | split("\n")[0])' 2>/dev/null
  local docker_exit="${PIPESTATUS[0]}"
  set -e
  log "[$ident] agent exited ($docker_exit)"

  # ---- verdict ----
  jq -cs '[.[] | select(.type == "result")] | last // empty' "$stream_log" > "$itmp/result.json" 2>/dev/null || true
  local ncommits
  ncommits="$(git -C "$wt" rev-list --count "$base_sha"..HEAD 2>/dev/null || echo 0)"

  if [ ! -s "$itmp/result.json" ]; then
    head -c 2000 "$err_log" > "$itmp/err_excerpt.txt" || true
    fail_back "$uuid" "$ident" "agent produced no result event (docker exit $docker_exit)" "$itmp/err_excerpt.txt"
    [ "$ncommits" -gt 0 ] || cleanup_wt "$wt" "$branch"
    return 1
  fi

  local subtype
  subtype="$(jq -r '.subtype // "unknown"' "$itmp/result.json")"
  jq -r '.result // ""' "$itmp/result.json" > "$itmp/summary.md"

  # rate limit → graceful stop; issue back to frontier untouched
  if grep -qiE 'usage limit|rate.?limit|limit (will )?reset|out of extra usage' "$itmp/summary.md" "$err_log"; then
    touch "$TMP/ratelimited"
    fail_back "$uuid" "$ident" "Claude usage limit hit — loop stopping gracefully; run again after the limit resets"
    [ "$ncommits" -gt 0 ] || cleanup_wt "$wt" "$branch"
    return 1
  fi

  local promise
  promise="$(grep -oE '<promise>[^<]*</promise>' "$itmp/summary.md" | tail -1 || true)"
  log "[$ident] result: subtype=$subtype commits=$ncommits promise=${promise:-none}"

  case "$promise" in
    "<promise>DONE</promise>")
      if [ "$ncommits" -eq 0 ]; then
        fail_back "$uuid" "$ident" "agent promised DONE but made no commits" "$itmp/summary.md"
        cleanup_wt "$wt" "$branch"
        return 1
      fi
      echo "$ncommits" > "$itmp/ncommits"
      touch "$itmp/land"
      return 0
      ;;
    "<promise>BLOCKED:"*)
      fail_back "$uuid" "$ident" "agent reported BLOCKED (worktree kept at \`$wt\`)" "$itmp/summary.md"
      return 1
      ;;
    *)
      fail_back "$uuid" "$ident" "agent run ended without a promise (subtype: $subtype; worktree kept if it has commits)" "$itmp/summary.md"
      [ "$ncommits" -gt 0 ] || cleanup_wt "$wt" "$branch"
      return 1
      ;;
  esac
}

# -------------------------------------------------------------------- land ---
# land_issue <uuid> <ident> <title> — sequential, after the wave settles
land_issue() {
  local uuid="$1" ident="$2" title="$3"
  local wt="$NIKE_DIR/$ident" branch="agent/$ident" itmp="$TMP/$ident"
  local ncommits; ncommits="$(cat "$itmp/ncommits")"

  { echo "**nike.sh: agent finished** ($ncommits commit(s) on \`$branch\`). Agent summary:"
    echo; echo "---"; echo; cat "$itmp/summary.md"
  } > "$itmp/relay.md"
  comment_issue "$uuid" "$itmp/relay.md"

  if [ "$MODE" = "pr" ]; then
    log "[$ident] pushing $branch and opening PR"
    git -C "$REPO_DIR" push -u origin "$branch" >/dev/null
    local pr_url
    pr_url="$(cd "$REPO_DIR" && gh pr create --head "$branch" --base "$BASE_BRANCH" \
      --title "$ident: $title" --body-file "$itmp/summary.md")"
    printf '**nike.sh: PR opened** — %s\n' "$pr_url" > "$itmp/pr.md"
    comment_issue "$uuid" "$itmp/pr.md"
    move_state "$uuid" "$STATE_IN_REVIEW"
    git -C "$REPO_DIR" worktree remove --force "$wt"
    log "[$ident] → In Review ($pr_url); branch kept until PR merges"
    return 0
  fi

  log "[$ident] merging $branch into $BASE_BRANCH"
  if git -C "$REPO_DIR" merge --no-ff "$branch" -m "nike: land $ident — $title" >/dev/null 2>&1; then
    move_state "$uuid" "$STATE_DONE"
    git -C "$REPO_DIR" worktree remove --force "$wt"
    git -C "$REPO_DIR" branch -d "$branch" >/dev/null
    log "[$ident] merged and Done — worktree/branch cleaned up"
    return 0
  else
    git -C "$REPO_DIR" merge --abort 2>/dev/null || true
    { echo "**nike.sh: merge conflict** landing \`$branch\` into \`$BASE_BRANCH\`."
      echo "Branch and worktree kept for manual resolution: \`$wt\`"
    } > "$itmp/conflict.md"
    comment_issue "$uuid" "$itmp/conflict.md"
    move_state "$uuid" "$STATE_IN_REVIEW"
    log "[$ident] merge conflict → In Review; worktree kept at $wt"
    return 1
  fi
}

# --------------------------------------------------------------- wave loop ---
# ATTEMPTED: idents picked (or skipped as leftovers) this run — excluded from
# later frontier queries so a failed/BLOCKED issue can't ping-pong back into a
# wave and re-fail on its own leftovers forever.
ATTEMPTED=""
WAVE_NUM=0
TOTAL_LANDED=0

while :; do
  WAVE_NUM=$((WAVE_NUM + 1))
  log "wave $WAVE_NUM: querying frontier (Todo + 'Ready for Agent' + unassigned + unblocked)"
  jq -n --arg teamId "$TEAM_ID" \
    '{query:"query($teamId: ID!) { issues(first: 250, filter: { team: { id: { eq: $teamId } }, state: { type: { eq: \"unstarted\" } }, labels: { name: { eq: \"Ready for Agent\" } }, assignee: { null: true } }) { nodes { id identifier title priority inverseRelations { nodes { type issue { identifier state { type } } } } } } }",
      variables:{teamId:$teamId}}' > "$TMP/frontier.json"
  lin "$TMP/frontier.json" "$TMP/frontier_out.json"

  # every blocker completed/canceled; not attempted this run; priority order (0 = none sorts last)
  jq -r --arg skip "$ATTEMPTED" '.data.issues.nodes
    | map(select([.inverseRelations.nodes[] | select(.type == "blocks") | .issue.state.type]
                 | all(. == "completed" or . == "canceled")))
    | map(select(.identifier as $i | ($skip | split(" ") | index($i)) == null))
    | sort_by(if .priority == 0 then 5 else .priority end)
    | .[] | "\(.id)\t\(.identifier)\t\(.title)"' "$TMP/frontier_out.json" > "$TMP/candidates.tsv"

  if [ ! -s "$TMP/candidates.tsv" ]; then
    log "frontier is empty — nothing left to do"
    break
  fi

  # ---- wave setup: pick + claim + worktree + prompt, sequentially ----
  WAVE_UUIDS=()
  WAVE_IDENTS=()
  WAVE_TITLES=()
  WAVE_BASE_SHA="$(git -C "$REPO_DIR" rev-parse HEAD)"

  while IFS="$(printf '\t')" read -r UUID IDENT TITLE; do
    [ "${#WAVE_IDENTS[@]}" -ge "$MAX_PARALLEL" ] && break
    BRANCH="agent/$IDENT"
    WT="$NIKE_DIR/$IDENT"

    # leftover worktree/branch needs a human — skip without Linear spam
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$BRANCH" || [ -e "$WT" ]; then
      log "[$IDENT] skipping: leftover worktree/branch on host — clean up and rerun"
      ATTEMPTED="$ATTEMPTED $IDENT"
      continue
    fi

    # claim (assign + In Progress); not atomic — verify it stuck
    jq -n --arg id "$UUID" --arg me "$ME" --arg state "$STATE_IN_PROGRESS" \
      '{query:"mutation($id: String!, $me: String!, $state: String!) { issueUpdate(id: $id, input: { assigneeId: $me, stateId: $state }) { success issue { assignee { id } } } }",
        variables:{id:$id,me:$me,state:$state}}' > "$TMP/claim.json"
    lin "$TMP/claim.json" "$TMP/claim_out.json"
    CLAIMED_BY="$(jq -r '.data.issueUpdate.issue.assignee.id // ""' "$TMP/claim_out.json")"
    if [ "$CLAIMED_BY" != "$ME" ]; then
      log "[$IDENT] claim did not stick (got: $CLAIMED_BY) — skipping"
      ATTEMPTED="$ATTEMPTED $IDENT"
      continue
    fi

    ITMP="$TMP/$IDENT"
    mkdir -p "$ITMP"

    # fetch + render issue
    jq -n --arg id "$IDENT" \
      '{query:"query($id: String!) { issue(id: $id) { identifier title description url state { name } labels { nodes { name } } comments(first: 50) { nodes { createdAt body user { displayName } } } } }",
        variables:{id:$id}}' > "$ITMP/fetch.json"
    lin "$ITMP/fetch.json" "$ITMP/issue.json"
    jq -r '.data.issue
      | "# \(.identifier): \(.title)\n"
        + (if (.labels.nodes | length) > 0 then "Labels: \([.labels.nodes[].name] | join(", "))\n" else "" end)
        + "\n## Description\n\n\(.description // "_(no description)_")\n"
        + (if (.comments.nodes | length) > 0
           then "\n## Comments\n\n" + ([.comments.nodes | sort_by(.createdAt)[] | "### \(.user.displayName // "unknown") (\(.createdAt))\n\n\(.body)\n"] | join("\n"))
           else "" end)' "$ITMP/issue.json" > "$ITMP/issue.md"

    git -C "$REPO_DIR" worktree add -b "$BRANCH" "$WT" >/dev/null
    log "[$IDENT] claimed; worktree $WT (branch $BRANCH from $BASE_BRANCH@${WAVE_BASE_SHA:0:7})"

    git -C "$REPO_DIR" log --oneline -10 > "$ITMP/commits.txt"
    jq -rn --rawfile tpl "$SCRIPT_DIR/prompt.md" \
           --rawfile issue "$ITMP/issue.md" \
           --rawfile commits "$ITMP/commits.txt" \
           --arg branch "$BRANCH" \
      '$tpl | split("{{ISSUE}}") | join($issue)
            | split("{{COMMITS}}") | join($commits)
            | split("{{BRANCH}}") | join($branch)' > "$ITMP/prompt.txt"

    WAVE_UUIDS+=("$UUID")
    WAVE_IDENTS+=("$IDENT")
    WAVE_TITLES+=("$TITLE")
    ATTEMPTED="$ATTEMPTED $IDENT"
  done < "$TMP/candidates.tsv"

  if [ "${#WAVE_IDENTS[@]}" -eq 0 ]; then
    log "no launchable issues this wave (all skipped) — stopping"
    break
  fi

  # ---- launch wave: parallel agents, allSettled ----
  log "wave $WAVE_NUM: launching ${#WAVE_IDENTS[@]} agent(s): ${WAVE_IDENTS[*]} (image $IMAGE, max $MAX_TURNS turns each)"
  WAVE_PIDS=()
  for i in "${!WAVE_IDENTS[@]}"; do
    run_agent "${WAVE_UUIDS[$i]}" "${WAVE_IDENTS[$i]}" "$WAVE_BASE_SHA" &
    WAVE_PIDS+=("$!")
  done

  WAVE_OK=0
  WAVE_FAIL=0
  for i in "${!WAVE_PIDS[@]}"; do
    if wait "${WAVE_PIDS[$i]}"; then
      WAVE_OK=$((WAVE_OK + 1))
    else
      WAVE_FAIL=$((WAVE_FAIL + 1))
    fi
  done
  log "wave $WAVE_NUM: settled — $WAVE_OK ready to land, $WAVE_FAIL failed/blocked"

  # ---- land survivors sequentially, in pick (priority) order ----
  LANDED=0
  for i in "${!WAVE_IDENTS[@]}"; do
    if [ -f "$TMP/${WAVE_IDENTS[$i]}/land" ]; then
      if land_issue "${WAVE_UUIDS[$i]}" "${WAVE_IDENTS[$i]}" "${WAVE_TITLES[$i]}"; then
        LANDED=$((LANDED + 1))
      fi
    fi
  done
  TOTAL_LANDED=$((TOTAL_LANDED + LANDED))
  log "wave $WAVE_NUM: landed $LANDED of ${#WAVE_IDENTS[@]}"

  if [ -f "$TMP/ratelimited" ]; then
    log "usage limit hit during wave $WAVE_NUM — stopping loop"
    break
  fi
done

log "done — $TOTAL_LANDED issue(s) landed across $WAVE_NUM wave(s)"
