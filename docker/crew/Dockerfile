# firstmate-crew: minimal image to run a claude crewmate sandboxed.
# Build (from repo root):
#   docker build -t firstmate-crew:latest -f docker/crew/Dockerfile .
FROM node:22-bookworm-slim

# git (worktree ops, commits, push) + gh (PRs) + curl/gnupg (gh apt repo).
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ca-certificates curl gnupg \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Claude Code CLI. Pin/replace to match how you install claude on the host.
RUN npm install -g @anthropic-ai/claude-code

# Optional: the no-mistakes validation pipeline + axi tools the crewmate may
# invoke for ship tasks. Uncomment if you run no-mistakes-mode projects.
# RUN curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh
# RUN npm install -g gh-axi chrome-devtools-axi lavish-axi

# claude refuses --dangerously-skip-permissions as root, so run as the image's
# built-in non-root "node" user (uid 1000). Credential mounts target its home.
ENV HOME=/home/node
USER node

ENTRYPOINT []
