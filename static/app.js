let csrf = '', current = null, page = 'overview', projects = [], dirty = false, busy = false;
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const titles = { overview: '工程总览', cables: '电缆统计', params: '计算参数', aliases: '柜名匹配', issues: '问题清单', outputs: '输出文件', guide: 'CAD 数据导出' };

// 主题切换逻辑 (对齐 sentools)
function updateThemeUI() {
    const isDark = document.documentElement.classList.contains('dark');
    const icon = $('#themeIcon');
    const text = $('#themeText');
    if (icon && text) {
        if (isDark) {
            icon.textContent = '🌙';
            text.textContent = '暗色';
        } else {
            icon.textContent = '☀️';
            text.textContent = '浅色';
        }
    }
}

function toggleTheme() {
    const isDark = document.documentElement.classList.toggle('dark');
    localStorage.setItem('sen_tools_theme', isDark ? 'dark' : 'light');
    updateThemeUI();
}

async function api(url, method = 'GET', body) {
    const options = { method, headers: { 'X-CSRF-Token': csrf } };
    if (body instanceof FormData) options.body = body;
    else if (body !== undefined) {
        options.headers['Content-Type'] = 'application/json';
        options.body = JSON.stringify(body);
    }
    const r = await fetch('/api' + url, options);
    let data;
    try {
        data = await r.json();
    } catch {
        throw Error(r.status === 429 ? '登录尝试过于频繁，请稍后再试' : '服务暂时无法响应，请稍后重试');
    }
    if (!r.ok) {
        if (r.status === 401 && url != '/login') {
            await boot();
        }
        throw Error(data.error || '请求失败');
    }
    return data;
}

let toastTimer = null;
function notify(text, error = false) {
    const t = $('#toast');
    if (!t) return;
    if (toastTimer) clearTimeout(toastTimer);
    t.hidden = false;
    t.className = error ? 'error' : '';
    t.textContent = text;
    toastTimer = setTimeout(() => {
        t.hidden = true;
    }, 3200);
}

async function action(fn) {
    if (busy) return;
    busy = true;
    document.querySelectorAll('button').forEach(b => b.disabled = true);
    try {
        await fn();
    } catch (e) {
        notify(e.message, true);
    } finally {
        busy = false;
        document.querySelectorAll('button').forEach(b => b.disabled = false);
    }
}

function link(relative) {
    return '/api/projects/' + current.id + '/file/' + relative.split('/').map(encodeURIComponent).join('/');
}

function table(headers, rows) {
    return '<div class="table-wrap"><table><thead><tr>' + headers.map(h => '<th>' + esc(h) + '</th>').join('') + '</tr></thead><tbody>' + rows.map(r => '<tr>' + r.map(c => '<td>' + c + '</td>').join('') + '</tr>').join('') + '</tbody></table></div>';
}

