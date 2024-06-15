"""Read-only local dashboard. Use a trusted TLS/auth proxy for remote access."""
import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from .core import evaluate

STATIC = Path(__file__).parent / 'static'

def handler(store):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass
        def respond(self, code, content, mime='application/json'):
            self.send_response(code)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(content)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'")
            self.end_headers()
            self.wfile.write(content)
        def do_GET(self):
            if self.path == '/healthz':
                return self.respond(200, b'{"status":"ok"}')
            if self.path == '/api/assets':
                token = os.environ.get('RADAR_API_TOKEN', '')
                if token and not hmac.compare_digest(self.headers.get('Authorization', '').encode(), ('Bearer ' + token).encode()):
                    return self.respond(401, b'{"error":"Authentication required"}')
                rows = [evaluate(x) for x in store.items()]
                rows.sort(key=lambda x: (x['deadline'] is None, x['deadline'] or ''))
                with store.connect() as db:
                    notifications = db.execute("SELECT COUNT(*) FROM deliveries d JOIN assets a ON a.id=d.asset_id WHERE channel='notification'").fetchone()[0]
                payload = {'assets': rows, 'runs': store.runs(), 'notifications': notifications}
                return self.respond(200, json.dumps(payload).encode())
            paths = {'/': ('index.html', 'text/html; charset=utf-8'), '/app.js': ('app.js', 'text/javascript'), '/style.css': ('style.css', 'text/css')}
            if self.path not in paths:
                return self.respond(404, b'{"error":"Not found"}')
            file, mime = paths[self.path]
            self.respond(200, (STATIC/file).read_bytes(), mime)
    return Handler

def serve(store, host='127.0.0.1', port=8080):
    if host not in ('127.0.0.1', 'localhost', '::1') and len(os.getenv('RADAR_API_TOKEN', '')) < 32:
        raise ValueError('A RADAR_API_TOKEN of at least 32 characters is required for non-loopback binding')
    server = ThreadingHTTPServer((host, port), handler(store))
    print(f'Radar dashboard listening on {host}:{port}', flush=True)
    server.serve_forever()
