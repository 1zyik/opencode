# Repository discovery checklist

Work through this before writing or reviewing any Dockerfile. Use fast,
read-only commands (`ls`, `find`, `grep`/`rg`, reading files). Record each
fact and the file it came from, because the final report must cite them.

## 1. Map the repo

```sh
git rev-parse --show-toplevel 2>/dev/null; git ls-files | head -200
ls -la
find . -maxdepth 3 \( -name node_modules -o -name .git -o -name .venv -o -name target -o -name dist \) -prune -o \
  \( -name 'package.json' -o -name 'pyproject.toml' -o -name 'requirements*.txt' -o -name 'go.mod' -o -name 'Cargo.toml' \
     -o -name 'pom.xml' -o -name 'build.gradle*' -o -name '*.csproj' -o -name 'Gemfile' -o -name 'composer.json' \
     -o -name 'Dockerfile*' -o -name '*.dockerfile' -o -name 'compose*.y*ml' -o -name 'docker-compose*.y*ml' \
     -o -name '.dockerignore' -o -name 'Procfile' -o -name 'Makefile' \) -print
```

Decide:
- **Single app or monorepo?** Look for workspaces (`package.json` `workspaces`,
  `pnpm-workspace.yaml`, `turbo.json`, `nx.json`, `lerna.json`, `go.work`,
  Cargo `[workspace]`, multi-module Maven/Gradle).
- **Which deployable is being containerized?** If there are several and the
  user didn't say, ask.

## 2. Runtime version (pin to this)

Check in this priority order, and stop at the first authoritative source:

| Ecosystem | Sources |
|---|---|
| Node | `.nvmrc`, `.node-version`, `.tool-versions`, `package.json` `engines.node`, `volta.node`, CI `actions/setup-node` `node-version` |
| Python | `.python-version`, `.tool-versions`, `pyproject.toml` `requires-python`, `runtime.txt`, CI `setup-python` |
| Go | `go.mod` `go` / `toolchain` directives |
| Rust | `rust-toolchain.toml` / `rust-toolchain`, `Cargo.toml` `rust-version` |
| Java/Kotlin | Maven `maven.compiler.release` / `java.version`, Gradle `toolchain { languageVersion }`, `.sdkmanrc`, CI `setup-java` |
| .NET | `global.json`, `<TargetFramework>` in `*.csproj` |
| Ruby / PHP | `.ruby-version`, `Gemfile` `ruby`; `composer.json` `require.php` |

If sources disagree (for example `.nvmrc` says 20 and CI uses 22), point out
the conflict and prefer what CI or production actually runs, or ask.

## 3. Dependencies and package manager

- Identify the lockfile. **Its presence decides the package manager**:
  `package-lock.json` → npm, `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn (check
  `.yarnrc.yml` for Berry/PnP), `bun.lock`/`bun.lockb` → bun, `uv.lock` → uv,
  `poetry.lock` → poetry, `Pipfile.lock` → pipenv.
- `package.json` `packageManager` field → use that exact version through corepack.
- **No lockfile?** Warn that builds won't be reproducible and recommend
  generating one.
- Private registries: `.npmrc`, `.yarnrc.yml`, `pip.conf`, `uv` index config,
  `GOPRIVATE`, `settings.xml`. These need BuildKit secret mounts, never `COPY`.
- Native modules or system libraries. Grep the manifests for: `sharp`,
  `bcrypt`, `argon2`, `canvas`, `node-gyp`, `prisma`, `better-sqlite3`,
  `puppeteer`/`playwright` (need Chromium), `psycopg` (non-binary), `mysqlclient`,
  `lxml`, `Pillow`, `numpy`/`scipy` (wheels usually OK on glibc), Go `import "C"`,
  Rust `openssl-sys`/`-sys` crates. These decide between slim and alpine and
  which build/runtime packages are needed.
- **Prisma:** needs `prisma generate` at build time and the correct
  `binaryTargets` for the runtime OS (for example `debian-openssl-3.0.x`, or
  `linux-musl-openssl-3.0.x` on alpine), plus `openssl` at runtime.

## 4. Build and start

- Build command: `package.json` `scripts.build`, `Makefile`, framework CLI,
  CI workflow build steps (often the most accurate source).
- Build output: `tsconfig.json` `outDir`, `dist/`, `build/`, `.next/`
  (check `next.config.*` `output: 'standalone'`), `target/*.jar`,
  `bin/Release/.../publish`.
- Start command: `scripts.start`, `main`/`exports`, `Procfile` `web:`,
  `[project.scripts]`, `cmd/<name>/main.go`, Spring Boot jar, ASGI/WSGI app
  path (`uvicorn module:app`, `gunicorn module:app`).
- Production server: if Python uses the Flask/Django dev server, switch to
  gunicorn/uvicorn and say so.
- Other runtime steps: migrations (prefer a separate one-off command or job
  over running them in `CMD`), asset compilation, codegen.

## 5. Network and health

```sh
rg -n --no-heading -e 'listen\(' -e 'PORT' -e 'port\s*[:=]' -e 'EXPOSE' -e 'addr\s*:?=' \
   -g '!node_modules' -g '!*.lock' . | head -40
rg -n --no-heading -e '/health' -e '/healthz' -e '/ready' -e '/live' -e '/status' -e '/ping' \
   -g '!node_modules' . | head -20
```

- Make sure the server binds `0.0.0.0` (not `127.0.0.1`/`localhost`), or it
  won't be reachable from outside the container. Flag it if it doesn't.
- Note the default port and whether it can be overridden with an env var.

## 6. Configuration and secrets

- Read `.env.example` / `.env.sample` / config loaders for required vars.
  Classify each var: **secret** (passed at runtime, never baked in), **build-time
  public** (for example `NEXT_PUBLIC_*`, `VITE_*`, which get inlined into the
  bundle, so build args are acceptable only for non-secret values), or
  **runtime config**.
- Never read or print actual `.env` contents. Just confirm `.env*` is excluded
  by `.dockerignore`.

## 7. Filesystem writes

Grep for disk writes (`fs.write`, `open(..., 'w')`, upload dirs, `sqlite`,
`logs/`, cache dirs). Each writable path must be `/tmp`, a declared `VOLUME`,
or a directory owned by the app user, so `--read-only` works.

## 8. Existing container and deploy setup

- Existing `Dockerfile*` / `.dockerignore`: read them fully. Keep working
  conventions, and fix problems.
- `compose*.yml`: ports, env, volumes, dependent services (DBs, caches), and
  whether healthchecks are expected.
- `.github/workflows/*`, `.gitlab-ci.yml`, `Jenkinsfile`, `cloudbuild.yaml`,
  `docker-bake.hcl`: how the image is built (context path, `--target`,
  `--build-arg`, `--platform`, registry). Your Dockerfile must keep working with
  this invocation.
- k8s/helm manifests: `securityContext` (`runAsUser`, `readOnlyRootFilesystem`),
  probes, ports. Match UID and port, and stay compatible with read-only root.
- Target platforms: if CI builds `linux/arm64` or multi-arch, use
  `--platform=$BUILDPLATFORM` in build stages with `TARGETOS`/`TARGETARCH` for
  cross-compilation (Go and Rust especially).

## 9. Summarize before writing

Write a short internal summary: runtime+version, package manager, build cmd,
output path, start cmd, port, health path, env vars (secret vs not),
native deps, writable paths, monorepo target, CI constraints. If any critical
item is unknown, ask the user before proceeding.
