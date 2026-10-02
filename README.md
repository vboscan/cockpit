# vicks-prompt-hello-world

A Star Wars welcome banner and a colour-coded prompt for zsh.

Every new terminal shows an X-wing in its film colours, a caption in Star Wars yellow,
a snapshot of the machine, and the route this machine takes to the internet.

## Install

```bash
git clone https://github.com/vboscan/vicks-prompt-hello-world.git
cd vicks-prompt-hello-world
./install.sh
```

The installer does two things:

1. Installs [Starship](https://starship.rs) with Homebrew if it is missing.
2. Adds one marked block to `~/.zshrc` that sources `vicks.zsh` from this folder.

Remove it again with `./install.sh --uninstall`.

## What the banner shows

| Section | Contents |
|---|---|
| X-wing | White and grey hull, red squadron stripes, orange engines, blue canopy |
| System | Host, OS version and build, kernel, hardware, shell, date, uptime |
| Who is here | Every logged-in user with session count, remote logins, your last login |
| Resources | CPU, memory and disk bars, load averages, battery, process count |
| Network | Interface and Wi-Fi name, private IP, gateway, VPN and other IPs, DNS, public IP, ISP, NAT |
| Route to internet | Each traceroute hop to `8.8.8.8` with address kind, latency and network owner |

The public IP comes from a lookup at `ipinfo.io`, so it is correct behind NAT.
Hop owners come from the same service. Hops are classed as private, carrier-grade NAT or public.

Network results are cached for ten minutes, so a new tab opens in about 0.2 seconds.

## Commands and settings

| Command or variable | Effect |
|---|---|
| `hello` | Show the banner again |
| `hello --fresh` | Ignore the cache and look everything up again |
| `hello --no-net` | Skip the public IP lookup and traceroute |
| `VICKS_NO_BANNER=1` | No banner on new shells |
| `VICKS_NO_NET=1` | Banner without any network lookups |
| `VICKS_CACHE_TTL=600` | Seconds to cache network results |
| `VICKS_TRACE_TARGET=8.8.8.8` | Traceroute destination |
| `VICKS_ART=/path/to/file` | Use different art |

Set the variables in `~/.zshrc` above the vicks block.

## Using your own art

The art lives in [xwing.art](xwing.art). Colour tokens switch colour until the next token.

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
╭─ vicks-prompt-hello-world/src git:main +1 !2 ?3 ⇡1 🐍 (myproject) v3.13.1          Fri 02 Oct 17:30:12
╰─ ❯
```

| Part | Meaning |
|---|---|
| Path | Blue. Inside a git repository the repository name is cyan and the path starts there |
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
| `vicks.zsh` | Entry point sourced from `~/.zshrc` |
| `banner.zsh` | The welcome banner |
| `xwing.art` | The X-wing with colour tokens |
| `starship.toml` | Prompt configuration |
| `prompt-fallback.zsh` | Prompt without Starship |
| `install.sh` | Installer and uninstaller |

Built for macOS and zsh. The banner also has Linux code paths, which are untested.
