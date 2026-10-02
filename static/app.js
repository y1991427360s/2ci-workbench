let csrf = '', current = null, page = 'overview', projects = [], dirty = false, busy = false;
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const titles = { overview: '工程总览', cables: '电缆统计', params: '计算参数', aliases: '柜名匹配', terminal: '端子排出图', issues: '问题清单', outputs: '输出文件', guide: 'CAD 数据导出' };

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
        c.innerHTML = '<div class="empty"><div class="mark">⚡</div><h2>从一个工程开始</h2><p class="muted">工程里的清册、CAD 数据、端子输入与成果会一起保存。</p><button class="primary" id="first-project">＋ 新建工程</button></div>';
        $('#first-project').onclick = () => $('#create-dialog').showModal();
        return;
    }
    if (page === 'overview') overview(c);
    if (page === 'cables') cables(c);
    if (page === 'params') await parameters(c);
    if (page === 'aliases') await aliases(c);
    if (page === 'terminal') await terminal(c);
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
    return '<div class="drop"><h3>导入工程数据</h3><p class="muted">上传原始清册 XLSX、CAD 导出的 CSV，或已有工程的 ZIP。ZIP 中的 outputs 不会覆盖成果。</p><input id="upload-files" type="file" multiple accept=".xlsx,.csv,.zip,.txt,.json"><button id="upload" class="primary">上传并保存</button><p class="muted" style="margin-top:8px">单次最多 80MB；中文 CSV 使用 UTF-8 BOM 编码。</p></div>';
}

function bindUpload() {
    if (!$('#upload')) return;
    $('#upload').onclick = () => action(async () => {
        const files = $('#upload-files').files;
        if (!files.length) throw Error('请先选择文件');
        const form = new FormData();
        for (const f of files) form.append('files', f);
        current = await api('/projects/' + current.id + '/upload', 'POST', form);
        notify('工程输入已保存');
        await render();
    });
}

function overview(c) {
    c.innerHTML = '<div class="hero"><p class="eyebrow">PROJECT / 当前工程</p><h2>' + esc(current.name) + '</h2><p>上传 CAD 路径与清册，计算电缆长度；粘贴端子排与接线，生成可编辑 DXF。成果与输入随工程实时隔离保存。</p></div>' + stats() + '<div class="grid"><div class="panel"><h3>工程输入状态</h3>' + statusTable() + '</div><div class="panel"><h3>设计流程向导</h3><div class="steps"><p>在 CAD 中导出柜子坐标、路径线段与竖井数据</p><p>上传清册与 CSV，核对计算参数及柜名匹配</p><p>计算长度并在线复核二维 / 三维可视化路径</p><p>检查端子接线，下载 DXF 格式工程成果图</p></div><div class="actions"><button data-goto="cables" class="primary">前往电缆统计 →</button><button data-goto="terminal">端子排出图 →</button></div></div></div>' + uploadBlock();
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
    c.innerHTML = '<div class="panel"><div class="terminal-toolbar"><label>柜名<input id="cabinet" value="' + esc(state.cabinet) + '" placeholder="请输入柜名，用于图签与文件名"></label><label>默认电缆方向<select id="direction"><option>向下</option><option>向上</option></select></label></div><div class="grid"><div><div class="editor-label"><strong>端子排定义</strong><span>普通 / CAD 坐标格式</span></div><textarea id="terminals" spellcheck="false" placeholder="X、1、2、3">' + esc(state.terminals) + '</textarea><input type="file" id="terminal-import" accept=".txt" style="margin-top:10px"><small class="muted" style="display:block;margin-top:4px">支持导入 UTF-8、GBK 或 UTF-16 TXT 文件</small></div><div><div class="editor-label"><strong>接线信息</strong><span>端子引用、原理号、去向柜</span></div><textarea id="wiring" spellcheck="false" placeholder="X:1、A610、甲柜">' + esc(state.wiring) + '</textarea><input type="file" id="wiring-import" accept=".txt" style="margin-top:10px"></div></div><div class="actions"><button id="inspect">🔍 检查输入 · F5</button><button class="primary" id="generate">⚡ 生成 DXF · Ctrl+Enter</button><button id="save-terminal">保存输入</button><button id="example">填入示例</button></div><p class="muted" id="save-status">切换页面和工程时自动保存。完整图与仅接线图坐标保持精确对齐。</p><div id="terminal-result"></div><div id="directions"></div></div>';
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
                const files = current.outputs.filter(f => f.name.endsWith('.dxf'));
                $('#terminal-result').innerHTML += '<div class="actions">' + files.map(f => '<a class="button primary" href="' + link(f.name) + '">↓ 下载 ' + esc(f.name.split('/').pop()) + '</a>').join('') + '</div>';
            }
            notify(r.ok ? (actionName === 'generate' ? 'DXF 已生成，可以下载' : '输入检查通过') : '请修正输入后重试', !r.ok);
        });
    }
}

