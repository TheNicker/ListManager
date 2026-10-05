const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const readSharedScript = (name) => fs.readFileSync(path.join(root, 'shared', name), 'utf8');

function loadDataIntegrity(fetch, options = {}) {
  const window = {
    document: {
      hidden: false,
      addEventListener() {}
    },
    setInterval() {
      return 1;
    }
  };
  vm.runInNewContext(readSharedScript('DataIntegrity.js'), { window, fetch });
  return window.DataIntegrity.create(options);
}

test('data integrity detects a changed server version', async () => {
  let conflictCount = 0;
  const integrity = loadDataIntegrity(async () => ({
    ok: true,
    headers: { get: () => '"version-2"' }
  }), { onConflict: () => conflictCount++ });
  integrity.setLoaded({ headers: { get: () => '"version-1"' } });

  await integrity.check();
  await integrity.check();

  assert.equal(integrity.hasConflict, true);
  assert.equal(conflictCount, 1);
});

test('a stale save triggers the conflict callback once', async () => {
  let conflictCount = 0;
  const integrity = loadDataIntegrity(async () => {}, { onConflict: () => conflictCount++ });
  integrity.setLoaded({ headers: { get: () => '"version-1"' } });

  await integrity.save(async () => ({ ok: false, status: 409 }));
  await integrity.save(async () => ({ ok: false, status: 428 }));

  assert.equal(integrity.hasConflict, true);
  assert.equal(conflictCount, 1);
});

test('a detected change reloads without sending a client-exit beacon', async () => {
  const listeners = {};
  const beacons = [];
  let reloadCount = 0;
  const window = {
    document: {
      hidden: false,
      addEventListener() {}
    },
    navigator: {
      sendBeacon(...args) {
        beacons.push(args);
      }
    },
    addEventListener(name, handler) {
      listeners[name] = handler;
    },
    location: {
      reload() {
        reloadCount++;
        listeners.pagehide();
      }
    },
    setInterval() {
      return 1;
    }
  };
  vm.runInNewContext(readSharedScript('AppLifecycle.js'), { window });
  vm.runInNewContext(readSharedScript('DataIntegrity.js'), {
    window,
    fetch: async () => ({
      ok: true,
      headers: { get: () => '"version-2"' }
    })
  });
  window.AppLifecycle.configure({ allowClientExit: true });
  const integrity = window.DataIntegrity.create({
    onConflict: () => window.AppLifecycle.reloadPage()
  });
  integrity.setLoaded({ headers: { get: () => '"version-1"' } });

  await integrity.check();

  assert.equal(reloadCount, 1);
  assert.deepEqual(beacons, []);
});

test('a stale in-flight poll cannot conflict with a successful local save', async () => {
  let resolveHead;
  let fetchCount = 0;
  const integrity = loadDataIntegrity(() => {
    fetchCount++;
    return new Promise(resolve => {
      resolveHead = resolve;
    });
  });
  integrity.setLoaded({ headers: { get: () => '"version-1"' } });

  const firstCheck = integrity.check();
  const overlappingCheck = integrity.check();
  assert.equal(fetchCount, 1);

  await integrity.save(async () => ({
    ok: true,
    status: 200,
    headers: { get: () => '"version-2"' }
  }));
  resolveHead({
    ok: true,
    headers: { get: () => '"version-1"' }
  });
  await Promise.all([firstCheck, overlappingCheck]);

  assert.equal(integrity.hasConflict, false);
});

test('intentional reload skips shutdown while ordinary page exit sends it', () => {
  function createLifecycle() {
    const listeners = {};
    const beacons = [];
    const window = {
      navigator: {
        sendBeacon(...args) {
          beacons.push(args);
        }
      },
      addEventListener(name, handler) {
        listeners[name] = handler;
      },
      location: {
        reload() {
          listeners.pagehide();
        }
      }
    };
    vm.runInNewContext(readSharedScript('AppLifecycle.js'), { window });
    window.AppLifecycle.configure({ allowClientExit: true });
    return { window, listeners, beacons };
  }

  const reload = createLifecycle();
  reload.window.AppLifecycle.reloadPage();
  assert.equal(reload.beacons.length, 0);

  const close = createLifecycle();
  close.listeners.pagehide();
  assert.deepEqual(close.beacons, [['client-exit', '']]);
});

test('HTML escaping covers all attribute and text metacharacters', () => {
  const window = {};
  vm.runInNewContext(readSharedScript('Html.js'), { window });

  assert.equal(window.escapeHtml(`<script a="b">&'`), '&lt;script a=&quot;b&quot;&gt;&amp;&#39;');
});
