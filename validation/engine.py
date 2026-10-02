from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from typing import Callable

CATEGORIES = ('电缆问题', '端子问题', '映射问题', '路径问题', '数据完整性问题')


@dataclass(frozen=True)
class Rule:
    rule_id: str
    name: str
    category: str
    severity: str
    description: str
    check: Callable
    evidence: str
    suggestion: str


def groups(rows, key):
    result = defaultdict(list)
    for row in rows:
        value = key(row)
        if value:
            result[value].append(row)
    return result


def pair(row):
    return frozenset((row.get('source_cabinet', ''), row.get('target_cabinet', '')))


def duplicate_cables(ctx):
    for number, rows in groups(ctx['cables'], lambda r: r['cable_number']).items():
        if len({(r['source_cabinet'], r['target_cabinet']) for r in rows}) > 1:
            yield rows[0], f'电缆 {number} 存在不同起终点', rows


def endpoints(ctx):
    for row in ctx['cables']:
        if not row['source_cabinet'] or not row['target_cabinet'] or row['source_cabinet'] == row['target_cabinet']:
            yield row, '电缆起终点为空或相同', [row]


def specification(ctx):
    for row in ctx['cables']:
        if row['cable_number'] and not row.get('specification'):
            yield row, '电缆规格缺失', [row]


def missing_cable(ctx):
    for row in ctx['terminals']:
        if row.get('external') and not row['cable_number']:
            yield row, '外部接线端子缺少电缆编号', [row]


def unreferenced(ctx):
    referenced = {r['cable_number'] for r in ctx['terminals']}
    for number, rows in groups(ctx['cables'], lambda r: r['cable_number']).items():
        if number not in referenced:
            yield rows[0], f'电缆 {number} 无端子引用', rows


def nonexistent(ctx):
    known = {r['cable_number'] for r in ctx['cables']}
    for row in ctx['terminals']:
        if row['cable_number'] and row['cable_number'] not in known:
            yield row, '端子引用的电缆不在清册中', [row]


def inconsistent(ctx):
    cables = groups(ctx['cables'], lambda r: r['cable_number'])
    for row in ctx['terminals']:
        candidates = cables.get(row['cable_number'], [])
        if candidates and row['source_cabinet'] and row['target_cabinet'] and all(pair(row) != pair(c) for c in candidates):
            yield row, '端子接线起终点与电缆清册不一致（允许两侧反向记录）', [row, *candidates]


def duplicate_terminals(ctx):
    for key, rows in groups(ctx['terminals'], lambda r: (r['source_cabinet'], r['terminal_strip'], r['terminal_number']) if r['terminal_number'] else None).items():
        # Multiple connections on one physical terminal are valid; only duplicate declarations count.
        declarations = {r.get('declaration_id', r['entity_id']) for r in rows}
        if len(declarations) > 1:
            yield rows[0], f'同柜同端子排端子 {key[1]}:{key[2]} 重复声明', rows


def circuits(ctx):
    for key, rows in groups(ctx['terminals'], lambda r: (r['source_cabinet'], r.get('circuit_number')) if r.get('circuit_number') else None).items():
        signatures = {(r['cable_number'], r['target_cabinet']) for r in rows if r['cable_number'] and r['target_cabinet']}
        if len(signatures) > 1:
            yield rows[0], f'柜 {key[0]} 的回路号 {key[1]} 指向不同电缆/设备', rows


def empty_fields(ctx):
    for row in ctx['cables']:
        if not row['cable_number']:
            yield row, '电缆清册缺少 cable_number', [row], 'ERROR'
    for row in ctx['terminals']:
        fields = [k for k in ('terminal_number', 'source_cabinet', 'terminal_strip') if not row[k]]
        if row.get('external') and not row['target_cabinet']:
            fields.append('target_cabinet')
        if fields:
            yield row, '端子关键字段为空：' + ', '.join(fields), [row], 'ERROR' if 'terminal_number' in fields else 'WARNING'


def isolated(ctx):
    for row in ctx['terminals']:
        if not any(row.get(k) for k in ('cable_number', 'left_circuit', 'right_circuit', 'circuit_number', 'valid_connection')):
            yield row, '孤立端子：无回路、电缆或有效连接', [row]


def one_side(ctx):
    for number, rows in groups(ctx['terminals'], lambda r: r['cable_number']).items():
        sides = {r['source_cabinet'] for r in rows if r['source_cabinet']}
        if len(sides) == 1:
            yield rows[0], f'电缆 {number} 只有一个柜侧的端子记录', rows


