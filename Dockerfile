# nike.sh agent container (JFV-34)
# Runs one Claude Code agent against a host git worktree mounted at its
# original absolute path (plus the parent repo's .git, so the worktree's
# gitdir pointer resolves). Auth via -e CLAUDE_CODE_OAUTH_TOKEN.
FROM node:22-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# giftwiz is a Python/uv workspace (requires-python >=3.12)
RUN curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh

# Mounted worktree/.git are owned by the host user, not `node`; and commits
# made inside the container need an identity.
RUN git config --system --add safe.directory '*' \
    && git config --system user.name "nike-agent" \
    && git config --system user.email "nike-agent@users.noreply.github.com"

# Non-root: claude refuses --dangerously-skip-permissions as root, and the
# node user's home gives it a writable throwaway ~/.claude for session state.
# ~/.claude/skills is bind-mounted read-only over this at runtime.
USER node
RUN mkdir -p /home/node/.claude/skills && uv python install 3.12
