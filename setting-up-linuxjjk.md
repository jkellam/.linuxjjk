# The `~/.linuxjjk` portable setup

Continuation doc. If you're a fresh Claude session reading this, this is the
whole state of the work — read it and carry on. It is the companion to
`vscode-setup/setting-up-vscode.md`, which covers the VS Code/SlickEdit parity
work in its own detail; this file covers everything else and how the two fit
together.

Written 2026-08-25.

## The goal

One directory that can be dropped onto any Linux box Jeff uses — new or
existing — to get his core environment running quickly **without breaking
anything already there**. Copy `~/.linuxjjk`, run `~/.linuxjjk/init`, done.

"Without breaking anything" is a real constraint, not a slogan. `init` never
overwrites or deletes an existing file it did not create; where it finds
something unexpected it reports and leaves it alone.

## Hard rules

These came from Jeff directly. Violating them is a bug, not a style choice.

**1. Never depend on the directory being named `.linuxjjk`.** Every path is
derived at runtime:

```bash
SCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
```

He *refers* to it as `~/.linuxjjk` when giving instructions, but the code must
survive a rename or a move. This is tested by copying the whole directory to a
different name and running against a sandbox `$HOME`.

**2. `init` colour semantics — judged by the state `init` leaves behind, not by
what it found.**

| colour | meaning |
|---|---|
| green | checked, already correct |
| yellow | something is off, but it might be fine / might be deliberate |
| red | **still wrong after `init` ran** |

The critical consequence: something missing that `init` then successfully
creates ends **green**. "Missing" is not itself an error — only "still broken
when `init` exits" is. Otherwise a perfectly successful first run on a fresh
machine would look like a screen of failures and he'd stop trusting the output.

**3. Tally at the check level, never inside a helper.** `red`/`yellow`/`green`
only print. `complain <level> <msg>` prints *and* counts. Each `check_*`
function decides the tally after any repair has been attempted. This is what
stops one problem being counted twice, or a repaired problem still counting as
an error.

**4. If something isn't applicable to this machine, say nothing at all.** A
group that doesn't exist, no `code` CLI, no `vscode-setup` directory — all
return 0 silently. Nagging about things that are simply not part of a given box
is noise.

**5. Bright yellow is `\e[1;33m`.** `\e[0;33m` is brown. Matches the
`COLOR_YELLOW` / `COLOR_BROWN` definitions in `bashrc_jjk`. A multi-line
warning must be **entirely** yellow — continuation lines included.

**6. Jeff's global rules apply** (see `~/.claude/CLAUDE.md`): never push, open a
PR, post to a tracker, or publish anything without his explicit say-so in the
current conversation. Also: keep answers short, and don't recap the current
state of his machine back to him — he knows.

## What's in the directory

```
~/.linuxjjk/
├── init                      the installer/health-checker (bash)
├── bashrc_jjk               his bash config, sourced by ~/.bashrc
├── .aliases                  shell functions, sourced by bashrc_jjk
├── .gitconfig                portable git config; ~/.gitconfig symlinks here
├── .claude/                  (pre-existing, untouched this session)
├── bin/                      scripts that land on PATH
│   ├── git-meld-wrapper.sh
│   ├── git-tidy-branches
│   ├── jjk_gitlog.py         shared engine, imported by the four below
│   ├── git-trunk             `git trunk`
│   ├── git-tree              `git tree`
│   ├── git-fsl               `git fsl`
│   └── git-sl                `git sl`
├── vscode-setup/             VS Code Brief/SlickEdit parity setup
│   └── setting-up-vscode.md  its own continuation doc — read separately
└── setting-up-linuxjjk.md    this file
```

Machine-local files that live in `$HOME` and are deliberately **not** in here:

- `~/.gitid` — this machine's git identity. Never copied between machines.
- `~/.gitconfig`, `~/.aliases` — symlinks into this directory, made by `init`.

## `init`, check by check

Runs in this order. Every check is idempotent; re-running changes nothing that
is already correct.

### 1. `check_gitid` — `~/.gitid`

Holds only `[user] name/email`. The portable `.gitconfig` pulls it in with
`[include] path = ~/.gitid`, so identity is the one thing that differs per
machine.