def data_issues(ctx):
    for row in ctx.get('input_issues', []):
        yield row, row['message'], [row], row.get('severity', 'ERROR')


def mapping(ctx):
    for row in ctx.get('mapping_issues', []):
        yield row, row['message'], [row]


def paths(ctx):
    for row in ctx.get('path_issues', []):
        yield row, row['message'], [row], row.get('severity', 'WARNING')


RULES = [
    Rule('C001', '电缆编号重复', '电缆问题', 'ERROR', '同编号存在不同有向起终点', duplicate_cables, '全部冲突清册行', '核对电缆编号和起终点，消除冲突。'),
    Rule('C002', '电缆起终点异常', '电缆问题', 'ERROR', '起终点为空或相同', endpoints, '原始清册行', '补齐起终点并核对柜名。'),
    Rule('C003', '电缆规格缺失', '电缆问题', 'WARNING', '有编号但无型号规格', specification, '原始清册行', '补齐电缆型号和规格。'),
    Rule('T001', '端子缺少电缆编号', '端子问题', 'ERROR', '外部接线必须关联电缆', missing_cable, '原始端子行', '填写清册中的电缆编号。'),
    Rule('C004', '电缆无端子引用', '电缆问题', 'WARNING', '清册电缆无端子引用', unreferenced, '清册行及端子覆盖范围', '补录两侧端子或确认暂未接线。'),
    Rule('T002', '端子引用不存在电缆', '端子问题', 'ERROR', '电缆引用必须存在于清册', nonexistent, '原始端子行', '修正引用或补齐清册。'),
    Rule('T003', '起终点不一致', '端子问题', 'ERROR', '端子与清册两端柜名必须对应', inconsistent, '端子行和对应清册行', '核对两端设备及柜名映射。'),
    Rule('T004', '重复端子', '端子问题', 'ERROR', '同柜同排重复物理端子声明', duplicate_terminals, '全部重复声明', '删除重复声明；同端子多根接线应共用声明。'),
    Rule('T005', '回路号冲突', '端子问题', 'WARNING', '同柜同回路号关联不同电缆或设备', circuits, '全部冲突接线', '核对回路号；允许的分支接线需人工确认。'),
    Rule('D001', '空关键字段', '数据完整性问题', 'WARNING', '按实体及接线场景检查必填字段', empty_fields, '原始行及缺失字段', '补齐报告列出的关键字段。'),
    Rule('T006', '孤立端子', '端子问题', 'WARNING', '无任何有效连接的端子', isolated, '原始端子声明', '确认备用端子或补齐接线。'),
    Rule('C005', '电缆只有单侧端子', '电缆问题', 'WARNING', '引用仅出现在一个柜侧', one_side, '全部引用及柜侧', '补录另一侧端子；柜侧由 source_cabinet 表示。'),
    Rule('D002', '输入完整性', '数据完整性问题', 'ERROR', '缺失、歧义和无法解析的输入', data_issues, '文件和解析错误', '修复原始文件后重新检查。'),
    Rule('M001', '柜名映射异常', '映射问题', 'WARNING', '映射冲突或目标不存在', mapping, '原始映射和柜名', '核对柜名别名与柜子坐标。'),
    Rule('P001', '路径复核状态', '路径问题', 'INFO', '现有计算结果的失败与时效', paths, '原计算结果或输入时效', '重新计算并复核路径问题。'),
]


def validate(context):
    issues = []
    for rule in RULES:
        for finding in rule.check(context):
            row, message, evidence, *severity = finding
            issues.append(dict(rule_id=rule.rule_id, name=rule.name, category=rule.category,
                               severity=severity[0] if severity else rule.severity, message=message,
                               project_id=context['project_id'], entity_type=row.get('entity_type', 'input'),
                               entity_id=row.get('entity_id', ''), cable_number=row.get('cable_number', ''),
                               terminal_number=row.get('terminal_number', ''), source=row.get('source_cabinet', ''),
                               target=row.get('target_cabinet', ''), evidence=evidence, suggestion=rule.suggestion))
    return dict(project_id=context['project_id'], issues=issues,
                counts={s: sum(i['severity'] == s for i in issues) for s in ('ERROR', 'WARNING', 'INFO')},
                categories={c: sum(i['category'] == c for i in issues) for c in CATEGORIES},
                rules=[{k: v for k, v in vars(r).items() if k != 'check'} for r in RULES],
                coverage=context.get('coverage', {}))
