# .dockerignore

Always create or update `.dockerignore` in the same directory as the build
context root (not necessarily next to the Dockerfile). It shrinks the context,
speeds up builds, keeps caches stable, and stops secrets from leaking into
layers through `COPY . .`.

## Base template

Start from this, then **remove any line that excludes something the build
needs**, and add the stack-specific entries below.

```gitignore
# --- VCS & CI ---
.git
.gitignore
.gitattributes
.github
.gitlab-ci.yml

# --- Secrets & local config (never ship these) ---
.env
.env.*
!.env.example
*.pem
*.key
*.crt
*.p12
id_rsa*
.npmrc
.pypirc
secrets/

# --- Docker files themselves (changes shouldn't bust the COPY . . cache) ---
Dockerfile*
*.dockerfile
.dockerignore
docker-compose*
compose*.y*ml

# --- Editors, OS, tooling ---
.vscode
.idea
*.swp
.DS_Store
Thumbs.db
.opencode
.claude

# --- Docs & tests (keep if the build or runtime needs them) ---
# Keep README.md only if the build needs it (e.g. pyproject `readme =`); otherwise delete the next line
*.md
!README.md
docs/
coverage/
.nyc_output/

# --- Logs & temp ---
*.log
tmp/
.cache/
```

## Stack-specific additions

| Stack | Add |
|---|---|
| Node | `node_modules`, `npm-debug.log*`, `.pnpm-store`, `.yarn/cache` (keep `.yarn/releases` for Berry), `.next`, `.nuxt`, `.turbo`, `dist`, `build`, `out` |
| Python | `__pycache__`, `*.py[cod]`, `.venv`, `venv`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`, `*.egg-info`, `dist`, `build` |
| Go | `bin/`, `vendor/` (only if not building with `-mod=vendor`), `*.test`, `*.out` |
| Rust | `target/` |
| Java | `target/`, `build/`, `.gradle/`, `out/` (keep `.mvn/` and `gradle/wrapper`) |
| .NET | `bin/`, `obj/`, `*.user` |
| Terraform/infra in repo | `.terraform/`, `*.tfstate*`, `infra/`, `k8s/`, `helm/` (unless needed) |

## Rules

- **Check every exclusion against the Dockerfile.** If the Dockerfile `COPY`s
  something, or the build reads it (README for Python packaging, `.npmrc`
  through a secret mount is fine, `.yarn/releases`, `.mvn/wrapper`, codegen
  inputs, `prisma/schema.prisma`, `public/`), it must **not** be ignored.
- Excluding `dist`/`build` is correct when the image builds the output itself.
  If the Dockerfile copies prebuilt artifacts, don't exclude them.
- Prefer an allowlist for very large or sensitive repos: `*` then `!src`,
  `!package.json`, and so on.
- In a monorepo built from the root, exclude other apps' heavy dirs, and
  remember that patterns are relative to the context root.
- Per-Dockerfile ignore files (`api.Dockerfile.dockerignore`, next to the
  Dockerfile) take precedence. Use them when one repo has several images with
  different needs.
- Comment each section, as in the template. Comments must be on their own line:
  `.dockerignore` (like Dockerfiles) does not support trailing `#` comments.
