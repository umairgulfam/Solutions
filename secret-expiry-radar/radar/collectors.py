"""Explicit operator-run collection; dashboard input cannot initiate network scans."""
import json
import socket
import ssl
import subprocess
from datetime import datetime, timezone

def cli(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90, check=False)
    if result.returncode:
        raise RuntimeError('Cloud CLI collection failed; check local authentication and permissions')
    return json.loads(result.stdout)

def tls(host, port, owner, environment):
    with socket.create_connection((host, port), timeout=10) as sock:
        with ssl.create_default_context().wrap_socket(sock, server_hostname=host) as conn:
            cert = conn.getpeercert()
    expires = datetime.fromtimestamp(ssl.cert_time_to_seconds(cert['notAfter']), timezone.utc)
    return [{'id': f'tls:{host}:{port}', 'name': host, 'kind': 'tls', 'owner': owner,
             'environment': environment, 'expires_at': expires.isoformat(), 'source': 'verified-tls'}]

def aws(user, owner, environment, rotation_days):
    account = cli(['aws', 'sts', 'get-caller-identity', '--output', 'json'])['Account']
    data = cli(['aws', 'iam', 'list-access-keys', '--user-name', user, '--output', 'json'])
    return [{'id': f"aws:{account}:{key['AccessKeyId']}", 'name': f"{user} / …{key['AccessKeyId'][-4:]}",
             'kind': 'aws_access_key', 'created_at': key['CreateDate'], 'rotation_days': rotation_days,
             'owner': owner, 'environment': environment, 'source': 'aws-iam'}
            for key in data['AccessKeyMetadata'] if key['Status'] == 'Active']

def azure(app_id, owner, environment):
    account = cli(['az', 'account', 'show', '--output', 'json'])
    values = cli(['az', 'ad', 'app', 'credential', 'list', '--id', app_id, '--output', 'json'])
    return [{'id': f"azure:{account['tenantId']}:{app_id}:{x['keyId']}",
             'name': x.get('displayName') or f'Application {app_id}', 'kind': 'azure_secret',
             'owner': owner, 'environment': environment, 'expires_at': x.get('endDateTime'),
             'source': 'azure-app-registration'} for x in values]
