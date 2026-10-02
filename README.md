# vicks-prompt-hello-world

A Star Wars welcome banner, a live system dashboard and a colour-coded prompt for zsh.

Every new terminal shows an X-wing in its film colours, a caption in Star Wars yellow,
a snapshot of the machine, and the route this machine takes to the internet.
The banner stays pinned at the top of the window and keeps itself up to date while you work below it.

## Install

```bash
git clone https://github.com/vboscan/vicks-prompt-hello-world.git
cd vicks-prompt-hello-world
./install.sh
```

The installer does six things:

1. Installs [Starship](https://starship.rs) with Homebrew if it is missing. It draws the prompt.
2. Installs [tmux](https://github.com/tmux/tmux) and `iperf3` with Homebrew if they are missing. The cockpit needs tmux, and the Tailscale speed test needs iperf3.
3. Adds one marked block to `~/.zshrc` that sources `vicks.zsh` from this folder.
4. If a Ghostty or cmux configuration file exists, adds one marked block to it that makes Cmd+K work with the pinned banner.
5. If Claude Code is set up (`~/.claude` exists), installs the `/btw` side pane: a skill, one hook in `~/.claude/settings.json` and one marked block in `~/.claude/CLAUDE.md`. See [Claude Code in the cockpit](#claude-code-in-the-cockpit).

6. If cmux is set up, adds two browser shortcuts to `~/.config/cmux/cmux.json`, unless that file already has its own shortcuts.

Remove all of it again with `./install.sh --uninstall`.

## What the banner shows

| Section | Contents |
|---|---|
| X-wing | White and grey hull, red squadron stripes, orange engines, blue canopy |
| System | Host, OS version and build, pending macOS updates, kernel, hardware, outdated Homebrew packages, uptime |
| Who is here | Every logged-in user with session count, remote logins, your last login |
| Attention | Optional. What a headless Claude run thinks needs you, colour-coded by severity |
| Resources | CPU, memory and disk bars, load averages, battery, process count |
| Top apps | The five biggest consumers of CPU and the five biggest consumers of memory, side by side |
| Now playing | While [ncspot](https://github.com/hrkfdn/ncspot) runs: the current track and artist, the next track, and the playlist |
| Network | Interface and Wi-Fi name, private IP, gateway, other IPs, DNS, public IP, ISP, NAT, internet speed |
| Tailscale | Connection state, tailnet, this device, exit node, every peer with online state, speed to one peer |
| Route to internet | Each hop from this machine until the route reaches Google's network, with address kind, latency and network owner |

The public IP comes from a lookup at `ipinfo.io`, so it is correct behind NAT.
Hop owners come from the same service. Hops are classed as private, carrier-grade NAT or public.

The trace is aimed at `8.8.8.8`, and the route shown stops at the first hop that Google owns.
That covers your router, your ISP's network and the handover to Google, without the hops inside Google.
Ownership is matched on the network number of the target, so a different target stops at its own network.

The top apps are grouped by app, so an app's helper processes count as one entry.
Their CPU figures are a share of the whole machine, on the same scale as the CPU bar.
WebKit web pages are the pages open in Safari and in other apps that embed WebKit.

### Attention: a Claude check of the banner's data

With `VICKS_REVIEW=1`, a headless [Claude Code](https://claude.com/claude-code) run reads the banner's data about once an hour and lists what needs your attention.
The result sits under the X-wing, numbered and colour-coded.

```
ATTENTION checked 4m ago ─────────
1 ● macOS updates available
2 ● Tailscale peer offline
3 ● Homebrew package outdated
→ cockpit fix  opens Claude on it
```

| Colour | Meaning |
|---|---|
| Green heading, "All clear" | Nothing needs you |
| Red dot | Act today: someone else logged in, no internet, disk nearly full |
| Orange dot | Act this week: pending OS updates, a slow hop, a failed speed test |
| Blue dot | Housekeeping: outdated packages, a peer offline for days |

The heading takes the colour of the worst finding, so one glance is enough.

| Command | Effect |
|---|---|
| `cockpit review` | Run the check now and print each finding with its reason and a suggested action |
| `cockpit fix` | Open an interactive Claude session that starts from all the findings |
| `cockpit fix 2` | The same, for finding number 2 only |
| `hello --data` | Print the plain-text snapshot the check reads |

- **Read-only:** the headless run receives the data as text and has every tool switched off. It cannot run commands or touch files. Its answer is forced into a fixed shape and stripped of control characters before it is printed.
- **The hand-off:** `cockpit fix` starts a normal interactive session with the findings and the snapshot as its first message, and asks Claude to verify each finding and to check with you before changing anything.
- **Cost and speed:** about ten seconds and roughly one cent per check on Haiku, at most once an hour while a banner is open. It uses the Claude account you are signed in to.
- **What leaves the machine:** the snapshot goes to Anthropic through Claude Code. It contains what the banner shows, including host name, user names, IP addresses, Wi-Fi name, app names and Tailscale peers.
- **Opt-in:** it is off unless `VICKS_REVIEW=1` is set, and it needs the `claude` command.

### Now playing

While ncspot, a terminal Spotify client, is running, the banner shows what it is playing.

```
NOW PLAYING ncspot · 1:12/3:06 ─────────────────
  ▶ Fight Like A Girl (feat. K.Flay) · Evanescence, K.Flay
  Next         Starburster · Fontaines D.C.
  Playlist     Brussels Rock Night with Imagine Dragons · 138/142
```

- **Current track, artist and progress** come live from ncspot's socket. `▶` is playing, `‖` paused, `■` stopped.
- **The playlist and the next track are worked out, not reported.** ncspot does not publish its queue. The banner looks the current track up in ncspot's local cache of your playlists, saved albums and liked songs, and takes the track that follows it there.
- **A `?` marks a guess.** It appears when the last track change did not follow the list order, which happens with shuffle, after you jump to a track by hand, and for the first track the banner sees. When a track is in several playlists, the one where the previous track sits right before it is chosen.
- **Not in your library:** a track from search or from someone else's playlist shows its album, and the next track as unknown.
- The section disappears when ncspot is not running. `VICKS_MUSIC=0` hides it for good. It is never sent to the Claude check.

### Rotating tips

Under the X-wing, the banner shows five cmux shortcuts and commands at a time and moves to the next five every 30 seconds.
The list has 65 tips in thirteen themed pages, from getting around and tabs through to cmux commands and this banner's own commands.

- **The list is a text file:** [cmux-tips.txt](cmux-tips.txt), one `shortcut | description` per line. Edit it freely; changes show on the next redraw.
- **Shortcuts are cmux's defaults,** checked against cmux's [published shortcut data](https://cmux.com/docs/keyboard-shortcuts). If you rebind one in `~/.config/cmux/cmux.json`, or cmux changes a default, update its line in the file.
- **Where it appears:** on machines that have cmux, and not over SSH. In windows too narrow for the X-wing it becomes an ordinary section.

### Speed tests

Two speed tests run once when a new terminal window opens, in the background.
They never run on a redraw, and their results appear in the banner when they finish.

| Test | How |
|---|---|
| Internet | Eight parallel downloads and four parallel uploads of 25 MB against `speed.cloudflare.com`, each direction capped at 8 seconds |
| Tailscale | `iperf3` to one peer, 5 seconds in each direction |

- **Data use:** the internet test moves roughly 100 MB per run on a 60 Mbps line, and at most 300 MB on a fast one.
- **Several windows in a row:** a result younger than 15 minutes is reused, and a test already running is not started twice.
- **Rate limits:** Cloudflare rejects heavy use of this endpoint for about 15 minutes. The banner then shows "rate-limited" for that direction instead of a number.
- **On demand:** `cockpit speedtest` runs both again right now.
- **Remote machines:** a machine reached over SSH does not test by default. Set `VICKS_SPEEDTEST=1` there to turn it on.
- **Tailscale peer:** name it in `~/.config/vicks/config` as `VICKS_IPERF_HOST=user@host`. Both ends need `iperf3`, and you need SSH access to the peer. A one-shot `iperf3` server is started there for each direction and exits afterwards, so nothing is left running.

### How fresh the data is

| Data | Refresh |
|---|---|
| CPU, memory, disk, battery, users, now playing | Every time |
| Tailscale | Every 20 seconds |
| Public IP and traceroute | Every 10 minutes in the banner, every 2 minutes in the cockpit |
| macOS and Homebrew updates | Every 6 hours, checked in the background |
| Claude check | Every hour, in the background |
| Speed tests | Once per new terminal window |

The update checks take several seconds, so they never block the terminal.
The banner prints the last known result with its age, and starts a new check when that is stale.
The first banner after installing says "checking…".

## The cockpit: the banner stays on screen

Every new terminal runs inside tmux, and one terminal per cmux workspace shows the banner.
The banner is pinned at the top of that terminal and redraws itself every five seconds.
Your shell runs underneath it, so commands and their output scroll below the banner.

- **One banner per workspace.** The first roomy terminal in a workspace gets it. Further splits and tabs in that workspace are plain shells, so they keep their full height.
- **It follows the workspace.** When the terminal holding the banner closes, the banner appears in the most recently used terminal of that workspace. The shell there is not disturbed.
- **`cockpit here`** moves the banner into the terminal you are in.
- **Small windows** under 80 columns by 30 rows run in tmux too, inside cmux, but are never given the banner.
- **Outside cmux** there are no workspaces, so every roomy terminal has its own banner. Smaller ones stay plain shells and print the one-off banner.
- The banner pane sizes itself to its content, up to 60% of the window, and is display-only: clicking it hands focus straight back to the shell.
- Typing `exit`, or closing the window, ends that terminal's tmux session.
- It runs on its own tmux server with [tmux.conf](tmux.conf), so a personal tmux setup is untouched.

| Command or setting | Effect |
|---|---|
| `cockpit here` | Move this workspace's banner into the current terminal |
| `cockpit refresh` | Look everything up again right now |
| `cockpit speedtest` | Run the internet and Tailscale speed tests again right now |
| `hello` | Print the full, long-form banner once in the shell |
| `export VICKS_COCKPIT_LAYOUT=side` | Pin the banner in a right-hand column instead of on top |
| `export VICKS_DASH_ART=0` | Leave out the X-wing for a shorter banner |
| `export VICKS_PLAIN=1` | A raw shell: no tmux and no banner. The prompt and commands stay |
| `export VICKS_AUTO_COCKPIT=0` | No tmux. New terminals print a one-off banner that scrolls away |

tmux does not start by itself in these cases, where a plain shell is used instead:

- inside another tmux, and in VS Code, JetBrains, Emacs and Claude desktop app terminals
- outside cmux, in windows smaller than 80 columns by 30 rows
- for `zsh -c` and other non-interactive shells
- if tmux fails to start, so a broken setup can never lock you out of the terminal

**How it works.** Each terminal has its own tmux session holding only its shell, tagged with its cmux workspace.
The banner is one extra pane. [cockpit.sh](cockpit.sh) reconciles whenever a terminal opens or closes: a workspace with no banner gets one in its most recently used terminal, and a workspace with two loses the older one.
Because the banner is only a pane, moving it never touches a running shell.

### cmux shortcuts

[cmux/shortcuts.jsonc](cmux/shortcuts.jsonc) holds the cmux key bindings this setup adds.

| Keys | Action |
|---|---|
| `cmd+shift+b` | Browser in a split below |
| `cmd+ctrl+b` | Browser in a split to the right |

cmux's default for a browser to the right is `cmd+opt+d`, which macOS uses to hide the Dock.
cmux has no setting for where a new browser opens, so its own "Open browser" key, `cmd+shift+l`, keeps cmux's placement. Use `cmd+shift+b` when you want it below.

### Sidebar labels in cmux

cmux lists your workspaces in its left sidebar. The setup labels each one so you can tell them apart at a glance.

| What you see | Meaning |
|---|---|
| `segundo` | An idle shell in that project. In a git repository the project is the repository name |
| `segundo/infra`, `segundo/…/image` | The same, one or more folders down |
| `segundo · claude` | A program is running there |
| `⇄ devbox-1 · segundo` | An SSH session is open in that terminal |
| A red pill reading `devbox-1` | The workspace has an SSH session to that host. One pill per session |

- **How:** tmux sets the terminal title, which cmux uses as the workspace name. The project part comes from a hook that runs when you change folder. The pill is set by the `ssh` wrapper through `cmux set-status` and cleared when `ssh` returns.
- **Closed mid-session:** a pill left behind by a terminal that was closed while connected is swept away the next time any terminal opens or closes.
- **Your own names win.** A workspace you rename with `cmd+shift+r` keeps your name.
- **Limits:** only `ssh` typed at the prompt is tracked, not tools that call ssh themselves, such as git. The project name needs zsh; in bash the folder name is used.

The layout adapts to the window width.

| Width | Layout |
|---|---|
| 226 columns or more | X-wing plus three columns of data |
| 162 to 225 columns | X-wing plus two full-width columns of data, about 24 rows |
| 142 to 161 columns | X-wing plus two slightly narrower columns |
| 126 to 141 columns | Two columns of data, no art |
| Narrower | One column |

### What changes inside the cockpit

- **Scrolling:** the mouse wheel scrolls the shell history. The terminal's own scrollbar does not.
- **Cmd+K:** clears the shell pane and its scrollback and leaves the banner alone. In Ghostty-based terminals (Ghostty, cmux) the installer remaps Cmd+K to send a private key code, because the default action wipes the terminal's own buffer behind tmux's back. Reload the terminal's configuration once after installing. In other terminals, use `clear && tmux clear-history`.
- **Copying:** drag to select and the text is copied on release. Hold Option while dragging to use the terminal's own selection.

### Claude Code in the cockpit

The installer sets up three things for [Claude Code](https://claude.com/claude-code), all from the [claude](claude) folder.

- **`/btw <question>` opens a side session.** The pane to the right of the asking session runs a new interactive Claude session. It is a fork of the asking session, so it knows the conversation so far and keeps its own history. Leaving it with `/exit` closes the pane.
- **The asking session spends no turn on it.** A `UserPromptExpansion` hook opens the pane and blocks the prompt. The session shows one "blocked by hook" line saying the side question was opened.
- **Claude shows its sub-tasks in tmux panes.** A marked block in `~/.claude/CLAUDE.md` tells Claude to run test runs, builds and similar work in a helper pane of the cockpit window instead of a new terminal.

| Situation | What `/btw` does |
|---|---|
| In the cockpit, or any tmux | Splits the current tmux window, so the banner stays shared |
| Outside tmux, inside cmux | Opens a cmux split |
| Neither | Claude answers the question inline, as a normal turn |
| Claude is in the middle of a turn | The command waits in the queue and opens the pane when the turn ends |

Set `BTW_FOCUS=true` to move keyboard focus to the new pane. By default focus stays where you are.

The skill replaces Claude Code's built-in `/btw` overlay. `./install.sh --uninstall` brings the overlay back.

cmux gives each terminal its own identifiers, such as `CMUX_WORKSPACE_ID`. Each cockpit session takes them from the terminal that opened it, so `cmux` commands run inside the cockpit act on the right workspace.

## Remote machines

```bash
vicks-deploy user@host
```

This copies the setup to `~/.vicks` on the remote machine over SSH and runs the installer there.
`vicks-deploy` is a real command in `~/.local/bin`, so it works from any shell.
Log in with `ssh user@host` afterwards and the banner is pinned on that machine too.

- **A different ship:** any shell reached over SSH shows a TIE fighter instead of the X-wing, plus a "Remote" line with the host name. One glance tells you which machine a window is on.
- **Death Star:** put `export VICKS_REMOTE_ART=deathstar` in the remote's `~/.bashrc` or `~/.zshrc`, above the vicks block. `xwing` and a file path also work.
- **One banner at a time:** when you `ssh` from the cockpit to a machine you deployed to, the local banner hides for the length of the session and the remote one takes its place. It returns when you log out. Other hosts leave the local banner where it is.
- **Works with bash:** most Linux servers log in with bash. The installer hooks into `~/.bashrc` there through [vicks.bash](vicks.bash), and your shell stays bash.
- **Packages:** the remote needs zsh, tmux, jq, curl, traceroute and dig. The installer lists what is missing and asks before installing with `sudo`. It also offers to install Starship into `~/.local/bin`.
- **No sudo:** on a locked-down machine or container the installer names the packages to add to the machine's image instead. zsh is the one hard requirement; without it the banner cannot run.
- **Updating:** run `vicks-deploy user@host` again after changing anything here.
- **Removing:** `vicks-deploy user@host --uninstall`.

| Option | Effect |
|---|---|
| `--deps` | Install missing packages on the remote without asking |
| `--no-deps` | Never install packages, only list what is missing |
| `--uninstall` | Remove the shell hook and `~/.vicks` from the remote |

On Linux the banner uses `ip`, `free` and `/proc` in place of the macOS tools, and reports upgradable apt packages and a pending reboot under "OS updates".

## Commands and settings

| Command or variable | Effect |
|---|---|
| `hello` | Show the banner again |
| `hello --fresh` | Ignore the cache and look everything up again |
| `hello --no-net` | Skip the public IP lookup and traceroute |
| `VICKS_NO_BANNER=1` | No banner on new shells |
| `VICKS_NO_NET=1` | Banner without any network lookups |
| `VICKS_CACHE_TTL=600` | Seconds to cache network results for the banner |
| `VICKS_DASH_NET_TTL=120` | The same for the cockpit |
| `VICKS_DASH_INTERVAL=5` | Seconds between cockpit redraws |
| `VICKS_UPDATE_TTL=21600` | Seconds between update checks |
| `VICKS_TRACE_TARGET=8.8.8.8` | Where the traceroute is aimed |
| `VICKS_TRACE_STOP=owner` | Where the shown route ends. `owner` is the first hop in the target's own network, `public` the first public address, `full` every hop |
| `VICKS_TOP_N=5` | How many apps each top list shows |
| `VICKS_SPEEDTEST=0` | Never run speed tests. `1` also runs them on remote machines |
| `VICKS_SPEEDTEST_SECONDS=8` | Time cap for each direction of the internet test |
| `VICKS_SPEEDTEST_MIN_AGE=900` | Reuse a result younger than this many seconds |
| `VICKS_SPEEDTEST_MB=25` | Megabytes requested per stream |
| `VICKS_REVIEW=1` | Turn on the Claude check |
| `VICKS_REVIEW_TTL=3600` | Seconds between checks |
| `VICKS_REVIEW_MODEL=haiku` | Model used for the check |
| `VICKS_IPERF_HOST=user@host` | Tailscale peer for the `iperf3` test. Unset means no Tailscale test |
| `VICKS_MUSIC=0` | Hide the ncspot now-playing section |
| `VICKS_TIPS=0` | Hide the rotating tips |
| `VICKS_TIPS_SECONDS=30` | How long each page of tips stays up |
| `VICKS_TIPS_COUNT=5` | Tips per page |
| `VICKS_TIPS_FILE=/path/to/file` | Use your own tips file |
| `VICKS_ART=/path/to/file` | Use different art |
| `VICKS_REMOTE_ART=tie` | Ship shown when reached over SSH: `tie`, `deathstar`, `xwing` or a file path |

Set the variables in `~/.zshrc` above the vicks block, or as plain `VAR=value` lines in `~/.config/vicks/config`.
The config file is read on every redraw, so it also reaches a banner that is already pinned.

## The art

The X-wing lives in [xwing.art](xwing.art). It is classic ASCII art signed "snd".
The pinned banner uses [xwing-small.art](xwing-small.art), a reduced redraw of the same ship, so the data gets more room.
`hello` prints the full-size one. Set `VICKS_DASH_ART_FILE` to pin a different file.
Remote sessions use [tie.art](tie.art) or [deathstar.art](deathstar.art).
Colour tokens switch colour until the next token.

| Token | Colour |
|---|---|
| `{W}` | Hull white |
| `{G}` | Hull grey |
| `{D}` | Dark grey |
| `{R}` | Red stripes |
| `{O}` | Engine orange |
| `{C}` | Canopy blue |
| `{S}` | TIE hull steel blue |
| `{L}` | Imperial laser green |
| `{Y}` | Star Wars yellow |
| `{X}` | Reset |

## The prompt

```
╭─ vicky ~/Git/vicks-prompt-hello-world/src git:main +1 !2 ?3 ⇡1 🐍 (myproject) v3.13.1     Fri 02 Oct 17:30:12
╰─ ❯
```

| Part | Meaning |
|---|---|
| User | Who is running the commands. Green for an ordinary user, white on red for root. Over SSH it becomes `user@host` |
| `⚠ not vicky` | An orange badge when the current user is not the one who opened the terminal, as inside `sudo -s` or `su` |
| Path | The full path from `~`, in blue. Inside a git repository the repository name is cyan |
| `git:main` | Current branch in purple |
| `+1 !2 ?3` | Staged in green, modified in orange, untracked in blue |
| `⇡1 ⇣1` | Commits ahead of or behind the remote |
| `🐍 (name) v3.x` | Active virtual environment from venv, uv, virtualenv or conda, and the Python version |
| `○ venv not active` | A `.venv` folder exists here but is not activated |
| Right side | How long the last command took, its exit code if it failed, then local day and time |
| `❯` | Green after success, red after a failure |

The prompt is configured in [starship.toml](starship.toml).
If Starship is not installed, [prompt-fallback.zsh](prompt-fallback.zsh) draws the same layout in plain zsh.

## Files

| File | Purpose |
|---|---|
| `vicks.zsh` | Entry point for zsh, sourced from `~/.zshrc`. Defines `hello`, `cockpit` and `vicks-deploy` |
| `vicks.bash` | Entry point for bash, sourced from `~/.bashrc` |
| `cockpit.sh` | Starts the pinned banner. Shared by both entry points |
| `deploy.sh` | Copies the setup to a remote machine and installs it there |
| `banner.zsh` | The welcome banner and the live dashboard |
| `xwing.art` | The full-size X-wing with colour tokens, used by `hello` |
| `xwing-small.art` | The smaller X-wing used by the pinned banner |
| `tie.art`, `deathstar.art` | The ships shown on machines reached over SSH |
| `cmux-tips.txt` | The rotating tips: cmux shortcuts and commands |
| `starship.toml` | Prompt configuration |
| `prompt-fallback.zsh` | Prompt without Starship |
| `tmux.conf` | tmux settings used only by the cockpit |
| `claude/btw/` | The `/btw` skill for Claude Code and the script that opens the side pane |
| `claude/cockpit-rules.md` | The block added to `~/.claude/CLAUDE.md` |
| `cmux/shortcuts.jsonc` | The key bindings added to cmux's settings |
| `install.sh` | Installer and uninstaller for macOS and Linux |

Built and tested on macOS with zsh and bash. The Linux code paths are written but have not been run on a Linux machine yet.