async function projectValidation(c) {
    const projectId = current.id;
    let report = await api('/projects/' + projectId + '/validation');
    if (current?.id !== projectId || page !== 'validation') return;
    c.innerHTML = '<div class="panel"><div class="actions"><button class="primary" id="run-validation">运行项目检查</button><a class="button" id="validation-json">下载 JSON</a><a class="button" id="validation-md">下载 Markdown</a></div><p id="validation-status"></p><div id="validation-stats" class="stats"></div><p class="muted" id="validation-coverage"></p><div class="actions"><label>严重程度<select id="validation-severity"><option value="">全部</option><option>ERROR</option><option>WARNING</option><option>INFO</option></select></label><label>规则<select id="validation-rule"><option value="">全部规则</option></select></label><label>电缆号<input id="validation-cable" placeholder="搜索电缆编号"></label><label>柜名<input id="validation-cabinet" placeholder="搜索起点或终点"></label></div><div id="validation-results"></div></div>';
    function draw() {
        $('#validation-status').textContent = report ? '检查时间：' + report.generated_at + (report.stale ? ' · 输入已变化，请重新检查' : '') : '尚未运行项目检查';
        for (const [id, file] of [['validation-json', 'validation.json'], ['validation-md', 'validation.md']]) {
            $('#' + id).hidden = !report;
            $('#' + id).href = link('outputs/reports/' + file);
        }
        if (!report) return;
        $('#validation-stats').innerHTML = ['ERROR', 'WARNING', 'INFO'].map(s => '<div class="stat"><span>' + s + '</span><strong>' + report.counts[s] + '</strong></div>').join('');
        const coverage = report.coverage;
        const terminalSource = coverage.terminal_source?.startsWith('端子数据.csv') ? '端子 CSV（优先于出图 TXT，支持两侧记录）' : '出图 TXT（单柜侧，自动生成电缆号）';
        $('#validation-coverage').textContent = '检查范围：清册 ' + coverage.cable_rows + ' 行 · 端子 ' + coverage.terminal_rows + ' 行 · 柜坐标 ' + (coverage.cabinet_coordinates ?? 0) + ' 个 · 柜名映射 ' + (coverage.cabinet_aliases ?? 0) + ' 条。端子来源：' + terminalSource + '。路径：' + (coverage.path_result_reused ? '复用现有计算结果' : '未计算或结果已过期') + '。0 ERROR 仍需结合检查范围及警告复核。';
        const severity = $('#validation-severity').value, rule = $('#validation-rule').value;
        const cable = $('#validation-cable').value.toLowerCase(), cabinet = $('#validation-cabinet').value.toLowerCase();
        const rows = report.issues.filter(i => (!severity || i.severity === severity) && (!rule || i.rule_id === rule) && i.cable_number.toLowerCase().includes(cable) && (i.source + ' ' + i.target).toLowerCase().includes(cabinet));
        $('#validation-results').innerHTML = ['电缆问题', '端子问题', '映射问题', '路径问题', '数据完整性问题'].map(category => {
            const selected = rows.filter(i => i.category === category);
            return '<h3>' + esc(category) + '（显示 ' + selected.length + ' / 共 ' + report.categories[category] + '）</h3>' + (selected.length ? table(['程度 / 规则', '电缆 / 端子', '起点 → 终点', '问题 / 原始证据', '处理建议'], selected.map(i => [esc(i.severity + ' / ' + i.rule_id), esc(i.cable_number || '—') + '<br>' + esc(i.terminal_number || '—'), esc(i.source) + ' → ' + esc(i.target), esc(i.message) + '<br><small>' + esc(i.entity_id) + '</small><details><summary>查看原始证据</summary><pre style="white-space:pre-wrap">' + esc(JSON.stringify(i.evidence, null, 2)) + '</pre></details>', esc(i.suggestion)])) : '<p class="muted">无符合筛选条件的问题</p>');
        }).join('');
    }
    function rules() {
        $('#validation-rule').innerHTML = '<option value="">全部规则</option>' + (report?.rules || []).map(r => '<option value="' + esc(r.rule_id) + '">' + esc(r.rule_id + ' ' + r.name) + '</option>').join('');
    }
    for (const id of ['validation-severity', 'validation-rule', 'validation-cable', 'validation-cabinet']) $('#' + id).oninput = draw;
    $('#run-validation').onclick = () => action(async () => {
        report = await api('/projects/' + projectId + '/validation', 'POST', {});
        if (current?.id !== projectId || page !== 'validation') return;
        await reload();
        rules(); draw(); notify('项目检查完成，报告已保存');
    });
    rules(); draw();
}

async function boot() {
    const state = await api('/session');
    csrf = state.csrf;
    $('#login').hidden = state.authenticated;
    $('#workspace').hidden = !state.authenticated;
    if (state.authenticated) await refreshProjects();
    updateThemeUI();
}

async function refreshProjects(selected) {
    projects = await api('/projects');
    $('#projects').innerHTML = projects.length ? projects.map(p => '<option value="' + p.id + '">' + esc(p.name) + '</option>').join('') : '<option>还没有工程</option>';
    const id = selected || current?.id || localStorage.getItem('2ci-project');
    current = projects.find(p => p.id === id) || projects[0] || null;
    if (current) {
        $('#projects').value = current.id;
        localStorage.setItem('2ci-project', current.id);
    }
    await render();
}

