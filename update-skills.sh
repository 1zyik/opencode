#!/usr/bin/env bash
# Update OpenCode skills that are installed as clones as submodules in vendor/ and linked into
# skills/ via relative links. Shows incoming changes per repo and asks before pulling.
#   ./update-skills.sh          review + confirm each repo
#   ./update-skills.sh --check  only report what's new, change nothing
set -uo pipefail

REPOS=(anatomy archify security-audit-skill impeccable diagram-design superpowers taste-skill hallmark caveman stop-slop understand-anything logo-design-skill humanize-writing-skill)
CHECK_ONLY=false; [[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

for name in "${REPOS[@]}"; do
  repo="$(cd "$(dirname "$0")" && pwd)/vendor/$name"
  if [[ ! -e "$repo/.git" ]]; then echo "!! $name: not a submodule checkout at $repo, skipping"; continue; fi

  if ! git -C "$repo" fetch -q 2>/dev/null; then echo "!! $name: fetch failed"; continue; fi
  count=$(git -C "$repo" rev-list --count HEAD..@{u})
  if [[ "$count" == 0 ]]; then echo "✓ $name: up to date ($(git -C "$repo" log -1 --format=%h))"; continue; fi

  echo
  echo "=== $name: $count new commit(s) ==="
  git -C "$repo" log --oneline HEAD..@{u} | head -20
  echo "--- changed files (sparse checkouts show only what you have checked out) ---"
  git -C "$repo" diff --stat HEAD..@{u} -- $(git -C "$repo" sparse-checkout list 2>/dev/null || echo .) | tail -25
  # Flag script changes: these run on your machine, so they deserve a look
  scripts=$(git -C "$repo" diff --name-only HEAD..@{u} -- $(git -C "$repo" sparse-checkout list 2>/dev/null || echo .) | grep -E '\.(sh|mjs|cjs|js|ts|py)$' || true)
  [[ -n "$scripts" ]] && { echo "--- ⚠ scripts changed (review with: git -C $repo diff HEAD..@{u} -- <file>) ---"; echo "$scripts" | head -15; }

  $CHECK_ONLY && continue
  read -r -p "Pull $name? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    if git -C "$repo" pull -q --ff-only; then
      echo "✓ $name updated to $(git -C "$repo" log -1 --format=%h)"
      # Understand-Anything runs a built TypeScript core; rebuild so dist/ matches the new source
      if [[ "$name" == "understand-anything" ]]; then
        (cd "$repo/understand-anything-plugin" && npx -y pnpm@10 install --frozen-lockfile >/dev/null \
          && npx -y pnpm@10 --filter @understand-anything/core build >/dev/null) \
          && echo "  ✓ core rebuilt" || echo "  !! core rebuild failed; run pnpm install + build in $repo/understand-anything-plugin"
      fi
    else
      echo "!! $name: pull failed (local changes or diverged history?)"
    fi
  else
    echo "- $name skipped"
  fi
done
