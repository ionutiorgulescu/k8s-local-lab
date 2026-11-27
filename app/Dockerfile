# syntax=docker/dockerfile:1

# ---------- Stage 1: build ----------
# Full Node.js with npm and a shell: needed to install dependencies and compile TypeScript.
# None of this ends up in the final image.
# Pinned by tag (readable) AND digest (exact). When both are given, Docker uses the digest.
FROM node:24.22.3-trixie-slim@sha256:e50d187fecf517dca835935aa69788d79a2e737b8801c616c6da87423896ddc5 AS build
WORKDIR /app

# Copy only the dependency manifests first. Docker caches each step, so `npm ci` reruns
# only when package.json or package-lock.json change, not on every source edit.
COPY package.json package-lock.json ./
# `npm ci` installs exactly what package-lock.json says (and fails if it disagrees with
# package.json). `npm install` may resolve different versions: not reproducible.
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
# Compile, then delete devDependencies (TypeScript, @types/*) from node_modules.
RUN npm run build && npm prune --omit=dev

# ---------- Stage 2: runtime ----------
# Distroless: only the Node.js runtime and its system libraries. No shell, no package
# manager, no npm, so far fewer vulnerabilities and nothing for an attacker to use.
# The "nonroot" variant defaults to user 65532.
FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:39b0407357c9fadf1a9708d22088f02de21f0e1e8a688474eea2d8701e7d5693
WORKDIR /app
ENV NODE_ENV=production

# Files are owned by root and only readable by the app user: the app can't modify its
# own code. This also works with readOnlyRootFilesystem: true in Kubernetes (Step 6).
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist

# Numeric UID, not a name: with runAsNonRoot: true, Kubernetes can only verify that a
# numeric user is non-root. A name like "nonroot" makes the pod fail to start.
# The Git commit this image was built from, set by CI (--build-arg APP_REVISION=...) and
# reported by GET /api/version. Placed after the COPY steps so a new value only rebuilds
# this tiny layer, not the cached ones above.
ARG APP_REVISION=dev
ENV APP_REVISION=$APP_REVISION

USER 65532:65532
EXPOSE 8080

# The image's entrypoint is already the node binary, so this runs `node dist/main.js`.
# Node is PID 1 and receives SIGTERM directly. (`npm start` as the command would put npm
# in between, and npm doesn't reliably forward signals, which breaks graceful shutdown.)
CMD ["dist/main.js"]
