import os
import secrets
from pathlib import Path
from werkzeug.security import generate_password_hash

base = Path(__file__).resolve().parents[1]
env = base / '.env'
if env.exists():
    raise SystemExit('Credentials already exist; refusing to replace')
password = secrets.token_urlsafe(18)
env.write_text('SECRET_KEY='+secrets.token_hex(32)+'\nPASSWORD_HASH='+generate_password_hash(password)+
               '\nCOOKIE_SECURE=1\nDATA_DIR=/home/ubuntu/2ci-data\n', encoding='utf-8')
target = Path('D:/Users/ys199/Documents/2ci网页版登录信息.txt')
target.write_text('电气二次设计工作台网页版\n网址：https://2ci.sen666.com\n密码：'+password+
                  '\n服务器：9号 / 10.241.188.23\n服务：2ci.service\n数据：/home/ubuntu/2ci-data\n', encoding='utf-8')
print('Credentials saved; password omitted from logs')
