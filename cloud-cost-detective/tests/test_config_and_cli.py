from __future__ import annotations

import json

import pytest

from costdetective.cli import main
from costdetective.config import ConfigError, load_config
from costdetective.sources import SourceError, build_change_sources, build_cost_source

# --- config --------------------------------------------------------------


def test_yaml_overrides_defaults(tmp_path):
    path = tmp_path / "costdetective.yaml"
    path.write_text("cost_source: aws\nmin_delta: 5.5\naws:\n  region: eu-west-1\n")

    config = load_config(path)
    assert config.get("cost_source") == "aws"
    assert config.get("min_delta") == 5.5
    assert config.get("aws.region") == "eu-west-1"
    assert config.get("aws.metric") == "UnblendedCost"  # default preserved


def test_env_vars_are_expanded(tmp_path, monkeypatch):
    monkeypatch.setenv("MY_SUB", "sub-1234")
    path = tmp_path / "costdetective.yaml"
    path.write_text("azure:\n  subscription_id: ${MY_SUB}\n  scope: ${MISSING:-/subscriptions/x}\n")

    config = load_config(path)
    assert config.get("azure.subscription_id") == "sub-1234"
    assert config.get("azure.scope") == "/subscriptions/x"


def test_env_overrides_beat_the_file(tmp_path, monkeypatch):
    path = tmp_path / "costdetective.yaml"
    path.write_text("cost_source: demo\n")
    monkeypatch.setenv("COSTDETECTIVE_COST_SOURCE", "aws")

    assert load_config(path).get("cost_source") == "aws"


def test_missing_config_file_raises():
    with pytest.raises(ConfigError, match="not found"):
        load_config("/nonexistent/costdetective.yaml")


def test_validation_catches_bad_values(tmp_path):
    path = tmp_path / "costdetective.yaml"
    path.write_text("cost_source: gcp\nchange_sources: [svn]\n")

    problems = load_config(path).validate()
    assert len(problems) == 2
    assert any("gcp" in p for p in problems)


def test_azure_without_subscription_is_invalid(tmp_path):
    path = tmp_path / "costdetective.yaml"
    path.write_text("cost_source: azure\n")
    assert any("subscription_id" in p for p in load_config(path).validate())


# --- source registry -----------------------------------------------------


def test_unknown_source_names_are_rejected(config):
    with pytest.raises(SourceError, match="unknown cost source"):
        build_cost_source(config, "gcp")
    with pytest.raises(SourceError, match="unknown change source"):
        build_change_sources(config, ["mercurial"])


def test_demo_source_reproduces_the_scenario(config):
    snapshot = build_cost_source(config, "demo").fetch(days=1)
    assert snapshot.total_delta == 47.0
    assert {s.service for s in snapshot.increases()} == {"EC2", "RDS", "API Gateway", "AI Foundry"}


# --- CLI -----------------------------------------------------------------


def test_report_demo_exits_clean(capsys):
    assert main(["report", "--demo"]) == 0
    out = capsys.readouterr().out
    assert "Today's increase: +$47" in out
    assert "Review unused deployment." in out


def test_report_json_is_parseable(capsys):
    assert main(["report", "--demo", "--format", "json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["snapshot"]["total_delta"] == 47.0


def test_report_writes_to_a_file(tmp_path):
    target = tmp_path / "nested" / "report.md"
    assert main(["report", "--demo", "-f", "markdown", "-o", str(target)]) == 0
    assert "| Service | Change |" in target.read_text()


def test_fail_over_threshold_returns_exit_code_two(capsys):
    assert main(["report", "--demo", "--fail-over", "10"]) == 2
    assert "exceeds threshold" in capsys.readouterr().err


def test_fail_over_below_threshold_passes():
    assert main(["report", "--demo", "--fail-over", "100"]) == 0


def test_explain_known_service(capsys):
    assert main(["explain", "AI Foundry", "--demo"]) == 0
    out = capsys.readouterr().out
    assert "+325.0%" in out
    assert "azurerm_cognitive_deployment" in out


def test_explain_unknown_service_errors(capsys):
    assert main(["explain", "Redshift", "--demo"]) == 1
    assert "no increase recorded" in capsys.readouterr().err


def test_sources_command_lists_providers(capsys):
    assert main(["sources"]) == 0
    out = capsys.readouterr().out
    assert "aws" in out and "terraform" in out


def test_validate_command_accepts_defaults(capsys):
    assert main(["validate", "--demo"]) == 0
    assert "configuration OK" in capsys.readouterr().out


def test_min_delta_flag_is_honoured(capsys):
    assert main(["report", "--demo", "--min-delta", "12.5"]) == 0
    out = capsys.readouterr().out
    assert "EC2" not in out
    assert "RDS" in out
