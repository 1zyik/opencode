# Language patterns

Proven starting points. **Always adapt them to the repo facts from discovery:**
runtime version, package manager, build command, output dir, entry file,
port, health path. Version numbers below are placeholders. Replace them with
the repo's pinned version and verify the tag exists:

```sh
docker buildx imagetools inspect node:22-bookworm-slim
```

Every Dockerfile starts with:

```dockerfile
# syntax=docker/dockerfile:1
```

---

## Node.js (npm), API / server

```dockerfile
# syntax=docker/dockerfile:1
# Set from .nvmrc / engines.node
ARG NODE_VERSION=22

# ---- base: shared settings for all stages ----
FROM node:${NODE_VERSION}-bookworm-slim AS base
WORKDIR /app

# ---- deps: full dependency install (cached unless the lockfile changes) ----
FROM base AS deps
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci

# ---- build: compile TypeScript / bundle ----
FROM deps AS build
COPY . .
RUN npm run build

# ---- prod-deps: runtime dependencies only ----
FROM base AS prod-deps
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

# ---- runtime ----
FROM node:${NODE_VERSION}-bookworm-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
# tini as PID 1: forwards SIGTERM and reaps zombies (Node ignores SIGTERM as PID 1 without a handler)
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini \
 && rm -rf /var/lib/apt/lists/*
# Files stay root-owned and read-only to the app user
COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
# Built-in "node" user (uid/gid 1000); numeric so k8s runAsNonRoot can verify it
USER 1000:1000
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "dist/main.js"]
```

Variants:
- **pnpm:** `RUN corepack enable` in base (Node ≥ 25 doesn't bundle corepack, so use
  `npm i -g corepack@latest` first, or install the exact `packageManager` version).
  Deps: `COPY pnpm-lock.yaml ./` → `RUN --mount=type=cache,target=/pnpm/store pnpm fetch`
  → `COPY package.json ./` → `pnpm install --offline --frozen-lockfile`. Set
  `ENV PNPM_HOME=/pnpm` and `pnpm config set store-dir /pnpm/store`. Prod deps:
  `pnpm install --prod --frozen-lockfile` (or `pnpm deploy --prod /out` in workspaces).
- **yarn berry:** `corepack enable`, copy `.yarnrc.yml` + `.yarn/releases`, and run
  `yarn install --immutable`. Use `yarn workspaces focus --production` for prod deps.
- **No build step (plain JS):** drop the `build` stage and copy the source into runtime.
- **Private registry:** `RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm ci`, then
  build with `--secret id=npmrc,src=$HOME/.npmrc`.
- **Native modules (sharp, bcrypt, prisma):** stay on `-slim` (glibc). If node-gyp
  must compile, add `python3 make g++` to the **deps** stage only.
- **Prisma:** run `npx prisma generate` in build, copy the generated client
  (`node_modules/.prisma`, or the custom `output` path) into runtime, and install
  `openssl` in runtime.

## Node.js, Next.js (standalone)

Requires `output: 'standalone'` in `next.config.*`. Add it if it's missing and
mention it in the report.

```dockerfile
# runtime stage (after a build stage that ran `npm run build`)
FROM node:${NODE_VERSION}-bookworm-slim AS runtime
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 HOSTNAME=0.0.0.0
WORKDIR /app
COPY --from=build /app/public ./public
COPY --from=build /app/.next/standalone ./
COPY --from=build /app/.next/static ./.next/static
# Next writes its image/fetch cache here, so it must be writable by the app user
RUN mkdir -p .next/cache && chown 1000:1000 .next/cache
# Built-in "node" user (uid/gid 1000); numeric so k8s runAsNonRoot can verify it
USER 1000:1000
EXPOSE 3000
CMD ["node", "server.js"]
```

`NEXT_PUBLIC_*` values are inlined at **build** time. Pass them as build args,
and only if they're non-secret.

## Static frontend (Vite / CRA / Angular), served by nginx

```dockerfile
FROM node:${NODE_VERSION}-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
# Output dir: dist/ (Vite) or build/ (CRA). Check the config
RUN npm run build

# Runs as uid 101 and listens on 8080
FROM nginxinc/nginx-unprivileged:1.27-alpine AS runtime
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
HEALTHCHECK CMD ["wget", "-qO-", "http://127.0.0.1:8080/"]
```

Minimal `nginx.conf` for SPA routing:

```nginx
server {
  listen 8080;
  root /usr/share/nginx/html;
  location / { try_files $uri $uri/ /index.html; }
  location ~* \.(js|css|png|svg|woff2?)$ { expires 1y; add_header Cache-Control "public, immutable"; }
}
```

---

## Python (uv)

