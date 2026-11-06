const { spawn } = require('node:child_process');

// Git's HTTPS/SSH transports are separate processes. Kill the entire process
// group on timeout, so an expired upload cannot survive a later retry.
function runProcess(command, args, { cwd, env = process.env, timeout = 90000, onStderr } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env, windowsHide: true, detached: process.platform !== 'win32', stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '', timedOut = false, outputExceeded = false, settled = false, forceTimer, pendingClose;
    const terminate = force => {
      if (!child.pid) return;
      if (process.platform === 'win32') {
        const killer = spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
        killer.on('error', () => child.kill());
      } else {
        try { process.kill(-child.pid, force ? 'SIGKILL' : 'SIGTERM'); } catch (e) { if (e.code !== 'ESRCH') child.kill(); }
      }
    };
    const stop = () => {
      terminate(false);
      forceTimer ||= setTimeout(() => { terminate(true); forceTimer = null; pendingClose?.(); }, 1000);
    };
    const timer = setTimeout(() => { timedOut = true; stop(); }, timeout);
    const finish = (error, code, signal) => {
      if (settled) return;
      settled = true; clearTimeout(timer); clearTimeout(forceTimer);
      if (error || code !== 0 || timedOut || outputExceeded) {
        const failure = error || new Error(timedOut ? 'Git operation timed out' : outputExceeded ? 'Git output exceeded limit' : `Git exited with code ${code}`);
        Object.assign(failure, { stdout, stderr, timedOut, outputExceeded, signal, code: error?.code || code });
        reject(failure);
      } else resolve({ stdout, stderr });
    };
    child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
    child.stdout.on('data', chunk => { stdout += chunk; if (Buffer.byteLength(stdout) > 10 * 1024 * 1024) { outputExceeded = true; stop(); } });
    child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-128 * 1024); onStderr?.(chunk); });
    child.on('error', error => finish(error));
    child.on('close', (code, signal) => {
      if (forceTimer) pendingClose = () => finish(null, code, signal);
      else finish(null, code, signal);
    });
  });
}

function gitError(error, operation) {
  const action = operation === 'push' ? '上传' : operation === 'fetch' || operation === 'clone' ? '下载' : 'Git 操作';
  if (error.code === 'ENOENT') return new Error('未找到 Git，请安装 Git 后重新启动应用。');
  if (error.timedOut) return new Error(`${action}超时，本地更改已保留。请检查网络后重试。`);
  const detail = (error.stderr || error.stdout || error.message || '').replace(/https?:\/\/[^\s/@]+@/g, 'https://').trim();
  if (/authentication failed|could not read Username|permission denied \(publickey\)|repository not found|\b403\b|write access.*not granted/i.test(detail)) return new Error('无法访问远程仓库，请检查登录凭据和仓库写入权限。');
  if (/could not resolve host|failed to connect|connection.*(reset|refused|timed out)|network is unreachable|RPC failed|curl \d+|TLS|SSL|HTTP\/2|Operation too slow/i.test(detail)) return new Error('仓库连接中断，本地更改已保留。请检查网络后重试。');
  if (/non-fast-forward|fetch first|rejected.*stale/i.test(detail)) return new Error('远程仓库有新的更改，请重新同步。');
  if (error.outputExceeded) return new Error('Git 输出超过限制，请检查仓库状态后重试。');
  // Prefer Git's actual diagnosis over transfer progress or the command line.
  const lines = detail.split(/[\r\n]+/).filter(line => !/^(Enumerating|Counting|Compressing|Writing|Receiving|Resolving|Total) (objects|deltas)|^remote: (Enumerating|Counting|Compressing|Resolving)/.test(line));
  return new Error((lines.join('\n') || `${action}失败，本地更改已保留。`).slice(-1500));
}
module.exports = { runProcess, gitError };
