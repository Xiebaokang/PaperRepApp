const { test } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { createTray } = require('../electron/tray.cjs');

function setup(platform) {
  const app = new EventEmitter(), library = new EventEmitter();
  library.state = { busy: false };
  let tray, shown = 0, hidden = 0, quitCount = 0, exited = false, iconPath;
  const icon = { isEmpty: () => false, setTemplateImage(value) { this.template = value; },
    resize(size) { this.size = size; return this; } };
  class FakeTray extends EventEmitter {
    constructor(image) { super(); tray = this; this.image = image; }
    setToolTip(value) { this.tooltip = value; }
    setContextMenu(menu) { this.menu = menu; }
    destroy() { this.destroyed = true; }
  }
  app.quit = () => {
    quitCount++;
    const event = { prevented: false, preventDefault() { this.prevented = true; } };
    app.emit('before-quit', event);
    if (!event.prevented) { app.emit('will-quit'); exited = true; }
  };
  const controller = createTray({ app, Tray: FakeTray, Menu: { buildFromTemplate: items => items },
    nativeImage: { createFromPath(value) { iconPath = value; return icon; } } },
  { library, platform, showWindow: () => shown++, hideWindow: () => hidden++ });
  return { app, library, controller, tray, icon, get iconPath() { return iconPath; },
    get shown() { return shown; }, get hidden() { return hidden; },
    get exited() { return exited; }, get quitCount() { return quitCount; } };
}

for (const platform of ['win32', 'darwin']) {
  test(`${platform}: closing hides the window, restore paths work, and only tray exit quits`, () => {
    const state = setup(platform);
    assert.equal(state.tray.tooltip, 'PaperRep');
    if (platform === 'darwin') {
      assert.match(state.iconPath, /trayTemplate\.png$/);
      assert.equal(state.icon.template, true);
    } else {
      assert.match(state.iconPath, /tray\.png$/);
      assert.deepEqual(state.icon.size, { width: 16, height: 16 });
      state.tray.emit('click');
      assert.equal(state.shown, 1);
    }
    for (const busy of [false, true]) {
      state.library.state.busy = busy;
      let prevented = false;
      state.controller.handleClose({ preventDefault() { prevented = true; } });
      assert.equal(prevented, true);
    }
    assert.equal(state.hidden, 2);
    assert.equal(state.quitCount, 0);
    const initial = state.shown;
    state.tray.menu[0].click();
    state.tray.emit('double-click');
    state.app.emit('activate');
    state.app.emit('second-instance');
    assert.equal(state.shown, initial + 4);
    state.app.emit('window-all-closed');
    assert.equal(state.quitCount, 0);
    // Dock/app-menu quit must not bypass the tray's explicit exit action.
    state.library.state.busy = false;
    state.app.quit();
    assert.equal(state.exited, false);
    assert.equal(state.hidden, 3);
    state.tray.menu[2].click();
    assert.equal(state.exited, true);
    assert.equal(state.tray.destroyed, true);
    let prevented = false;
    state.controller.handleClose({ preventDefault() { prevented = true; } });
    assert.equal(prevented, false);
  });

  test(`${platform}: tray exit waits for active work and exits once after success or failure`, () => {
    for (const error of ['', 'Network unavailable']) {
      const state = setup(platform);
      state.library.state.busy = true;
      state.tray.menu[2].click();
      assert.equal(state.quitCount, 0);
      assert.equal(state.tray.menu[2].label, '完成当前操作后退出');
      assert.equal(state.tray.menu[2].enabled, false);
      state.library.emit('state', state.library.state);
      assert.equal(state.quitCount, 0);
      state.library.state = { busy: false, error };
      state.library.emit('state', state.library.state);
      assert.equal(state.exited, true);
      assert.equal(state.quitCount, 1);
    }
  });
}
