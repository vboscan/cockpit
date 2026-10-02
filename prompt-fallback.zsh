# prompt-fallback.zsh — pure-zsh prompt used when Starship is not installed.
# Same layout and colours as starship.toml: path, git, virtual env, day/time.

autoload -Uz vcs_info add-zsh-hook
setopt prompt_subst

zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:git:*' check-for-changes true
zstyle ':vcs_info:git:*' stagedstr   ' %F{82}+%f'
zstyle ':vcs_info:git:*' unstagedstr ' %F{214}!%f'
zstyle ':vcs_info:git:*' formats       ' %F{245}git:%f%F{141}%b%f%c%u %F{245}in %F{51}%r%f'
zstyle ':vcs_info:git:*' actionformats ' %F{245}git:%f%F{141}%b%f %F{196}(%a)%f%c%u'

_vicks_precmd() {
  vcs_info
  _vicks_who=""
  [[ -n ${SSH_CONNECTION:-} ]] && _vicks_who='%B%F{214}%n@%m%f%b '
  _vicks_venv=""
  if [[ -n ${VIRTUAL_ENV:-} ]]; then
    local name=${VIRTUAL_ENV:t}
    # ".venv" says nothing: show the project folder that owns it instead
    [[ $name == (.venv|venv) ]] && name=${VIRTUAL_ENV:h:t}
    _vicks_venv=" %B%F{220}🐍 (${name})%f%b"
  elif [[ -n ${CONDA_DEFAULT_ENV:-} ]]; then
    _vicks_venv=" %B%F{220}🐍 (${CONDA_DEFAULT_ENV})%f%b"
  elif [[ -d .venv || -d venv ]]; then
    _vicks_venv=" %F{245}○ venv not active%f"
  fi
}
add-zsh-hook precmd _vicks_precmd

PROMPT=$'\n''%F{240}╭─%f %(!.%B%F{196}%n%f%b .)${_vicks_who}%B%F{39}%~%f%b${vcs_info_msg_0_}${_vicks_venv}'$'\n''%F{240}╰─%f %(?.%B%F{82}.%B%F{196})❯%f%b '
RPROMPT='%(?..%B%F{196}✘ %?%f%b )%F{220}%D{%a %d %b %H:%M:%S}%f'