| state | result |
|---|---|
| valid | green `~/.gitid valid (Name <email>)` |
| missing → prompt accepted | yellow while prompting, then green |
| missing → declined or EOF | red + what the file needs |
| missing → blank name/email given | red, nothing written |
| bad ini syntax | red + `git config -f ~/.gitid --list` to see git's complaint |
| no `user.name` / `user.email` / email fails a sanity regex | red, naming the specific problem |

Validity is judged by **git itself** (`git config -f "$GITID" --get user.name`),
not by grepping. If git can read it, git will use it — that's the only
definition that matters.

`confirm()` returns non-zero on EOF, so running non-interactively declines
rather than hanging.

### 2 & 3. `check_portable_symlink` — `~/.gitconfig` and `~/.aliases`

`check_portable_symlink <link> <target> <error|warn>`.

| state | result |
|---|---|
| symlink → correct target | green |
| missing | creates it, green |
| symlink → elsewhere, or dangling | at the level passed in |
| regular file | **always** yellow, regardless of level |
| neither file nor symlink | at the level passed in |
| target missing in this directory | **always** red — the directory is incomplete |

`~/.gitconfig` is passed `error` (wrong git config means committing with the
wrong identity or tooling); `~/.aliases` is passed `warn` (a machine-local
aliases file is plausible). Jeff chose that asymmetry deliberately.

`-L` is tested **before** `-e`, because `-e` is false for a dangling symlink and
that case deserves its own message.

### 4. `check_bashrc_hook` — getting `bashrc_jjk` sourced

Two mechanisms, chosen by what the machine actually offers:

| condition | action |
|---|---|
| something really loops over `~/.bashrc.d` | symlink `~/.bashrc.d/50-linuxjjk.sh` → `bashrc_jjk`; `~/.bashrc` untouched |
| otherwise | marker-delimited block appended to `~/.bashrc` |

```bash
## >>> linuxjjk >>>
##  Managed by ~/.linuxjjk/init -- edits between these markers are lost.
[ -f "/home/banshee/.linuxjjk/bashrc_jjk" ] && . "/home/banshee/.linuxjjk/bashrc_jjk"
## <<< linuxjjk <<<
```

Design decisions and why:

- **Detect the mechanism, not the distro.** The test greps for an actual glob
  over the directory (`\.bashrc\.d[^/]?/\*`), not for the directory's
  existence. A `~/.bashrc.d` that nothing sources would make the drop-in
  silently dead — and that exact trap exists on Mint, which has the directory
  but no loop. A distro check would also be wrong: Fedora only added its loop
  around F32, so an older RHEL account lacks it while an Arch user may have
  built one by hand.
- **The markers** make re-runs idempotent (delete between them, rewrite) and
  mark which lines `init` owns. That ownership boundary is what lets the
  competing-hook check work: strip our block first, and anything left that
  sources a config by name is definitely Jeff's. The `>>> name >>>` spelling is
  the convention conda/rustup/nvm/pyenv all use.
- **Correctness is a whole-block comparison** against exactly what `init` would
  write — `extract_bashrc_block` vs `bashrc_block_body` — not a grep of the
  block for our path. A block with one of its two paths edited must count as
  wrong.
- **Writes through the existing file** (`cat "$tmp" > "$BASHRC"`) rather than
  `mv`, so a `~/.bashrc` that is itself a symlink stays one and keeps its mode.
  One backup is taken the first time, at `~/.bashrc.linuxjjk.bak`.
- **`~/.bash_aliases` was considered and rejected.** Debian/Mint's stock
  `~/.bashrc` sources it if present, so it would have needed zero `.bashrc`
  edits. Rejected because it's semantically "your aliases", it's a single slot
  (any machine with a real one forces a fallback, so behaviour would differ per
  machine), and `~/.bashrc` is a `/etc/skel` copy that is Jeff's to edit anyway.

