const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const exec = promisify(execFile);
const { Library } = require('../electron/library.cjs');
async function fixture(t) {
  const base = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'paperrep-test-')));
  t.after(() => fs.rm(base, { recursive: true, force: true }));
  const root = path.join(base, 'papers'); await fs.mkdir(root);
  const trashed = [];
  const lib = new Library(path.join(base, 'config', 'library.json'), async p => { trashed.push(p); await fs.rename(p, path.join(base, `trash-${trashed.length}`)); });
  await lib.init(); await lib.configure({ root, remote: '' });
  const pdf = async (name = 'A paper.pdf', content = 'original') => { const p = path.join(base, name); await fs.writeFile(p, `%PDF-1.7\n\0${content}\n%%EOF`); return p; };
  return { base, root, lib, pdf, trashed };
}
test('batch import moves originals, preserves names, records Git commits and scans year/month hierarchy', async t => {
  const { lib, pdf, root } = await fixture(t);
  const sources = await Promise.all([pdf('论文一.pdf'), pdf('A paper.PDF')]);
  const result = await lib.importFiles({ files: sources, month: '2026/11' });
  assert.equal(result.count, 2); assert.deepEqual(result.retained, []);
  for (const source of sources) await assert.rejects(fs.access(source));
  assert.equal(lib.state.papers.length, 2);
  assert.deepEqual(lib.state.folders.map(f => f.id), ['2026', '2026/11']);
  assert.equal(await lib.git(['status', '--porcelain']), '');
  assert.match(await fs.readFile(path.join(root, '2026/11/论文一.pdf'), 'utf8'), /original/);
});
test('batch validation is atomic; same-name and non-PDF imports never remove originals', async t => {
  const { lib, pdf, base } = await fixture(t);
  const good = await pdf(); const bad = path.join(base, 'bad.pdf'); await fs.writeFile(bad, 'not a pdf');
  await assert.rejects(lib.importFiles({ files: [good, bad], month: '2026/11' }), /有效的 PDF/);
  await fs.access(good); assert.equal(lib.state.papers.length, 0);
  await lib.importFiles({ files: [good], month: '2026/11' });
  const duplicate = await pdf('a PAPER.pdf');
  await assert.rejects(lib.importFiles({ files: [duplicate], month: '2026/11' }), /已有/);
  await fs.access(duplicate); assert.equal(lib.state.papers.length, 1);
  assert.equal(lib.state.busy, false);
});
test('only year/month paths are accepted, symlinks and unsafe cross-platform filenames are refused', async t => {
  const { lib, root, base, pdf } = await fixture(t);
  for (const invalid of ['../2026/11', '2026/13', '2026/1', '/2026/11', '2026/11/../../x.pdf']) await assert.rejects(lib.safePath(invalid, true));
  if (process.platform !== 'win32') {
    await fs.symlink(base, path.join(root, '2025'));
    await assert.rejects(lib.createFolder('2025/01'), /符号链接/);
    const bad = await pdf('bad:name.pdf');
    await assert.rejects(lib.importFiles({ files: [bad], month: '2026/11' }), /跨平台/); await fs.access(bad);
    const link = path.join(base, 'linked.pdf'); await fs.symlink(bad, link);
    await assert.rejects(lib.importFiles({ files: [link], month: '2026/11' }), /普通 PDF/);
  } else {
    await assert.rejects(lib.importFiles({ files: [path.join(base, 'bad:name.pdf')], month: '2026/11' }), /跨平台/);
  }
});
test('year folders and selected PDF files are trashed and deletions committed', async t => {
  const { lib, pdf, trashed } = await fixture(t);
  await lib.importFiles({ files: [await pdf()], month: '2026/11' });
  await lib.remove(['2026/11/A paper.pdf']);
  assert.equal(lib.state.papers.length, 0); assert.equal(trashed.length, 1);
  await lib.createFolder('2025/03');
  await lib.remove(['2025', '2025/03']);
  assert.equal(trashed.length, 2); assert(!lib.state.folders.some(f => f.id.startsWith('2025')));
  assert.equal(await lib.git(['status', '--porcelain']), '');
});
test('operation lock rejects overlapping operations and releases after failure', async t => {
  const { lib } = await fixture(t);
  let release;
  const promise = lib.lock('test', () => new Promise(resolve => { release = resolve; }));
  await assert.rejects(lib.createFolder('2026/11'), /正在同步/);
  release(); await promise;
  await assert.rejects(lib.createFolder('invalid'));
  assert.equal(lib.state.busy, false);
  await lib.createFolder('2026/11'); assert.equal(lib.state.error, '');
});
test('settings persist across app restarts and nonempty arbitrary folders are refused', async t => {
  const { lib, root, base } = await fixture(t);
  const reopened = new Library(lib.configPath, async () => {}); await reopened.init(); assert.equal(reopened.config.root, root);
  const other = path.join(base, 'nonempty'); await fs.mkdir(other); await fs.writeFile(path.join(other, 'private.txt'), 'private');
  await assert.rejects(lib.configure({ root: other, remote: '' }), /空文件夹/); assert.equal(lib.config.root, root);
});
test('real Git remote round trip: import, second-device pull, external edit push, and conflict preservation', async t => {
  const { lib, root, base, pdf } = await fixture(t);
  const bare = path.join(base, 'remote.git'); await exec('git', ['init', '--bare', '-b', 'main', bare]);
  await lib.git(['remote', 'add', 'origin', bare]); lib.config.remote = bare;
  await lib.importFiles({ files: [await pdf()], month: '2026/11' });
  const root2 = path.join(base, 'device2'); await exec('git', ['clone', bare, root2]);
  const device2 = new Library(path.join(base, 'config2.json'), async () => {});
  await device2.init(); await device2.configure({ root: root2, remote: '' });
  assert.equal(device2.state.papers.length, 1);
  await fs.writeFile(path.join(root, '2026/11/A paper.pdf'), '%PDF-1.7\n\0edited in reader\n%%EOF');
  await lib.poll(); assert.equal(lib.pendingChange, true);
  lib.changedAt = Date.now() - 4000; await lib.poll();
  await device2.sync(); assert.match(await fs.readFile(path.join(root2, '2026/11/A paper.pdf'), 'utf8'), /edited in reader/);
  await fs.writeFile(path.join(root, '2026/11/A paper.pdf'), '%PDF-1.7\n\0device one\n%%EOF'); await lib.sync();
  await fs.writeFile(path.join(root2, '2026/11/A paper.pdf'), '%PDF-1.7\n\0device two\n%%EOF');
  await assert.rejects(device2.sync(), /冲突/);
  assert.match(await fs.readFile(path.join(root2, '2026/11/A paper.pdf'), 'utf8'), /device two/);
  await assert.rejects(fs.access(path.join(root2, '.git/MERGE_HEAD')));
  assert.equal(device2.state.busy, false); assert.match(device2.state.error, /冲突/);
});
test('push failure retains imported PDF and local commit, then supports retry', async t => {
  const { lib, root, base, pdf } = await fixture(t);
  lib.config.remote = path.join(base, 'missing.git');
  await lib.git(['remote', 'add', 'origin', lib.config.remote]);
  const source = await pdf();
  await assert.rejects(lib.importFiles({ files: [source], month: '2026/11' }));
  await fs.access(path.join(root, '2026/11/A paper.pdf'));
  assert.equal(lib.state.papers.length, 1); assert.equal(lib.state.busy, false);
  assert.equal(await lib.git(['status', '--porcelain']), '');
  await exec('git', ['init', '--bare', '-b', 'main', lib.config.remote]);
  await lib.sync(); assert.equal(lib.state.error, ''); assert(lib.state.lastSync);
});