async function reload() {
    if (current) current = await api('/projects/' + current.id);
}

async function savePending() {
    if (dirty && current && page === 'terminal') {
        await api('/projects/' + current.id + '/terminal', 'PUT', terminalPayload());
        dirty = false;
    }
}

async function render() {
    document.querySelectorAll('nav button').forEach(b => b.classList.toggle('active', b.dataset.page === page));
    $('#page-title').textContent = titles[page];
    $('#export').hidden = !current;
    $('#export').href = current ? '/api/projects/' + current.id + '/export' : '#';
    const c = $('#content');
    if (!current && page !== 'guide') {
        c.innerHTML = '<div class="empty"><div class="mark">⚡</div><h2>从一个工程开始</h2><p class="muted">工程里的清册、CAD 数据与计算成果会一起保存。</p><button class="primary" id="first-project">＋ 新建工程</button></div>';
        $('#first-project').onclick = () => $('#create-dialog').showModal();
        return;
    }
    if (page === 'overview') overview(c);
    if (page === 'cables') cables(c);
    if (page === 'params') await parameters(c);
    if (page === 'aliases') await aliases(c);
    if (page === 'issues') issues(c);
    if (page === 'outputs') outputs(c);
    if (page === 'guide') guide(c);
}

function stats() {
    const r = current.result;
    return '<div class="stats">' + [['工程输入', current.files.filter(f => f.exists).length + ' / 7'], ['已计算电缆', r?.ok ?? '—'], ['待处理电缆', r?.failed ?? '—'], ['向上取整合计', r ? r.summary.ceil_sum + ' m' : '—']].map(([l, v]) => '<div class="stat"><span>' + l + '</span><strong>' + esc(v) + '</strong></div>').join('') + '</div>';
}

function statusTable() {
    return table(['输入文件', '数据行数', '状态'], [[current.workbook || '清册.xlsx', '—', current.workbook ? '<span class="badge">已上传</span>' : '<span class="badge warn">待上传</span>'], ...current.files.map(f => [esc(f.name), f.exists ? f.rows : '—', '<span class="badge ' + (!f.exists && f.required ? 'warn' : '') + '">' + (f.exists ? '已上传' : f.required ? '必需 · 待上传' : '可选') + '</span>'])]);
}

function uploadBlock() {
    return '<div class="drop" id="upload-drop"><h3>导入工程数据</h3><p class="muted">上传原始清册 XLSX、CAD 导出的 CSV，或已有工程的 ZIP。ZIP 中的 outputs 不会覆盖成果。</p><p class="drop-hint">将文件拖到这里，可多次追加；也可点击下方选择文件。</p><input id="upload-files" aria-label="选择工程数据文件" type="file" multiple accept=".xlsx,.csv,.zip,.txt,.json"><div id="upload-selection" aria-live="polite"></div><button id="upload" class="primary">上传并保存</button><p class="muted" style="margin-top:8px">单次最多 80MB；中文 CSV 使用 UTF-8 BOM 编码。</p></div>';
}

