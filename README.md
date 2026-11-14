# OpenCode config

Global OpenCode config. `~/.config/opencode` is a symlink to this repo.

| Path | What |
|---|---|
| `opencode.jsonc` | MCP servers and plugins. Secrets come from `{file:~/.secrets/...}`, never inline. |
| `cli.json` | TUI settings |
| `agent/` | Custom agents |
| `skills/` | Own skills (`create-docker-file`) plus relative links into `vendor/` |
| `commands/` | Own commands plus relative links into `vendor/` |
| `vendor/` | Third-party skill repos as shallow git submodules, pinned to reviewed commits |

## Restore on a new machine

```sh
git clone --recursive git@github.com-1zyik:1zyik/opencode.git ~/repos/03-1zyik/opencode
~/repos/03-1zyik/opencode/bootstrap.sh
```

The script prints what it can't restore (secrets, shell env, OAuth sign-ins).

## Update third-party skills

```sh
./update-skills.sh --check   # what's new, changes nothing
./update-skills.sh           # per repo: commits, changed files, flagged scripts, y/N to pull
git add vendor && git commit -m "chore: bump skills"   # record the reviewed versions
```

## Add a skill

```sh
git submodule add --depth 1 <url> vendor/<name>
git config -f .gitmodules submodule.vendor/<name>.shallow true
ln -s ../vendor/<name>/<path-to-skill-dir> skills/<id>
```

Then add `<name>` to `REPOS` in `update-skills.sh`.

`service.json` holds the local service password and is gitignored.
