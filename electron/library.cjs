const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const { runProcess, gitError } = require('./git-process.cjs');
const YEAR = /^\d{4}$/;
const MONTH = /^(0[1-9]|1[0-2])$/;
const MAX_PDF = 95 * 1024 * 1024;
const exists = async p => fs.access(p).then(() => true, () => false);
const digest = async p => crypto.createHash('sha256').update(await fs.readFile(p)).digest('hex');

class Library extends EventEmitter {
  constructor(configPath, trash) {
    super();
    this.configPath = configPath;
    this.trash = trash;
    this.config = {};
    this.state = { busy: false, phase: '', error: '', lastSync: null, connected: false, root: '', remote: '', papers: [], folders: [] };
    this.fingerprint = '';
  }
  publish() { this.emit('state', structuredClone(this.state)); }
  async init() {
    try { this.config = JSON.parse(await fs.readFile(this.configPath, 'utf8')); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    if (this.config.root) {
      this.state.root = this.config.root;
      this.state.remote = this.config.remote || '';
      this.state.connected = !!this.config.remote;
      await this.scan();
    }
    return this.state;
  }
  async git(args, cwd = this.config.root) {
    const network = ['push', 'fetch', 'clone'].includes(args[0]);
    try {
      const { stdout } = await runProcess('git', ['-c', 'core.quotepath=false', '-c', 'core.hooksPath=' + path.join(path.dirname(this.configPath), 'empty-hooks'),
        ...(network ? ['-c', 'http.lowSpeedLimit=1', '-c', 'http.lowSpeedTime=90'] : []), ...args], {
        cwd, timeout: network ? 15 * 60 * 1000 : 90000,
        env: { ...process.env, LC_ALL: 'C', GIT_TERMINAL_PROMPT: '0', GIT_SSH_COMMAND: process.env.GIT_SSH_COMMAND || 'ssh -o BatchMode=yes -o ConnectTimeout=15' },
        onStderr: args[0] === 'push' ? chunk => {
          const writing = [...chunk.matchAll(/Writing objects:\s*(\d+)%/g)].pop();
          if (!writing) return;
          const phase = `上传论文 ${writing[1]}%`;
          if (phase !== this.state.phase) { this.state.phase = phase; this.publish(); }
        } : undefined
      });
      return stdout.trim();
    } catch (e) {
      const error = gitError(e, args[0]);
      error.cause = e;
      throw error;
    }
  }
  async lock(phase, action) {
    if (this.state.busy) throw new Error('正在同步，请稍候。');
    this.state.busy = true; this.state.phase = phase; this.state.error = ''; this.publish();
    try { return await action(); }
    catch (e) { this.state.error = e.message; throw e; }
    finally {
      try { if (this.config.root) await this.scan(); } catch (e) { this.state.error ||= e.message; }
      this.state.busy = false; this.state.phase = ''; this.publish();
    }
  }
  async safePath(relative, allowMissing = false) {
    if (!this.config.root || typeof relative !== 'string') throw new Error('请先设置论文仓库。');
    const parts = relative.split('/');
    if (parts.length > 3 || !YEAR.test(parts[0]) || (parts.length > 1 && !MONTH.test(parts[1])) ||
      (parts.length === 3 && (!parts[2] || parts[2].includes('\\') || parts[2].includes('\0') || !/\.pdf$/i.test(parts[2])))) throw new Error('无效的论文路径。');
    let cursor = this.config.root;
    for (const part of parts) {
      cursor = path.join(cursor, part);
      try { if ((await fs.lstat(cursor)).isSymbolicLink()) throw new Error('不支持符号链接。'); }
      catch (e) { if (!(allowMissing && e.code === 'ENOENT')) throw e; }
    }
    return cursor;
  }
  async scan() {
    const folders = [], papers = [];
    for (const year of await fs.readdir(this.config.root, { withFileTypes: true })) {
      if (!year.isDirectory() || !YEAR.test(year.name)) continue;
      folders.push({ id: year.name, name: year.name, level: 'year', date: (await fs.stat(path.join(this.config.root, year.name))).mtimeMs });
      for (const month of await fs.readdir(path.join(this.config.root, year.name), { withFileTypes: true })) {
        if (!month.isDirectory() || !MONTH.test(month.name)) continue;
        const folder = `${year.name}/${month.name}`;
        folders.push({ id: folder, name: month.name, level: 'month', date: (await fs.stat(path.join(this.config.root, folder))).mtimeMs });
        for (const file of await fs.readdir(path.join(this.config.root, folder), { withFileTypes: true })) {
          if (!file.isFile() || !/\.pdf$/i.test(file.name)) continue;
          const id = `${folder}/${file.name}`, stat = await fs.stat(path.join(this.config.root, id));
          papers.push({ id, name: file.name.slice(0, -4), filename: file.name, folder, size: stat.size, date: stat.mtimeMs, created: stat.birthtimeMs });
        }
      }
    }
    this.state.papers = papers;
    this.state.folders = folders;
    this.fingerprint = JSON.stringify(papers.map(p => [p.id, p.size, p.date]).sort());
    return this.state;
  }
  async configure({ root, remote }) {
    return this.lock('连接仓库', async () => {
      if (!root || typeof root !== 'string' || typeof remote !== 'string') throw new Error('请选择存储位置。');
      remote = remote.trim();
      if (remote && !/^(https:\/\/github\.com\/|git@github\.com:)[\w.-]+\/[\w.-]+(?:\.git)?$/.test(remote)) throw new Error('请输入 GitHub 仓库的 HTTPS 或 SSH 地址。');
      root = await fs.realpath(root);
      if ((await fs.lstat(root)).isSymbolicLink()) throw new Error('请选择真实文件夹。');
      const currentRoot = this.config.root;
      // A repository belongs to this folder, never implicitly adopt its parent's repository.
      if (!(await exists(path.join(root, '.git')))) {
        if ((await fs.readdir(root)).filter(n => n !== '.DS_Store').length) throw new Error('请选择空文件夹，或已存在的论文 Git 仓库。');
        if (remote) await this.git(['clone', '--', remote, root], path.dirname(root));
        else await this.git(['init', '-b', 'main', root], path.dirname(root));
      }
      const actualRoot = await this.git(['rev-parse', '--show-toplevel'], root);
      if (path.resolve(actualRoot) !== root) throw new Error('请选择 Git 仓库根目录。');
      const origin = await this.git(['remote', 'get-url', 'origin'], root).catch(() => '');
      if (origin && remote && origin.replace(/\.git$/, '') !== remote.replace(/\.git$/, '')) throw new Error('此文件夹已连接其他仓库，请选择新的空文件夹。');
      if (remote && !origin) await this.git(['remote', 'add', 'origin', remote], root);
      // Local commit identity is scoped to the paper repository.
      if (!(await this.git(['config', 'user.name'], root).catch(() => ''))) await this.git(['config', 'user.name', 'PaperRep'], root);
      if (!(await this.git(['config', 'user.email'], root).catch(() => ''))) await this.git(['config', 'user.email', 'paperrep@users.noreply.github.com'], root);
      this.config = { root, remote: remote || origin };
      try {
        await fs.mkdir(path.dirname(this.configPath), { recursive: true });
        await fs.writeFile(this.configPath + '.tmp', JSON.stringify(this.config, null, 2));
        await fs.rename(this.configPath + '.tmp', this.configPath);
      } catch (e) { this.config.root = currentRoot; throw e; }
      Object.assign(this.state, { root, remote: this.config.remote, connected: !!this.config.remote });
      await this.scan();
      await this.syncUnlocked();
      return this.state;
    });
  }
  async makeMonth(month) {
    if (!/^\d{4}\/(0[1-9]|1[0-2])$/.test(month)) throw new Error('请选择有效的年份和月份。');
    const dest = await this.safePath(month, true);
    await fs.mkdir(dest, { recursive: true });
    await fs.writeFile(path.join(dest, '.gitkeep'), '');
    return dest;
  }
  async createFolder(month) {
    return this.lock('创建文件夹', async () => { await this.makeMonth(month); await this.syncUnlocked(); });
  }
  async importFiles({ files, month }) {
    return this.lock('导入论文', async () => {
      if (!Array.isArray(files) || !files.length || files.length > 500) throw new Error('请选择 PDF 文件。');
      const planned = [], names = new Set();
      await this.safePath(month, true);
      // Validate the whole batch before copying or moving any source.
      for (const source of files) {
        const name = path.basename(source);
        if (!/\.pdf$/i.test(name) || /[<>:"|?*\\\x00-\x1f]/.test(name) || /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\./i.test(name)) throw new Error(`文件名无法跨平台使用：${name}`);
        const stat = await fs.lstat(source);
        if (!stat.isFile() || stat.isSymbolicLink()) throw new Error(`不是普通 PDF 文件：${name}`);
        if (stat.size > MAX_PDF) throw new Error(`${name} 超过 95 MB，无法直接同步至 GitHub。`);
        const handle = await fs.open(source, 'r');
        try { const header = Buffer.alloc(5); await handle.read(header, 0, 5, 0); if (header.toString() !== '%PDF-') throw new Error(`文件不是有效的 PDF：${name}`); } finally { await handle.close(); }
        const canonical = name.normalize('NFC').toLowerCase();
        const realSource = await fs.realpath(source);
        if (realSource === this.config.root || realSource.startsWith(this.config.root + path.sep)) throw new Error('论文已在仓库中，请从仓库外导入。');
        if (names.has(canonical)) throw new Error(`所选文件存在同名论文：${name}`);
        names.add(canonical);
        const dest = await this.safePath(`${month}/${name}`, true);
        planned.push({ source, dest, name, hash: await digest(source) });
      }
      const destDir = await this.makeMonth(month);
      const existing = new Set((await fs.readdir(destDir)).map(n => n.normalize('NFC').toLowerCase()));
      for (const item of planned) if (existing.has(item.name.normalize('NFC').toLowerCase())) throw new Error(`目标文件夹已有「${item.name}」，请先修改源文件名。`);
      const copied = [];
      try {
        for (const item of planned) {
          await fs.copyFile(item.source, item.dest, fs.constants.COPYFILE_EXCL); copied.push(item);
          const h = await fs.open(item.dest, 'r+'); try { await h.sync(); } finally { await h.close(); }
          if (await digest(item.dest) !== item.hash || await digest(item.source) !== item.hash) throw new Error(`导入时文件发生变化：${item.name}，请关闭阅读器后重试。`);
        }
      } catch (e) { for (const item of copied) await fs.unlink(item.dest).catch(() => {}); throw e; }
      const retained = [];
      for (const item of planned) {
        // Never remove a source that changed while the other files were being copied.
        if (await digest(item.source).catch(() => '') !== item.hash) { retained.push(item.name); continue; }
        await fs.unlink(item.source).catch(() => retained.push(item.name));
      }
      await this.syncUnlocked();
      return { count: planned.length, retained };
    });
  }
  async remove(ids) {
    return this.lock('移至废纸篓', async () => {
      if (!Array.isArray(ids) || !ids.length) throw new Error('请先选择论文或文件夹。');
      const unique = [...new Set(ids)].filter(id => !ids.some(parent => id !== parent && id.startsWith(parent + '/')));
      const targets = await Promise.all(unique.map(id => this.safePath(id)));
      for (const target of targets) await this.trash(target);
      await this.syncUnlocked();
    });
  }
  async syncUnlocked() {
    this.state.phase = '保存本地更改'; this.publish();
    const unmerged = await this.git(['diff', '--name-only', '--diff-filter=U']);
    if (unmerged) throw new Error('仓库存在未解决的冲突，请先在 Git 中解决后重试。');
    // Stage only the managed year folders; never accidentally publish other local files.
    const years = new Set((await fs.readdir(this.config.root)).filter(n => YEAR.test(n)));
    const tracked = await this.git(['ls-files', '-z']);
    for (const name of tracked.split('\0')) if (YEAR.test(name.split('/')[0])) years.add(name.split('/')[0]);
    if (years.size) await this.git(['add', '-A', '--', ...years]);
    const staged = await this.git(['diff', '--cached', '--name-only']);
    // Refuse to commit files staged by another program outside the library.
    if (staged.split('\n').some(n => n && !/^\d{4}\//.test(n))) throw new Error('仓库中有论文目录外的暂存更改，请先在 Git 中处理。');
    if (staged) await this.git(['commit', '-m', `PaperRep: update library ${new Date().toISOString()}`]);
    if (!this.config.remote) { await this.scan(); return; }
    this.state.phase = '同步 GitHub'; this.publish();
    const branch = await this.git(['symbolic-ref', '--short', 'HEAD']).catch(() => '');
    if (!branch) throw new Error('仓库处于分离 HEAD 状态，请先切换到一个分支。');
    await this.git(['fetch', '--prune', 'origin']);
    const remoteHead = await this.git(['rev-parse', '--verify', `refs/remotes/origin/${branch}`]).catch(() => '');
    if (remoteHead) {
      try { await this.git(['merge', '--no-edit', `refs/remotes/origin/${branch}`]); }
      catch (e) { await this.git(['merge', '--abort']).catch(() => {}); throw new Error('多端更改存在冲突，本地论文已保留。请在 Git 中合并后重试同步。\n' + e.message); }
    }
    const head = await this.git(['rev-parse', '--verify', 'HEAD']).catch(() => '');
    if (head) await this.git(['push', '--progress', '--porcelain', '--set-upstream', 'origin', branch]);
    this.state.lastSync = Date.now();
    await this.scan();
  }
  async sync() { if (!this.config.root) return; return this.lock('同步 GitHub', () => this.syncUnlocked()); }
  async poll() {
    if (this.state.busy || !this.config.root) return;
    const previous = this.fingerprint;
    await this.scan();
    if (previous !== this.fingerprint) {
      this.publish();
      // Wait for editors' atomic replacement or write bursts to settle.
      this.changedAt = Date.now();
      this.pendingChange = true;
    }
    if (this.pendingChange && Date.now() - this.changedAt >= 3000) {
      this.pendingChange = false;
      await this.sync();
    }
  }
}
module.exports = { Library };
