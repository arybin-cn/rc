alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias cdd='cd ~/Desktop'
alias cdp='cd ~/Projects'

alias tt='tmux ls'
function t() {
    local session="${1:-0}"
    tmux att -t "$session" 2>/dev/null || tmux new-session -s "$session"
}