Then `warn_competing_hooks` — any other uncommented line sourcing a config *by
name* (a distro's own directory loop is excluded) gets a yellow warning, since
it runs alongside ours and can override it.

Then `verify_bashrc_hook`, which is the only thing that actually proves the
hook works: spawn a fresh interactive bash and ask what it loaded.

| probe result | meaning |
|---|---|
| `1` and dir matches | green |
| `0` | red — hook installed but not firing |
| dir mismatch | red — two copies of the setup are installed |
| `≥2` | yellow — more than one hook installed |

**This function is dangerous to get wrong — see "The `bash -ic` hang" below.**

### 5. `check_vscode_setup`

`vscode-setup/` ships its own health check and installer, so `init` reimplements
nothing:

- `check-install.sh` — reports only, changes nothing, **exit 0 == healthy**
- `install.sh` — does the work; refuses to run while VS Code is open

It asks two independent questions, because `check-install.sh` can only answer
the first:

1. **Is the install intact?** — `check-install.sh`.
2. **Was it made from the *current* contents of this folder?** — a payload hash
   compared against a machine-local stamp.

Question 2 exists because of a real gap. `check-install.sh` reports a differing
`keybindings.json` with `note` (a `[warn]`, which does **not** increment
`$fail`), so it **exits 0** — deliberately, because from its point of view the
difference is ambiguous: the folder might be newer, or the active file might
have been edited on purpose. Before stamping, that meant editing
`keybindings.json` on another machine and copying it back left `init` reporting
green and installing nothing. Verified by experiment, not assumed.

**The stamp.** After a successful install, `init` writes a hash of the payload
to `${XDG_CONFIG_HOME:-~/.config}/linuxjjk/vscode.stamp`. Shipped hash ≠ stamp
means the folder changed since this machine was set up from it.

**The stamp is machine-local on purpose.** Putting it inside the portable
directory would make it travel along with the very changes it exists to detect.

**Payload** = the files that actually get installed somewhere:
`keybindings.json`, `settings-fragment.json`, `brief-slickedit-helpers-*.vsix`,
`fonts/*.ttf`. Filenames are hashed alongside contents, so adding, removing or
renaming one also changes the hash. Deliberately **excluded**: `install.sh`,
`check-install.sh`, `source/`, and `setting-up-vscode.md` — those are tooling
and notes, nothing installs them, so editing a comment must not force a
reinstall. A genuinely broken install is still caught by `check-install.sh` on
its own terms.

Hasher is the first of `sha256sum`, `sha1sum`, `md5sum`, `cksum` that exists.

| state | result |
|---|---|
| no `code` CLI, or no `vscode-setup/` dir | silent, return 0 |
| intact **and** hash matches stamp | green `healthy and up to date` |
| intact, no stamp yet, active `keybindings.json` matches shipped | adopt: write the stamp, green |
| intact, no stamp yet, active `keybindings.json` differs | treated as changed → offer install |
| intact but hash ≠ stamp | yellow "has changed since this machine was set up from it" → offer install |
| not intact | yellow "needs installing or repairing" → offer install |
| offering install, VS Code running | red — quit it and re-run |
| prompt declined | red + `cd … && bash install.sh` |
| install ok, re-check clean | **re-stamps**, green + yellow "start VS Code, then re-run check-install.sh" |
| install.sh failed, or install ran but check still fails | red |
| no hashing tool at all | green for the install + yellow that changes can't be detected |

The **adopt** row handles a machine set up before stamping existed (this one).
It avoids a pointless reinstall, but only adopts if the one thing
`check-install.sh` downgrades to a warning — the active `keybindings.json` —
really does match what ships here. Otherwise it declines to adopt and offers
the install.

Timestamps were considered instead of a hash and rejected: `cp -p` and
`rsync -a` preserve mtimes, so a file edited long ago elsewhere and copied back
would look older than the local install.

The trailing yellow after an install matters and is not decoration: per
`setting-up-vscode.md`'s "Stale extension copies" section, the stale-copy
reclaim happens on the *next* VS Code startup, so a clean bill of health only
means something after that start.

`init` re-checks with `check-install.sh` rather than trusting `install.sh`'s
exit code, and re-hashes rather than reusing the earlier value — `install.sh`
can take a while, and stamping something no longer on disk would hide the next
real change.

### 6. `check_bin` — the execute bit on `bin/`

`bin/` is found through PATH, so its scripts have to be executable. A round trip
through a USB stick loses that: the sticks are vfat and cannot store the bit, so
anything copied back lands as `644` and `git trunk` becomes "command not found"
with no obvious cause. This check restores it.

Only files starting with `#!` are touched — `bin/` is for scripts, and a stray
README has no business coming out executable.

| state | result |
|---|---|
| all scripts already executable | green `all N script(s) in bin/ are executable` |
| bit missing → chmod worked | green, naming what it fixed |
| `bin/` is on vfat/exfat (running from a stick) | yellow + where the real copy is |
| chmod genuinely failed | red + the files, ownership and mount options to check |

Not-executable-then-fixed is **green**, not yellow: it is right by the time the
line is printed, and a re-run finds nothing to do. Same rule as a created
`~/.gitid`.

**The trap this check exists to survive:** `chmod +x` on vfat **succeeds** —
exit status 0 — and changes nothing. Verified on both sticks 2026-08-26. So
trusting the exit status would report a fix that did not happen. Every chmod is
re-tested with `-x` instead, which is also what lets the vfat case be reported
as the harmless thing it is rather than as a failure.

### 7. `check_group` — `dialout` and `i2c`

`dialout` for serial/USB-serial devices; `i2c` for `/dev/i2c-*`, which
`ddcutil` needs for the monitor-input switching in `.aliases`.

Runs **last**, because it's the only check that needs a password.

| state | result |
|---|---|
| group absent on this machine | **silent**, return 0 |
| in group, session has it | green |
| in `/etc/group` but session predates it | yellow + log out and back in |
| not in group | yellow, then prompt `Add … now? (needs your sudo password)` |
| added | green + yellow "log out and back in" |
| declined / EOF | red + `sudo usermod -aG <g> <user>` |
| `usermod` failed | red |
| no `sudo` on PATH | red + the manual command |

Two different questions, and the distinction is load-bearing:

```bash
in_group_system() { id -nG "$2" | tr ' ' '\n' | grep -qx -- "$1"; }   # /etc/group — what init can change
in_group_now()    { id -nG      | tr ' ' '\n' | grep -qx -- "$1"; }   # this process's credentials
```

The array is `REQUIRED_GROUPS`, **not** `GROUPS` — that name is a bash builtin
array and assigning to it is an error.

## `bashrc_jjk`

**Renamed from `.bashrc_jjk` on 2026-08-26.** It lives in `~/.linuxjjk`, not in
`$HOME`, so there was nothing for the leading dot to hide it from. Only `init`
referenced the old name; re-running it repoints `~/.bashrc`'s managed block at
the new path and reports `block repointed`. A machine still carrying the old
block keeps working in the meantime — the block is `[ -f … ] &&` guarded, so it
silently sources nothing rather than erroring, until `init` runs there.

Changes made this session:

**Per-machine block at the bottom.** `uname -n` selects; unknown machines get a
yellow nag:

```bash
if [[ "$(uname -n)" == "banshee" ]]; then
    umask 002                     # group-writable, for the NFS mount to Unraid
elif [[ "$(uname -n)" == "jeffklinux" ]]; then
    true                          # nothing machine-specific here yet
else
    echo -e "${COLOR_YELLOW}${BASH_SOURCE[0]} has not yet been customized for your machine.${COLOR_NC}"
fi
```

Note this box is `jeffklinux`, so `umask 002` does **not** apply here — that was
Jeff's explicit choice when asked (hostname, not username; `banshee` is the
username here, and his original note said `uname -m`, which is the CPU arch).

