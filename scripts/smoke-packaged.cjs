const { _electron: electron } = require('@playwright/test');
const path = require('node:path');
(async () => {
  const app = await electron.launch({ executablePath: path.resolve('release/mac-arm64/PaperRep.app/Contents/MacOS/PaperRep'), args: [], env: { ...process.env, ELECTRON_RUN_AS_NODE: '' } });
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
