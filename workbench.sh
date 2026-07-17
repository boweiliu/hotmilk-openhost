# Site config for the hotmilk workbench. Installed at /etc/profile.d/workbench.sh
# so login shells (`bash -l`) pick it up via /etc/profile, and sourced from the
# bottom of /etc/bash.bashrc so non-login interactive bash gets it too.

if [ -n "${_HOTMILK_RC_LOADED:-}" ]; then
    return
fi
_HOTMILK_RC_LOADED=1

# Ensure npm global bin and the Python venv are on PATH
for d in "$HOME/.npm-global/bin" /opt/venv/bin /usr/sbin /sbin; do
    case ":$PATH:" in
        *":$d:"*) ;;
        *) PATH="$d:$PATH" ;;
    esac
done
export PATH

# Everything below is interactive-only.
case $- in *i*) ;; *) return;; esac

# Colored prompt + ls/grep aliases
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

if [ "$color_prompt" = yes ]; then
    PS1='\[\033[01;32m\]hotmilk\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='hotmilk:\w\$ '
fi
unset color_prompt

if [ -x /usr/bin/dircolors ]; then
    eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Interactive login banner
if [ -f "/etc/profile.d/hotmilk-banner" ]; then
    cat /etc/profile.d/hotmilk-banner
fi