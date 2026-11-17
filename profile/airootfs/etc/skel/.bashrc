# HacknetOS live user .bashrc

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Prompt
PS1='\[\e[1;34m\]hacknet\[\e[0m\] \[\e[1;32m\]\w\[\e[0m\] \$ '

# Aliases
alias ls='ls --color=auto'
alias ll='ls -la'
alias grep='grep --color=auto'
alias hacknetctl='hacknetctl'
alias ht='hacknetctl theme'
alias hw='hacknetctl windows'
alias hn='hacknetctl netmap'
alias hs='hacknetctl state'

# History
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth
shopt -s histappend

# Editor
export EDITOR=nano
export VISUAL=nano

# HacknetOS
export XDG_CURRENT_DESKTOP=HacknetOS

# Welcome
if [ -z "$HACKNET_WELCOME_SHOWN" ]; then
    export HACKNET_WELCOME_SHOWN=1
    fastfetch --logo-type none --logo-width 0 --structure "title:os:host:kernel:uptime:packages:shell:terminal:memory"
    echo ""
    echo "  HacknetOS Environment"
    echo "  ────────────────────────"
    echo "  Super+Enter       : New terminal"
    echo "  Super+Shift+Enter : Stage terminal"
    echo "  Super+Q           : Close window"
    echo "  Super+Tab         : Cycle windows"
    echo "  Super+E           : File manager"
    echo "  Print             : Screenshot"
    echo ""
    # The installer only makes sense on the live medium.
    if [ -d /run/archiso ]; then
        echo "  Install: sudo hacknetos-installer"
        echo ""
    fi
fi