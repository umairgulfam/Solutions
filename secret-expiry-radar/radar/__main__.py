import argparse
import json
import os
import sys
import time
from datetime import timedelta
from .core import Store, now, KINDS
from .alerts import check
from . import collectors
from .server import serve

def main():
    parser = argparse.ArgumentParser(description='Secret Expiry Radar — metadata only')
    parser.add_argument('--db', default=os.getenv('RADAR_DB', 'data/radar.db'))
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('demo', help='Seed synthetic metadata into an empty database')
    imp = commands.add_parser('import', help='Atomically upsert a JSON metadata array')
    imp.add_argument('file')
    commands.add_parser('export')
    remove = commands.add_parser('remove', help='Retire one asset and delete its delivery ledger')
    remove.add_argument('asset_id')
    run = commands.add_parser('check')
    run.add_argument('--send', action='store_true', help='Deliver alerts; default is dry run')
    worker = commands.add_parser('worker')
    worker.add_argument('--send', action='store_true')
    worker.add_argument('--interval', type=int, default=3600)
    web = commands.add_parser('serve')
    web.add_argument('--host', default='127.0.0.1')
    web.add_argument('--port', type=int, default=8080)
    collect = commands.add_parser('collect')
    collect.add_argument('provider', choices=['tls', 'aws', 'azure'])
    collect.add_argument('target', help='Hostname, IAM username, or Azure application ID')
    collect.add_argument('--owner', required=True)
    collect.add_argument('--environment', default='production')
    collect.add_argument('--port', type=int, default=443)
    collect.add_argument('--rotation-days', type=int, default=90)
    args = parser.parse_args()
    store = Store(args.db)
    if args.command == 'demo':
        if store.items():
            raise ValueError('Demo requires an empty database; choose a separate --db')
        names = ['api.example.com', 'Payments API key', 'Deployment access key', 'Azure service principal',
                 'GitHub production token', 'Build runner SSH key', 'DNS service certificate', 'OAuth integration']
        values = [4, 45, 12, 21, 8, None, 2, -2]
        rows = []
        for i, (kind, name, days) in enumerate(zip(KINDS, names, values)):
            row = dict(id=f'demo-{i}', kind=kind, name=name, owner='Platform team', environment='demo', source='synthetic')
            if kind == 'aws_access_key':
                row.update(created_at=(now()-timedelta(days=78)).isoformat(), rotation_days=90)
            elif days is not None:
                row['expires_at'] = (now()+timedelta(days=days)).isoformat()
            rows.append(row)
        print(json.dumps({'imported': store.upsert(rows), 'synthetic': True}))
    elif args.command == 'import':
        with open(args.file) as source:
            rows = json.load(source)
        if not isinstance(rows, list):
            raise ValueError('Expected an array')
        print(json.dumps({'imported': store.upsert(rows)}))
    elif args.command == 'remove':
        with store.connect() as db:
            count = db.execute('DELETE FROM assets WHERE id=?', (args.asset_id,)).rowcount
            db.execute('DELETE FROM deliveries WHERE asset_id=?', (args.asset_id,))
        print(json.dumps({'removed': count}))
    elif args.command == 'export':
        print(json.dumps(store.items(), indent=2))
    elif args.command == 'serve':
        serve(store, args.host, args.port)
    elif args.command in ('check', 'worker'):
        if args.command == 'worker' and args.interval < 60:
            raise ValueError('Interval must be at least 60 seconds')
        while True:
            report = check(store, dry_run=not args.send)
            print(json.dumps(report), flush=True)
            if args.command == 'check':
                return 1 if report['failed'] or (args.send and report['skipped']) else 0
            time.sleep(args.interval)
    elif args.command == 'collect':
        if args.provider == 'tls':
            rows = collectors.tls(args.target, args.port, args.owner, args.environment)
        elif args.provider == 'aws':
            rows = collectors.aws(args.target, args.owner, args.environment, args.rotation_days)
        else:
            rows = collectors.azure(args.target, args.owner, args.environment)
        print(json.dumps({'imported': store.upsert(rows)}))
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Exception,) as exc:
        # Do not leak URLs, CLI stderr, or environment credentials.
        print(f'Operation failed ({type(exc).__name__}). Check inputs, permissions and configuration.', file=sys.stderr)
        sys.exit(1)
