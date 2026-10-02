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

The installer does three things:

1. Installs [Starship](https://starship.rs) with Homebrew if it is missing. It draws the prompt.
2. Installs [tmux](https://github.com/tmux/tmux) with Homebrew if it is missing. The cockpit needs it.
3. Adds one marked block to `~/.zshrc` that sources `vicks.zsh` from this folder.

Remove the block again with `./install.sh --uninstall`.

## What the banner shows

| Section | Contents |
|---|---|
| X-wing | White and grey hull, red squadron stripes, orange engines, blue canopy |
| System | Host, OS version and build, pending macOS updates, kernel, hardware, outdated Homebrew packages, uptime |
| Who is here | Every logged-in user with session count, remote logins, your last login |
| Resources | CPU, memory and disk bars, load averages, battery, process count |
| Network | Interface and Wi-Fi name, private IP, gateway, other IPs, DNS, public IP, ISP, NAT |
| Tailscale | Connection state, tailnet, this device, exit node, every peer with online state |
| Route to internet | Each traceroute hop to `8.8.8.8` with address kind, latency and network owner |

The public IP comes from a lookup at `ipinfo.io`, so it is correct behind NAT.
Hop owners come from the same service. Hops are classed as private, carrier-grade NAT or public.

### How fresh the data is

| Data | Refresh |
|---|---|
| CPU, memory, disk, battery, users | Every time |
| Tailscale | Every 20 seconds |
| Public IP and traceroute | Every 10 minutes in the banner, every 2 minutes in the cockpit |
| macOS and Homebrew updates | Every 6 hours, checked in the background |

The update checks take several seconds, so they never block the terminal.
The banner prints the last known result with its age, and starts a new check when that is stale.
The first banner after installing says "checking…".

## The cockpit: the banner stays on screen

Every new terminal opens in the cockpit.
The banner is pinned at the top of the window and redraws itself every five seconds.
Your shell runs underneath it, so commands and their output scroll below the banner.

- The banner pane sizes itself to its content, up to 60% of the window.
- The banner is display-only. Clicking it hands focus straight back to the shell.
- Typing `exit`, or closing the window, ends the cockpit and its banner.
- It runs on tmux with its own server and [tmux.conf](tmux.conf), so a personal tmux setup is untouched.

| Command or setting | Effect |
|---|---|
| `cockpit refresh` | Look everything up again right now |
| `hello` | Print the full, long-form banner once in the shell |
| `export VICKS_COCKPIT_LAYOUT=side` | Pin the banner in a right-hand column instead of on top |
| `export VICKS_DASH_ART=0` | Leave out the X-wing for a shorter banner |
| `export VICKS_AUTO_COCKPIT=0` | Go back to a one-off banner that scrolls away. `cockpit` still starts it by hand |

The cockpit does not start by itself in these cases, where a plain shell with the one-off banner is used instead:

- inside tmux, VS Code, JetBrains or Emacs terminals
- windows smaller than 80 columns by 30 rows
- if tmux fails to start, so a broken setup can never lock you out of the terminal

The layout adapts to the window width.

| Width | Layout |
|---|---|
| 173 columns or more | X-wing plus two or three columns of data, 20 to 24 rows |
| 153 to 172 columns | X-wing plus two slightly narrower columns, about 24 rows |
| 126 to 152 columns | Two columns of data, no art |
| Narrower | One column |

### What changes inside the cockpit

- **Scrolling:** the mouse wheel scrolls the shell history. The terminal's own scrollbar does not.
- **Copying:** drag to select and the text is copied on release. Hold Option while dragging to use the terminal's own selection.

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
| `VICKS_TRACE_TARGET=8.8.8.8` | Traceroute destination |
| `VICKS_ART=/path/to/file` | Use different art |

Set the variables in `~/.zshrc` above the vicks block.

## The art

The X-wing lives in [xwing.art](xwing.art). It is classic ASCII art signed "snd".
Colour tokens switch colour until the next token.

| Token | Colour |
|---|---|
| `{W}` | Hull white |
| `{G}` | Hull grey |
| `{D}` | Dark grey |
| `{R}` | Red stripes |
| `{O}` | Engine orange |
| `{C}` | Canopy blue |
| `{Y}` | Star Wars yellow |
| `{X}` | Reset |

## The prompt

```
╭─ ~/Git/vicks-prompt-hello-world/src git:main +1 !2 ?3 ⇡1 🐍 (myproject) v3.13.1     Fri 02 Oct 17:30:12
╰─ ❯
```

| Part | Meaning |
|---|---|
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
| `vicks.zsh` | Entry point sourced from `~/.zshrc`. Defines `hello` and `cockpit` |
| `banner.zsh` | The welcome banner and the live dashboard |
| `xwing.art` | The X-wing with colour tokens |
| `starship.toml` | Prompt configuration |
| `prompt-fallback.zsh` | Prompt without Starship |
| `tmux.conf` | tmux settings used only by the cockpit |
| `install.sh` | Installer and uninstaller |

Built for macOS and zsh. The banner also has Linux code paths, which are untested.
