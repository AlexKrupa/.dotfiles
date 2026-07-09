#!/usr/bin/env bash
source "$(dirname "$0")/_common.sh"
init_hook

printf 'Active design doc exists at %s. Before compaction, run /doc-sync to capture decisions made this session.\n' "$doc"
