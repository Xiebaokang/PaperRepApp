const { contextBridge, ipcRenderer, webUtils } = require('electron');
contextBridge.exposeInMainWorld('paperrep', {
  invoke: (method, data) => ipcRenderer.invoke('library', method, data),
  filePath: file => webUtils.getPathForFile(file),
  onState: callback => {
    const listener = (_, state) => callback(state);
    ipcRenderer.on('library-state', listener);
    return () => ipcRenderer.removeListener('library-state', listener);
  },
  platform: process.platform
});
