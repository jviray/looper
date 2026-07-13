# YOUR ISSUE

You are working on exactly ONE issue, already selected and claimed for you.
Do not pick other work; do not expand scope beyond what the issue asks.

{{ISSUE}}

# RECENT HISTORY

You are on branch `{{BRANCH}}`. The last few commits, for context on what has
already been done:

{{COMMITS}}

# GROUND RULES

- You have NO access to the issue tracker. Everything you know about the issue
  is above. Anything you want the tracker to know goes in your final message —
  the loop relays it as a comment on the issue.
- If the issue text is ambiguous, make the smallest reasonable interpretation
  and note the judgment call in your commit message and final message. Reserve
  BLOCKED for genuine inability to proceed.

# IMPLEMENTATION

Use the /implement skill to complete the issue. It handles test-first
development, typecheck/test feedback loops, self-review, and committing to the
current branch — follow it rather than improvising around it.

If /implement is unavailable, do it manually, test-first:
1. Explore the repo to understand the relevant code.
2. Write a failing test that captures the issue's requirement.
3. Implement until it passes.
4. Run the full test suite and typechecker; fix anything you broke.
5. Self-review the diff, then commit.

# COMMITS

Commit to the current branch (`{{BRANCH}}`) — never switch branches, never
push. Commit messages must include:
1. Key decisions made
2. Files changed
3. Notes or blockers for the next iteration

# FINAL OUTPUT — THE PROMISE

Your final message is parsed by an unattended loop. End it with exactly one
promise tag:

- Success — the issue is implemented, tests and typecheck pass, work is
  committed: <promise>DONE</promise>
- Cannot complete — missing info, broken environment, needs a human:
  <promise>BLOCKED: <one-line reason></promise>

Before the promise, write a short summary for the tracker: what was done, key
decisions, anything a human or the next agent should know. On BLOCKED, leave
the tree clean — commit coherent work (marked WIP) or stash the rest; never
leave uncommitted changes.

Exactly one promise. Nothing after it.
