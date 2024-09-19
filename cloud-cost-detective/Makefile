.DEFAULT_GOAL := help
.PHONY: help install test test-cov lint format typecheck demo docker docker-run clean build all

PYTHON  ?= python3
IMAGE   ?= cloud-cost-detective
TAG     ?= local

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install: ## Editable install with dev extras
	$(PYTHON) -m pip install -e ".[dev]"

test: ## Run the test suite
	$(PYTHON) -m pytest

test-cov: ## Run tests with a coverage report
	$(PYTHON) -m pytest --cov=costdetective --cov-report=term-missing --cov-report=xml

lint: ## Lint with ruff
	$(PYTHON) -m ruff check .

format: ## Auto-fix lint and format
	$(PYTHON) -m ruff check --fix .
	$(PYTHON) -m ruff format .

typecheck: ## Static types with mypy
	$(PYTHON) -m mypy

demo: ## Run the offline scenario
	costdetective report --demo --verbose

docker: ## Build the container image
	docker build -t $(IMAGE):$(TAG) .

docker-run: docker ## Build then run the demo in the container
	docker run --rm $(IMAGE):$(TAG) report --demo

build: ## Build wheel and sdist
	$(PYTHON) -m build

clean: ## Remove build and test artefacts
	rm -rf build dist *.egg-info .pytest_cache .ruff_cache .mypy_cache .coverage coverage.xml htmlcov
	find . -type d -name __pycache__ -prune -exec rm -rf {} +

all: lint typecheck test ## Everything CI runs

check: lint typecheck test ## Alias for `all` — everything CI runs
.PHONY: check

install-all: ## Editable install with every cloud SDK
	$(PYTHON) -m pip install -e ".[aws,azure,dev]"
.PHONY: install-all

demo-json: ## Offline scenario as JSON
	costdetective report --demo --format json
.PHONY: demo-json
