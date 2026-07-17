# Site config for the hotmilk workbench. Installed at /etc/profile.d/workbench.sh
# so login shells (`bash -l`) pick it up via /etc/profile, and sourced from the
# bottom of /etc/bash.bashrc so non-login interactive bash gets it too.

if [ -n "${_HOTMILK_RC_LOADED:-}" ]; then
    return
fi
_HOTMILK_RC_LOADED=1

# `bash -l` sources /etc/profile, which resets PATH to the system default and
# drops the additions baked in via Dockerfile `ENV PATH=...`. Re-add all needed
# paths so `pi` (~/.npm-global/bin or /usr/local/bin) and the Python venv
# (/opt/venv/bin) are reachable in every new tab.
for d in /opt/venv/bin /usr/local/bin /usr/sbin /sbin; do
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

# ── Interactive login banner ──────────────────────────────────────────────
echo
echo "  🥛  hotmilk on openhost"
echo "  ─────────────────────"
echo "  pi       $(command -v pi 2>/dev/null || echo '(not found)')"
echo "  hotmilk  $([ -f "$HOME/.pi/agent/hotmilk.json" ] && echo 'installed' || echo '(install on first pi run)')"
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    echo "  OPENROUTER_API_KEY  configured"
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "  ANTHROPIC_API_KEY   configured"
fi
echo "  ─────────────────────"
echo "  Type 'pi' to start the coding agent."
echo