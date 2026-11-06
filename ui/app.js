const $ = id => document.getElementById(id);
const paths = {
  brand: '<path d="M6 3h9l4 4v14H6z"/><path d="M14 3v5h5M9 12h7M9 16h5"/>',
  folder: '<path d="M3 7V5a1 1 0 0 1 1-1h5l2 2h9a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1Z"/><path d="M3 9h18"/>',
  'folder-plus': '<path d="M3 7V5a1 1 0 0 1 1-1h5l2 2h9a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1Z"/><path d="M9 13h6m-3-3v6"/>',
  file: '<path d="M5 3h9l5 5v13H5z"/><path d="M14 3v5h5M8 12h8M8 16h6"/>',
  stack: '<rect x="6" y="3" width="14" height="15" rx="2"/><path d="M3 7v13a1 1 0 0 0 1 1h12M10 7h6M10 11h6"/>',
  library: '<path d="M4 4v16M8 4v16M13 4v16M17 4l4 15"/>',
  database: '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v7c0 4 16 4 16 0V5M4 12v7c0 4 16 4 16 0v-7"/>',
  chevron: '<path d="m9 6 6 6-6 6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  list: '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  sort: '<path d="M4 5h16M4 12h11M4 19h6"/>',
  'arrow-down': '<path d="M12 4v16m-6-6 6 6 6-6"/>',
  'arrow-up': '<path d="M12 20V4m-6 6 6-6 6 6"/>',
  'arrow-right': '<path d="M4 12h16m-6-6 6 6-6 6"/>',
  refresh: '<path d="M20 7v5h-5M4 17v-5h5"/><path d="M6.2 7a7 7 0 0 1 11.6-1L20 9M4 15l2.2 3A7 7 0 0 0 18 17"/>',
  settings: '<path d="m10 3-.6 2.2-2 .9L5 5.5l-2 3.4 1.7 1.6v3L3 15.1l2 3.4 2.4-.6 2 .9L10 21h4l.6-2.2 2-.9 2.4.6 2-3.4-1.7-1.6v-3L21 8.9l-2-3.4-2.4.6-2-.9L14 3Z"/><circle cx="12" cy="12" r="3"/>',
  github: '<path d="M9 19c-4 1-4-2-6-2m12 5v-4a3.5 3.5 0 0 0-1-3c3.5-.4 6-1.7 6-5.6A4.5 4.5 0 0 0 19 6c.1-1.2 0-2.3-.5-3-1.5 0-2.5.5-3.5 1a12 12 0 0 0-6 0C8 3.5 7 3 5.5 3 5 3.7 4.9 4.8 5 6a4.5 4.5 0 0 0-1 3.4C4 13.3 6.5 14.6 10 15a3.5 3.5 0 0 0-1 3v4"/>',
  shield: '<path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6Z"/><path d="m8 12 3 3 5-6"/>',
  mouse: '<rect x="6" y="2" width="12" height="20" rx="6"/><path d="M12 2v7"/>',
  open: '<path d="M14 3h7v7m0-7L10 14M10 3H4v17h16v-6"/>',
  trash: '<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/>',
  x: '<path d="m6 6 12 12M6 18 18 6"/>',
  download: '<path d="M12 3v12m-5-5 5 5 5-5M4 15v6h16v-6"/>',
  alert: '<path d="m12 3 10 18H2Z"/><path d="M12 9v5m0 3v.1"/>'
};
const icon = name => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.file}</svg>`;
document.querySelectorAll('[data-icon]').forEach(el => { el.innerHTML = icon(el.dataset.icon); });
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const api = window.paperrep;
let state = { papers: [], folders: [], root: '', remote: '', connected: false, busy: false, error: '' };
let mode = localStorage.getItem('mode') || 'folders', current = '', sort = localStorage.getItem('sort') || 'name';
let descending = localStorage.getItem('descending') === 'true', query = '', selected = new Set(), rows = [], anchor = null;
let searchTimer, toastTimer, pendingFiles = null, chosenRoot = '', monthPurpose = 'create', dragDepth = 0;
const today = () => { const d = new Date(); return `${d.getFullYear()}/${String(d.getMonth() + 1).padStart(2, '0')}`; };
const formatSize = bytes => { if (bytes < 1024) return [bytes ? '1' : '0', 'KB']; if (bytes < 1048576) return [(bytes / 1024).toFixed(0), 'KB']; if (bytes < 1073741824) return [(bytes / 1048576).toFixed(1), 'MB']; return [(bytes / 1073741824).toFixed(2), 'GB']; };
const date = timestamp => new Date(timestamp).toLocaleDateString('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit' });
async function call(method, data) {
  if (!api) throw new Error('请通过桌面应用打开 PaperRep。');
  const result = await api.invoke(method, data);
  if (result.error) throw new Error(result.error);
  return result.data;
}
function toast(message) { $('toast').textContent = message; $('toast').hidden = false; clearTimeout(toastTimer); toastTimer = setTimeout(() => { $('toast').hidden = true; }, 4500); }
function handleError(e) { if (state.error !== e.message) toast(e.message); }
function navigate(nextMode, folder = '') {
  if (state.busy) return;
  mode = nextMode; current = folder; selected.clear(); anchor = null; query = ''; $('search').value = ''; clearTimeout(searchTimer);
  localStorage.setItem('mode', mode); hideContext(); render();
}
function render() {
  if (current && !state.folders.some(f => f.id === current)) current = '';
  $('stat-papers').innerHTML = `${state.papers.length} <small>篇</small>`;
  $('stat-months').innerHTML = `${state.folders.filter(f => f.level === 'month').length} <small>个</small>`;
  const totalSize = formatSize(state.papers.reduce((a, p) => a + p.size, 0));
  $('stat-size').innerHTML = `${totalSize[0]} <small>${totalSize[1]}</small>`;
  $('nav-count').textContent = state.papers.length;
  for (const [id, active] of [['nav-folders', mode === 'folders'], ['nav-all', mode === 'all'], ['view-folders', mode === 'folders'], ['view-all', mode === 'all']]) {
    $(id).classList.toggle('active', active); $(id).setAttribute('aria-pressed', String(active));
  }
  $('new-folder').hidden = mode !== 'folders';
  $('year-nav').innerHTML = state.folders.filter(f => f.level === 'year').sort((a, b) => b.name.localeCompare(a.name)).map(f => `<button class="year-button ${mode === 'folders' && current.startsWith(f.id) ? 'selected' : ''}" data-year="${f.id}">${icon('folder')}<span>${f.name}</span><span>${state.papers.filter(p => p.id.startsWith(f.id + '/')).length}</span></button>`).join('');
  $('breadcrumbs').innerHTML = `<span class="crumb-icon">${icon(mode === 'all' ? 'stack' : 'folder')}</span><button data-path="">${mode === 'all' ? '所有论文' : '全部文件夹'}</button>` + (mode === 'folders' && current ? current.split('/').map((part, i, parts) => `${icon('chevron')}<button data-path="${parts.slice(0, i + 1).join('/')}">${part}${i === 0 ? ' 年' : ' 月'}</button>`).join('') : '');
  $('sync-title').textContent = state.error ? '同步需要处理' : state.connected ? (state.remote.includes('gitee.com') ? '已连接 Gitee' : '已连接 GitHub') : '本地资料库';
  $('sync-detail').textContent = state.lastSync ? `上次同步 ${new Date(state.lastSync).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}` : '';
  $('sync-detail').hidden = !state.lastSync || !!state.error;
  $('sync-card').classList.toggle('connected', state.connected && !state.error);
  $('sync-card').classList.toggle('sync-error', !!state.error);
  $('sync-label').textContent = state.root ? state.connected ? '立即同步' : '保存本地更改' : '设置资料库';
  $('error-banner').hidden = !state.error;
  $('error-message').textContent = state.error;
  $('busy-overlay').hidden = !state.busy;
  if (state.busy && !$('busy-overlay').open) $('busy-overlay').showModal();
  if (!state.busy && $('busy-overlay').open) $('busy-overlay').close();
  $('busy-phase').textContent = state.phase || '正在处理';
  $('app').inert = state.busy;
  for (const dialog of document.querySelectorAll('dialog:not(#busy-overlay)')) dialog.inert = state.busy;
  $('sort').value = sort;
  $('sort-direction').innerHTML = icon(descending ? 'arrow-up' : 'arrow-down');
  $('sort-direction').title = descending ? '降序，点击切换升序' : '升序，点击切换降序';
  renderList();
}
function renderList() {
  const papers = mode === 'all' ? state.papers : state.papers.filter(p => p.folder === current);
  let folders = mode === 'folders' ? state.folders.filter(f => current ? f.level === 'month' && f.id.split('/')[0] === current : f.level === 'year') : [];
  if (current.split('/').length === 2) folders = [];
  folders = folders.map(f => {
    const contents = state.papers.filter(p => p.id.startsWith(f.id + '/'));
    return { ...f, kind: 'folder', size: contents.reduce((a, p) => a + p.size, 0), count: contents.length };
  });
  const compare = (a, b) => (sort === 'date' ? a.date - b.date : a.name.localeCompare(b.name, 'zh-CN', { numeric: true, sensitivity: 'base' })) * (descending ? -1 : 1);
  rows = [...(query ? [] : folders.sort(compare)), ...papers.filter(p => p.name.toLocaleLowerCase().includes(query.toLocaleLowerCase())).map(p => ({ ...p, kind: 'paper' })).sort(compare)];
  selected = new Set([...selected].filter(id => rows.some(row => row.id === id)));
  $('file-list').innerHTML = rows.map(row => `<div class="file-row ${selected.has(row.id) ? 'selected' : ''}" data-id="${escape(row.id)}" data-kind="${row.kind}" role="row" aria-selected="${selected.has(row.id)}" tabindex="0"><label class="check-wrap row-check"><input type="checkbox" ${selected.has(row.id) ? 'checked' : ''} aria-label="选择 ${escape(row.name)}"></label><div class="file-name"><span class="file-icon ${row.kind === 'paper' ? 'pdf' : ''}">${icon(row.kind === 'paper' ? 'file' : 'folder')}</span><div class="file-info"><div class="file-title" title="${escape(row.filename || row.name)}">${escape(row.name)}${row.kind === 'folder' ? (row.level === 'year' ? '<span class="folder-unit"> 年</span>' : '<span class="folder-unit"> 月</span>') : ''}</div><div class="file-subtitle">${row.kind === 'paper' ? (mode === 'all' ? escape(row.folder.replace('/', ' / ')) : '') : `${row.count} 篇论文`}</div></div></div><span class="file-date">${row.date ? date(row.date) : '—'}</span><span class="file-size">${row.size ? formatSize(row.size).join(' ') : '—'}</span><span class="row-chevron">${row.kind === 'folder' ? icon('chevron') : ''}</span></div>`).join('');
  const empty = rows.length === 0;
  $('empty').hidden = !empty;
  $('file-list').hidden = empty;
  $('list-count').textContent = query ? `${rows.length} 个搜索结果` : `${rows.length} 个项目`;
  $('selection-count').textContent = selected.size ? `已选择 ${selected.size} 项` : '';
  $('select-all').checked = rows.length > 0 && selected.size === rows.length;
  $('select-all').indeterminate = selected.size > 0 && selected.size < rows.length;
  $('select-all').disabled = !rows.length;
  $('empty-title').textContent = query ? '无搜索结果' : !state.root ? '尚未设置资料库' : mode === 'folders' && !current ? '暂无文件夹' : '暂无论文';
  $('empty-description').textContent = query && !papers.length ? '进入月份或切换到所有论文后搜索' : '';
  $('empty-description').hidden = !query || !!papers.length;
  $('empty-action').textContent = query ? '清除搜索' : state.root ? '添加论文' : '设置资料库';
}
function settings() {
  if (state.busy) return;
  chosenRoot = state.root;
  $('root-label').textContent = chosenRoot || '选择存储文件夹';
  $('remote').value = state.remote || ''; $('settings-error').hidden = true;
  $('settings-dialog').showModal();
}
function monthDialog(purpose, files = null) {
  monthPurpose = purpose; pendingFiles = files;
  $('month-title').textContent = purpose === 'create' ? '新建文件夹' : '选择归档月份';
  $('month-description').textContent = purpose === 'import' ? `已选择 ${files.length} 篇论文` : '';
  $('month-description').hidden = purpose === 'create';
  const initial = current ? current.split('/').length === 2 ? current : current + '/' + today().split('/')[1] : today();
  $('month-input').value = initial.replace('/', '-');
  $('month-submit').textContent = purpose === 'create' ? '创建文件夹' : '添加论文';
  $('month-error').hidden = true; $('month-dialog').showModal();
}
async function importTo(files, month) {
  const result = await call('import', { files, month });
  if (result.retained?.length) toast(`${result.retained.length} 个源文件发生变化或无法移除，已保留。`);
}
async function addFiles(files, dropTarget = null) {
  if (state.busy || !files.length) return;
  if (!state.root) { settings(); return; }
  if (mode === 'folders' && !current) { await importTo(files, today()); return; }
  if (dropTarget && dropTarget.split('/').length === 2) { await importTo(files, dropTarget); return; }
  if (mode === 'folders' && current.split('/').length === 2) { await importTo(files, current); return; }
  monthDialog('import', files);
}
async function add() {
  if (!state.root) { settings(); return; }
  try { await addFiles(await call('pickFiles')); } catch (e) { handleError(e); }
}
function createFolder() { if (!state.root) settings(); else monthDialog('create'); }
function hideContext() { $('context-menu').hidden = true; }
function selection(row, event) {
  const index = rows.findIndex(r => r.id === row.id);
  if (event.shiftKey && anchor !== null) {
    if (!event.metaKey && !event.ctrlKey) selected.clear();
    for (let i = Math.min(anchor, index); i <= Math.max(anchor, index); i++) selected.add(rows[i].id);
  } else if (event.metaKey || event.ctrlKey || event.target.matches('input[type=checkbox]')) {
    if (selected.has(row.id)) selected.delete(row.id); else selected.add(row.id);
    anchor = index;
  } else { selected = new Set([row.id]); anchor = index; }
  updateSelection();
}
function updateSelection() {
  document.querySelectorAll('.file-row').forEach(el => {
    const active = selected.has(el.dataset.id);
    el.classList.toggle('selected', active);
    el.setAttribute('aria-selected', String(active));
    el.querySelector('input').checked = active;
  });
  $('selection-count').textContent = selected.size ? `已选择 ${selected.size} 项` : '';
  $('select-all').checked = rows.length > 0 && selected.size === rows.length;
  $('select-all').indeterminate = selected.size > 0 && selected.size < rows.length;
}
async function openRow(row) { if (!row || state.busy) return; if (row.kind === 'folder') navigate('folders', row.id); else await call('open', row.id); }
$('nav-folders').onclick = $('view-folders').onclick = () => navigate('folders');
$('nav-all').onclick = $('view-all').onclick = () => navigate('all');
$('year-nav').onclick = e => { const button = e.target.closest('[data-year]'); if (button) navigate('folders', button.dataset.year); };
$('breadcrumbs').onclick = e => { const button = e.target.closest('[data-path]'); if (button) navigate(mode, button.dataset.path); };
$('settings-button').onclick = settings;
$('sync-button').onclick = () => state.root ? call('sync').catch(handleError) : settings();
$('retry').onclick = () => call('sync').catch(handleError);
$('add-button').onclick = add;
$('empty-action').onclick = () => { if (query) { clearTimeout(searchTimer); query = ''; $('search').value = ''; renderList(); } else add(); };
$('new-folder').onclick = $('side-create').onclick = createFolder;
$('choose-root').onclick = async () => { try { const root = await call('chooseRoot'); if (root) { chosenRoot = root; $('root-label').textContent = root; } } catch (e) { handleError(e); } };
document.querySelectorAll('.close-dialog').forEach(button => { button.onclick = () => button.closest('dialog').close(); });
$('settings-form').onsubmit = async e => {
  e.preventDefault();
  if (!chosenRoot) { $('settings-error').textContent = '请先选择论文存储文件夹。'; $('settings-error').hidden = false; return; }
  try { await call('configure', { root: chosenRoot, remote: $('remote').value }); $('settings-dialog').close(); }
  catch (e) { $('settings-error').textContent = e.message; $('settings-error').hidden = false; }
};
$('month-form').onsubmit = async e => {
  e.preventDefault(); const month = $('month-input').value.replace('-', '/');
  try {
    if (monthPurpose === 'create') { await call('createFolder', month); }
    else await importTo(pendingFiles, month);
    $('month-dialog').close();
  } catch (e) {
    // A sync failure can happen after a successful local import. Do not offer to move the same sources twice.
    if (state.error && state.papers.some(p => p.folder === month && pendingFiles?.some(f => f.split(/[\\/]/).pop() === p.filename))) { $('month-dialog').close(); handleError(e); }
    else { $('month-error').textContent = e.message; $('month-error').hidden = false; }
  }
};
$('search').oninput = () => { clearTimeout(searchTimer); const value = $('search').value.trim(); searchTimer = setTimeout(() => { query = value; selected.clear(); anchor = null; renderList(); }, 1000); };
$('sort').onchange = e => { sort = e.target.value; localStorage.setItem('sort', sort); anchor = null; renderList(); };
$('sort-direction').onclick = () => { descending = !descending; localStorage.setItem('descending', descending); anchor = null; render(); };
$('name-heading').onclick = () => { if (sort === 'name') descending = !descending; else sort = 'name'; anchor = null; localStorage.setItem('sort', sort); localStorage.setItem('descending', descending); render(); };
$('select-all').onchange = e => { selected = e.target.checked ? new Set(rows.map(r => r.id)) : new Set(); updateSelection(); };
$('file-list').onclick = e => { const el = e.target.closest('.file-row'); if (!el || state.busy) return; selection(rows.find(r => r.id === el.dataset.id), e); };
$('file-list').ondblclick = e => { const el = e.target.closest('.file-row'); if (el && !e.target.matches('input')) openRow(rows.find(r => r.id === el.dataset.id)).catch(handleError); };
$('file-list').onkeydown = e => {
  if (state.busy) return;
  if ((e.metaKey || e.ctrlKey) && e.key === 'a') { e.preventDefault(); selected = new Set(rows.map(r => r.id)); updateSelection(); }
  if (e.key === 'Enter' && selected.size === 1) openRow(rows.find(r => selected.has(r.id))).catch(handleError);
  if (e.key === 'Escape') { selected.clear(); renderList(); }
};
$('file-list').oncontextmenu = e => {
  const el = e.target.closest('.file-row'); if (!el || state.busy) return; e.preventDefault();
  if (!selected.has(el.dataset.id)) { selected = new Set([el.dataset.id]); renderList(); }
  $('context-open').hidden = selected.size !== 1;
  $('context-count').textContent = selected.size > 1 ? selected.size : '';
  $('context-menu').hidden = false;
  $('context-menu').style.left = `${Math.min(e.clientX, innerWidth - 200)}px`;
  $('context-menu').style.top = `${Math.min(e.clientY, innerHeight - 95)}px`;
  $('context-open').focus();
};
$('context-open').onclick = () => { const row = rows.find(r => selected.has(r.id)); hideContext(); openRow(row).catch(handleError); };
$('context-delete').onclick = async () => { hideContext(); try { const result = await call('delete', [...selected]); if (!result?.canceled) { selected.clear(); renderList(); } } catch (e) { handleError(e); } };
document.addEventListener('click', e => { if (!e.target.closest('#context-menu')) hideContext(); });
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') hideContext();
  if (state.busy && e.key === 'Escape') e.preventDefault();
  if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k' && !state.busy && !document.querySelector('dialog[open]')) { e.preventDefault(); $('search').focus(); }
});
document.querySelectorAll('dialog').forEach(dialog => dialog.addEventListener('cancel', e => { if (state.busy) e.preventDefault(); }));
const panel = document.querySelector('.library-panel');
document.addEventListener('dragover', e => e.preventDefault());
document.addEventListener('drop', e => e.preventDefault());
panel.addEventListener('dragenter', e => { e.preventDefault(); if (state.busy || !Array.from(e.dataTransfer.types).includes('Files')) return; dragDepth++; });
panel.addEventListener('dragover', e => {
  e.preventDefault(); if (state.busy) { e.dataTransfer.dropEffect = 'none'; return; }
  e.dataTransfer.dropEffect = 'move';
  document.querySelectorAll('.drag-target').forEach(el => el.classList.remove('drag-target'));
  const target = e.target.closest('.file-row[data-kind="folder"]');
  const month = mode === 'folders' && current && target?.dataset.id.split('/').length === 2 ? target.dataset.id : null;
  if (month) { target.classList.add('drag-target'); $('drop-overlay').hidden = true; }
  else { $('drop-overlay').hidden = false; $('drop-label').textContent = mode === 'folders' && !current ? `添加到 ${today().replace('/', ' 年 ')} 月` : current.split('/').length === 2 ? `添加到 ${current.replace('/', ' 年 ')} 月` : '松开后选择归档月份'; }
});
panel.addEventListener('dragleave', () => { dragDepth--; if (dragDepth <= 0) { $('drop-overlay').hidden = true; document.querySelectorAll('.drag-target').forEach(el => el.classList.remove('drag-target')); } });
panel.addEventListener('drop', async e => {
  e.preventDefault(); dragDepth = 0; $('drop-overlay').hidden = true;
  const target = e.target.closest('.file-row[data-kind="folder"]');
  document.querySelectorAll('.drag-target').forEach(el => el.classList.remove('drag-target'));
  if (state.busy) return;
  try {
    const files = Array.from(e.dataTransfer.files);
    if (files.some(f => !/\.pdf$/i.test(f.name))) throw new Error('仅支持添加 PDF 文件。');
    const filePaths = files.map(f => api.filePath(f));
    if (filePaths.some(p => !p)) throw new Error('无法获取文件位置，请使用添加按钮。');
    await addFiles(filePaths, mode === 'folders' && current ? target?.dataset.id : null);
  } catch (e) { handleError(e); }
});
if (api) {
  if (api.platform === 'win32') { document.body.classList.add('windows'); document.querySelector('.search kbd').textContent = 'Ctrl K'; }
  api.onState(next => { state = next; if (state.busy) hideContext(); render(); });
  call('state').then(next => { state = next; render(); }).catch(handleError);
} else { render(); toast('请通过 Electron 桌面应用启动，以使用文件与同步功能。'); }
