.PHONY: check fmt lint test

check: fmt lint test

fmt:
	cargo fmt --check

lint:
	cargo clippy -q --all-targets --locked -- -D warnings

test:
	./test.sh