function bindUpload() {
    const upload = $('#upload'), input = $('#upload-files'), zone = $('#upload-drop');
    if (!upload) return;
    let pending = [], dragDepth = 0;
    const sizeLabel = bytes => bytes < 1024 * 1024 ? (bytes / 1024).toFixed(1) + ' KB' : (bytes / 1024 / 1024).toFixed(1) + ' MB';
    function drawSelection() {
        $('#upload-selection').innerHTML = pending.length ? '<p>待上传 ' + pending.length + ' 个文件 · ' + sizeLabel(pending.reduce((sum, f) => sum + f.size, 0)) + '</p><ul class="upload-list">' + pending.map((f, i) => '<li><span>' + esc(f.name) + ' <small>' + sizeLabel(f.size) + '</small></span><button type="button" data-remove="' + i + '" aria-label="移除 ' + esc(f.name) + '">移除</button></li>').join('') + '</ul>' : '';
        $('#upload-selection').querySelectorAll('[data-remove]').forEach(button => {
            button.onclick = () => {
                if (busy) return;
                pending.splice(Number(button.dataset.remove), 1);
                drawSelection();
            };
        });
    }
    function addFiles(files) {
        if (busy) return;
        const incoming = Array.from(files);
        if (!incoming.length) return;
        if (incoming.some(f => !/\.(xlsx|csv|zip|txt|json)$/i.test(f.name))) {
            notify('请选择 XLSX、CSV、ZIP、TXT 或 JSON 文件；文件夹请先压缩为 ZIP', true);
            return;
        }
        const next = pending.slice();
        for (const f of incoming) {
            const index = next.findIndex(old => old.name === f.name);
            if (index < 0) next.push(f);
            else next[index] = f;
        }
        if (next.reduce((sum, f) => sum + f.size, 0) > 80 * 1024 * 1024) {
            notify('待上传文件总大小超过 80MB，请分批上传', true);
            return;
        }
        pending = next;
        drawSelection();
    }
    input.onchange = () => {
        addFiles(input.files);
        input.value = '';
    };
    const isFileDrag = event => Array.from(event.dataTransfer?.types || []).includes('Files');
    zone.addEventListener('dragenter', event => {
        if (!isFileDrag(event)) return;
        event.preventDefault();
        dragDepth++;
        if (!busy) zone.classList.add('drag-over');
    });
    zone.addEventListener('dragover', event => {
        if (!isFileDrag(event)) return;
        event.preventDefault();
        event.dataTransfer.dropEffect = busy ? 'none' : 'copy';
    });
    zone.addEventListener('dragleave', event => {
        event.preventDefault();
        if (--dragDepth <= 0) {
            dragDepth = 0;
            zone.classList.remove('drag-over');
        }
    });
    zone.addEventListener('drop', event => {
        event.preventDefault();
        dragDepth = 0;
        zone.classList.remove('drag-over');
        const items = Array.from(event.dataTransfer?.items || []);
        if (items.some(item => item.webkitGetAsEntry?.()?.isDirectory)) {
            notify('暂不支持直接拖入文件夹，请选择其中的文件，或压缩为 ZIP 后上传', true);
            return;
        }
        addFiles(event.dataTransfer?.files || []);
    });
    upload.onclick = () => action(async () => {
        if (!pending.length) throw Error('请先选择或拖入文件');
        const form = new FormData();
        for (const f of pending) form.append('files', f);
        current = await api('/projects/' + current.id + '/upload', 'POST', form);
        notify('工程输入已保存');
        await render();
    });
}

function overview(c) {
    c.innerHTML = '<div class="hero"><p class="eyebrow">PROJECT / 当前工程</p><h2>' + esc(current.name) + '</h2><p>上传 CAD 路径与清册，计算电缆长度，在线复核二维 / 三维路径。成果与输入随工程实时隔离保存。</p></div>' + stats() + '<div class="grid"><div class="panel"><h3>工程输入状态</h3>' + statusTable() + '</div><div class="panel"><h3>设计流程向导</h3><div class="steps"><p>在 CAD 中导出柜子坐标、路径线段与竖井数据</p><p>上传清册与 CSV，核对计算参数及柜名匹配</p><p>计算长度并在线复核二维 / 三维可视化路径</p><p>查看问题清单，下载计算结果工作簿</p></div><div class="actions"><button data-goto="cables" class="primary">前往电缆统计 →</button></div></div></div>' + uploadBlock();
    bindUpload();
    bindGoto();
}

function bindGoto() {
    document.querySelectorAll('[data-goto]').forEach(b => b.onclick = () => navigate(b.dataset.goto));
}

