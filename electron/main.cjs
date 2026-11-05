const { app, BrowserWindow, ipcMain, dialog, shell, Menu, Tray, nativeImage } = require('electron');
const path = require('node:path');
const { Library } = require('./library.cjs');
const { createTray } = require('./tray.cjs');
let window, library, desktopTray;
if (!app.isPackaged && process.env.PAPERREP_USER_DATA) app.setPath('userData', process.env.PAPERREP_USER_DATA);
if (!app.requestSingleInstanceLock()) app.quit();
else {
app.whenReady().then(async () => {
  library = new Library(path.join(app.getPath('userData'), 'library.json'), p => shell.trashItem(p));
  let initError;
  try { await library.init(); } catch (e) { initError = e.message; library.state.error = initError; }
  const createWindow = () => {
    window = new BrowserWindow({ width: 960, height: 720, minWidth: 960, minHeight: 720, backgroundColor: '#f7f8fa',
      title: 'PaperRep', titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
      trafficLightPosition: { x: 20, y: 20 }, webPreferences: { preload: path.join(__dirname, 'preload.cjs'), contextIsolation: true, nodeIntegration: false, sandbox: true } });
    window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    window.webContents.on('will-navigate', e => e.preventDefault());
    window.loadFile(path.join(__dirname, '../ui/index.html'));
    window.on('close', e => desktopTray.handleClose(e));
    window.on('closed', () => { window = null; });
  };
  const showWindow = () => {
    if (!window || window.isDestroyed()) createWindow();
    if (window.isMinimized()) window.restore();
    window.show();
    window.focus();
  };
  desktopTray = createTray({ app, Menu, Tray, nativeImage }, {
    library, showWindow, hideWindow: () => { if (window && !window.isDestroyed()) window.hide(); }
  });
  library.on('state', state => { if (window && !window.isDestroyed()) window.webContents.send('library-state', state); });
  const allowed = new Set(['state', 'chooseRoot', 'configure', 'pickFiles', 'import', 'createFolder', 'delete', 'sync', 'open', 'reveal']);
  ipcMain.handle('library', async (event, method, data) => {
    if (!window || event.sender !== window.webContents || !allowed.has(method)) return { error: '无效操作。' };
    try {
      if (method === 'state') return { data: library.state };
      if (library.state.busy) throw new Error('正在同步，请稍候。');
      let result;
      switch (method) {
        case 'chooseRoot': {
          const chosen = await dialog.showOpenDialog(window, { title: '选择论文存储文件夹', properties: ['openDirectory', 'createDirectory'] });
          result = chosen.canceled ? null : chosen.filePaths[0]; break;
        }
        case 'pickFiles': {
          const chosen = await dialog.showOpenDialog(window, { title: '添加论文', filters: [{ name: 'PDF', extensions: ['pdf'] }], properties: ['openFile', 'multiSelections'] });
          result = chosen.canceled ? [] : chosen.filePaths; break;
        }
        case 'configure': result = await library.configure(data); break;
        case 'import': result = await library.importFiles(data); break;
        case 'createFolder': result = await library.createFolder(data); break;
        case 'delete': {
          if (!Array.isArray(data) || !data.length) throw new Error('请选择文件。');
          const answer = await dialog.showMessageBox(window, { type: 'warning', title: '移至废纸篓', message: `将选中的 ${data.length} 个项目移至废纸篓？`, detail: '文件夹中的论文也会一并移除，并同步至 GitHub。', buttons: ['取消', '移至废纸篓'], defaultId: 0, cancelId: 0 });
          if (answer.response === 1) result = await library.remove(data); else result = { canceled: true }; break;
        }
        case 'sync': result = await library.sync(); break;
        case 'open': {
          if (typeof data !== 'string' || data.split('/').length !== 3) throw new Error('请选择 PDF 文件。');
          const error = await shell.openPath(await library.safePath(data)); if (error) throw new Error(error); break;
        }
        case 'reveal': if (library.config.root) shell.showItemInFolder(library.config.root); break;
      }
      return { data: result };
    } catch (e) { return { error: e.message }; }
  });
  Menu.setApplicationMenu(process.platform === 'darwin' ? Menu.buildFromTemplate([
    ...(process.platform === 'darwin' ? [{ label: 'PaperRep', submenu: [{ role: 'about' }, { type: 'separator' }, { role: 'hide' }, { role: 'hideOthers' }, { type: 'separator' }, { role: 'quit' }] }] : []),
    { label: '编辑', submenu: [{ role: 'undo' }, { role: 'redo' }, { type: 'separator' }, { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }] },
    { label: '视图', submenu: [{ role: 'resetZoom' }, { role: 'zoomIn' }, { role: 'zoomOut' }, { role: 'togglefullscreen' }] },
    { label: '窗口', submenu: [{ role: 'minimize' }, { role: 'close' }] }
  ]) : null);
  createWindow();
  if (library.config.root && !initError) library.sync().catch(() => {});
  // This checks local saves only; idle time never triggers a remote sync.
  setInterval(() => library.poll().catch(e => { library.state.error = e.message; library.publish(); }), 2000).unref();
});
}
