"""Repeatable real API acceptance; preserves inputs/reports under outputs/acceptance."""
import io
import json
import os
import secrets
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import openpyxl
from werkzeug.security import generate_password_hash
import app as web


def main():
    web.ROOT = web.BASE / 'outputs' / 'acceptance' / 'projects'
    web.ROOT.mkdir(parents=True, exist_ok=True)
    password = secrets.token_urlsafe(24)
    os.environ['PASSWORD_HASH'] = generate_password_hash(password)
    web.app.config.update(TESTING=True, SESSION_COOKIE_SECURE=False)
    client = web.app.test_client()
    csrf = client.get('/api/session').json['csrf']
    response = client.post('/api/login', json={'password': password}, headers={'X-CSRF-Token': csrf})
    assert response.status_code == 200, response.json
    csrf = response.json['csrf']
    headers = {'X-CSRF-Token': csrf}
    results = []
    for damaged in (False, True):
        response = client.post('/api/projects', json={'name': 'V2故障验收' if damaged else 'V2正常验收'}, headers=headers)
        assert response.status_code == 201, response.json
        pid = response.json['id']
        wb = openpyxl.Workbook()
        wb.active.append(['电缆编号', '起点', '终点', '电缆长度', '电缆规格'])
        wb.active.append(['C1', '1#保护柜', '35kV开关柜', 10, 'KVVP 4x1.5'])
        if damaged:
            wb.active.append(['C1', '1#保护柜', '10kV开关柜', 10, 'KVVP 4x1.5'])
        stream = io.BytesIO(); wb.save(stream); wb.close()
        terminals = 'terminal_strip,terminal_number,cable_number,source_cabinet,target_cabinet,circuit_number,external\n'
        terminals += 'X,1,C1,1#保护柜,' + ('备用柜' if damaged else '35kV开关柜') + ',K1,true\n'
        terminals += 'X,1,C1,35kV开关柜,1#保护柜,K1,true\n'
        if damaged:
            terminals += 'X,2,UNKNOWN,1#保护柜,35kV开关柜,K2,true\nX,3,,1#保护柜,,,false\n'
        response = client.post(f'/api/projects/{pid}/upload', data={'files': [
            (io.BytesIO(stream.getvalue()), '自动统计.xlsx'),
            (io.BytesIO(terminals.encode('utf-8-sig')), '端子数据.csv')]}, headers=headers)
        assert response.status_code == 200, response.json
        response = client.post(f'/api/projects/{pid}/validation', json={}, headers=headers)
        assert response.status_code == 200, response.json
        report = response.json
        if damaged:
            assert {'C001', 'T003', 'T006', 'T002'}.issubset({i['rule_id'] for i in report['issues']})
        else:
            assert report['counts']['ERROR'] == 0, report
        results.append({'project_id': pid, 'counts': report['counts'], 'rules': sorted({i['rule_id'] for i in report['issues']}),
                        'report': str(web.ROOT / pid / 'outputs' / 'reports' / 'validation.md')})
    (web.BASE / 'outputs' / 'acceptance' / 'summary.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
