const { _electron: electron } = require('@playwright/test');
const path = require('node:path');
(async () => {
  const executable = process.argv[2] || (process.platform === 'win32'
    ? 'release/win-unpacked/PaperRep.exe'
    : `release/${process.arch === 'arm64' ? 'mac-arm64' : 'mac'}/PaperRep.app/Contents/MacOS/PaperRep`);
  const env = { ...process.env };
  delete env.ELECTRON_RUN_AS_NODE;
  const app = await electron.launch({ executablePath: path.resolve(executable), args: [], env });
  try {
    const page = await app.firstWindow();
    await page.waitForSelector('#busy-overlay', { state: 'hidden' });
    const result = await app.evaluate(({ app }) => ({ packaged: app.isPackaged, version: app.getVersion() }));
    if (!result.packaged || result.version !== '1.0.0') throw new Error('Unexpected packaged build');
    if (await page.title() !== 'PaperRep') throw new Error('Window did not load');
    await page.screenshot({ path: 'test-results/packaged.png' });
    console.log('Packaged app launched successfully:', result);
  } finally { await app.close(); }
})();
