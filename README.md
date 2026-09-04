# claude-statusline

A two-line statusline for [Claude Code](https://claude.com/claude-code), in one
file of bash.

```
moonlit-society · main ↑2 ● · Opus 5 (1M) · $3.87 · +142/−38 · 1h15m
ctx [█░░░░░░░░░] 7% 70K/1M   5h [█████░░░░░] 52% ⟳17:08   7g [█████████░] 91%
```

Line one: working directory, branch with divergence and a dot when dirty, the
model, session cost, lines added and removed, elapsed time. Line two: three
bars — context window, the 5-hour rate limit with its reset clock, and the
7-day one. Each bar is 10 cells, so **one cell is 10%**, and bar and percentage
change colour together: green under 50%, yellow from 50, orange from 75, red
from 90.

## Install

```sh
bash -c "$(curl -fsSL https://github.com/Galfurian/claude-statusline/releases/latest/download/install.sh)"
```

Or, the better habit — read it first:

```sh
curl -fsSL https://github.com/Galfurian/claude-statusline/releases/latest/download/install.sh -o install.sh
less install.sh && bash install.sh
```

Then start a new Claude Code session.

## What it installs

Exactly two things:

- `~/.claude/statusline.sh` — the script, mode 755
- one key, `.statusLine`, in `~/.claude/settings.json`

Nothing else is touched. Your other settings keys are merged around, not
replaced, and a timestamped backup is taken immediately before any change. If
`settings.json` already names another tool's statusline, the installer asks
before replacing it — and if it cannot ask, because it is running from a pipe,
it stops and tells you the command to force it.

To remove all of it: `bash install.sh --uninstall`.

## Requirements

bash 4.2 or newer and `jq`. `git` is optional — without it you simply lose the
branch segment. macOS ships bash 3.2, so `brew install bash` is needed there;
the installer checks this and says so rather than half-installing.

A reasonably recent Claude Code, too. The context bar needs
`context_window.used_percentage` in the JSON Claude Code writes to the
statusline's stdin, and the two rate-limit bars need `rate_limits` — added in
roughly v2.1.6 and v2.1.80. Every segment hides itself when its field is
absent, so on an older Claude Code nothing breaks: you get the first line and
no bars, which is worth knowing before you go looking for the bug.

## Why you can check this before running it

Piping a stranger's script into your shell deserves some scepticism, so:

- the one-liner resolves to the **immutable asset of the latest release**, not
  to a branch that can change under you
- `install.sh` carries the pinned `VERSION` and the expected `SHA256` of
  `statusline.sh`, and verifies the payload before installing it. A mismatch
  aborts and prints expected vs got
- CI refuses to let the pinned digest drift from the file it claims to describe
- the installer is ~230 lines and the statusline is ~180. Both are meant to be
  read in one sitting

The statusline itself makes **no network calls, reads no credentials, and
caches nothing on disk**. Every value comes from the JSON Claude Code writes to
its stdin. It costs one `jq` and one `git` per render, about 14 ms.

## Tuning

Set these in the command, e.g.
`"command": "BAR_W_CTX=20 bash ~/.claude/statusline.sh"`, or edit the block at
the top of the script.

| Variable | Default | Meaning |
|---|---|---|
| `BAR_W_CTX` | `10` | cells in the context bar |
| `BAR_W_LIM` | `10` | cells in the rate-limit bars |
| `T_MEDIUM` | `50` | percentage at which the colour turns yellow |
| `T_WARN` | `75` | ... orange |
| `T_CRIT` | `90` | ... red |
| `G_FILL` | `█` | filled cell |
| `G_EMPTY` | `░` | empty cell |
| `NO_COLOR` | unset | set to anything to disable colour |

Keeping both widths at 10 is what makes one cell mean 10%.

## Installer flags

| Flag | Effect |
|---|---|
| *(none)* | install, or update in place; a second run is a no-op |
| `--dry-run` | print what would happen, write nothing |
| `--force` | replace another tool's statusLine without asking |
| `--uninstall` | remove the script and the settings key, keep every other key |
| `--version` | print the pinned version |

## Contributing

```sh
./test.sh          # 47 render assertions
./test-install.sh  # 52 installer assertions, against a fake HOME
```

Neither suite touches your real `~/.claude` or the network. After changing
`statusline.sh`, run `./scripts/sync-digest.sh` so the pin in `install.sh`
stays true — CI fails if you forget.

MIT.