function cables(c) {
    const r = current.result;
    c.innerHTML = stats() + '<div class="panel"><h3>清册与 CAD 数据</h3>' + statusTable() + uploadBlock() + '<div class="actions"><button class="primary" id="calculate">⚡ 开始计算电缆长度</button><button data-goto="params">核对参数</button><button data-goto="aliases">柜名匹配</button>' + (r ? '<a class="button" target="_blank" href="' + link('outputs/路径可视化.html') + '">打开三维路径复核 ↗</a>' : '') + '</div><p class="muted">' + (current.outdated ? '输入已更新，请重新计算。' : '原始清册保留，计算结果写入 outputs。') + '</p></div>' + (r ? '<div class="panel"><h3>最近计算结果</h3><p class="muted" style="margin-bottom:14px">成功 ' + r.ok + ' 条 / 未计算 ' + r.failed + ' 条 · 计算耗时 ' + r.elapsed.toFixed(2) + ' 秒</p><div class="actions"><a class="button primary" href="' + link('outputs/自动统计_计算结果.xlsx') + '">↓ 下载结果工作簿 (Excel)</a><button data-goto="issues">查看问题清单</button></div><input class="search" id="cable-search" placeholder="🔍 搜索柜名、电缆号或问题"><div id="cabinet-results"></div></div>' : '');
    bindUpload();
    bindGoto();
    $('#calculate').onclick = () => action(async () => {
        notify('正在构建路径网络并计算，请稍候…');
        current = await api('/projects/' + current.id + '/calculate', 'POST', {});
        await render();
        notify('计算完成：成功 ' + current.result.ok + ' 条，未计算 ' + current.result.failed + ' 条');
    });
    if (r) {
        const rows = r.cabinet_check_rows;
        const draw = () => {
            const q = $('#cable-search').value;
            const filtered = rows.filter(x => JSON.stringify(x).includes(q));
            $('#cabinet-results').innerHTML = table(Object.keys(rows[0] || {}), filtered.map(x => Object.values(x).map(esc)));
        };
        $('#cable-search').oninput = draw;
        draw();
    }
}

async function parameters(c) {
    const data = await api('/projects/' + current.id + '/params');
    c.innerHTML = '<div class="panel"><h3>计算参数</h3><p class="muted" style="margin-bottom:16px">参数随当前工程保存。默认使用毫米图：1 米 = 1000 CAD 单位。</p>' + table(['参数', '值', '说明'], data.specs.map(s => [esc(s.name), '<input type="number" step="any" data-param="' + esc(s.name) + '" value="' + esc(data.values[s.name]) + '">', esc(s.note)])) + '<div class="actions"><button id="save-params" class="primary">保存参数配置</button></div></div>';
    $('#save-params').onclick = () => action(async () => {
        const values = {};
        document.querySelectorAll('[data-param]').forEach(i => values[i.dataset.param] = Number(i.value));
        await api('/projects/' + current.id + '/params', 'PUT', values);
        await reload();
        notify('计算参数已保存，请重新计算');
    });
}

async function aliases(c) {
    const data = await api('/projects/' + current.id + '/aliases');
    const old = Object.fromEntries(data.rows.map(r => [r['清册名称'], r['CAD名称']]));
    c.innerHTML = '<div class="panel"><h3>清册柜名 → CAD 柜名</h3><p class="muted" style="margin-bottom:16px">相似名称需人工确认。空白表示不添加映射；也可上传 柜名别名.csv 完整替换。</p><datalist id="cad-names">' + data.cad.map(n => '<option value="' + esc(n) + '">').join('') + '</datalist>' + table(['清册柜名', '匹配状态', '对应 CAD 柜名'], [...new Set([...data.required, ...Object.keys(old)])].map(n => [esc(n), data.cad.includes(n) ? '<span class="badge">直接匹配</span>' : '<span class="badge warn">核对映射</span>', '<input data-alias="' + esc(n) + '" list="cad-names" value="' + esc(old[n] || '') + '" placeholder="选择或填写 CAD 柜名">'])) + '<div class="actions"><button class="primary" id="save-aliases">保存柜名映射</button></div>' + (data.required.length ? '' : '<p class="muted">先上传清册与柜子坐标，系统将自动分析待匹配名称。</p>') + '</div>';
    $('#save-aliases').onclick = () => action(async () => {
        const mapping = {};
        document.querySelectorAll('[data-alias]').forEach(i => mapping[i.dataset.alias] = i.value);
        await api('/projects/' + current.id + '/aliases', 'PUT', mapping);
        await reload();
        notify('柜名映射已保存，请重新计算');
    });
}

