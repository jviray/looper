# nike.sh — just do it

A Linear-driven, parallel, AFK (away-from-keyboard) coding loop in ~350 lines of bash.

Run it from inside a target repo. It pulls ready issues from Linear, runs each one as a
Claude Code agent inside a docker container (one git worktree + branch per issue, N agents
in parallel), lands the results back on your main branch (`--merge`) or as pull requests
(`--pr`), and reports everything — claims, summaries, failures — back to Linear. You come
back to merged commits and updated tickets, or to a loop that stopped gracefully and told
Linear why.

Modeled on Matt Pocock's [ralph loop (`afk.sh`)](https://github.com/mattpocock/ai-engineer-workshop-2026-project)
and the three-phase shape of [sandcastle's parallel-planner](https://github.com/mattpocock/sandcastle),
adapted to Linear as the task store and plain `docker run` as the sandbox.

---

## Table of contents

- [How it works (one paragraph)](#how-it-works-one-paragraph)
- [Requirements](#requirements)
- [One-time setup](#one-time-setup)
- [Usage](#usage)
- [The Linear contract](#the-linear-contract)
- [Architecture](#architecture)
  - [The wave loop](#the-wave-loop)
  - [Isolation: worktrees + containers](#isolation-worktrees--containers)
  - [The agent prompt and the promise contract](#the-agent-prompt-and-the-promise-contract)
  - [Landing](#landing)
  - [Output surfacing and logs](#output-surfacing-and-logs)
- [Failure modes and recovery](#failure-modes-and-recovery)
- [Cost and security model](#cost-and-security-model)
- [Repo and runtime layout](#repo-and-runtime-layout)
- [Retargeting: another team or repo](#retargeting-another-team-or-repo)
- [Extending the loop](#extending-the-loop)
- [Development gotchas](#development-gotchas)
- [Design history](#design-history)

---

## How it works (one paragraph)

Each iteration ("wave"): query Linear for the **frontier** — Todo issues labeled
`Ready for Agent`, unassigned, with every blocking issue completed — take the first N by
priority (default 2), claim each one (assign + In Progress), give each its own git worktree
and `agent/<ISSUE-ID>` branch, and launch one containerized Claude Code agent per issue in
parallel. Wait for all of them (`Promise.allSettled` semantics — one failure never cancels
the wave). Agents that end with `<promise>DONE</promise>` and real commits get landed
sequentially (merge or PR); everything else is commented back to Linear and returned to the
frontier. Re-query and repeat until the frontier is empty or a usage limit fires.

```
            ┌─────────────────────────────────────────────────────┐
            │                       wave loop                     │
            │                                                     │
 Linear ───►│ frontier query ─► pick N by priority ─► claim each  │
            │        │                                            │
            │        ▼                                            │
            │ worktree + branch per issue (sequential setup)      │
            │        │                                            │
            │        ▼                                            │
            │ ┌────────────┐  ┌────────────┐   parallel agents    │
            │ │ docker run │  │ docker run │   (allSettled)       │
            │ │  claude -p │  │  claude -p │                      │
            │ └─────┬──────┘  └─────┬──────┘                      │
            │       ▼               ▼                             │
            │ verdict: DONE+commits? ── no ─► comment + Todo      │
            │       │ yes                                         │
            │       ▼                                             │
            │ land sequentially (--merge | --pr) ─► Done/InReview │
            │       │                                             │
            │       └──── re-query ─── frontier empty? ─► exit    │
            └─────────────────────────────────────────────────────┘
```

## Requirements

**On the host:**

| Dependency | Why |
|---|---|
| `bash` (macOS 3.2 is fine) | the loop itself |
| `git` | worktrees, branches, merging |
| `docker` | agent containers (Docker Desktop on macOS works; plain `docker run`, **not** `docker sandbox`) |
| `jq`, `curl` | Linear GraphQL API |
| `gh` (only for `--pr` mode) | opening pull requests |
| the `nike-agent` image | built from this repo's `Dockerfile` |

**In `.env` next to `nike.sh`** (gitignored):

```bash
LINEAR_API_KEY=lin_api_...            # personal API key, Settings → API
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat... # from `claude setup-token` (subscription auth)

# Linear team/workflow ids — see Retargeting for how to fetch yours
LINEAR_TEAM_ID=...
LINEAR_ME=...                # your Linear user id, used as the claim assignee
LINEAR_STATE_TODO=...
LINEAR_STATE_IN_PROGRESS=...
LINEAR_STATE_IN_REVIEW=...
LINEAR_STATE_DONE=...
```

**In Linear:** a team with a `Ready for Agent` label and the usual
Todo / In Progress / In Review / Done states. The team, state, and user ids all come from
`.env` (not hardcoded in the script) — see [Retargeting](#retargeting-another-team-or-repo)
for how to fetch them.

**In the target repo:** it just needs to be a git repo whose test tooling the agent can run.
The current image bundles `uv` + Python 3.12 because the current target is a
Python/uv workspace; bake in whatever your repo needs (see
[Retargeting](#retargeting-another-team-or-repo)).

## One-time setup

1. **Claude auth token** (subscription-based, not metered API billing):

   ```bash
   claude setup-token
   # paste the resulting token into looper/.env as CLAUDE_CODE_OAUTH_TOKEN
   ```

2. **Turn extra usage OFF** in your Claude account settings if you're on Pro/Max. This is a
   load-bearing guardrail: when you hit your plan's usage limit, agents stop instead of
   silently rolling into pay-as-you-go billing. The loop detects the limit and exits
   gracefully (see [Failure modes](#failure-modes-and-recovery)).

3. **Linear API key** → `.env` as `LINEAR_API_KEY`. Also fetch your team/state/user ids
   (see [Retargeting](#retargeting-another-team-or-repo)) and put them in `.env` as
   `LINEAR_TEAM_ID`, `LINEAR_ME`, `LINEAR_STATE_TODO`, `LINEAR_STATE_IN_PROGRESS`,
   `LINEAR_STATE_IN_REVIEW`, `LINEAR_STATE_DONE`. `nike.sh` refuses to start if any of
   these are missing.

4. **Build the agent image:**

   ```bash
   docker build -t nike-agent /path/to/looper
   ```

   The image is `node:22-slim` + git + the `claude` CLI + `uv`/Python 3.12, running as the
   non-root `node` user (`claude` refuses `--dangerously-skip-permissions` as root), with
   `safe.directory '*'` and a git identity baked in (mounted worktrees are owned by the
   host user, and commits need an author).

5. **Put `nike.sh` on your PATH** (optional — you can also call it by absolute path).

## Usage

Run it **from inside the target repo**, on the branch you want work landed onto (it uses
the currently checked-out branch as the merge/PR base):

```bash
cd ~/projects/your-org/target-repo
nike.sh --merge              # land finished branches directly onto the current branch
nike.sh --pr                 # push branches and open PRs instead
nike.sh --merge --max 4      # up to 4 parallel agents per wave (default 2)
nike.sh --max-turns 80       # per-agent turn budget (default 50)
nike.sh --image my-agent     # alternative agent image (default nike-agent)
nike.sh -h                   # help
```

| Flag | Default | Meaning |
|---|---|---|
| `--merge` | ✔ (default) | after each wave, `git merge --no-ff` each successful branch into the base branch |
| `--pr` | | push each successful branch and `gh pr create` against the base branch; issue → In Review |
| `--max N` | `2` | max parallel agents per wave (also your cost throttle) |
| `--max-turns N` | `50` | `claude --max-turns` per agent (bounds a runaway agent) |
| `--image NAME` | `nike-agent` | docker image to run agents in |

The loop exits `0` when the frontier is empty (or a usage limit stopped it gracefully).
It's safe to just run it again at any time: all state lives in Linear and git, not in the
script.

**What a run looks like:**

```
nike: wave 1: querying frontier (Todo + 'Ready for Agent' + unassigned + unblocked)
nike: [JFV-37] claimed; worktree ../.nike/target-repo/JFV-37 (branch agent/JFV-37 from main@604513f)
nike: [JFV-38] claimed; worktree ../.nike/target-repo/JFV-38 (branch agent/JFV-38 from main@604513f)
nike: wave 1: launching 2 agent(s): JFV-37 JFV-38 (image nike-agent, max 50 turns each)
  [JFV-37]> I'll use the /implement skill to complete this issue.
  [JFV-38]> Now let's look at the existing test file for conventions.
  ...
nike: [JFV-38] agent exited (0)
nike: [JFV-38] result: subtype=success commits=1 promise=<promise>DONE</promise>
nike: [JFV-37] agent exited (0)
nike: [JFV-37] result: subtype=success commits=1 promise=<promise>DONE</promise>
nike: wave 1: settled — 2 ready to land, 0 failed/blocked
nike: [JFV-37] merging agent/JFV-37 into main
nike: [JFV-37] merged and Done — worktree/branch cleaned up
nike: [JFV-38] merging agent/JFV-38 into main
nike: [JFV-38] merged and Done — worktree/branch cleaned up
nike: wave 1: landed 2 of 2
nike: wave 2: querying frontier (Todo + 'Ready for Agent' + unassigned + unblocked)
nike: frontier is empty — nothing left to do
nike: done — 2 issue(s) landed across 2 wave(s)
```

## The Linear contract

Linear is the single source of truth for *what* to work on; the loop is the only thing
that writes to Linear. Agents never see the Linear API key — the loop relays each agent's
final summary as an issue comment.

**The frontier rule** — an issue is eligible when ALL of:

1. state is **Todo** (state type `unstarted` — note: Backlog does *not* qualify),
2. it has the **`Ready for Agent`** label,
3. it is **unassigned**,
4. every issue that *blocks* it (checked via `inverseRelations`, Linear's incoming
   "blocks" edges) is completed or canceled.

Selection is deterministic: sort eligible issues by priority (Urgent → Low; "no priority"
sorts last), take the first N. There is deliberately **no runtime planner agent** — the
Linear blocking graph, authored at triage time (by you, or by an agent writing tickets), is
the sole dependency authority. If two issues would touch the same files, encode that as a
blocking edge when you write the tickets.

**State transitions the loop performs:**

| Event | Linear effect |
|---|---|
| picked from frontier | assign to owner + **In Progress** |
| agent DONE + commits, merge clean | summary comment + **Done** |
| agent DONE + commits, `--pr` mode | summary comment + PR link comment + **In Review** |
| merge conflict | conflict comment (names kept branch/worktree) + **In Review** |
| agent BLOCKED / no promise / no result / DONE-without-commits | reason comment + back to **Todo**, unassigned |
| usage limit hit | comment + back to **Todo**, unassigned; loop stops |

Issues returned to Todo re-enter the frontier automatically — but not within the same run
(see the ping-pong trap under [Failure modes](#failure-modes-and-recovery)).

**Writing good agent tickets.** The issue description (plus all its comments) is rendered
into the agent's prompt verbatim, and it's *all* the agent knows about the task. What works
well: name the exact files/modules in scope, enumerate the cases to cover, state
constraints explicitly ("pure unit tests — no database, no network", "put tests in a NEW
file X, do NOT touch existing tests"), and keep one issue = one coherent change. The agent
is instructed to make the smallest reasonable interpretation of ambiguity rather than
block, so precision in the ticket is your steering wheel.

## Architecture

### The wave loop

Each wave has four phases, with deliberate sequential/parallel boundaries:

1. **Select** (sequential): query the frontier, filter blocked and already-attempted
   issues in `jq`, sort by priority, walk the candidate list until N launchable issues are
   found. Candidates with a leftover worktree or branch on the host are skipped with a
   warning (they need a human — see failure table).

2. **Set up** (sequential, per issue): claim it (assign + In Progress, then *verify the
   assignment stuck* — Linear claims aren't atomic), fetch and render the full issue
   (description + comments) to markdown, `git worktree add -b agent/<ID> ../.nike/<repo>/<ID>`,
   and render `prompt.md` with the issue, recent commits, and branch name substituted in.
   Setup is sequential on purpose: it avoids intra-run claim races and concurrent
   `git worktree add` lock contention.

3. **Run** (parallel): each issue's agent is a background job (`run_agent ... &`), then
   the loop `wait`s on each PID individually — bash's version of `Promise.allSettled`.
   Every job carries its own verdict logic and failure handling; Linear helper functions
   use per-call `mktemp` files so concurrent writes never collide. One failing agent never
   cancels the others.

4. **Land** (sequential, in pick order): only issues whose job left a `land` marker (DONE
   promise + ≥1 commit) get landed, one at a time. The job→loop channel is plain files in
   the run's temp dir: `land`, `summary.md`, `ncommits`.

All worktrees in a wave branch from the same base SHA (captured at wave setup), and landing
happens strictly after the wave settles, so sequential merges are well-ordered; the next
wave branches from the new HEAD.

### Isolation: worktrees + containers

Each agent runs in a plain `docker run --rm` container that mounts exactly three things:

```bash
docker run --rm \
  -e CLAUDE_CODE_OAUTH_TOKEN \
  -v "$WT:$WT" \                                      # the issue's worktree, read-write
  -v "$REPO_DIR/.git:$REPO_DIR/.git" \                # parent repo's .git (worktree gitdir pointer)
  -v "$HOME/.claude/skills:/home/node/.claude/skills:ro" \  # your skills, read-only
  -w "$WT" \
  nike-agent \
  claude --dangerously-skip-permissions -p --output-format stream-json --verbose \
    --max-turns 50 "<rendered prompt>"
```

Key points:

- The worktree is mounted **at its original absolute path**, and the parent repo's `.git`
  alongside it, so the worktree's `.git` pointer file resolves inside the container (the
  same trick sandcastle's `resolveGitMounts` uses). This is why plain `docker run` is used
  and **not** Docker Desktop's `docker sandbox`: sandboxes mount only the workspace
  directory, the parent `.git` is invisible, and host-created worktrees simply don't work
  there (researched to death on JFV-23).
- Nothing else from the host exists in the container. The agent can `rm -rf` to its
  heart's content; your home directory isn't mounted. Skills are read-only, so the agent
  can't rewrite your host Claude config.
- The container's own `~/.claude` is throwaway session scratch owned by the `node` user.

**A note about your local machine.** The `$HOME/.claude/skills` mount is resolved from
*whoever runs the script*, not a path baked into the repo. Anyone who clones this and runs
`nike.sh` mounts their own local skills directory into the container — read-only, never
committed anywhere — but if your `~/.claude/skills` contains anything you consider private,
know that it's exposed to the agent at runtime. Nothing else about your machine (username,
absolute paths, hostname) is referenced anywhere in `nike.sh`; all paths are derived at
runtime from `$SCRIPT_DIR`, `$REPO_DIR`, and `$HOME`.

### The agent prompt and the promise contract

`prompt.md` is the entire agent briefing. The loop substitutes three placeholders:

| Placeholder | Content |
|---|---|
| `{{ISSUE}}` | the rendered Linear issue: title, labels, description, all comments |
| `{{COMMITS}}` | `git log --oneline -10` of the base branch, for context |
| `{{BRANCH}}` | the agent's branch name (it must never switch or push) |

The prompt tells the agent to use the `/implement` skill (test-first development,
typecheck/test loops, self-review, commit), with a manual TDD fallback if the skill is
unavailable, and to end its final message with **exactly one promise tag**:

- `<promise>DONE</promise>` — implemented, tests pass, committed.
- `<promise>BLOCKED: <one-line reason></promise>` — genuinely cannot proceed (missing
  info, broken environment, needs a human). On BLOCKED the agent must leave the tree
  clean (WIP commit or stash).

The loop parses the promise out of the last `result` event in the `stream-json` output.
The verdict is promise **and** evidence: `DONE` with zero commits is treated as a failure,
and only branches with actual commits ever reach landing.

### Landing

- **`--merge` (default):** `git merge --no-ff agent/<ID>` into the base branch, so every
  issue lands as one merge commit (`nike: land JFV-38 — <title>`) with the agent's commits
  preserved underneath. Success → issue Done, worktree and branch deleted. Conflict →
  merge aborted, branch and worktree kept for manual resolution, issue → In Review with a
  comment naming them. A conflict never stops the rest of the wave from landing.
- **`--pr`:** push the branch, `gh pr create` (title `<ID>: <issue title>`, body = agent
  summary), comment the PR URL on the issue, issue → In Review. The worktree is removed
  but the branch is kept until the PR merges. Requires a GitHub remote and `gh` auth.

### Output surfacing and logs

With N agents talking at once, three layers keep it legible:

1. **Live interleaved stream:** each agent's assistant messages are reduced to one line
   each and prefixed `[JFV-XX]>`, so the combined terminal feed stays attributable at a
   glance (comfortable at N=2–4).
2. **Wave summaries:** `settled — X ready to land, Y failed/blocked` and
   `landed X of Y` lines after each wave.
3. **Full logs on disk:** every agent's complete `stream-json` output and stderr land in
   `../.nike/<repo>/logs/<ISSUE-ID>.jsonl` and `<ISSUE-ID>.stderr.log`, and survive the
   run. This is where you go to autopsy a weird run — e.g.
   `jq -r 'select(.type=="assistant") | .message.model' logs/JFV-37.jsonl` tells you which
   model ran, and the `result` event holds the final summary, cost, and turn count.

## Failure modes and recovery

Design stance: the loop **never retries silently and never destroys evidence**. Failures
are commented onto the issue, the issue returns to the frontier, and anything with commits
in it is kept on disk.

| Failure | Loop behavior | Your recovery |
|---|---|---|
| Agent ends `BLOCKED: <reason>` | comment + back to Todo; **worktree/branch kept** | read the reason, fix the ticket or environment, clean up the worktree, rerun |
| Agent ends with no promise (ran out of turns, crashed mid-thought) | comment (with result subtype) + back to Todo; worktree kept only if it has commits | check the `.jsonl` log; maybe raise `--max-turns` |
| Agent claims DONE but committed nothing | treated as failure: comment + back to Todo, worktree removed | usually a ticket-clarity problem |
| No `result` event at all (container died, CLI crashed) | comment with stderr excerpt + back to Todo | read `logs/<ID>.stderr.log` |
| Merge conflict on landing | issue → In Review, branch + worktree kept, comment names them | resolve by hand in the kept worktree, merge, mark Done, delete branch |
| Claude usage limit hit | detecting agent's issue → back to Todo untouched; a sentinel stops the loop **after** the current wave settles and its survivors land | rerun after the limit resets |
| Leftover worktree/branch from a past failure | issue is **skipped at selection** with a host-side warning (no Linear spam) | `git worktree remove <path>` + `git branch -D agent/<ID>`, then rerun |
| Claim doesn't stick (concurrent writer) | logged, issue skipped this run | none needed |

**The ping-pong trap (why the ATTEMPTED set exists).** A BLOCKED issue goes back to Todo
with its worktree kept for inspection. A naive loop would immediately re-pick it on the
next wave, hit the leftover-worktree guard, fail, return it to Todo… forever. So the loop
keeps a per-run `ATTEMPTED` set: every issue that was picked — or skipped as a leftover —
is excluded from all later frontier queries *in this run*. The set is deliberately not
persisted: a fresh invocation retries everything, which is the retry policy (one attempt
per issue per run, unbounded across runs, human in the loop in between).

## Cost and security model

This is built to run on a **Claude Pro subscription**, and the guardrails assume
subscription auth:

1. **Extra usage OFF** in account settings — the hard stop is enforced by Anthropic.
   Hitting the plan limit blocks instead of billing.
2. **Rate-limit graceful stop** — the loop detects limit messages in agent output/stderr,
   returns the issue to the frontier untouched, finishes landing the wave, and exits.
3. **Concurrency cap** (`--max`, default 2) and **per-agent turn budget** (`--max-turns`,
   default 50).

Worst AFK outcome by construction: *"the loop stopped and issues are waiting"* — never a
surprise bill.

Security posture:

- The **agent never sees the Linear key**; the loop performs all Linear writes and relays
  the agent's summary.
- The agent *does* see `CLAUDE_CODE_OAUTH_TOKEN` (any credential a process can use, it can
  read). Bounded risk: the token only spends the Claude subscription and is revocable.
  The realistic threat is prompt injection via issue content — mitigated here because the
  issue author is you. **If you ever point this at a tracker with untrusted ticket
  authors, revisit this.**
- Containers get the worktree read-write, the parent `.git` (necessarily writable for
  commits), read-only skills, and nothing else from the host.

## Repo and runtime layout

**This repo (`looper/`):**

```
nike.sh       # the loop (single file, bash 3.2-compatible)
prompt.md     # agent briefing template ({{ISSUE}}/{{COMMITS}}/{{BRANCH}})
Dockerfile    # nike-agent image
.env          # LINEAR_API_KEY, CLAUDE_CODE_OAUTH_TOKEN, LINEAR_TEAM_ID/ME/STATE_* (gitignored)
HANDOFF.md    # session-to-session working state for the wayfinder process
README.md     # this file
```

**Runtime state (sibling of the target repo, nothing to gitignore):**

```
<parent-of-target-repo>/
├── target-repo/                  # the target repo (loop runs from here)
└── .nike/
    └── target-repo/
        ├── JFV-41/               # worktree, exists only while an issue is in flight
        │                         #   (or kept after BLOCKED/conflict for autopsy)
        └── logs/
            ├── JFV-41.jsonl          # full stream-json agent transcript
            └── JFV-41.stderr.log     # agent stderr
```

Branches are `agent/<ISSUE-ID>`, created from the base branch at wave start, deleted on
successful merge.

## Retargeting: another team or repo

Three things bind the script to its current environment:

1. **Linear ids live in `.env`**: `LINEAR_TEAM_ID`, `LINEAR_ME` (the claim assignee), and
   the workflow state UUIDs (`LINEAR_STATE_TODO`, `LINEAR_STATE_IN_PROGRESS`,
   `LINEAR_STATE_IN_REVIEW`, `LINEAR_STATE_DONE`). For a different team, fetch yours once
   and drop them into `.env`:

   ```bash
   curl -s https://api.linear.app/graphql \
     -H "Authorization: $LINEAR_API_KEY" -H "Content-Type: application/json" \
     -d '{"query":"{ teams { nodes { id key states { nodes { id name type } } labels { nodes { id name } } } } viewer { id } }"}' | jq .
   ```

   You also need a `Ready for Agent` label on that team (the frontier query matches it by
   name, so the label id itself isn't needed).

2. **The agent image must be able to build/test the target repo.** The current
   `Dockerfile` bakes in `uv` + Python 3.12 for a Python/uv target; add Node, Go, whatever your repo's
   test suite needs. The image contract is small: `claude` CLI on PATH, git with
   `safe.directory '*'` + an identity, a non-root user with a writable home
   (`--dangerously-skip-permissions` refuses to run as root), skills dir at
   `~/.claude/skills` to receive the read-only mount.

3. **The target repo is whatever you `cd` into** — `nike.sh` discovers it via
   `git rev-parse --show-toplevel` and uses the checked-out branch as the landing base.
   Nothing else about the target is assumed.

Portability notes: on macOS/Docker Desktop, file ownership between host and container is
mapped automatically, so the image's `node` (uid 1000) user just works. On a native Linux
host you'd need to align uids (sandcastle-style `AGENT_UID` build-args — see the JFV-34
ticket addendum). `--pr` mode requires the target repo to have a GitHub remote and an
authenticated `gh`; it is written but has not been exercised yet (the initial target repo has no remote).

## Extending the loop

Ordered roughly by how likely you are to want them. The first few were consciously parked
as "evidence-triggered" during design (JFV-26) — build them when reality demands, not
before.

**Pin or vary the model.** Agents currently run whatever the `claude` CLI defaults to for
your account (Sonnet 5, as of the last verified run). Add a `--model` flag to `nike.sh`
and pass it through to the `claude` invocation in `run_agent()` — or go per-issue with a
`model:<name>` label on the Linear ticket that the frontier query picks up. The seam is a
single line: the `claude ...` command in `run_agent()`.

**Planner filter** (parked until real waves hit merge conflicts often). A read-only agent
call between the frontier query and launch that picks a non-file-overlapping subset ≤ cap.
Slot it between selection and setup in the main loop. The deterministic alternative that
exists today: encode file-overlap as blocking edges at triage time.

**Merge agent** (parked until the loop has earned trust). Sandcastle-style: on merge
conflict, instead of going straight to In Review, launch a container whose only job is
resolving that conflict. The seam is the conflict branch of `land_issue()`. Keep the
deterministic path as the fallback.

**Smarter retry policy.** Today: one attempt per issue per run (the `ATTEMPTED` set),
unbounded retries across runs. If issues start ping-ponging *across* runs, persist an
attempt counter — an `agent-attempts:<n>` label on the issue, or a counter comment — and
have the frontier query (or a post-filter) skip issues past a threshold, flagging them for
a human instead.

**Per-issue turn/cost budgets.** `--max-turns` is global. A `budget:<turns>` label on the
ticket, parsed at setup, would let heavy issues get more room without raising the default.

**Wave-level notifications.** The loop is silent unless you're watching the terminal.
The end of the landing phase (after the `landed X of Y` log line) is the natural hook for
a push notification / Slack webhook with the wave summary.

**Frontier pagination.** The query fetches `first: 250` in one page, plenty for a personal
team. Past that, the cursor loop is already written and tested on the JFV-24 ticket —
lift it from there.

**Other target repos.** Nothing in `nike.sh` is tied to a specific repo; it's the image and the
Linear ids that bind (see [Retargeting](#retargeting-another-team-or-repo)). A
`nike.toml`/env-based config layer (team id, state ids, image name per repo) is the
natural shape if this grows beyond one target.

**Cloud execution** — researched and consciously ruled **out of scope** (JFV-31 canceled).
If it ever returns, start from the JFV-30 research: the recommendation was E2B running the
unmodified `claude -p --output-format stream-json` CLI, and the design seam is that the
whole per-issue agent run is already a single function (`run_agent`) whose only host
dependencies are the worktree and the two mounts.

**What NOT to change lightly:**

- *Selection stays deterministic.* No runtime planner re-deriving the dependency graph
  per wave — the Linear blocking graph is the authority, and it's human-reviewable in
  Linear's UI. This was decided deliberately against sandcastle's model (JFV-26).
- *The loop owns all Linear writes.* Handing agents the Linear key breaks both the
  security model and the single-writer simplicity.
- *Only branches with commits land; one failed agent never cancels the wave.* These two
  invariants are what make the loop safe to leave alone.

## Development gotchas

Hard-won; each of these cost real time. They matter the moment you edit `nike.sh`:

- **macOS ships bash 3.2.** No `declare -A` (hence the `WAVE_UUIDS`/`WAVE_IDENTS`/
  `WAVE_TITLES` parallel arrays), no `mapfile`. Heredocs inside `$(...)` mis-parse — write
  bodies to files and use `jq --rawfile`.
- **jq reserves the word `label`.** `--arg label` / `$label` fails to compile
  ("unexpected label"). Use `$lbl`.
- **Always pass markdown to Linear via GraphQL variables** (`jq -n --rawfile`), never
  string-interpolated into the query — backticks, quotes, and newlines will bite you.
- **Linear normalizes markdown on write** (`-` → `*`, URLs get wrapped in `<>`), so never
  exact-string-match against a description you wrote earlier.
- **Linear GraphQL errors arrive as HTTP 200** with an `errors` array — check for them
  explicitly (the `lin()` helper does), never trust the curl exit code.
- **Claiming isn't atomic.** Assign, then re-read and verify `assignee.id` is you (the
  setup phase does this).
- **`docker run -e VAR`** (no `=value`) forwards only **exported** variables — hence
  `set -a; source .env; set +a`.
- **`claude -p --output-format stream-json` requires `--verbose`**, or the CLI errors out.
- **Backgrounded functions under `set -e`:** collect statuses with
  `if wait "$pid"; then ...` — a bare `wait $pid` on a failed job kills the whole loop.
- **State type strings** in Linear filters are plain lowercase strings: `unstarted`,
  `started`, `completed`, `canceled`; relation type is `blocks`.
- Team/state/user UUIDs for team JFV are cached in `.env` and on the JFV-24 ticket.

## Design history

The full decision record lives in Linear: the wayfinder map
JFV-22 indexes everything, and each
resolved sub-issue carries its complete rationale in a resolution comment. Highlights:

| Ticket | What it settled |
|---|---|
| JFV-24 | Tested GraphQL snippets for frontier/claim/comment/state-moves; rate limits are a non-issue at loop scale |
| JFV-23 | Why `docker sandbox` was rejected (host worktrees don't resolve; auth/skills friction) |
| JFV-25 | Worktree/branch/merge mechanics, auth via `setup-token`, the cost-guardrail stack |
| JFV-26 | The agent prompt + promise contract; no runtime planner — Linear graph is the authority |
| JFV-35 / JFV-34 | Credentials + guardrails checklist; the `nike-agent` image, verified end-to-end |
| JFV-27 | Tracer: one issue through the whole pipeline (toy JFV-36) |
| JFV-28 | Parallel waves, verified with a live 2-agent wave (JFV-37/38); ping-pong fix; output surfacing |
| JFV-30 | Cloud execution research (E2B recommendation) — kept as reference, out of scope |

External references:

- Matt Pocock — [ralph loop / `afk.sh`](https://github.com/mattpocock/ai-engineer-workshop-2026-project) (`ralph/`): the original single-stream AFK loop this generalizes.
- Matt Pocock — [sandcastle](https://github.com/mattpocock/sandcastle) (`src/templates/parallel-planner/`): adopted the three-phase wave shape, commit-filtering, and allSettled semantics; rejected the runtime planner and merge agent (for now).
