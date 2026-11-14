# Dockerfile review checklist

Use this before handing over any Dockerfile, and as the rubric in review
mode. Report findings by severity: **Security > Correctness > Reliability >
Size > Cache efficiency.**

## Security
- [ ] Final stage runs as a non-root user (`USER` set, numeric UID preferred for k8s `runAsNonRoot`)
- [ ] No secrets in `ENV`, `ARG`, `LABEL`, or copied files. Build-time creds use `--mount=type=secret` / `--mount=type=ssh`
- [ ] `.dockerignore` excludes `.env*`, keys, certs, `.git`, `.npmrc`/`.pypirc`
- [ ] App code is root-owned and read-only to the app user. Only required dirs are writable
- [ ] Runtime stage has no compilers, package-manager caches, `curl`/`wget`/`git`, or dev dependencies unless required
- [ ] No `apt-get upgrade`, `chmod 777`, `sudo`, or `--privileged` assumptions
- [ ] Base images come from trusted official sources, pinned by version (and digest if reproducibility matters)
- [ ] Works with `--read-only --tmpfs /tmp --cap-drop=ALL --security-opt=no-new-privileges`

## Correctness
- [ ] Runtime version matches the repo (`.nvmrc`, `go.mod`, `requires-python`, and so on) and the CI setup
- [ ] Package manager matches the lockfile. Install is strict (`npm ci`, `--frozen-lockfile`, `--locked`)
- [ ] Build command and output path match the project config
- [ ] Entry command matches the real entry point and runs the runtime directly (not `npm start`)
- [ ] Server binds `0.0.0.0`. `EXPOSE` matches the real port
- [ ] Native deps are compatible with the base image libc (glibc vs musl). Required runtime `.so` libs are present
- [ ] `.dockerignore` doesn't exclude anything the build or runtime needs
- [ ] Works with how CI builds the image (context, `--target`, build args, platforms)

## Reliability
- [ ] Exec-form `CMD`/`ENTRYPOINT`
- [ ] SIGTERM handled: app handler, `tini`, or a documented `--init`. `docker stop` returns quickly
- [ ] `HEALTHCHECK` uses a tool that exists in the image (or is documented as delegated to orchestrator probes)
- [ ] Logs go to stdout/stderr
- [ ] Memory-aware runtime settings (JVM `MaxRAMPercentage`, Node `--max-old-space-size` if needed)
- [ ] Migrations aren't silently run on every container start (prefer a separate job/command)

## Size
- [ ] Multi-stage: only build outputs and production dependencies reach the final stage
- [ ] Smallest base that works (distroless/static > distroless/cc > slim > full). Alpine only if musl-safe
- [ ] `--no-install-recommends` and apt lists removed in the same layer
- [ ] No test files, docs, source maps, or build caches in the final image unless needed

## Cache efficiency
- [ ] `# syntax=docker/dockerfile:1` present (BuildKit features)
- [ ] Manifests and lockfiles copied and dependencies installed before `COPY . .`
- [ ] `RUN --mount=type=cache` for package-manager caches
- [ ] Instructions ordered from least to most frequently changed
- [ ] Docker files and docs excluded from context so edits don't bust the source `COPY` cache
- [ ] Volatile `ARG`s (version, git SHA) declared late, just before the `LABEL` that uses them

## Lint and scan (when available)
```sh
hadolint Dockerfile
docker build -t app:review . && docker images app:review
trivy image --severity HIGH,CRITICAL app:review    # or: docker scout cves app:review
docker run --rm --entrypoint id app:review         # expect a non-zero uid
```
