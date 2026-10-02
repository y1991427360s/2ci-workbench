import copy
import io
import json
import unittest
from unittest.mock import patch

import openpyxl

import test_web
from validation.engine import RULES, validate


def cable(number='C1', source='甲柜', target='乙柜'):
    return dict(entity_type='cable', entity_id='清册:2', cable_number=number,
                source_cabinet=source, target_cabinet=target, specification='KVVP 4x1.5')


def terminal(number='C1', source='甲柜', target='乙柜', t='1'):
    return dict(entity_type='terminal', entity_id=source + ':X:' + t, cable_number=number,
                source_cabinet=source, target_cabinet=target, terminal_strip='X', terminal_number=t,
                external=True, circuit_number='K1')


def normal():
    return dict(project_id='fixture', cables=[cable()], terminals=[terminal(), terminal(source='乙柜', target='甲柜')])


class RuleTests(unittest.TestCase):
    def test_normal_zero_errors(self):
        report = validate(normal())
        self.assertEqual(report['counts'], {'ERROR': 0, 'WARNING': 0, 'INFO': 0})

    def test_each_rule_fixture(self):
        fixtures = {}
        def fixture(rule):
            fixtures[rule] = normal()
            return fixtures[rule]
        fixture('C001')['cables'].append(cable(target='丙柜'))
        fixture('C002')['cables'][0]['target_cabinet'] = '甲柜'
        fixture('C003')['cables'][0]['specification'] = ''
        fixture('T001')['terminals'][0]['cable_number'] = ''
        fixture('C004')['terminals'] = []
        fixture('T002')['terminals'][0]['cable_number'] = 'UNKNOWN'
        fixture('T003')['terminals'][0]['target_cabinet'] = '丙柜'
        duplicate = copy.deepcopy(terminal()); duplicate['entity_id'] = 'duplicate:2'
        fixture('T004')['terminals'].append(duplicate)
        fixture('T005')['terminals'].append(terminal('C2', target='丙柜', t='2'))
        fixture('D001')['terminals'][0]['terminal_number'] = ''
        fixture('T006')['terminals'].append(dict(terminal('', target='', t='3'), circuit_number='', external=False))
        fixture('C005')['terminals'].pop()
        fixture('D002')['input_issues'] = [dict(message='读取失败')]
        fixture('M001')['mapping_issues'] = [dict(message='映射冲突')]
        fixture('P001')['path_issues'] = [dict(message='未计算', severity='INFO')]
        self.assertEqual(set(fixtures), {r.rule_id for r in RULES})
        for rule, ctx in fixtures.items():
            with self.subTest(rule=rule):
                found = [i for i in validate(ctx)['issues'] if i['rule_id'] == rule]
                self.assertTrue(found)
                self.assertTrue(found[0]['evidence'])
                self.assertEqual(found[0]['project_id'], 'fixture')

    def test_endpoint_empty_and_circuit_scope(self):
        for key in ('source_cabinet', 'target_cabinet'):
            ctx = normal(); ctx['cables'][0][key] = ''
            self.assertIn('C002', [i['rule_id'] for i in validate(ctx)['issues']])
        ctx = normal(); ctx['cables'][0]['cable_number'] = ''
        self.assertIn('D001', [i['rule_id'] for i in validate(ctx)['issues']])
        ctx = normal(); ctx['terminals'][1]['cable_number'] = 'C2'
        self.assertNotIn('T005', [i['rule_id'] for i in validate(ctx)['issues']])


