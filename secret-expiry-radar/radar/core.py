"""Metadata validation, expiry policy, and SQLite persistence."""
import json
import math
import sqlite3
from datetime import datetime, timezone, timedelta
from pathlib import Path

KINDS = ('tls', 'api_key', 'aws_access_key', 'azure_secret', 'github_token', 'ssh_key', 'dns_certificate', 'oauth_credential')
FIELDS = {'id', 'name', 'kind', 'owner', 'environment', 'expires_at', 'created_at', 'rotation_days', 'source'}

def now():
    return datetime.now(timezone.utc)

def timestamp(value):
    dt = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if dt.tzinfo is None:
        raise ValueError('Timestamps require a timezone, e.g. 2027-01-01T00:00:00Z')
    return dt.astimezone(timezone.utc)

def validate(item):
    if not isinstance(item, dict) or set(item) - FIELDS:
        raise ValueError('Unknown fields: only credential metadata is accepted')
    result = dict(item)
    for field in ('id', 'name', 'owner', 'environment'):
        if not isinstance(result.get(field), str) or not 1 <= len(result[field]) <= 200:
            raise ValueError(f'{field} must contain 1–200 characters')
    if result.get('kind') not in KINDS:
        raise ValueError('Invalid credential kind')
    if 'source' in result and (not isinstance(result['source'], str) or len(result['source']) > 300):
        raise ValueError('Invalid source')
    for field in ('expires_at', 'created_at'):
        if result.get(field):
            result[field] = timestamp(result[field]).isoformat()
    if result.get('rotation_days') is not None:
        days = result['rotation_days']
        if type(days) is not int or not 1 <= days <= 3650 or not result.get('created_at'):
            raise ValueError('rotation_days needs created_at and an integer from 1 to 3650')
    return result

def evaluate(item, clock=None):
    clock = clock or now()
    candidates = []
    if item.get('expires_at'):
        candidates.append((timestamp(item['expires_at']), 'expiry'))
    if item.get('rotation_days') and item.get('created_at'):
        candidates.append((timestamp(item['created_at']) + timedelta(days=item['rotation_days']), 'rotation'))
    deadline, basis = min(candidates) if candidates else (None, 'unknown')
    seconds = (deadline - clock).total_seconds() if deadline else None
    days = math.ceil(seconds / 86400) if seconds is not None else None
    status = ('unknown' if seconds is None else 'overdue' if seconds <= 0 else
              'critical' if seconds <= 7*86400 else 'warning' if seconds <= 30*86400 else 'healthy')
    return dict(item, deadline=deadline.isoformat() if deadline else None, basis=basis, days=days, status=status)

class Store:
    def __init__(self, path):
        self.path = str(path)
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript("""CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY, data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS deliveries(asset_id TEXT, deadline TEXT, channel TEXT,
            delivered_at TEXT, PRIMARY KEY(asset_id, deadline, channel));
            CREATE TABLE IF NOT EXISTS runs(id INTEGER PRIMARY KEY, at TEXT, summary TEXT);""")
    def connect(self):
        return sqlite3.connect(self.path, timeout=30)
    def upsert(self, items):
        clean = [validate(item) for item in items]
        if len({x['id'] for x in clean}) != len(clean):
            raise ValueError('Duplicate IDs in import')
        with self.connect() as db:
            db.executemany('INSERT INTO assets VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data',
                           [(x['id'], json.dumps(x)) for x in clean])
        return len(clean)
    def items(self):
        with self.connect() as db:
            return [json.loads(row[0]) for row in db.execute('SELECT data FROM assets ORDER BY id')]
    def delivered(self, item, channel):
        with self.connect() as db:
            return db.execute('SELECT 1 FROM deliveries WHERE asset_id=? AND deadline=? AND channel=?',
                              (item['id'], item['deadline'], channel)).fetchone() is not None
    def mark(self, item, channel):
        with self.connect() as db:
            db.execute('INSERT OR IGNORE INTO deliveries VALUES(?,?,?,?)',
                       (item['id'], item['deadline'], channel, now().isoformat()))
    def record(self, summary):
        with self.connect() as db:
            db.execute('INSERT INTO runs(at,summary) VALUES(?,?)', (now().isoformat(), json.dumps(summary)))
            db.execute('DELETE FROM runs WHERE id NOT IN (SELECT id FROM runs ORDER BY id DESC LIMIT 100)')
    def runs(self):
        with self.connect() as db:
            return [dict(at=r[0], summary=json.loads(r[1])) for r in db.execute('SELECT at,summary FROM runs ORDER BY id DESC LIMIT 10')]
