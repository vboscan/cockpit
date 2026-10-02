# vicks-prompt-hello-world

A Star Wars welcome banner, a live system dashboard and a colour-coded prompt for zsh.

Every new terminal shows an X-wing in its film colours, a caption in Star Wars yellow,
a snapshot of the machine, and the route this machine takes to the internet.
The `cockpit` command keeps the same information pinned on screen and updating.

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

## The cockpit: an always-on dashboard

```bash
cockpit
```

This opens tmux with the dashboard pinned in a pane above your shell.
Commands scroll in the shell pane while the dashboard redraws every five seconds.
The dashboard pane sizes itself to its content, up to 60% of the window.
Typing `exit` in the shell closes the cockpit.

| Command or key | Effect |
|---|---|
| `cockpit` | Dashboard on top, shell below |
| `cockpit side` | Dashboard in a column on the right |
| `r` with the dashboard pane focused | Refresh everything now |
| `q` with the dashboard pane focused | Close the dashboard pane |
| `export VICKS_AUTO_COCKPIT=1` | Every new terminal opens straight into the cockpit |
| `export VICKS_DASH_ART=0` | Leave out the X-wing for a shorter dashboard |

The layout adapts to the window width.

| Width | Layout |
|---|---|
| 173 columns or more | X-wing plus two columns of data, about 24 rows |
| 126 to 172 columns | Two columns of data, no art, about 24 rows |
| Narrower | One column |

The cockpit runs its own tmux server with [tmux.conf](tmux.conf), so a personal tmux setup is untouched.
The mouse wheel scrolls the shell history and dragging selects text and copies it.
Hold Option while dragging to use the terminal's own selection instead.

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