```dockerfile
# syntax=docker/dockerfile:1
# Set from .python-version / requires-python
ARG PYTHON_VERSION=3.12

FROM python:${PYTHON_VERSION}-slim-bookworm AS build
# Pin uv and verify the tag exists
COPY --from=ghcr.io/astral-sh/uv:0.5 /uv /uvx /bin/
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app
# 1) deps only: cached unless pyproject/lock change
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-dev
# 2) project itself
COPY . .
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev

FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY --from=build /app /app
USER 10001:10001
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).status==200 else 1)"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

Variants:
- **pip + requirements.txt:** in build, `python -m venv /opt/venv`, set
  `ENV PATH=/opt/venv/bin:$PATH`, run
  `RUN --mount=type=cache,target=/root/.cache/pip pip install -r requirements.txt`,
  then copy `/opt/venv` and the source into runtime.
- **poetry:** `pip install poetry==<ver> poetry-plugin-export`, then
  `poetry export -f requirements.txt --without dev -o req.txt` and install into a venv.
  Or `POETRY_VIRTUALENVS_IN_PROJECT=1 poetry install --only main --no-root`.
- **Django:** run `collectstatic` in build. Serve with
  `gunicorn project.wsgi:application --bind 0.0.0.0:8000 --workers ...`.
- **Flask:** `gunicorn "app:create_app()" --bind 0.0.0.0:8000`. Never use the dev server.
- **Compiled deps without wheels** (psycopg non-binary, mysqlclient): install
  `build-essential` and `libpq-dev` in **build** only, and the runtime `.so`
  packages (`libpq5`) in runtime.
- If `README.md` is referenced by `pyproject.toml` (`readme = ...`), the build
  needs it, so don't exclude it in `.dockerignore`.

---

## Go

```dockerfile
# syntax=docker/dockerfile:1
# Set from go.mod
ARG GO_VERSION=1.23
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-bookworm AS build
WORKDIR /src
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=bind,source=go.mod,target=go.mod \
    --mount=type=bind,source=go.sum,target=go.sum \
    go mod download
ARG TARGETOS TARGETARCH
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=bind,target=. \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/app

FROM gcr.io/distroless/static-debian12:nonroot AS runtime
COPY --from=build /out/app /app
# Built-in distroless "nonroot" user (uid/gid 65532)
USER 65532:65532
EXPOSE 8080
# No shell: implement `app healthcheck` in the binary, or rely on orchestrator probes
ENTRYPOINT ["/app"]
```

- If cgo is required (`import "C"`, sqlite3 with cgo), build with `CGO_ENABLED=1`
  and use `gcr.io/distroless/base-debian12:nonroot` (glibc) at runtime.
- The distroless `static` image already includes CA certificates and tzdata.

---

## Rust

```dockerfile
# syntax=docker/dockerfile:1
# Set from rust-toolchain.toml
ARG RUST_VERSION=1.82
FROM rust:${RUST_VERSION}-slim-bookworm AS build
WORKDIR /src
COPY . .
# target/ lives in a cache mount, so copy the binary out in the same RUN
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked \
 && cp target/release/myapp /myapp

FROM gcr.io/distroless/cc-debian12:nonroot AS runtime
COPY --from=build /myapp /myapp
# Built-in distroless "nonroot" user (uid/gid 65532)
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/myapp"]
```

- `openssl-sys`: add `pkg-config libssl-dev` in build and `libssl3` at runtime
  (use `debian:bookworm-slim` then), or switch the crate to `rustls`.
- For fully static binaries, use the `x86_64-unknown-linux-musl` target with
  `distroless/static` or `scratch`.
- Find the binary name in `Cargo.toml` (`[[bin]] name` or `package.name`).

---

## Java (Maven / Gradle, Spring Boot)

```dockerfile
# syntax=docker/dockerfile:1
ARG JAVA_VERSION=21
FROM eclipse-temurin:${JAVA_VERSION}-jdk AS build
WORKDIR /src
COPY .mvn .mvn
COPY mvnw pom.xml ./
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q dependency:go-offline
COPY src src
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q package -DskipTests \
 && cp target/*.jar /app.jar

FROM eclipse-temurin:${JAVA_VERSION}-jre AS runtime
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid app --no-create-home app
WORKDIR /app
COPY --from=build /app.jar app.jar
USER 10001:10001
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

- **Gradle:** copy `gradlew gradle/ settings.gradle* build.gradle*` first,
  cache `/root/.gradle`, then run `./gradlew --no-daemon bootJar -x test`.
- **Spring Boot layered jar:** extract layers in the build stage
  (`java -Djarmode=tools -jar app.jar extract --layers --launcher` on Boot ≥ 3.3,
  `-Djarmode=layertools extract` on older versions) and COPY each layer
  separately (dependencies → spring-boot-loader → snapshot-dependencies →
  application) for much better cache reuse.
- Exclude multi-jar outputs (`*-plain.jar`) when copying.

---

## .NET

```dockerfile
# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY *.sln ./
COPY src/MyApp/MyApp.csproj src/MyApp/
RUN --mount=type=cache,target=/root/.nuget/packages dotnet restore
COPY . .
RUN --mount=type=cache,target=/root/.nuget/packages \
    dotnet publish src/MyApp/MyApp.csproj -c Release -o /out --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app
COPY --from=build /out .
# Non-root user built into .NET 8+ images; they listen on 8080 by default
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "MyApp.dll"]
```

The `-chiseled` / `-noble-chiseled` variants are distroless-style and much
smaller. Use them when nothing needs a shell.

---

## Development target (when compose/dev is requested)

Add a `dev` stage that reuses `deps` and runs the watcher. Production builds
aren't affected because they target `runtime`:

```dockerfile
FROM deps AS dev
ENV NODE_ENV=development
COPY . .
CMD ["npm", "run", "dev"]
```

In compose, set `build: { context: ., target: dev }`, bind-mount the source,
and use an anonymous volume for `node_modules` so the host doesn't shadow it.
