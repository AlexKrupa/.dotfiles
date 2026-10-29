open_branch
agent start branch
check_fail branch 5 "watchd: HTTP 500"
wait_until "the agent record of the branch ends" record_gone branch