function terminalPayload() {
    const memory = {};
    document.querySelectorAll('[data-direction]').forEach(i => memory[i.dataset.direction] = i.value);
    return {
        cabinet: $('#cabinet').value,
        terminals: $('#terminals').value,
        wiring: $('#wiring').value,
        direction: $('#direction').value,
        directionMemory: { ...(current.terminalMemory || {}), ...memory }
    };
}

async function terminal(c) {
    const state = await api('/projects/' + current.id + '/terminal');
    current.terminalMemory = state.directionMemory;
    c.innerHTML = '<div class="panel"><div class="terminal-toolbar"><label>柜名<input id="cabinet" value="' + esc(state.cabinet) + '" placeholder="请输入柜名，用于图签与文件名"></label><label>默认电缆方向<select id="direction"><option>向下</option><option>向上</option></select></label></div><div class="grid"><div><div class="editor-label"><strong>端子排定义</strong><span>普通 / CAD 坐标格式</span></div><textarea id="terminals" spellcheck="false" placeholder="X、1、2、3">' + esc(state.terminals) + '</textarea><input type="file" id="terminal-import" accept=".txt" style="margin-top:10px"><small class="muted" style="display:block;margin-top:4px">支持导入 UTF-8、GBK 或 UTF-16 TXT 文件</small></div><div><div class="editor-label"><strong>接线信息</strong><span>端子引用、原理号、去向柜</span></div><textarea id="wiring" spellcheck="false" placeholder="X:1、A610、甲柜">' + esc(state.wiring) + '</textarea><input type="file" id="wiring-import" accept=".txt" style="margin-top:10px"></div></div><div class="actions"><button id="inspect">🔍 检查输入 · F5</button><button class="primary" id="generate">⚡ 生成 DXF · Ctrl+Enter</button><button id="save-terminal">保存输入</button><button id="example">填入示例</button><button id="clear-terminal" type="button">清除所有输入</button></div><p class="muted" id="save-status">切换页面和工程时自动保存。生成完整端子排 DXF 图纸。</p><div id="terminal-result"></div><div id="directions"></div></div>';
    $('#direction').value = state.direction;
    ['cabinet', 'terminals', 'wiring', 'direction'].forEach(id => $('#' + id).oninput = () => {
        dirty = true;
        $('#save-status').textContent = '输入已修改，尚未保存';
    });
    $('#direction').onchange = () => {
        document.querySelectorAll('[data-direction]').forEach(i => i.value = $('#direction').value);
        dirty = true;
    };
    $('#save-terminal').onclick = () => action(async () => {
        await savePending();
        await api('/projects/' + current.id + '/terminal', 'PUT', terminalPayload());
        dirty = false;
        $('#save-status').textContent = '输入已保存';
        notify('端子输入已保存');
    });
    $('#example').onclick = () => action(async () => {
        const x = await api('/examples');
        for (const k of ['cabinet', 'terminals', 'wiring']) $('#' + k).value = x[k];
        dirty = true;
        $('#save-status').textContent = '示例已填入，尚未保存';
    });
    $('#clear-terminal').onclick = () => action(async () => {
        if (!confirm('确定清除当前工程的所有端子输入吗？柜名、端子排定义、接线信息及方向设置将清空，已有生成文件保留。')) return;
        const empty = { cabinet: '', terminals: '', wiring: '', direction: '向下', directionMemory: {} };
        await api('/projects/' + current.id + '/terminal', 'PUT', empty);
        for (const id of ['cabinet', 'terminals', 'wiring', 'terminal-import', 'wiring-import']) $('#' + id).value = '';
        $('#direction').value = empty.direction;
        current.terminalMemory = {};
        current.terminalIssues = [];
        $('#terminal-result').innerHTML = '';
        $('#directions').innerHTML = '';
        dirty = false;
        $('#save-status').textContent = '所有端子输入已清除并保存，可以输入新的内容';
        notify('所有端子输入已清除');
        $('#cabinet').focus();
    });
    for (const [id, target] of [['terminal-import', 'terminals'], ['wiring-import', 'wiring']]) {
        $('#' + id).onchange = () => action(async () => {
            const f = $('#' + id).files[0];
            if (!f) return;
            const b = new Uint8Array(await f.arrayBuffer());
            let enc = 'utf-8';
            if (b[0] === 255 && b[1] === 254) enc = 'utf-16le';
            else if (b[0] === 254 && b[1] === 255) enc = 'utf-16be';
            let text;
            try {
                text = new TextDecoder(enc, { fatal: true }).decode(b);
            } catch {
                text = new TextDecoder('gb18030').decode(b);
            }
            $('#' + target).value = text;
            dirty = true;
        });
    }
    for (const actionName of ['inspect', 'generate']) {
        $('#' + actionName).onclick = () => action(async () => {
            const payload = terminalPayload();
            await api('/projects/' + current.id + '/terminal', 'PUT', payload);
            dirty = false;
            $('#save-status').textContent = '输入已保存';
            notify(actionName === 'generate' ? '正在生成 DXF…' : '正在检查输入…');
            const r = await api('/projects/' + current.id + '/terminal/' + actionName, 'POST', payload);
            current.terminalIssues = [...(r.errors || []).map(x => ['错误', x]), ...(r.warnings || []).map(x => ['警告', x])];
            $('#terminal-result').innerHTML = '<div class="results"><h3>' + (r.ok ? '检查通过' : '输入需要修正') + '</h3>' + ((r.errors || []).concat(r.warnings || [])).map(x => '<p>' + esc(x) + '</p>').join('') + (r.stats ? '<p style="margin-top:8px;font-weight:600">端子排 ' + r.stats.blocks + ' 块 · 端子 ' + r.stats.terminals + ' 个 · 电缆 ' + r.stats.cables + ' 根</p>' : '') + '</div>';
            $('#directions').innerHTML = table(['端子排', '电缆方向'], (r.strips || []).map(s => [esc(s.ident), '<select data-direction="' + esc(s.ident) + '"><option>向下</option><option>向上</option></select>']));
            document.querySelectorAll('[data-direction]').forEach(i => {
                i.value = payload.directionMemory[i.dataset.direction] || payload.direction;
                i.onchange = () => dirty = true;
            });
            if (actionName === 'generate' && r.ok) {
                const issues = current.terminalIssues;
                const memory = current.terminalMemory;
                await reload();
                current.terminalIssues = issues;
                current.terminalMemory = memory;
                const filename = r.path.replace(/\\/g, '/').split('/').pop();
                const output = 'outputs/端子排/' + filename;
                $('#terminal-result').innerHTML += '<div class="actions"><a class="button primary" href="' + link(output) + '">↓ 下载 ' + esc(filename) + '</a></div>';
            }
            notify(r.ok ? (actionName === 'generate' ? 'DXF 已生成，可以下载' : '输入检查通过') : '请修正输入后重试', !r.ok);
        });
    }
}

