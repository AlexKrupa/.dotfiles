# Herdr panes that run one command skip the rest of the interactive config.
# conf.d files load in name order, so this exec runs before the ~90 ms of rbenv, prompt and
# history init that a single `nvim FILE` never uses. pluck-open sets the two variables.
if status is-interactive; and set -q HERDR_PANE_CMD
    exec fish --no-config -c "$HERDR_PANE_CMD"
end
