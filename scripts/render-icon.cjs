const { chromium } = require('@playwright/test');
const fs = require('node:fs/promises');
(async () => {
  const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1024, height: 1024 }, deviceScaleFactor: 1 });
    const svg = await fs.readFile('build/icon.svg', 'utf8');
    await page.setContent(`<style>html,body{margin:0;background:transparent}</style>${svg}`);
    await page.screenshot({ path: 'build/icon.png', omitBackground: true });
  } finally { await browser.close(); }
})();