function issues(c) {
    const rows = [...(current.result?.issues || []).map(x => ['电缆', x[0], x[1]]), ...(current.terminalIssues || []).map(x => ['端子', x[0], x[1]])];
    c.innerHTML = '<div class="panel"><h3>问题清单 · ' + rows.length + ' 条</h3><p class="muted" style="margin-bottom:16px">问题来自最近一次电缆计算。</p>' + table(['来源', '级别', '说明'], rows.map(r => [esc(r[0]), '<span class="badge ' + (r[1] === '错误' ? 'error' : 'warn') + '">' + esc(r[1]) + '</span>', esc(r[2])])) + (rows.length ? '' : '<p class="muted">暂无问题记录。运行计算后在此查看详情。</p>') + '</div>';
}

function outputs(c) {
    c.innerHTML = '<div class="panel"><h3>工程成果文件</h3>' + table(['成果文件', '文件大小', '快捷操作'], current.outputs.map(f => [esc(f.name), Math.ceil(f.size / 1024) + ' KB', '<a class="button" style="height:30px;padding:0 14px;font-size:0.8rem" href="' + link(f.name) + '" ' + (f.name.endsWith('.html') ? 'target="_blank"' : '') + '>' + (f.name.endsWith('.html') ? '打开复核 ↗' : '下载 ↓') + '</a>'])) + (current.outputs.length ? '' : '<p class="muted">计算电缆后，工程成果将显示在这里。</p>') + '</div>';
}

