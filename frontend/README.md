# shop-frontend

React + TypeScript single-page app (Vite) showing the shop's products. Built into static
files and served by nginx (unprivileged image, port 8080).

## How it reaches the API

Relative URLs (`/api/products`, `/api/version`). In the cluster, the gateway sends `/api/*`
to the API and everything else to this frontend, on the same hostname, so the browser sees
one origin and no CORS is needed.

## Run locally

```bash
cd frontend && npm install
npm run dev          # http://localhost:5173, /api proxied to http://shop.local:8088
```

Needs the kind cluster running and `127.0.0.1 shop.local` in `/etc/hosts`.

## Build and deploy

CI (`.github/workflows/shop-frontend.yml`) builds the image on every push to `main` that
changes `frontend/`, publishes `ghcr.io/<owner>/shop-frontend:sha-<commit>`, and writes that
tag into `charts/shop/values-local.yaml`. The chart deploys it when `frontend.enabled` is
true. The page footer shows the commit it was built from, and the API's version.

## nginx

`nginx.conf` replaces the image's default server: `/healthz` for probes, long-lived caching
for the content-hashed files in `/assets/`, and `no-cache` for `index.html` so a deploy is
picked up immediately. The pod's root filesystem is read-only; nginx writes only to `/tmp`.
