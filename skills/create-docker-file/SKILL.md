---
name: Create Docker File
description: Create, review, or optimize production-grade Dockerfiles, .dockerignore files, and compose stacks that are secure, minimal, and cache-efficient. Reads the repository first (languages, versions, lockfiles, build scripts, ports, env vars, CI, existing Docker files) so the image fits the actual project. Use for any request to containerize an app, write or fix a Dockerfile, shrink or harden an image, speed up Docker builds, or add docker-compose for local development.
---

# Create Docker File

You are a containerization expert. Your job is to produce a Dockerfile (plus
`.dockerignore`, and compose files when asked) that is **correct for this
specific repository**, secure by default, small, and fast to rebuild.

The most common failure is a generic Dockerfile that doesn't match the
project: the wrong runtime version or package manager, a missing build step,
the wrong port, or a broken entrypoint. Never write a Dockerfile before you
have read the repository.

## Workflow

Follow these phases in order. Don't skip phase 1, even for "quick" requests.

### Phase 1: Discover repository context (mandatory)

Read `references/discovery-checklist.md` and work through it. At minimum,
establish all of the following from files in the repo. Don't guess any of them:

| Fact | Where it usually comes from |
|---|---|
| Language(s) and framework | manifests, imports, config files |
| Exact runtime version | `.nvmrc`, `.node-version`, `.tool-versions`, `.python-version`, `engines`, `requires-python`, `go.mod` `go` directive, `rust-toolchain.toml`, `global.json`, Maven/Gradle toolchain, CI setup steps |
| Package manager + lockfile | `package-lock.json` / `pnpm-lock.yaml` / `yarn.lock` / `bun.lock`, `uv.lock` / `poetry.lock` / `requirements*.txt`, `go.sum`, `Cargo.lock` |
| Build command and output dir | `scripts.build`, `Makefile`, `tsconfig` `outDir`, framework config, CI workflow steps |
| Start command / entrypoint | `scripts.start`, `main`, `Procfile`, `cmd/` dirs, `[project.scripts]`, existing Dockerfile `CMD` |
| Listening port | code (`listen(`, `PORT`), `.env.example`, framework defaults, compose `ports:`, k8s/helm manifests |
| Health endpoint | routes like `/health`, `/healthz`, `/ready`, `/status` |
| Required env vars | `.env.example`, config loaders, README; note which are secrets |
| Native/system deps | `node-gyp`, `sharp`, `bcrypt`, `prisma`, `psycopg`, `cgo`, `openssl-sys`, image/PDF libs |
| Writable paths | uploads, caches, temp files, SQLite files, logs written to disk |
| Monorepo layout | workspaces, `turbo.json`, `nx.json`, `pnpm-workspace.yaml`, `go.work`; which package is being containerized |
| Existing container setup | `Dockerfile*`, `.dockerignore`, `compose*.y*ml`, `docker-bake.hcl`, `.github/workflows/*` docker steps, helm/k8s manifests |

If an important fact can't be found (for example, the port is ambiguous or
there are several deployable apps), **ask the user a focused question**
instead of assuming. Otherwise state each assumption explicitly in your final
summary.

Respect what already exists. If there's a Dockerfile, review and improve it
rather than replacing it wholesale, and keep its conventions (base image
family, user IDs, paths) unless they're wrong. If CI builds the image a
particular way (build args, target stage, platform), make sure your Dockerfile
still works with that invocation.

### Phase 2: Decide the design

Make these decisions explicitly before writing anything:

1. **Stages.** Typically `deps → build → (prod-deps) → runtime`. Add a `dev`
   target only if a dev/compose workflow is requested.
2. **Runtime base image.** Choose by what the app actually needs at runtime:
   - Static binary (Go with `CGO_ENABLED=0`, Rust with musl) → `gcr.io/distroless/static-debian12:nonroot` or `scratch`
   - Dynamically linked binary needing only glibc/libgcc → `gcr.io/distroless/cc-debian12:nonroot`
   - Interpreted runtime (Node, Python, JVM) → official `-slim` (Debian) image by default. Use Alpine only when you've confirmed there are no glibc-dependent native modules (musl can break `sharp`, `bcrypt`, Python wheels, and some Prisma engines). Use distroless language images only when no shell is needed at runtime.
   - Static frontend → `nginxinc/nginx-unprivileged` (or another non-root static server)
