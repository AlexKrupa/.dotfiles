# $GOPATH is set in conf.d/01-env.fish, so `go env GOPATH` would only re-read it from a fork.
fish_add_path -ga $GOPATH/bin

