"""Notification backends."""

from costdetective.notify.slack import NotifyError, post_to_slack

__all__ = ["NotifyError", "post_to_slack"]
