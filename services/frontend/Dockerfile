# syntax=docker/dockerfile:1

# ---------- Stage 1: build the static files ----------
# --platform=$BUILDPLATFORM: run this stage on the build machine's own CPU type, even when
# building for several platforms. Its output (HTML, JS, CSS) is the same for every platform,
# so there's no need to repeat it under emulation for arm64. Same pinned Node as the API.
FROM --platform=$BUILDPLATFORM node:24.22.3-trixie-slim@sha256:e50d187fecf517dca835935aa69788d79a2e737b8801c616c6da87423896ddc5 AS build
WORKDIR /app

# Dependencies first, so this layer stays cached until the lockfile changes.
COPY package.json package-lock.json ./
RUN npm ci

COPY index.html tsconfig.json vite.config.ts ./
COPY src ./src

# The Git commit, set by CI. Vite inlines VITE_* variables into the bundle at build time,
# so the page can show which commit it was built from. Declared after `npm ci` so a new
# commit doesn't invalidate the dependency cache.
ARG APP_REVISION=dev
ENV VITE_APP_REVISION=$APP_REVISION
RUN npm run build

# ---------- Stage 2: serve them ----------
# The official unprivileged nginx image: runs as numeric user 101 (passes runAsNonRoot),
# listens on 8080, stops gracefully on SIGQUIT. Stable line (even minor version).
FROM nginxinc/nginx-unprivileged:1.30.6-alpine3.24@sha256:f5116ed4606f3eb015dd4a8e28cb9b351476dc0ad4bc6e9f93b19cec130cdf03

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

USER 101:101
EXPOSE 8080
