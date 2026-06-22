# Pinch cloud image (Fly.io always-on Machine).
#
# IMPORTANT: build context is the MONOREPO ROOT, not infra/cloud.
# Build from the repo root so the workspaces resolve:
#
#   docker build -f infra/cloud/Dockerfile -t pinch .
#
# (Fly does this for you via fly.toml's [build].dockerfile when you `fly deploy`
#  from the repo root.)

# ---- build stage -----------------------------------------------------------
FROM node:20-bookworm-slim AS build
WORKDIR /app

# git is needed at build time only if you run any prepare scripts; the clone
# at runtime happens in the final image (see below).
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy manifests first for better layer caching. Paths are relative to the
# repo root (the build context).
COPY package.json package-lock.json* ./
COPY packages/protocol/package.json packages/protocol/
COPY backend/package.json backend/

# Install all workspace deps (protocol + backend). simulator is not needed in
# the cloud image; we only build what the server requires.
RUN npm install --workspace @pinch/protocol --workspace @pinch/backend --include-workspace-root

# Now copy sources and build.
COPY packages/protocol packages/protocol
COPY backend backend
RUN npm run build --workspace @pinch/protocol --if-present \
 && npm run build --workspace @pinch/backend

# ---- runtime stage ---------------------------------------------------------
FROM node:20-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production

# git for cloning repos at boot; ca-certificates for TLS to GitHub + Anthropic.
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Bring over installed node_modules and built output. Copying the whole tree
# keeps the workspace symlinks (@pinch/protocol -> packages/protocol) intact.
COPY --from=build /app /app

# Run from the backend workspace so `node dist/index.js` and dotenv resolve.
WORKDIR /app/backend

# The agent operates on repos cloned into /workspace (a mounted Fly volume).
RUN mkdir -p /workspace
ENV PINCH_PROJECTS=/workspace

EXPOSE 8787

COPY infra/cloud/entrypoint.sh /usr/local/bin/pinch-entrypoint
RUN chmod +x /usr/local/bin/pinch-entrypoint

ENTRYPOINT ["/usr/local/bin/pinch-entrypoint"]
