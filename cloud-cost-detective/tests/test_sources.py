from __future__ import annotations

import json
import shutil
import subprocess
from datetime import datetime, timedelta

import pytest

from costdetective.sources import SourceError
from costdetective.sources.azure import _parse_azure_date
from costdetective.sources.git import GitChangeSource, _action_from_subject
from costdetective.sources.terraform import TerraformChangeSource

# --- terraform -----------------------------------------------------------

PLAN = {
    "format_version": "1.2",
    "resource_changes": [
        {
            "address": "module.ai_platform.azurerm_cognitive_deployment.gpt4o",
            "type": "azurerm_cognitive_deployment",
            "change": {"actions": ["create"], "after": {"tags": {"Team": "AI-R&D"}}},
        },
        {
            "address": "aws_db_instance.orders",
            "type": "aws_db_instance",
            "change": {"actions": ["update"], "after": {"instance_class": "db.r6g.xlarge"}},
        },
        {
            "address": "aws_s3_bucket.logs",
            "type": "aws_s3_bucket",
            "change": {"actions": ["no-op"], "after": {}},
        },
    ],
}

STATE = {
    "values": {
        "root_module": {
            "resources": [
                {
                    "address": "aws_instance.web",
                    "type": "aws_instance",
                    "values": {"created_at": "2026-09-02T10:00:00Z", "tags": {"Team": "platform"}},
                }
            ],
            "child_modules": [
                {
                    "resources": [
                        {
                            "address": "module.db.aws_db_instance.orders",
                            "type": "aws_db_instance",
                            "values": {"created_at": "2020-01-01T00:00:00Z"},
                        }
                    ]
                }
            ],
        }
    }
}


def _write(tmp_path, name, payload):
    path = tmp_path / name
    path.write_text(json.dumps(payload))
    return str(path)


def test_plan_json_yields_changes_and_skips_noops(config, tmp_path):
    config.data["terraform"]["plan_json"] = _write(tmp_path, "plan.json", PLAN)
    changes = TerraformChangeSource(config).fetch(since=datetime.utcnow() - timedelta(hours=72))

    assert len(changes) == 2  # the no-op is dropped
    by_type = {c.resource_types[0]: c for c in changes}
    assert by_type["azurerm_cognitive_deployment"].action == "create"
    assert by_type["azurerm_cognitive_deployment"].services == ["AI Foundry"]
    assert by_type["azurerm_cognitive_deployment"].team == "AI-R&D"
    assert by_type["aws_db_instance"].action == "update"


def test_plan_titles_are_human_readable(config, tmp_path):
    config.data["terraform"]["plan_json"] = _write(tmp_path, "plan.json", PLAN)
    changes = TerraformChangeSource(config).fetch(since=datetime.utcnow() - timedelta(hours=72))
    titles = {c.title for c in changes}

    assert "AI Foundry resource created (gpt4o)" in titles
    assert "RDS resource updated (orders)" in titles


def test_state_json_walks_child_modules_and_respects_since(config, tmp_path):
    config.data["terraform"]["state_json"] = _write(tmp_path, "state.json", STATE)
    since = datetime(2026, 9, 1)
    changes = TerraformChangeSource(config).fetch(since=since)

    # Only the recently created instance qualifies; the 2020 database does not.
    assert [c.identifier for c in changes] == ["aws_instance.web"]
    assert changes[0].team == "platform"


def test_missing_plan_file_is_a_clear_error(config):
    config.data["terraform"]["plan_json"] = "/nope/plan.json"
    with pytest.raises(SourceError, match="missing file"):
        TerraformChangeSource(config).fetch(since=datetime.utcnow())


# --- git -----------------------------------------------------------------


@pytest.mark.parametrize(
    ("subject", "expected"),
    [
        ("feat(ai): add gpt-4o deployment", "create"),
        ("remove unused nat gateway", "delete"),
        ("bump instance size", "update"),
    ],
)
def test_action_inferred_from_commit_subject(subject, expected):
    assert _action_from_subject(subject) == expected


@pytest.mark.skipif(shutil.which("git") is None, reason="git not installed")
def test_git_source_reads_real_commits(config, tmp_path):
    repo = tmp_path / "infra"
    repo.mkdir()

    def git(*args):
        subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)

    git("init", "-q")
    git("config", "user.email", "dev@example.com")
    git("config", "user.name", "Test Dev")

    (repo / "foundry.tf").write_text(
        'resource "azurerm_cognitive_deployment" "gpt4o" {\n  name = "gpt4o"\n}\n'
    )
    git("add", ".")
    git("commit", "-q", "-m", "feat(ai): add gpt-4o deployment")

    # A second commit guards against file lists leaking between records.
    (repo / "docs.md").write_text("# runbooks\n")
    git("add", ".")
    git("commit", "-q", "-m", "docs: update runbook links")

    config.data["git"]["repo"] = str(repo)
    changes = GitChangeSource(config).fetch(since=datetime.utcnow() - timedelta(hours=24))

    assert len(changes) == 2
    by_title = {c.title: c for c in changes}

    foundry = by_title["feat(ai): add gpt-4o deployment"]
    assert foundry.author == "Test Dev"
    assert foundry.action == "create"
    assert "azurerm_cognitive_deployment" in foundry.resource_types
    assert "AI Foundry" in foundry.services
    assert foundry.metadata["files"] == ["foundry.tf"]

    docs = by_title["docs: update runbook links"]
    assert docs.metadata["files"] == ["docs.md"]
    assert docs.resource_types == []  # no .tf touched, so no resources inferred


def test_git_source_rejects_a_non_repo(config, tmp_path):
    config.data["git"]["repo"] = str(tmp_path)
    with pytest.raises(SourceError, match="does not look like a git repository"):
        GitChangeSource(config).check()


# --- azure helper --------------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "expected"),
    [("20260903", (2026, 9, 3)), ("2026-09-03T00:00:00Z", (2026, 9, 3))],
)
def test_azure_date_parsing(raw, expected):
    parsed = _parse_azure_date(raw, datetime(2000, 1, 1).date())
    assert (parsed.year, parsed.month, parsed.day) == expected


def test_azure_date_falls_back_on_garbage():
    fallback = datetime(2026, 1, 1).date()
    assert _parse_azure_date("not-a-date", fallback) == fallback
