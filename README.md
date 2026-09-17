# .linuxjjk

**A portable Linux environment in one directory.** Drop it on any box — new or already lived-in —
run `init`, and you have the same shell, git tooling, editor setup and keybindings you had
everywhere else.

The guiding constraint is that it never breaks what is already there. `init` does not overwrite or
delete a file it did not create; anything unexpected is reported and left alone.

```bash
git clone <this> ~/.linuxjjk      # or just copy the directory
~/.linuxjjk/init
exec bash -l                      # pick up the new shell config
```

`init` is safe to re-run as often as you like — it is a health check as much as an installer.
Nothing here depends on the directory being called `.linuxjjk`; every path is derived at runtime, so
rename or relocate it freely.

## What `init` checks

Each check reports, repairs what it can, then reports again. Re-running after a successful run is
always a screen of green.

| # | Check | What it does |
|---|---|---|
| 1 | `~/.gitid` | Prompts for and writes this machine's git identity. Machine-local, never copied. |
| 2 | `~/.gitconfig` | Symlinks it to the portable `.gitconfig` here. |
| 3 | `~/.aliases` | Symlinks it to `.aliases` here. |
| 4 | `~/.bashrc` hook | Gets `bashrc_jjk` sourced by every new interactive shell — a drop-in under `~/.bashrc.d` where the distro loops over that directory, otherwise a marker-delimited block appended to `~/.bashrc`. |
| 5 | VS Code setup | Installs/verifies the Brief–SlickEdit parity setup in `vscode-setup/` (settings, keybindings, fonts, helper extension). |
| 6 | `bin/` | Restores the execute bit, which a round trip through a vfat USB stick silently drops. |
| 7 | Cinnamon shortcuts | Installs the monitor-input keybinding. Says so and moves on where Cinnamon is not running. |
| 8 | Groups | Offers to add you to `dialout` (serial/USB-serial) and `i2c` (`ddcutil`). Last, because it is the only check that wants a sudo password. |

Output colours mean one specific thing:

| Colour | Meaning |
|---|---|
| green | checked, already correct — *or* was missing and `init` fixed it |
| yellow | might be off, might be deliberate; nothing `init` can safely do |
| red | **still wrong after `init` ran** |

Something missing that `init` then creates is **green**, not a failure. Red is reserved for the
state the run actually leaves behind.

## Layout

```
~/.linuxjjk/
├── init                        installer + health checker (bash)
├── bashrc_jjk                  bash config, sourced by ~/.bashrc
├── .aliases                    shell functions, sourced by bashrc_jjk
├── .gitconfig                  portable git config; ~/.gitconfig symlinks here
├── bin/                        scripts that land on PATH
│   ├── jjk_gitlog.py           shared rendering engine for the log views
│   ├── git-trunk               git trunk  — first-parent log, no side branches
│   ├── git-tree                git tree   — every local branch vs the remote trunk
│   ├── git-sl                  git sl     — the stack: local + origin/<user>/* since base
│   ├── git-fsl                 git fsl    — this branch's own commits back to its base
│   ├── git-tidy-branches       find/delete local branches already merged (squash-merge aware)
│   ├── git-meld-wrapper.sh     git difftool --dir-diff wrapper that keeps copy-back working
│   ├── mouse-buttons           print Solaar's name for each button on a Logitech mouse
│   └── go_home_helper.sh       switch the monitor to DisplayPort from a desktop keybinding
├── vscode-setup/               VS Code Brief/SlickEdit parity setup (own installer + doc)
├── setting-up-linuxjjk.md      the deep doc: every check, every trap, in detail
└── README.md                   this file
```

## Shell

`bashrc_jjk` is the portable half: prompt (with branch name), colour variables, history settings,
`PATH` additions for `~/.local/bin` and `bin/`, and it sources `.aliases`.

`.aliases` is shell *functions*, not aliases, so they compose and take arguments:

| | |
|---|---|
| `work` / `home` | switch the monitor between inputs over DDC/CI (`ddcutil`) |
| `code` / `vs` / `start` | launch VS Code, SlickEdit, or a file manager detached from the terminal — `code` opens a new window only when none is on the current desktop |
| `cgrep` `hgrep` `cppgrep` `hppgrep` `pygrep` `agrep` | recursive grep scoped to one family of source files |
| `ffind` | `find . -type f -name …`, quietly |
| `detach` | run anything fully detached, no job-control noise |

### Per-machine customisation

Anything true of only one box goes in **`~/.bashrc_local`**, which stays behind when the directory
travels. `bashrc_jjk` sources it if present, and otherwise prints a one-line note that you might
want one. Typical contents: a `umask` for a particular NFS mount, an SDK's `setenv` script, licence
server variables, extra `PATH` entries.

`PATH` and the `COLOR_*` variables are already set by the time it is sourced, so a local file can
use them.

## git

`.gitconfig` here is included by `~/.gitconfig` (a symlink), and it in turn `[include]`s
`~/.gitid` — so the portable config carries the tooling and aliases while the identity stays
machine-local. Meld is wired up as both difftool and mergetool; `push.default`, LFS filters and
colour settings come along too.

Aliases include `db` `dt` `dp` `changes` `mt` `lol` `low` `sb` `rbi` `rbc` `wc` `s` `top` `why`, plus
the four `bin/` log views above, which all share one renderer (`jjk_gitlog.py`) so they stay
consistent and fit on one screen.

## Monitor input switching

The `work` / `home` functions drive a DELL U4025QW over DDC/CI with `ddcutil`, which needs the
`i2c` group (check 8). `bin/go_home_helper.sh` is the same thing reachable from a desktop
keybinding: it sources `bashrc_jjk` itself, because a keybinding runs a non-interactive shell where
`~/.bashrc` returns before it ever reaches the hook. `init` binds it to
<kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>NumPad&nbsp;7</kbd> under Cinnamon, registering both `KP_7` and
`KP_Home` so NumLock does not matter.

## VS Code

`vscode-setup/` is a self-contained sub-installer for Brief/SlickEdit editing parity: a settings
fragment merged into your `settings.json`, a `keybindings.json`, Cascadia Code fonts, and a small
helper extension (`.vsix`, with source). `init` calls it, stamps a hash of what it installed, and
notices when the shipped payload moves on. See `vscode-setup/setting-up-vscode.md`.

## Machine-local files, deliberately not in here

| Path | Why it stays behind |
|---|---|
| `~/.gitid` | Identity differs per machine; copying it would commit under the wrong name. |
| `~/.bashrc_local` | Per-machine shell setup. |
| `~/.gitconfig`, `~/.aliases` | Symlinks into this directory, created by `init`. |

## Requirements

`bash` and `git` are the only hard ones. Everything else is optional and skipped silently when
absent: `ddcutil` (monitor switching), `wmctrl` (the current-desktop test behind `code`), `gsettings`
(Cinnamon keybindings), the `code` CLI (VS Code setup), `python3` (the git log views).

## Gotchas

- **Run `init` from the copy you are installing**, not from the USB stick. It configures the tree it
  lives in.
- **vfat sticks cannot store the execute bit**, and `chmod` on one *succeeds* while changing
  nothing. `init` re-tests rather than trusting it, and says plainly when a copy is running from a
  stick.
- **Startup files must not print to stdout** beyond what is intended — `scp` and friends parse it.

## Docs

- **`setting-up-linuxjjk.md`** — the long form: every check explained, the design rules, and the
  traps found the hard way. Start there before changing `init`.
- **`vscode-setup/setting-up-vscode.md`** — the editor parity work in its own detail.
