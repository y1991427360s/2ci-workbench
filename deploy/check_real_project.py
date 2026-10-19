"""Server-side API acceptance against the migrated real project."""
import hashlib
import json
import os
from pathlib import Path

base = Path('/home/ubuntu/2ci-workbench')
for line in (base/'.env').read_text().splitlines():
    key, value = line.split('=', 1)
    os.environ[key] = value
import sys
sys.path.insert(0, str(base))
import app as web
client = web.app.test_client()
with client.session_transaction() as s:
    s['authenticated'] = True
    s['csrf'] = 'server-acceptance'
pid = next(p.name for p in web.ROOT.iterdir() if (p/'project.json').exists() and (p/'自动统计.xlsx').exists())
source = web.ROOT/pid/'自动统计.xlsx'
before = hashlib.sha256(source.read_bytes()).hexdigest()
response = client.post('/api/projects/'+pid+'/calculate', json={}, headers={'X-CSRF-Token': 'server-acceptance'})
assert response.status_code == 200, response.json
assert before == hashlib.sha256(source.read_bytes()).hexdigest()
result = response.json['result']
print(json.dumps({'project': pid, 'total': result['total'], 'ok': result['ok'], 'failed': result['failed'],
                  'summary': result['summary'], 'original_unchanged': True}, ensure_ascii=False))
