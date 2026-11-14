#!/usr/bin/env bash
# Restore this OpenCode config on a machine: fetch skill submodules, link the config dir,
# rebuild what needs building. Safe to re-run.
#   git clone --recursive git@github.com-1zyik:1zyik/opencode.git ~/repos/03-1zyik/opencode
#   ~/repos/03-1zyik/opencode/bootstrap.sh
set -euo pipefail
R="$(cd "$(dirname "$0")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

echo "→ submodules (shallow)"
git -C "$R" submodule update --init --depth 1

echo "→ sparse checkouts for the large upstream repos (skill folders only)"
sparse() { git -C "$R/vendor/$1" sparse-checkout set "${@:2}" >/dev/null && echo "  $1: ${*:2}"; }
sparse archify archify
sparse caveman skills src/plugins/opencode/commands
sparse hallmark skills
sparse impeccable .opencode
sparse taste-skill skills
sparse understand-anything understand-anything-plugin

echo "→ link $CFG -> $R"
if [ -L "$CFG" ]; then ln -sfn "$R" "$CFG"
elif [ -e "$CFG" ]; then mv "$CFG" "$CFG.pre-repo.$(date +%s)"; ln -s "$R" "$CFG"; echo "  existing config moved aside"
else mkdir -p "$(dirname "$CFG")"; ln -s "$R" "$CFG"; fi
ln -sfn "$R/vendor/understand-anything/understand-anything-plugin" "$HOME/.understand-anything-plugin"

# Superpowers plugin path in opencode.jsonc is absolute (OpenCode doesn't expand ~)
sed -i "s|\"/[^\"]*/vendor/superpowers\"|\"$R/vendor/superpowers\"|" "$R/opencode.jsonc"

echo "→ build Understand-Anything core"
(cd "$R/vendor/understand-anything/understand-anything-plugin" \
  && npx -y pnpm@10 install --frozen-lockfile >/dev/null \
  && npx -y pnpm@10 --filter @understand-anything/core build >/dev/null) && echo "  ok" || echo "  !! build failed (needs Node 22+)"

broken=$(find "$R/skills" "$R/commands" -xtype l)
[ -z "$broken" ] && echo "→ all skill/command links resolve" || { echo "!! broken links:"; echo "$broken"; }

cat <<'EOF'

Not in this repo, restore by hand:
  ~/.secrets/                 github-1zyik, github-sid, exa-api-key, sid-mongo-prod (chmod 600)
  ~/.bashrc.d/                archify, superpowers, chrome-path (CHROME_PATH must match this machine)
  service.json                created by OpenCode on first run
  MCP OAuth sign-ins          firecrawl, prembly: /mcps in the TUI
EOF