function guide(c) {
    c.innerHTML = '<div class="hero"><p class="eyebrow">CAD DATA / 数据导出向导</p><h2>从图纸提取路径，在网页完成计算</h2><p>使用原版完整 CAD 导出向导，一键从 CAD 提取设备、路径与竖井数据，上传至当前工程即可完成自动化设计计算。</p></div><div class="panel"><div class="actions"><a class="button primary" href="/static/cad_cable_wizard.lsp" download>↓ 下载 CAD 导出向导 (AutoLISP)</a></div><div class="steps"><p>在 AutoCAD / ZWCAD 中输入 APPLOAD 命令，加载下载的 LISP 向导程序。</p><p>在命令行输入 DCW 打开向导，按六步依次建楼层、定义房间、标柜子、画通道、标竖井，随时输入 DCV 查看已定义内容。</p><p>在向导第 6 步检查后，自动将四个 CSV 导出到桌面，无需选择文件夹。</p><p>进入网页版「电缆统计」模块，上传原始工程清册，将桌面导出的四个 CSV 拖入导入区域并保存。</p><p>核对计算参数与柜名映射，点击计算并打开二维 / 三维路径可视化复核。</p></div></div>';
}

async function navigate(next) {
    await action(async () => {
        await savePending();
        $('#toast').hidden = true;
        page = next;
        await reload();
        await render();
    });
}

// 导航与工程切换绑定
document.querySelectorAll('nav button').forEach(b => b.onclick = () => navigate(b.dataset.page));
$('#projects').onchange = () => action(async () => {
    const id = $('#projects').value;
    try {
        await savePending();
    } catch (e) {
        $('#projects').value = current.id;
        throw e;
    }
    current = projects.find(p => p.id === id);
    localStorage.setItem('2ci-project', id);
    await reload();
    await render();
});

$('#new-project').onclick = () => $('#create-dialog').showModal();
$('#cancel-create').onclick = () => $('#create-dialog').close();
$('#create-form').onsubmit = e => {
    e.preventDefault();
    action(async () => {
        await savePending();
        const p = await api('/projects', 'POST', { name: $('#project-name').value });
        $('#create-dialog').close();
        $('#project-name').value = '';
        await refreshProjects(p.id);
        notify('工程已创建');
    });
};

$('#login-form').onsubmit = async e => {
    e.preventDefault();
    try {
        const r = await api('/login', 'POST', { password: $('#password').value });
        csrf = r.csrf;
        $('#password').value = '';
        $('#login-error').textContent = '';
        await boot();
    } catch (e) {
        $('#login-error').textContent = e.message;
    }
};

$('#logout').onclick = () => action(async () => {
    await savePending();
    await api('/logout', 'POST', {});
    current = null;
    await boot();
});

// 主题切换按钮绑定
$('#themeToggle')?.addEventListener('click', toggleTheme);

window.addEventListener('beforeunload', e => {
    if (dirty) {
        e.preventDefault();
        e.returnValue = '';
    }
});

document.addEventListener('dragover', e => {
    if (Array.from(e.dataTransfer?.types || []).includes('Files')) e.preventDefault();
});
document.addEventListener('drop', e => {
    if (Array.from(e.dataTransfer?.types || []).includes('Files')) e.preventDefault();
});

document.addEventListener('keydown', e => {
    if (page !== 'terminal' || !current) return;
    if (e.key === 'F5') {
        e.preventDefault();
        $('#inspect')?.click();
    }
    if (e.ctrlKey && e.key === 'Enter') {
        e.preventDefault();
        $('#generate')?.click();
    }
});

boot().catch(e => {
    $('#login-error').textContent = e.message;
});