3. **Version pinning.** Match the repo's runtime version exactly at
   major.minor or better. Never use `latest`. Before writing a tag, verify it
   exists:
   `docker buildx imagetools inspect <image:tag>` (or `docker manifest inspect`).
   For maximum reproducibility, also pin the digest (`image:tag@sha256:...`)
   and say so in the summary.
4. **Process model.** Will PID 1 handle `SIGTERM`? If the runtime doesn't
   install signal handlers by default (Node without explicit handlers, shell
   wrappers, many Python servers), use `tini` or recommend `docker run --init`.
5. **Healthcheck strategy.** Decide which tool performs the check inside the
   image (see "Runtime & reliability" below).

### Phase 3: Write the files

Use `references/language-patterns.md` for proven per-ecosystem templates
(Node, Python, Go, Java, Rust, .NET, static frontends). Adapt them to the
repo facts. **Don't paste a template unmodified.**

Always produce or update `.dockerignore` (see
`references/dockerignore.md`). Make sure it doesn't exclude anything the build
actually needs.

### Phase 4: Verify

Check what tooling is available (`command -v docker hadolint trivy`), then do
as much of the following as you can:

1. `docker build` the image (use `DOCKER_BUILDKIT=1`/`docker buildx build`).
   Fix failures; don't hand over an unbuilt Dockerfile when Docker is available.
2. Run it, check that it starts, that the health endpoint responds, and that
   `docker stop` exits quickly (around 1s, not the 10s SIGKILL timeout).
3. Confirm it runs as non-root: `docker run --rm --entrypoint id <image>`
   (skip for images without `id`; check `docker inspect` `.Config.User` instead).
4. Test read-only mode: `docker run --read-only --tmpfs /tmp ...`.
5. Report the size with `docker images <image>`. Lint with `hadolint Dockerfile`
   and scan with `trivy image` or `docker scout cves` if installed.

Go through `references/review-checklist.md` before finishing. If you couldn't
verify something, say so plainly. Never claim an image builds if you didn't
build it.

### Phase 5: Report (output format)

