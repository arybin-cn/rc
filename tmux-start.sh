#!/bin/bash

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check the number of arguments
if [ "$#" -ne 3 ]; then
    echo -e "${RED}[ERROR]${NC} Invalid number of arguments."
    echo -e "${YELLOW}Usage:${NC} $0 <session_name> <directory> <command>"
    exit 1
fi

SESSION_NAME=$1
DIRECTORY=$2
COMMAND=$3

# Generate log filename
LOG_FILE="${SESSION_NAME}_$(date +%Y%m%d).log"

# Check if tmux is installed
if ! command -v tmux &> /dev/null; then
    echo -e "${RED}[ERROR]${NC} tmux is not installed. Please install it first."
    exit 1
fi

# Check if directory exists
if [ ! -d "$DIRECTORY" ]; then
    echo -e "${RED}[ERROR]${NC} Directory '${BLUE}$DIRECTORY${NC}' does not exist."
    exit 1
fi

# Check if the tmux session already exists
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo -e "${YELLOW}[CANCEL]${NC} tmux session ${BLUE}'$SESSION_NAME'${NC} already exists. Operation canceled."
    exit 0
fi

# 1. Create a new tmux session
if tmux new-session -d -s "$SESSION_NAME"; then
    # 2. Set the working directory
    tmux send-keys -t "$SESSION_NAME" "cd $DIRECTORY" C-m

    # 3. Start pipe-pane
    tmux pipe-pane -t "$SESSION_NAME" "exec cat >> $DIRECTORY/$LOG_FILE"

    # 4. Execute the command
    tmux send-keys -t "$SESSION_NAME" "$COMMAND" C-m

    # --- Success Message ---
    echo -e "${GREEN}[SUCCESS]${NC} Session ${BLUE}'$SESSION_NAME'${NC} started successfully."
    echo -e "  - Log path: ${BLUE}$DIRECTORY/$LOG_FILE${NC}"
    echo -e "  - View live: ${YELLOW}tmux attach -t $SESSION_NAME${NC}"
else
    echo -e "${RED}[ERROR]${NC} Failed to create tmux session."
    exit 1
fi
