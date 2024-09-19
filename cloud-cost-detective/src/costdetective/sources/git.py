"""Git change source.

Reads commits from an infrastructure repository and turns each into a
:class:`~costdetective.models.Change`. Touched ``.tf`` files give us resource
types directly; the commit subject gives us keyword hints.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

from costdetective.models import Change
from costdetective.servicemap import default_map
from costdetective.sources.base import ChangeSource, SourceError

_SEPARATOR = "\x1e"  # record separator, safe inside commit messages
_FIELD = "\x1f"
_RESOURCE_RE = re.compile(r'resource\s+"([a-z0-9_]+)"', re.IGNORECASE)


class GitChangeSource(ChangeSource):
    name = "git"

    def check(self) -> None:
        if shutil.which("git") is None:
            raise SourceError("`git` binary not found on PATH")
        repo = Path(self.config.get("git.repo", ".")).expanduser()
        if not (repo / ".git").exists():
            raise SourceError(f"{repo} does not look like a git repository")

    def _run(self, args: list[str]) -> str:
        repo = Path(self.config.get("git.repo", ".")).expanduser()
        try:
            proc = subprocess.run(
                ["git", "-C", str(repo), *args],
                capture_output=True,
                text=True,
                timeout=60,
                check=True,
            )
        except FileNotFoundError as exc:
            raise SourceError("`git` binary not found on PATH") from exc
        except subprocess.CalledProcessError as exc:
            raise SourceError(f"git {' '.join(args)} failed: {exc.stderr.strip()}") from exc
        except subprocess.TimeoutExpired as exc:
            raise SourceError("git command timed out after 60s") from exc
        return proc.stdout

    def fetch(self, since: datetime) -> list[Change]:
        max_commits = int(self.config.get("git.max_commits", 200))
        branch = self.config.get("git.branch")
        # The separator must LEAD the record: `--name-only` appends filenames
        # after the formatted header, so a trailing separator would file each
        # commit's paths under the following commit.
        fmt = _SEPARATOR + _FIELD.join(["%H", "%an", "%aI", "%s"])

        args = [
            "log",
            f"--since={since.isoformat()}",
            f"--max-count={max_commits}",
            f"--pretty=format:{fmt}",
            "--name-only",
        ]
        if branch:
            args.append(branch)

        raw = self._run(args)
        smap = default_map()
        changes: list[Change] = []

        for record in raw.split(_SEPARATOR):
            record = record.strip("\n")
            if not record.strip():
                continue
            header, _, files_block = record.partition("\n")
            parts = header.split(_FIELD)
            if len(parts) < 4:
                continue
            sha, author, iso_date, subject = parts[0], parts[1], parts[2], parts[3]
            try:
                timestamp = datetime.fromisoformat(iso_date).replace(tzinfo=None)
            except ValueError:
                continue

            files = [f for f in files_block.splitlines() if f.strip()]
            resource_types = self._resource_types(sha, files)
            services = sorted(
                {
                    s
                    for rt in resource_types
                    if (s := smap.service_for_resource_type(rt)) is not None
                }
                | set(smap.services_in_text(subject + " " + " ".join(files)))
            )

            changes.append(
                Change(
                    source="git",
                    identifier=sha[:7],
                    title=subject,
                    timestamp=timestamp,
                    action=_action_from_subject(subject),
                    author=author,
                    resource_types=sorted(resource_types),
                    services=services,
                    metadata={"files": files, "sha": sha},
                )
            )

        return changes

    def _resource_types(self, sha: str, files: list[str]) -> set[str]:
        """Pull `resource "aws_x"` declarations out of the added lines of a commit."""
        tf_files = [f for f in files if f.endswith((".tf", ".tf.json", ".hcl"))]
        if not tf_files:
            return set()
        try:
            diff = self._run(["show", "--unified=0", "--format=", sha, "--", *tf_files])
        except SourceError:
            return set()
        added = "\n".join(
            line for line in diff.splitlines() if line.startswith("+") and not line.startswith("+++")
        )
        return set(_RESOURCE_RE.findall(added))


def _action_from_subject(subject: str) -> str:
    lowered = subject.lower()
    if any(word in lowered for word in ("add", "create", "introduce", "feat(", "new ")):
        return "create"
    if any(word in lowered for word in ("remove", "delete", "destroy", "drop")):
        return "delete"
    return "update"