**Idempotent PATH.** Was `export PATH="$SCRIPT_DIR/bin:$HOME/.local/bin:$PATH"`,
which duplicated entries on every re-source (PATH is exported, so nested shells
and double hooks both hit it). Now:

```bash
for _dir in "$HOME/.local/bin" "$SCRIPT_DIR/bin"; do
    case ":$PATH:" in
        *":$_dir:"*) ;;
        *) PATH="$_dir:$PATH" ;;
    esac
done
unset _dir
export PATH
```

Same precedence (`$SCRIPT_DIR/bin` first — listed lowest-priority first since
each is prepended). Sourced 3×: was 6 entries, now 2.

**Load marker**, for `verify_bashrc_hook`:

```bash
LINUXJJK_LOADED=$(( ${LINUXJJK_LOADED:-0} + 1 ))
LINUXJJK_DIR="$SCRIPT_DIR"
```

**Deliberately not exported.** Every new shell starts at zero, so a count above
one means the file was sourced twice in *one* shell — i.e. two hooks — rather
than a value inherited from a parent.

## git config layout

```
~/.gitconfig  ->  ~/.linuxjjk/.gitconfig      (symlink, made by init)
~/.gitid                                       machine-local [user], included
```

`~/.linuxjjk/.gitconfig` has `[include] path = ~/.gitid` near the top. A missing
include is silently ignored by git, so a machine with no `~/.gitid` simply has
no identity — which git complains about on the first commit, and which `init`
catches first.

