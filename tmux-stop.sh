#!/bin/bash

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if the correct number of arguments is provided
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo -e "${RED}[ERROR]${NC} Invalid number of arguments."
    echo -e "${YELLOW}Usage:${NC} $0 <session_name> [cmd]"
    exit 1
fi

SESSION_NAME=$1
CMD=${2:-}  # Optional command

# Check if tmux is installed
if ! command -v tmux &> /dev/null; then
    echo -e "${RED}[ERROR]${NC} tmux is not installed."
    exit 1
fi

# Check if the tmux session exists
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo -e "${RED}[ERROR]${NC} tmux session ${BLUE}'$SESSION_NAME'${NC} does not exist."
    exit 1
fi

# 1. Interrupt any running process (SIGINT)
tmux send-keys -t "$SESSION_NAME" C-c
tmux send-keys -t "$SESSION_NAME" C-m

# 2. Execute new command if provided
if [ -n "$CMD" ]; then
    # Run the command and then exit
    tmux send-keys -t "$SESSION_NAME" "$CMD" C-m
    echo -e "${GREEN}[SUCCESS]${NC} Command sent to session ${BLUE}'$SESSION_NAME'${NC}."
else
    echo -e "${GREEN}[SUCCESS]${NC} Session ${BLUE}'$SESSION_NAME'${NC} interrupted."
fi

# 3. Always send exit command to close the session
# This will close the shell after the command finishes (or immediately if no cmd)
tmux send-keys -t "$SESSION_NAME" "exit" C-m

echo -e "${YELLOW}[INFO]${NC} Exit signal sent to session ${BLUE}'$SESSION_NAME'${NC}."