class ValidationAcceptance(unittest.TestCase):
    setUp = test_web.WebTests.setUp
    tearDown = test_web.WebTests.tearDown
    call = test_web.WebTests.call
    login = test_web.WebTests.login

    def test_csv_aliases_empty_fields_and_report_rollback(self):
        self.login()
        pid = self.call('/projects', 'POST', {'name': 'CSV正常工程'}).json['id']
        cables = '电缆编号,起点,终点,规格\nC1,甲别名,乙柜,KVVP 4x1.5\n'
        terminals = ('terminal_strip,terminal_number,cable_number,source_cabinet,target_cabinet\n'
                     'X,1,C1,甲柜,乙柜\nX,1,C1,乙柜,甲柜\n')
        coordinates = '柜子名称,楼层,X,Y\n甲柜,1F,0,0\n乙柜,1F,1000,0\n'
        aliases = '清册名称,CAD名称\n甲别名,甲柜\n'
        files = [(io.BytesIO(text.encode('utf-8-sig')), name) for text, name in [
            (cables, '电缆清册.csv'), (terminals, '端子数据.csv'), (coordinates, '柜子坐标.csv'), (aliases, '柜名别名.csv')]]
        response = self.client.post('/api/projects/' + pid + '/upload', data={'files': files}, headers={'X-CSRF-Token': self.csrf})
        self.assertEqual(response.status_code, 200, response.json)
        report = self.call('/projects/' + pid + '/validation', 'POST', {}).json
        self.assertEqual(report['counts']['ERROR'], 0, report)
        import app as web
        from validation.service import run_project
        path = web.ROOT / pid
        reports = [path / 'outputs' / 'reports' / name for name in ('validation.json', 'validation.md')]
        originals = [p.read_bytes() for p in reports]
        replace = test_web.os.replace
        calls = 0
        def fail_second(src, dst):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError('模拟报告替换失败')
            return replace(src, dst)
        with patch('modules.terminal.service.os.replace', side_effect=fail_second):
            with self.assertRaises(OSError):
                run_project(path)
        self.assertEqual([p.read_bytes() for p in reports], originals)
        (path / 'data' / 'terminal' / '端子数据.csv').write_text(terminals + 'X,,,甲柜,乙柜\n', encoding='utf-8')
        ids = {i['rule_id'] for i in self.call('/projects/' + pid + '/validation', 'POST', {}).json['issues']}
        self.assertTrue({'T001', 'D001'}.issubset(ids))

    def test_duplicate_upload_rejected_without_overwrite(self):
        self.login()
        pid = self.call('/projects', 'POST', {'name': '上传隔离'}).json['id']
        response = self.client.post('/api/projects/' + pid + '/upload', data={'files': [
            (io.BytesIO(b'first'), '端子数据.csv'), (io.BytesIO(b'second'), '端子数据.csv')]}, headers={'X-CSRF-Token': self.csrf})
        self.assertEqual(response.status_code, 400)
    def test_validation_actual_import(self):
        self.login()
        pid = self.call('/projects', 'POST', {'name': 'V2实际验收工程'}).json['id']
        wb = openpyxl.Workbook()
        wb.active.append(['电缆编号', '起点', '终点', '电缆长度', '规格'])
        wb.active.append(['C1', '甲柜', '乙柜', 10, 'KVVP 4x1.5'])
        wb.active.append(['C1', '甲柜', '丙柜', 10, 'KVVP 4x1.5'])
        stream = io.BytesIO(); wb.save(stream); original = stream.getvalue(); wb.close()
        text = ('terminal_strip,terminal_number,cable_number,source_cabinet,target_cabinet,circuit_number,external\n'
                'X,1,C1,甲柜,丁柜,K1,true\nX,2,UNKNOWN,甲柜,乙柜,K2,true\nX,3,,甲柜,,,false\n')
        response = self.client.post('/api/projects/' + pid + '/upload', data={'files': [
            (io.BytesIO(original), '自动统计.xlsx'), (io.BytesIO(text.encode('utf-8-sig')), '端子数据.csv')]}, headers={'X-CSRF-Token': self.csrf})
        self.assertEqual(response.status_code, 200, response.json)
        report = self.call('/projects/' + pid + '/validation', 'POST', {}).json
        self.assertTrue({'C001', 'T003', 'T006', 'T002'}.issubset({i['rule_id'] for i in report['issues']}))
        import app as web
        path = web.ROOT / pid
        self.assertEqual((path / '自动统计.xlsx').read_bytes(), original)
        for name in ('validation.json', 'validation.md'):
            self.assertTrue((path / 'outputs' / 'reports' / name).is_file())
        self.assertFalse(self.call('/projects/' + pid + '/validation').json['stale'])
        (path / 'data' / 'terminal' / '端子数据.csv').write_text(text + 'X,4,,甲柜,,,false\n', encoding='utf-8')
        self.assertTrue(self.call('/projects/' + pid + '/validation').json['stale'])
        other = self.call('/projects', 'POST', {'name': '隔离工程'}).json['id']
        self.assertIsNone(self.call('/projects/' + other + '/validation').json)

    def test_legacy_duplicate_and_missing_reference(self):
        self.login()
        pid = self.call('/projects', 'POST', {'name': 'TXT验收'}).json['id']
        self.call('/projects/' + pid + '/terminal', 'PUT', dict(terminals='X、1、1、2', wiring='X:99、K1、乙柜', cabinet='甲柜'))
        response = self.call('/projects/' + pid + '/validation', 'POST', {})
        self.assertEqual(response.status_code, 200, response.json)
        ids = {i['rule_id'] for i in response.json['issues']}
        self.assertTrue({'T004', 'D002', 'T006'}.issubset(ids))
