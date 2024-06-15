"""Escalating, retryable delivery. One worker per database is required."""
import hashlib
import json
import os
import smtplib
import ssl
import urllib.request
from email.message import EmailMessage
from .core import evaluate

THRESHOLDS = {'notification': 30, 'slack': 14, 'email': 7, 'pagerduty': 3}

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def post(url, body):
    if not url.startswith('https://'):
        raise ValueError('HTTPS required')
    request = urllib.request.Request(url, json.dumps(body).encode(), {'Content-Type': 'application/json'})
    with urllib.request.build_opener(NoRedirect).open(request, timeout=15) as response:
        if not 200 <= response.status < 300:
            raise RuntimeError('Delivery rejected')

def send(channel, item):
    message = f"{item['name']}: {item['basis']} deadline {item['deadline']} ({item['days']} days). Owner: {item['owner']}"
    if channel == 'notification':
        return True  # Persisted in local delivery ledger; visible as dashboard notification count.
    if channel == 'slack':
        url = os.getenv('SLACK_WEBHOOK_URL')
        if not url:
            return False
        post(url, {'text': message})
    elif channel == 'pagerduty':
        key = os.getenv('PAGERDUTY_ROUTING_KEY')
        if not key:
            return False
        dedup = hashlib.sha256(f"{item['id']}:{item['deadline']}".encode()).hexdigest()
        post('https://events.pagerduty.com/v2/enqueue', {'routing_key': key, 'event_action': 'trigger',
             'dedup_key': dedup, 'payload': {'summary': message, 'source': 'secret-expiry-radar', 'severity': 'critical'}})
    elif channel == 'email':
        if not all(os.getenv(k) for k in ('SMTP_HOST', 'SMTP_FROM', 'SMTP_TO')):
            return False
        mail = EmailMessage()
        mail['Subject'] = '[Secret Expiry Radar] Action required'
        mail['From'] = os.environ['SMTP_FROM']
        mail['To'] = os.environ['SMTP_TO']
        mail.set_content(message)
        with smtplib.SMTP(os.environ['SMTP_HOST'], int(os.getenv('SMTP_PORT', '587')), timeout=15) as smtp:
            smtp.starttls(context=ssl.create_default_context())
            if os.getenv('SMTP_USER'):
                smtp.login(os.environ['SMTP_USER'], os.environ['SMTP_PASSWORD'])
            smtp.send_message(mail)
    return True

def check(store, *, dry_run=True, clock=None, sender=send):
    summary = {'dry_run': dry_run, 'due': 0, 'sent': 0, 'skipped': 0, 'failed': 0, 'events': []}
    for raw in store.items():
        item = evaluate(raw, clock)
        for channel, threshold in THRESHOLDS.items():
            if item['days'] is None or item['days'] > threshold or store.delivered(item, channel):
                continue
            summary['due'] += 1
            state = 'would_send'
            if not dry_run:
                try:
                    if sender(channel, item):
                        store.mark(item, channel)
                        summary['sent'] += 1
                        state = 'sent'
                    else:
                        summary['skipped'] += 1
                        state = 'not_configured'
                except Exception:
                    # Never log exception text: upstream errors can contain credentials/URLs.
                    summary['failed'] += 1
                    state = 'failed'
            summary['events'].append({'asset_id': item['id'], 'channel': channel, 'state': state})
    store.record(summary)
    return summary
