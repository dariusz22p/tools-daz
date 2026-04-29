.PHONY: test test-bats test-python lint check all clean

# Run all tests
test: test-bats test-python

# Run bats shell tests
test-bats:
	bats tests/server/*.bats tests/macbook/*.bats tests/minecraft/*.bats

# Run Python tests
test-python:
	cd sharepoint && python -m pytest test_sharepoint_dl.py -v

# Run ShellCheck on all shell scripts
lint:
	find . -name '*.sh' -not -path './.venv/*' -print0 | xargs -0 shellcheck --severity=warning
	uvx ruff check .

# Run all checks (lint + test)
check: lint test

# Setup development environment
setup:
	python3 -m venv .venv
	. .venv/bin/activate && pip install -r requirements.txt
	@echo "Run 'source .venv/bin/activate' to activate the venv"
	@echo "Run 'pre-commit install' to enable git hooks"

# Clean build artifacts
clean:
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name .ruff_cache -exec rm -rf {} + 2>/dev/null || true