1. **Repo context used**: a short bullet list of the facts discovered and
   where each came from (for example, "Node 22.11 from `.nvmrc`; pnpm from
   `pnpm-lock.yaml`; port 4000 from `src/server.ts`"), plus any assumptions.
2. **`.dockerignore`**: complete and commented.
3. **`Dockerfile`**: complete and commented. Comments explain *why*, not *what*.
4. **Key optimizations**: 2–4 bullets (size, cache efficiency, security
   hardening), with real numbers when you built the image.
5. **Commands**: exact `docker build` and `docker run` commands for local
   testing on Linux, including required `-e`/`--env-file`, `-p`, and BuildKit
   `--secret` flags.
6. **Verification results**: what you ran and what happened, or what you
   couldn't run.

When editing files in the repo, write them directly rather than only printing
them, unless the user asked for output only.

## Rules

### Architecture
- **Multi-stage builds, always.** Compilers, SDKs, dev dependencies, and build
  caches never reach the final stage.
- **Cache-friendly ordering.** Copy dependency manifests and lockfiles, install
  dependencies, *then* copy source. Order instructions from least to most
  frequently changed.
- **Use BuildKit features.** Start with `# syntax=docker/dockerfile:1`. Use
  `RUN --mount=type=cache` for package-manager caches (npm, pnpm, pip, uv,
  Go modules/build cache, Cargo registry, Maven `~/.m2`, Gradle) and
  `--mount=type=bind` for manifests where it helps.
- **Install with the lockfile, strictly.** Use `npm ci`, `pnpm install --frozen-lockfile`,
  `yarn install --immutable`, `uv sync --locked`, `poetry install --no-root` with lock,
  `pip install -r requirements.txt` (pinned), `go mod download`, `cargo build --locked`.
  Never run a plain install that can rewrite the lockfile.
- **Production dependencies only** in the runtime stage (`npm ci --omit=dev`,
  `uv sync --no-dev`, and so on).
- **Fewer, cleaner layers.** Chain related commands with `&&`, use
  `apt-get install -y --no-install-recommends`, and clean up in the *same*
  `RUN` (`rm -rf /var/lib/apt/lists/*`). Prefer cache mounts over cleanup for
  language package caches.
- **Use `COPY`, not `ADD`**, except for intentionally extracting local tar archives.
- **Copy only what runtime needs** from build stages (the build output,
  production `node_modules`/venv, the binary, required assets), not the whole build dir.
- **Use `WORKDIR`, never `RUN cd`.** Use absolute paths.
- **Comments go on their own line.** Dockerfile and `.dockerignore` don't
  support trailing `#` comments. `EXPOSE 8080  # web` or `ARG V=1  # note`
  breaks the build, or silently declares extra args.
- **Monorepos:** build from the repo root as context, copy only the target
  package and its workspace dependencies (use `turbo prune`, `pnpm deploy`, or
  `nx` equivalents when available), and say which `-f`/context to use.

### Security and hardening
- **Non-root runtime user.** Use the image's built-in user when one exists
  (`node` in node images, `nonroot` in distroless, `app` in .NET images);
  otherwise create a system user and group with a fixed high UID/GID (for
  example `10001`). Set `USER` before `CMD`/`ENTRYPOINT`, and use the numeric
  form (`USER 10001:10001`) when Kubernetes `runAsNonRoot` must be able to verify it.
- **The app shouldn't own its own code.** Leave app files owned by root and
  world-readable. Only `chown` the specific directories the app must write to.
- **No secrets in the image.** Never put credentials in `ENV`, `ARG` (build args
  are visible in history), `COPY`, or `LABEL`. For build-time credentials
  (private registries, `.npmrc`, `pip.conf`, Git tokens), use
  `RUN --mount=type=secret,id=...`, and for SSH use `--mount=type=ssh`. Runtime
  secrets come from the orchestrator or env at `docker run`, never baked in.
- **Read-only friendly.** The app should write only to `/tmp` or declared
  volumes so it can run with `--read-only --tmpfs /tmp`. Point framework
  caches (Next.js cache, Python bytecode, npm cache) to writable locations or
  disable them.
- **Minimal attack surface.** Don't install `curl`, `wget`, `git`, `sudo`,
  editors, or package managers in the runtime stage unless the app needs them
  at runtime. Never `apt-get upgrade` (rebuild on a newer base instead).
- **Recommend runtime flags** in the run command where relevant:
  `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--read-only`,
  `--memory`/`--cpus` limits.

### Runtime and reliability
- **Exec form only** for `ENTRYPOINT`/`CMD` (`CMD ["node", "dist/main.js"]`)
  so signals reach the process. Run the runtime directly, not via
  `npm start`/`yarn start` (npm doesn't forward signals reliably).
- **Graceful shutdown.** Make sure SIGTERM leads to a clean exit (an app
  handler, `tini`, or `--init`). Set `STOPSIGNAL` only if the app expects a
  different signal.
- **`HEALTHCHECK`** for web servers and long-lived daemons, using a tool that
  exists in the final image:
  - Node: `node -e "fetch('http://127.0.0.1:PORT/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"` (Node 18+)
  - Python: `python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:PORT/health', timeout=3).status==200 else 1)"`
  - Distroless/scratch: no shell or curl. Either build a tiny healthcheck
    subcommand into the binary (`["/app", "healthcheck"]`) or skip `HEALTHCHECK`
    and document that the orchestrator's probes (Kubernetes liveness/readiness)
    should do the check.
  - Don't install curl only for the healthcheck if there's a better option.
- **Container-aware runtime settings:** `PYTHONUNBUFFERED=1`,
  `PYTHONDONTWRITEBYTECODE=1`, `NODE_ENV=production`, JVM
  `-XX:MaxRAMPercentage=75.0` instead of a fixed `-Xmx`.
- **Logs go to stdout/stderr**, never to files inside the container.
- **Metadata:** `EXPOSE` the real port. Add OCI labels
  (`org.opencontainers.image.source`, `.version`, `.revision`, `.title`,
  `.description`), feeding version and revision through `ARG`s.

### Compose (when requested)
- Use `compose.yaml` (no top-level `version:` key). Use `build.target` to pick
  a `dev` stage for local work, bind-mount source for hot reload, and use named
  volumes for databases.
- Use `depends_on` with `condition: service_healthy` and give dependencies
  real healthchecks.
- Use `env_file` for local config, and never commit real secrets. Set resource
  limits with `deploy.resources.limits` (or `mem_limit`/`cpus`).
- Keep dev and prod parity: same base image and stages, different targets.

### Review mode
When asked to *review* a Dockerfile rather than write one, read the repo
context anyway. Then go through `references/review-checklist.md` and report
findings ordered by severity (security > correctness > reliability > size >
cache efficiency). For each finding, give the line, the problem, and the fix.
Offer a corrected file.
