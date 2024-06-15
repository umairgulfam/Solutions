import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from unittest.mock import patch
from radar.core import Store, evaluate, validate
from radar.alerts import check, send, post
from radar.collectors import aws, azure
from radar.server import handler, serve

CLOCK = datetime(2026, 9, 3, 12, tzinfo=timezone.utc)
def asset(days=4, **overrides):
    row = dict(id='test', name='Example credential', owner='Platform', environment='test', kind='api_key',
               expires_at=(CLOCK+timedelta(days=days)).isoformat())
    row.update(overrides)
    return row

class PolicyTests(unittest.TestCase):
    def test_status_boundaries_and_unknown(self):
        for days, expected in [(-1,'overdue'),(0,'overdue'),(3,'critical'),(7,'critical'),(8,'warning'),(30,'warning'),(31,'healthy')]:
            self.assertEqual(evaluate(asset(days), CLOCK)['status'], expected)
        self.assertEqual(evaluate(asset(expires_at=None), CLOCK)['status'], 'unknown')
    def test_exact_threshold_does_not_alert_early(self):
        row = asset(expires_at=(CLOCK+timedelta(days=7, seconds=1)).isoformat())
        self.assertEqual(evaluate(row, CLOCK)['days'], 8)
    def test_rotation_and_earliest_deadline(self):
        row = asset(50, created_at=(CLOCK-timedelta(days=85)).isoformat(), rotation_days=90)
        result = evaluate(validate(row), CLOCK)
        self.assertEqual((result['days'], result['basis']), (5, 'rotation'))
    def test_validation_rejects_secret_fields_and_naive_dates(self):
        for row in [asset(secret='do-not-store'), asset(expires_at='2026-09-01'), asset(rotation_days=True, created_at=CLOCK.isoformat())]:
            with self.assertRaises(ValueError): validate(row)
    def test_utc_normalization(self):
        self.assertEqual(validate(asset(expires_at='2026-09-03T17:00:00+05:00'))['expires_at'], CLOCK.isoformat())

class StorageAndDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.store=Store(self.tmp.name+'/radar.db')
    def tearDown(self): self.tmp.cleanup()
    def test_import_is_atomic_and_duplicate_ids_rejected(self):
        for values in [[asset(),asset(id='other',secret='no')],[asset(),asset()]]:
            with self.assertRaises(ValueError):self.store.upsert(values)
        self.assertEqual(self.store.items(), [])
    def test_dry_run_does_not_mark_or_send(self):
        self.store.upsert([asset(2)])
        with patch('radar.alerts.send') as sender:
            result=check(self.store,clock=CLOCK,sender=sender)
            sender.assert_not_called()
        self.assertEqual(result['due'],4)
        self.assertFalse(self.store.delivered(evaluate(asset(2),CLOCK),'slack'))
    def test_delivery_dedup_persists_and_new_expiry_realerts(self):
        self.store.upsert([asset(2)])
        report=check(self.store,dry_run=False,clock=CLOCK,sender=lambda *_:True)
        self.assertEqual(report['sent'],4)
        reopened=Store(self.store.path)
        self.assertEqual(check(reopened,dry_run=False,clock=CLOCK,sender=lambda *_:True)['due'],0)
        self.store.upsert([asset(1)])
        self.assertEqual(check(self.store,dry_run=False,clock=CLOCK,sender=lambda *_:True)['sent'],4)
    def test_failure_and_unconfigured_channels_are_retried(self):
        self.store.upsert([asset(2)])
        def sender(channel,item):
            if channel=='email':raise RuntimeError('sensitive text')
            return channel=='notification'
        result=check(self.store,dry_run=False,clock=CLOCK,sender=sender)
        self.assertEqual((result['sent'],result['skipped'],result['failed']),(1,2,1))
        self.assertNotIn('sensitive text',json.dumps(self.store.runs()))
        self.assertEqual(check(self.store,dry_run=False,clock=CLOCK,sender=lambda *_:True)['sent'],3)
    def test_each_channel_threshold(self):
        for days,count in [(31,0),(30,1),(14,2),(7,3),(3,4),(-2,4)]:
            self.store.upsert([asset(days)])
            self.assertEqual(check(self.store,clock=CLOCK)['due'],count)

class CollectorTests(unittest.TestCase):
    @patch('radar.collectors.cli')
    def test_aws_active_keys_are_rotation_metadata(self, cli):
        cli.side_effect=[{'Account':'123456789012'},{'AccessKeyMetadata':[
            {'AccessKeyId':'TESTONLY1234','CreateDate':CLOCK.isoformat(),'Status':'Active'},
            {'AccessKeyId':'TESTONLY5678','CreateDate':CLOCK.isoformat(),'Status':'Inactive'}]}]
        rows=aws('deploy','Platform','test',90)
        self.assertEqual(len(rows),1);self.assertNotIn('expires_at',rows[0])
        self.assertEqual(rows[0]['rotation_days'],90)
    @patch('radar.collectors.cli')
    def test_azure_does_not_copy_secret_fields(self, cli):
        cli.side_effect=[{'tenantId':'tenant' },[{'keyId':'id','displayName':'app','endDateTime':CLOCK.isoformat(),'secretText':'never copy'}]]
        row=azure('app-id','Platform','test')[0]
        self.assertNotIn('secretText',row);validate(row)
    @patch('radar.alerts.post')
    def test_pagerduty_payload_and_stable_dedup(self, post_mock):
        with patch.dict(os.environ,{'PAGERDUTY_ROUTING_KEY':'test-placeholder'}):
            send('pagerduty',evaluate(asset(),CLOCK));send('pagerduty',evaluate(asset(),CLOCK))
        first=post_mock.call_args_list[0].args[1]
        self.assertEqual(first['event_action'],'trigger')
        self.assertEqual(first['dedup_key'],post_mock.call_args_list[1].args[1]['dedup_key'])
    def test_non_https_delivery_rejected(self):
        with self.assertRaises(ValueError):post('http://example.com',{})

class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.store=Store(self.tmp.name+'/radar.db');self.store.upsert([asset()])
        self.env=patch.dict(os.environ,{'RADAR_API_TOKEN':'x'*32});self.env.start()
        self.server=ThreadingHTTPServer(('127.0.0.1',0),handler(self.store))
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.url=f'http://127.0.0.1:{self.server.server_port}'
    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join();self.env.stop();self.tmp.cleanup()
    def test_api_requires_token(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:urllib.request.urlopen(self.url+'/api/assets')
        self.assertEqual(ctx.exception.code,401)
        request=urllib.request.Request(self.url+'/api/assets',headers={'Authorization':'Bearer '+'x'*32})
        with urllib.request.urlopen(request) as response:
            self.assertEqual(len(json.load(response)['assets']),1)
    def test_static_assets_and_security_headers(self):
        for path in ['/','/app.js','/style.css','/healthz']:
            with urllib.request.urlopen(self.url+path) as response:
                self.assertEqual(response.status,200)
                self.assertIn("frame-ancestors 'none'",response.headers['Content-Security-Policy'])
    def test_remote_binding_requires_strong_token(self):
        with patch.dict(os.environ,{'RADAR_API_TOKEN':''}):
            with self.assertRaises(ValueError):serve(self.store,'0.0.0.0',0)

if __name__=='__main__':unittest.main()
