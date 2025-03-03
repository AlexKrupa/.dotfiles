#!/bin/env bash
SESSION_NAME="0-me"

# Check if the session already exists
/opt/homebrew/bin/tmux has-session -t $SESSION_NAME 2>/dev/null

if [ $? -eq 0 ]; then
 # If the session exists, reattach to it
 # /opt/homebrew/bin/tmux attach-session -t $SESSION_NAME
 /opt/homebrew/bin/tmux
else
 # If the session doesn't exist, start a new one
 /opt/homebrew/bin/tmux new-session -s $SESSION_NAME -d
 /opt/homebrew/bin/tmux attach-session -t $SESSION_NAME
fi
