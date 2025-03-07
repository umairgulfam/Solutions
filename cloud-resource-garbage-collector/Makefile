.PHONY: install test lint security run scan demo docker clean

install:
	python -m pip install -e ".[all,dev]"

test:
	pytest

lint:
	ruff check .
	ruff format --check .
	mypy src

security:
	bandit -c pyproject.toml -r src

run:
	uvicorn garbage_collector.api:app --reload --port 8080

scan:
	crgc scan --provider mock --output table

demo:
	crgc seed-demo
	uvicorn garbage_collector.api:app --reload --port 8080

docker:
	docker compose up --build

clean:
	find . -type d -name __pycache__ -prune -exec rm -rf {} +
	rm -rf .pytest_cache .ruff_cache .mypy_cache htmlcov .coverage