function issues(c) {
    const rows = [...(current.result?.issues || []).map(x => ['电缆', x[0], x[1]]), ...(current.terminalIssues || []).map(x => ['端子', x[0], x[1]])];
    c.innerHTML = '<div class="panel"><h3>问题清单 · ' + rows.length + ' 条</h3><p class="muted" style="margin-bottom:16px">电缆问题来自最近一次计算；端子问题来自本次输入检查。</p>' + table(['来源', '级别', '说明'], rows.map(r => [esc(r[0]), '<span class="badge ' + (r[1] === '错误' ? 'error' : 'warn') + '">' + esc(r[1]) + '</span>', esc(r[2])])) + (rows.length ? '' : '<p class="muted">暂无问题记录。运行计算或端子检查后在此查看详情。</p>') + '</div>';
}

function outputs(c) {
    c.innerHTML = '<div class="panel"><h3>工程成果文件</h3>' + table(['成果文件', '文件大小', '快捷操作'], current.outputs.map(f => [esc(f.name), Math.ceil(f.size / 1024) + ' KB', '<a class="button" style="height:30px;padding:0 14px;font-size:0.8rem" href="' + link(f.name) + '" ' + (f.name.endsWith('.html') ? 'target="_blank"' : '') + '>' + (f.name.endsWith('.html') ? '打开复核 ↗' : '下载 ↓') + '</a>'])) + (current.outputs.length ? '' : '<p class="muted">计算电缆或生成端子图后，工程成果将显示在这里。</p>') + '</div>';
}

function guide(c) {
    c.innerHTML = '<div class="hero"><p class="eyebrow">CAD DATA / 数据导出向导</p><h2>从图纸提取路径，在网页完成计算</h2><p>使用原版完整 CAD 导出向导，一键从 CAD 提取设备、路径与坚井数据，上传至当前工程即可完成自动化设计计算。</p></div><div class="panel"><div class="actions"><a class="button primary" href="/static/cad_cable_wizard.lsp" download>↓ 下载 CAD 导出向导 (AutoLISP)</a></div><div class="steps"><p>在 AutoCAD / ZWCAD 中输入 APPLOAD 命令，加载下载的 LISP 向导程序。</p><p>在命令行执行 DDFD_CABLE_WIZARD 命令，按向导定义房间范围、柜子、路径及竖井。</p><p>在向导第 5 步选定工程导出目标文件夹，自动导出 CSV 数据至 data 目录。</p><p>进入网页版「电缆统计」模块，上传原始工程清册与导出的 CSV 文件。</p><p>核对计算参数与柜名映射，点击计算并打开二维 / 三维路径可视化复核。</p></div><h3 style="margin-top:24px">端子与接线输入示例</h3><div class="grid"><pre>端子排输入示例：\nX、1、2、3\nZD、1、11</pre><pre>接线输入示例：\nX:1、A610\nX:2、B903、甲柜\nX:3、701、乙柜</pre></div><p class="muted" style="margin-top:14px">同一根电缆只在最后一条填去向柜。坐标格式的端子名称行须以「端子名」结尾。普通格式与坐标格式不能混用。</p></div>';
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
