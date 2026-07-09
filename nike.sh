#!/usr/bin/env bash

# nike.sh — just do it. (aka ralph loop for iterating over task list and implementing each without human oversight until complete)

# Requires: LINEAR_API_KEY

set -euo pipefail

# --- load .env (LINEAR_API_KEY, etc.) if present ---
if [ -f "$(dirname "$0")/.env" ]; then
  set -a; source "$(dirname "$0")/.env"; set +a
fi

# --- pull open issues from Linear ---
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ issues(first: 10, filter: { state: { type: { eq: \"unstarted\" } } }) { nodes { identifier title } } }"}' \
| jq -r '.data.issues.nodes[] | "\(.identifier)  \(.title)"'
