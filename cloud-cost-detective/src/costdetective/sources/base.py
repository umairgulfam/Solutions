"""Source interfaces.

A *cost source* answers "what did we spend?".
A *change source* answers "what did we change?".

Adding a provider means implementing one of these and registering it in
``costdetective/sources/__init__.py`` — nothing else in the codebase changes.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from datetime import datetime

from costdetective.config import Config
from costdetective.models import Change, CostSnapshot


class SourceError(RuntimeError):
    """A source could not produce data (missing creds, bad path, API failure)."""


class CostSource(ABC):
    """Fetches spend for a period and its comparable baseline."""

    name: str = "base"

    def __init__(self, config: Config) -> None:
        self.config = config

    @abstractmethod
    def fetch(self, days: int = 1) -> CostSnapshot:
        """Return a snapshot comparing the last ``days`` against the prior ``days``."""

    def check(self) -> None:  # noqa: B027 - intentionally optional to override
        """Raise :class:`SourceError` if this source is not usable. Optional."""


class ChangeSource(ABC):
    """Fetches things that happened, to correlate against spend."""

    name: str = "base"

    def __init__(self, config: Config) -> None:
        self.config = config

    @abstractmethod
    def fetch(self, since: datetime) -> list[Change]:
        """Return changes that occurred at or after ``since``."""

    def check(self) -> None:  # noqa: B027 - optional hook, not all sources need it
        """Raise :class:`SourceError` if this source is not usable. Optional."""
