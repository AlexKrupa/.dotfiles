# The check of the branch fails 5 times in a row with HTTP 500: the daemon ends the agent record.
open_branch
agent start branch
check_fail branch 5 "watchd: HTTP 500"
wait_until "the agent record of the branch ends" record_gone branch
