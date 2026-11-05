const path = require('node:path');

function createTray({ app, Menu, Tray, nativeImage }, { library, showWindow, hideWindow, platform = process.platform }) {
  let quitting = false, quitRequested = false;
  const icon = nativeImage.createFromPath(path.join(__dirname, 'assets',
    platform === 'darwin' ? 'trayTemplate.png' : 'tray.png'));
  if (icon.isEmpty()) throw new Error('无法加载托盘图标。');
  if (platform === 'darwin') icon.setTemplateImage(true);
  const tray = new Tray(platform === 'darwin' ? icon : icon.resize({ width: 16, height: 16 }));
  tray.setToolTip('PaperRep');
  const finishQuit = () => {
    if (quitting || !quitRequested || library.state.busy) return;
    quitting = true;
    app.quit();
  };
  const requestQuit = () => {
    quitRequested = true;
    updateMenu();
    finishQuit();
  };
  const updateMenu = () => {
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: '打开 PaperRep', click: showWindow },
      { type: 'separator' },
      { label: quitRequested && library.state.busy ? '完成当前操作后退出' : '退出 PaperRep',
        enabled: !quitRequested, click: requestQuit }
    ]));
  };
  updateMenu();
  // macOS opens the context menu on click; Windows restores on left click.
  if (platform !== 'darwin') tray.on('click', showWindow);
  tray.on('double-click', showWindow);
  app.on('activate', showWindow);
  app.on('second-instance', showWindow);
  app.on('before-quit', event => {
    if (!quitting || library.state.busy) {
      event.preventDefault();
      quitting = false;
      hideWindow();
    }
  });
  // Keep the tray available even if a window is destroyed unexpectedly.
  app.on('window-all-closed', () => {});
  app.on('will-quit', () => tray.destroy());
  library.on('state', () => {
    if (quitRequested) {
      updateMenu();
      finishQuit();
    }
  });
  return {
    handleClose(event) {
      if (!quitting) {
        event.preventDefault();
        hideWindow();
      }
    }
  };
}

module.exports = { createTray };
