"""Run on server 9 after DNS-01 certificate issuance."""
from pathlib import Path
import shutil
import subprocess

root = Path('/home/ubuntu/2ci-workbench')
stream = Path('/etc/nginx/stream.d/443-sni.conf')
text = stream.read_text()
if '2ci.sen666.com' not in text:
    shutil.copy2(stream, stream.with_name('443-sni.conf.before-2ci'))
    text = text.replace('map $ssl_preread_server_name $tls_backend_443 {',
                        'map $ssl_preread_server_name $tls_backend_443 {\n\t2ci.sen666.com\t127.0.0.1:9529;')
    stream.write_text(text)
shutil.copy2(root/'deploy/2ci.nginx.conf', '/etc/nginx/sites-available/2ci.sen666.com')
enabled = Path('/etc/nginx/sites-enabled/2ci.sen666.com')
if not enabled.exists():
    enabled.symlink_to('/etc/nginx/sites-available/2ci.sen666.com')
subprocess.run(['nginx', '-t'], check=True)
shutil.copy2(root/'deploy/2ci.service', '/etc/systemd/system/2ci.service')
subprocess.run(['systemctl', 'daemon-reload'], check=True)
subprocess.run(['systemctl', 'enable', '--now', '2ci'], check=True)
subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