Migration on this box was verified rather than assumed: the portable file was
confirmed a strict superset of the old `~/.gitconfig` except `user.*` before the
old one was replaced; afterwards `git var GIT_AUTHOR_IDENT` was correct,
`git config --list --show-origin` showed the identity coming from `~/.gitid`,
and a real test commit in a scratch repo was authored correctly. Old file
preserved at `~/.gitconfig.pre-linuxjjk.bak`.

`difftool.meld.cmd` was changed from `~/.local/bin/git-meld-wrapper.sh` to bare
`git-meld-wrapper.sh` so PATH resolves it. Trade-off: only works from shells
that sourced `bashrc_jjk`. Fine for an interactive-only tool.

Note `git config --global --list` does **not** expand includes — use
`--includes` or plain `git config --get`. Not a bug; just surprising.

## `bin/`

Created this session. `gitbranch`, `git-meld-wrapper.sh`, and
`git-tidy-branches` were consolidated here out of `~/.local/bin` and the
top level of this directory. `~/.local/bin` retains only unrelated things
(`claude`, `go-p1`, `go-pc`, `herdr`, `herdr-follow`, `pairing`, `screengrab`).

**`bin/gitbranch` was then deleted.** It was a python3 script duplicating the
`gitbranch()` shell function in `.aliases`, and shell functions beat PATH
lookups, so the script was dead code feeding nothing. Confirmed behaviourally
identical across 11 cases (normal branches, `users/banshee/*` → `(~/…)` rewrite,
other users' prefixes, detached HEAD, empty repo, non-git dir). The function is
also 3.2× faster — 100 invocations: 854 ms vs 2771 ms, ~19 ms off every prompt
render.

### `bin/jjk_gitlog.py` + `git-trunk`/`tree`/`fsl`/`sl` (2026-08-26)

All four aliases have been **removed from `.gitconfig`**. What replaced them is
one module holding the shared engine, plus four real scripts:

```
bin/jjk_gitlog.py   the engine: display-width math, wrapping, row budget,
                    git plumbing.  Not executable -- it is imported, not run.
bin/git-trunk       the first-parent log -- trunk only, no side branches
bin/git-tree        every local branch, against the remote trunk
bin/git-fsl         this branch's own commits, back to where it left its base
bin/git-sl          the stack: local and origin/jkellam/* branches since base
```

Each view is 20–55 lines: a `revs()` function if it needs one, and a call to
`screen_log(name=…, blurb=…, extra_log_args=…, revs=…)`. Everything else is in
the module. `git-trunk` has no `revs()` at all.

Selection was verified commit-for-commit against every original alias, in both
`fw-cypress` and `fw-cypress2`, on `main` and on a feature branch: same commits,
same order, all four. The comparison harness runs each under a 200-row pty so
neither side is cut short — it lives in the session scratchpad, not here.

Two bugs in the aliases were fixed on the way through:

- **`sl` died on a detached HEAD.** `git branch --format` prints a literal
  `(HEAD detached at abc1234)` line, which the alias split on whitespace into
  four bogus revision arguments: `fatal: Not a valid object name abc1234)`. The
  script uses `for-each-ref`, which only ever lists real refs.
- **`tree` died in a repo with no `origin/main`**, which it named
  unconditionally. It is now asked for only if it resolves.

**`main` vs `master` is asked, not assumed.** `trunk_name()` in the module
answers it, in order of how much the answer can be trusted: the
`refs/remotes/origin/HEAD` symref (authoritative, set at clone time, and copes
with a trunk called neither); then whichever of `origin/main`, `origin/master`
resolves; then `main`/`master` locally for a repo with no remote; then `"main"`
so callers always get a string. Cached per process — one extra `git symbolic-ref`
per command.

This mattered more than it looks. Hardcoded `origin/main` did not error in a
`master` repo — it **silently dropped commits**. Verified against a purpose-built
`master` clone whose `origin/master` was one commit ahead of anything local: the
hardcoded version showed that commit **zero** times, and labelled the trunk
`(master)` instead of `(origin/master, master)`. Checked against four repo
shapes: `main`, `master`, a `master` clone with `origin/HEAD` deleted (falls to
step 2), and one whose `origin/HEAD` points at `develop`.

`git <mode> --help` shows nothing useful — git turns that into `man git-<mode>`.
Use `git <mode> -h`, which the script handles itself.

Why it was rewritten: the alias ended in `| head -n $((LINES - 3))`, which counts
*logical* lines, while a terminal scrolls on *physical rows*. Any line wider than
the window wrapped and the output overran the screen — the exact thing the `- 3`
was there to prevent. Measured in `fw-cypress2` at 80×24, every one of the 21
lines it emitted was 119–154 columns wide, so 21 lines of log took about 42 rows
of a 24-row window. The script wraps instead, with a hanging indent at the subject
column, and spends a budget of physical rows: same repo and window, 21 rows, 10
commits, nothing over 80 columns. Date format is also shorter, `MM-DD HH:MM` on a
24-hour clock, which buys back 8 columns.

**Aliases shadow PATH.** Git resolves an alias *before* it searches PATH for
`git-<name>`, so a `git-foo` script is unreachable as `git foo` for as long as
`alias.foo` exists. That is why the alias had to go, not just be left unused.

**`--graph` implies `--topo-order`, and that is what makes a big repo feel slow.**
With no commit-graph file git walks the whole reachable history before emitting
line one, and `--max-count` does *not* bound that walk. On a synthetic
150k-commit repo: 21 commits without `--graph` 0.002 s, with `--graph` 0.42 s,
with `--graph` plus a commit-graph 0.003 s. So the fix for a slow repo is
`git commit-graph write --reachable` (or `git maintenance start`), not a smaller
count. None of the `fw-cypress*` clones have a commit-graph; at ~1000 commits they
walk in ~3 ms, so it has never mattered here.

**The `%x1f` sentinel.** The format string starts with `%x1f`, which terminates
git's graph prefix, so `line.split("\x1f")` separates graph from fields no matter
how deep the graph is or how much color git injected into the rails. Lines with no
`%x1f` are graph-only rows (`|\`, `|/`) and pass through untouched. Without the
leading separator there is no reliable way to tell where the rails stop.

Written in python3 rather than bash+awk for one reason: display width. Widths come
from `unicodedata` — 0 for combining marks and format characters, 2 for East Asian
Wide/Fullwidth, 1 otherwise — and getting that right in awk is where this class of
script normally breaks. Verified against glibc's `wcswidth` at widths from 120 down
to 30 columns: no row ever exceeds the window, no subject or author text is lost,
and a parenthesized author never splits across rows.

## Traps found the hard way

Each of these cost real debugging time. Don't re-learn them.

### The `bash -ic` hang (the worst one)

`verify_bashrc_hook` originally ran `bash -ic` with stdin inherited. From a real
terminal, an interactive bash with a tty on stdin enables job control and calls
`tcsetpgrp()` to take the terminal — but it isn't the foreground process group,
so the kernel sends `SIGTTOU` and **stops** it. `init` then waits forever on a
process that will never run again, and **Ctrl-C cannot help**, because the
signal goes to the terminal's foreground group, not the stopped probe. Observed
directly as `PID 246509  T  bash -ic printf "__LINUXJJK_PROBE__ …`.

`timeout 15` was useless: **an interactive bash ignores `SIGTERM`.**

Three guards, all load-bearing:

```bash
setsid -w                # own session -> no controlling terminal to fight over (the actual fix)
</dev/null               # never read from the terminal
timeout -k 5 15          # escalate to SIGKILL, since SIGTERM is ignored
```

**Why it wasn't caught:** every earlier test passed `</dev/null`, which silently
avoided the whole failure mode. **Anything that spawns an interactive shell must
be tested under a pty** — `timeout 30 script -qec '…' /dev/null`.

### Startup files print to stdout

The probe originally read its answer by line position and got Ubuntu's
"To run a command as administrator…" hint from `/etc/bash.bashrc` instead. Now
it emits a tagged `__LINUXJJK_PROBE__ <count> <dir>` line and greps for it.

### `~` in a substitution replacement gets tilde-expanded

`${var/#$HOME/~}` silently does nothing — the `~` expands back to `$HOME`, so it
replaces the prefix with itself. It must be `\~`:

```bash
tildify() { printf '%s' "${1/#$HOME/\~}"; }
```

### `-f` follows symlinks

Jeff's premise for the `.bashrc.d` drop-in was that it needs a real file because
Fedora's loop uses `[ -f "$rc" ]`. Not so — `-f` dereferences, so a symlink to a
regular file passes. Only a *dangling* symlink or a symlink to a directory
fails. That's why the drop-in is a symlink.

### `~/.bashrc.d/*` doesn't match dotfiles

Hence `50-linuxjjk.sh`, not `.linuxjjk`. Worth knowing: the pre-existing
`~/.bashrc.d/.bashrc` on this box would be invisible to Fedora's loop.

### Do not run `init` from a copy

`SCRIPT_DIR` is wherever `init` is, by design — so running the copy **on the USB
stick** makes the stick the source, and `init` dutifully repoints
`~/.bashrc`'s managed block at `/media/.../init`, and reports `~/.gitconfig` /
`~/.aliases` as wrong because they point into `~/.linuxjjk`. Done by accident
2026-08-25 while smoke-testing a stick copy; fixed by re-running
`~/.linuxjjk/init`, which repointed the block back.

Harmless and self-correcting, but worth knowing before wondering why a shell
suddenly depends on a mounted stick. To *test* a copy, run it against a sandbox
`$HOME` — never the real one.

### `GROUPS` is a bash builtin array

Assigning to it is an error. The variable is `REQUIRED_GROUPS`.

### Others

- A repaired problem must not still count as an error. First version reported
  `1 error(s)` after successfully creating `~/.gitid`.
- Grepping a managed block for our path passes a half-edited block. Compare the
  whole block.
- `id -nG` (process) vs `id -nG "$user"` (`/etc/group`) are different questions.
  Note the process Claude Code runs in lacks gid 20, so the `dialout` warning
  may be an artifact when `init` is run from a tool rather than Jeff's terminal.

## How this gets tested

No feature is called done on inspection. The pattern:

1. **Copy the whole directory to a different name** (`dotfiles-renamed`, `dot`)
   to prove nothing depends on `.linuxjjk`.
2. **Run against a sandbox `$HOME`** so the real home is never the test subject.
3. **Shim external commands** to reach otherwise-unreachable branches — `id`,
   `getent`, `sudo`, `pgrep`, `code`, plus stub `check-install.sh` /
   `install.sh` so no real install happens. Driven by `FAKE_*` env vars
   (`FAKE_SYSTEM_GROUPS`, `FAKE_SESSION_GROUPS`, `FAKE_EXISTING_GROUPS`,
   `FAKE_SUDO_RC`, `FAKE_PGREP_RC`, `FAKE_INSTALL_RC`).
4. **Run under a pty** (`script -qec … /dev/null`) as well as with
   `</dev/null`, and always with an outer `timeout`.
5. **Check colours as bytes** (`| cat -v`) rather than by eye.

Roughly 40 cases have been exercised this way: every `.gitid` state, every
symlink state, both hook mechanisms plus tampered/duplicate/absent variants,
all eight group states, all seven VS Code states, and colour/no-colour output.

## Current state of this machine (`jeffklinux`, Linux Mint)

`~/.linuxjjk/init` output as of writing:

```
~/.gitid valid  (Jeff Kellam <jeff.kellam@sesame.com>)
~/.gitconfig properly configured (symlink -> ~/.linuxjjk/.gitconfig)
~/.aliases properly configured (symlink -> ~/.linuxjjk/.aliases)
~/.bashrc sources ~/.linuxjjk/bashrc_jjk
a new interactive bash loads bashrc_jjk once, from ~/.linuxjjk
VS Code setup healthy and up to date with ~/.linuxjjk/vscode-setup
all 6 script(s) in bin/ are executable
WARNING: banshee is in the 'dialout' group, but this login session started before that.
         Log out and back in for it to take effect.
WARNING: banshee is in the 'i2c' group, but this login session started before that.
         Log out and back in for it to take effect.
```

Both remaining warnings clear on a log out / log back in.

## Open items

**Needs Jeff's decision or action:**

- **Both USB sticks were re-synced 2026-08-26** and verified identical to
  `~/.linuxjjk` (30 files each) — `bin/` gained `jjk_gitlog.py` and the four view
  scripts, and `.gitconfig`, `init` and this file were updated. No symlinks are
  involved any more, so the sticks are a faithful copy. Previously synced
  2026-08-25 (25 files):
  `/media/banshee/USB321FD/.linuxjjk/` and
  `/media/banshee/2EA2-1DF1/linux/.linuxjjk/`. Superseded files on both were
  deleted at his instruction (old flat `.aliases`/`.bashrc_jjk`, `gitbranch`,
  `gitbranch.py3`, the top-level `setting-up-vscode.md`, and the old top-level
  `vscode-setup/` on 2EA2-1DF1; `gitbranch` and `git-meld-wrapper.sh` on
  USB321FD). He is explicit about reviewing before things propagate — ask before
  syncing again.
- **The USB copy of `vscode-setup` is now stale.** `~/vscode-setup/` was the
  other redundant copy and was deleted 2026-08-25 after confirming it was
  byte-identical to `vscode-setup/` here.
- **`~/.bashrc.d/` still holds the predecessor setup** (`.bashrc`, an older fork
  of `bashrc_jjk`; `.aliases`, an older fork with `ddccontrol`-based
  `laptop`/`windows`/`homepc` instead of `ddcutil`-based `work`/`home`). Nothing
  sources it any more — he removed the hand-added hook from `~/.bashrc`. Safe to
  retire when he's ready.
- **Log out / back in** for `dialout` and `i2c`.

**USB round-trip notes:**

- Both sticks are **vfat**, mounted `fmask=0022,showexec`, so **the executable
  bit does not survive**. `init` comes back as `644`. Not a blocker — run
  `bash ~/.linuxjjk/init`, or `chmod +x init` after copying back.

  `bin/` used to be affected too, and silently: a `git-*` script back from a
  stick is unexecutable, so `git <name>` falls through to "not a git command"
  with nothing pointing at the permissions. `check_bin` now repairs
  that on every `init` run (check 6), so `bash ~/.linuxjjk/init` is the whole
  recovery. `init` itself still needs the `bash` prefix that one time, since it
  cannot chmod itself before it runs. The `vscode-setup` scripts were never
  affected — `init` invokes those via `bash` explicitly.
- vfat cannot store symlinks either, but nothing in `~/.linuxjjk` is a symlink
  (they all live in `$HOME` and are created by `init`), so that costs nothing.

**Known warts, not yet addressed:**

- **`.aliases` hardcodes `users/banshee/`** in `gitbranch()`. On a machine where
  he's a different user, the `(~/feature)` branch-name rewrite silently stops
  firing. `$USER` or a configurable prefix would travel better.
- **`mergetool.meld.cmd` is broken on Linux** — points at
  `'~/AppData/Local/Programs/meld/meld'`, a Windows path. `difftool` is fine;
  `git mergetool` with meld would fail. It's in the portable file, so it follows
  him everywhere.
- **`init` is bash-only** by design (`BASH_SOURCE`, `bind`, that `PS1`). A zsh
  or macOS machine is a separate problem, not a tweak.
- Backups left behind: `~/.gitconfig.pre-linuxjjk.bak`,
  `~/.bashrc.linuxjjk.bak`. Delete when confident.

**From the VS Code side** (see `vscode-setup/setting-up-vscode.md` for detail):

- Column marking (Alt+C, helpers 0.0.4) is installed and passes 21 headless
  tests but is **still awaiting his verdict from actual use**.
- `lastmac.e` holds one unbound, unported SlickEdit macro — ask if he wants it.

## Memories saved this session

In `~/.claude/projects/-home-banshee/memory/`:

- `feedback_init_status_colors.md` — the green/yellow/red rule above.
- `feedback_answer_brevity.md` — keep answers short; don't recap state he
  already knows.
