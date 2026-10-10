import hashlib
import io
import os
import tempfile
import unittest
import zipfile
from pathlib import Path

from werkzeug.security import generate_password_hash
import openpyxl
import ezdxf

os.environ["COOKIE_SECURE"] = "0"
os.environ["PASSWORD_HASH"] = generate_password_hash("test-password")
import app as web


class WebTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        web.ROOT = Path(self.tmp.name)
        web.app.config.update(TESTING=True, SESSION_COOKIE_SECURE=False)
        self.client = web.app.test_client()
        self.csrf = self.client.get('/api/session').json['csrf']

    def tearDown(self):
        self.tmp.cleanup()

    def call(self, path, method='GET', data=None):
        return self.client.open('/api'+path, method=method, json=data,
                                headers={'X-CSRF-Token': self.csrf})

    def login(self):
        response = self.call('/login', 'POST', {'password': 'test-password'})
        self.assertEqual(response.status_code, 200)
        self.csrf = response.json['csrf']

    def test_auth_and_csrf(self):
        self.assertEqual(self.call('/projects').status_code, 401)
        self.assertEqual(self.client.post('/api/login', json={'password': 'test-password'}).status_code, 403)
        self.login()
        self.assertEqual(self.call('/projects').status_code, 200)
        self.assertEqual(self.call('/projects/../../file/.env').status_code, 404)

    def test_end_to_end(self):
        self.login()
        response = self.call('/projects', 'POST', {'name': '验收工程'})
        self.assertEqual(response.status_code, 201)
        pid = response.json['id']
        wb = openpyxl.Workbook()
        wb.active.append(['电缆编号', '起点', '终点', '电缆长度'])
        wb.active.append(['C1', '甲柜', '乙柜', 16])
        stream = io.BytesIO()
        wb.save(stream)
        original = stream.getvalue()
        cabinets = '柜子名称,楼层,X,Y\n甲柜,1F,0,0\n乙柜,1F,10000,0\n'.encode('utf-8-sig')
        routes = '路径编号,楼层,起点X,起点Y,终点X,终点Y\nR1,1F,0,0,10000,0\n'.encode('utf-8-sig')
        response = self.client.post('/api/projects/'+pid+'/upload', data={'files': [
            (io.BytesIO(original), '自动统计.xlsx'), (io.BytesIO(cabinets), '柜子坐标.csv'),
            (io.BytesIO(routes), '路径线段.csv')]}, headers={'X-CSRF-Token': self.csrf})
        self.assertEqual(response.status_code, 200, response.json)
        result = self.call('/projects/'+pid+'/calculate', 'POST', {})
        self.assertEqual(result.status_code, 200, result.json)
        self.assertEqual(result.json['result']['ok'], 1)
        self.assertEqual(result.json['result']['summary']['ceil_sum'], 17)
        import json
        visual = json.loads((web.ROOT/pid/'outputs'/'路径可视化数据.json').read_text(encoding='utf-8'))
        self.assertEqual(visual['title'], '电缆路径可视化 · 验收工程')
        self.assertTrue(visual['generated_at'].endswith('+08:00'))
        self.assertEqual(hashlib.sha256((web.ROOT/pid/'自动统计.xlsx').read_bytes()).digest(), hashlib.sha256(original).digest())
        preview = self.call('/projects/'+pid+'/file/outputs/路径可视化.html')
        self.assertEqual(preview.status_code, 200)
        preview.close()
        example = self.call('/examples').json
        example['direction'] = '向下'
        result = self.call('/projects/'+pid+'/terminal/generate', 'POST', example)
        self.assertTrue(result.json['ok'], result.json)
        files = list((web.ROOT/pid/'outputs'/'端子排').glob('*.dxf'))
        self.assertEqual(len(files), 1)
        self.assertNotIn("wiringPath", result.json)
        self.assertFalse(any(f.name.endswith("-仅接线.dxf") for f in files))
        for f in files:
            self.assertGreater(len(ezdxf.readfile(f).modelspace()), 0)
        legacy = files[0].with_name("旧端子排-仅接线.dxf")
        legacy.write_bytes(files[0].read_bytes())
        visible = self.call('/projects/'+pid).json['outputs']
        self.assertFalse(any(f['name'].endswith('-仅接线.dxf') for f in visible))
        self.assertTrue(any(f['name'].endswith('.dxf') for f in visible))
        restored = self.call('/projects/'+pid+'/terminal').json
        self.assertEqual(restored['terminals'], example['terminals'])
        backup = self.call('/projects/'+pid+'/export')
        self.assertEqual(backup.status_code, 200)
        with zipfile.ZipFile(io.BytesIO(backup.data)) as z:
            self.assertIn('data/terminal/端子排.txt', z.namelist())
        second = self.call('/projects', 'POST', {'name': '隔离工程'}).json['id']
        self.assertEqual(self.call('/projects/'+second+'/terminal').json['terminals'], '')

    def test_zip_path_and_limits(self):
        self.login()
        pid = self.call('/projects', 'POST', {'name': '安全验收'}).json['id']
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as z:
            z.writestr('../参数.csv', 'invalid')
        response = self.client.post('/api/projects/'+pid+'/upload', data={'files': (io.BytesIO(stream.getvalue()), 'bad.zip')}, headers={'X-CSRF-Token': self.csrf})
        self.assertEqual(response.status_code, 400)
        values = self.call('/projects/'+pid+'/params').json['values']
        values['CAD每米单位'] = 0
        self.assertEqual(self.call('/projects/'+pid+'/params', 'PUT', values).status_code, 400)


if __name__ == '__main__':
    unittest.main()
