const { test } = require('node:test');
const assert = require('node:assert/strict');
const { setTimeout: delay } = require('node:timers/promises');
const { runProcess, gitError } = require('../electron/git-process.cjs');

test('streams progress and captures the actual failed command diagnosis', async () => {
  const progress = [];
  await assert.rejects(runProcess(process.execPath, ['-e', "process.stdout.write('result'); process.stderr.write('remote: write access not granted'); process.exitCode=7"], { onStderr: chunk => progress.push(chunk) }), error => {
    assert.equal(error.code, 7); assert.equal(error.stdout, 'result');
    assert.match(error.stderr, /write access/);
    assert.match(gitError(error, 'push').message, /写入权限/);
    return true;
  });
  assert.equal(progress.join(''), 'remote: write access not granted');
});

test('timeout terminates both the command and a transport child that ignores SIGTERM', { timeout: 10000 }, async t => {
  let transportPid;
  t.after(() => { if (transportPid) { try { process.kill(transportPid, 'SIGKILL'); } catch {} } });
  const script = `
    const { spawn } = require('node:child_process');
    const transport = spawn(process.execPath, ['-e', "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"], { stdio: 'ignore' });
    process.stderr.write(String(transport.pid));
    setInterval(()=>{},1000);
  `;
  await assert.rejects(runProcess(process.execPath, ['-e', script], { timeout: 800, onStderr: chunk => { transportPid = Number(chunk); } }), error => {
    assert.equal(error.timedOut, true);
    assert.equal(gitError(error, 'push').message, '上传超时，本地更改已保留。请检查网络后重试。');
    return true;
  });
  assert(Number.isInteger(transportPid) && transportPid > 0);
  let alive = true;
  for (let i = 0; i < 40; i++) {
    try { process.kill(transportPid, 0); await delay(50); }
    catch (e) { if (e.code === 'ESRCH') { alive = false; break; } throw e; }
  }
  assert.equal(alive, false, 'The transport must not survive and overlap a retry');
  transportPid = null;
});

test('connection, timeout and unknown errors produce useful messages without credentials', () => {
  assert.match(gitError({ stderr: 'error: RPC failed; curl 92 HTTP/2 stream' }, 'push').message, /连接中断/);
  const transport = gitError({ stderr: 'fatal: unable to access https://secret@gitee.com/a/b?access_token=private: SSL_connect: Connection reset by peer' }, 'fetch').message;
  assert.match(transport, /下载/);
  assert.match(transport, /SSL_connect: Connection reset by peer/);
  assert(!transport.includes('secret')); assert(!transport.includes('private'));
  assert.match(gitError({ timedOut: true, message: 'Command failed: git push' }, 'push').message, /上传超时/);
  assert.match(gitError({ stderr: 'remote rejected https://secret@github.com/a/b' }, 'push').message, /https:\/\/github/);
  assert(!gitError({ stderr: 'remote rejected https://secret@github.com/a/b' }, 'push').message.includes('secret'));
  assert.match(gitError({ code: 'ENOENT' }, 'push').message, /未找到 Git/);
});
