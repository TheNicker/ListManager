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

// The backup helper needs the platform APIs the browser provides, so the sandbox gets Node's
// equivalents. Writes are captured instead of reaching the filesystem, which keeps the test
// dependency-free while still exercising the real compression path.
function loadBackup(options = {}) {
  const saved = [];
  // In a page, fetch, CompressionStream, Blob, Response, and URL are all properties of window,
  // so the sandbox global is its own window.
  const context = {
    Blob,
    Response,
    CompressionStream,
    fetch: options.fetch,
    document: {
      createElement() {
        return {
          set href(value) {
            this._href = value;
          },
          set download(value) {
            this._download = value;
          },
          click() {
            saved.push({ fileName: this._download, via: 'anchor' });
          }
        };
      }
    },
    URL: {
      createObjectURL: () => 'blob:backup',
      revokeObjectURL() {}
    }
  };
  if (options.picker) context.showSaveFilePicker = options.picker;
  context.window = context;
  context.globalThis = context;
  vm.createContext(context);
  vm.runInContext(readSharedScript('Backup.js'), context);
  return { window: context, backup: context.Backup.create(options.backup), saved };
}

function gzipResponse(body, { name = 'data.json', compressed = false, ok = true, status = 200 } = {}) {
  const headers = {
    'X-List-Loaded-From-Gzip': String(compressed),
    'X-Data-File-Name': encodeURIComponent(name)
  };
  return {
    ok,
    status,
    headers: { get: header => (header in headers ? headers[header] : null) },
    arrayBuffer: async () => body.buffer.slice(body.byteOffset, body.byteOffset + body.byteLength)
  };
}

const jsonBody = new TextEncoder().encode('{"schema":{"fields":[]},"records":[]}');

test('a plain data file is compressed and named after the served file', async () => {
  const written = [];
  const payload = [];
  const { backup } = loadBackup({
    fetch: async () => gzipResponse(jsonBody, { name: 'Passwords.json' }),
    picker: async options => {
      written.push(options.suggestedName);
      return {
        createWritable: async () => ({
          async write(bytes) {
            payload.push(bytes);
          },
          close() {}
        })
      };
    }
  });

  const result = await backup.run();

  assert.equal(written.length, 1);
  assert.match(written[0], /^Passwords_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.json\.gz$/);
  assert.equal(result.sourceCompressed, false);
  assert.equal(result.servedName, 'Passwords.json');
  assert.equal(result.fileName, written[0]);
  assert.equal(result.byteLength, payload[0].byteLength);
  assert.deepEqual([...payload[0].slice(0, 2)], [0x1f, 0x8b], 'written bytes start with the gzip signature');

  const restored = await new Response(
    new Blob([payload[0]]).stream().pipeThrough(new DecompressionStream('gzip'))
  ).text();
  assert.equal(restored, new TextDecoder().decode(jsonBody), 'the backup round-trips to the served bytes');
});

test('a backup name carries no characters Windows rejects in file names', async () => {
  const written = [];
  const { backup } = loadBackup({
    fetch: async () => gzipResponse(jsonBody, { name: 'data.json' }),
    picker: async options => {
      written.push(options.suggestedName);
      return { createWritable: async () => ({ write() {}, close() {} }) };
    }
  });

  await backup.run();

  assert.equal(/[:*?"<>|]/.test(written[0]), false, `unexpected character in ${written[0]}`);
});

test('an already compressed data file still produces valid gzip under a single .gz name', async () => {
  const written = [];
  const payload = [];
  const { backup } = loadBackup({
    fetch: async () => gzipResponse(jsonBody, { name: 'people-sample.gz', compressed: true }),
    picker: async options => {
      written.push(options.suggestedName);
      return {
        createWritable: async () => ({
          async write(bytes) {
            payload.push(bytes);
          },
          close() {}
        })
      };
    }
  });

  const result = await backup.run();

  assert.match(written[0], /^people-sample_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.gz$/);
  assert.equal(result.sourceCompressed, true);
  assert.deepEqual([...payload[0].slice(0, 2)], [0x1f, 0x8b], 'a served .gz source is not stored as plain JSON');

  const restored = await new Response(
    new Blob([payload[0]]).stream().pipeThrough(new DecompressionStream('gzip'))
  ).text();
  assert.equal(restored, new TextDecoder().decode(jsonBody), 'the backup round-trips to the served bytes');
});

test('the served file name is decoded and used instead of the requested URL', async () => {
  const written = [];
  const { backup } = loadBackup({
    fetch: async () => gzipResponse(jsonBody, { name: 'רשימת ספרים.json' }),
    picker: async options => {
      written.push(options.suggestedName);
      return { createWritable: async () => ({ write() {}, close() {} }) };
    }
  });

  const result = await backup.run();

  assert.equal(result.servedName, 'רשימת ספרים.json');
  assert.ok(written[0].startsWith('רשימת ספרים_'), `unexpected name ${written[0]}`);
});

test('the requested URL names the backup when the server sends no file name', async () => {
  const headers = { get: () => null };
  const { backup } = loadBackup({
    fetch: async () => ({ ok: true, status: 200, headers, arrayBuffer: async () => jsonBody.buffer }),
    backup: { dataUrl: 'nested/lists.json' }
  });

  const result = await backup.run();

  assert.equal(result.servedName, 'lists.json');
});

test('browsers without a save dialog download the backup instead', async () => {
  const { backup, saved } = loadBackup({
    fetch: async () => gzipResponse(jsonBody, { name: 'data.json' })
  });

  const result = await backup.run();

  assert.equal(saved.length, 1);
  assert.equal(saved[0].fileName, result.fileName);
  assert.equal(saved[0].via, 'anchor');
});

test('cancelling the save dialog is not reported as a failure', async () => {
  let errors = 0;
  let cancels = 0;
  const { backup } = loadBackup({
    fetch: async () => gzipResponse(jsonBody, { name: 'data.json' }),
    picker: async () => {
      throw Object.assign(new Error('aborted'), { name: 'AbortError' });
    },
    backup: {
      onError: () => errors++,
      onCancel: () => cancels++
    }
  });

  const result = await backup.run();

  assert.equal(result, null);
  assert.equal(cancels, 1);
  assert.equal(errors, 0);
});

test('a failed data request rejects instead of writing an empty backup', async () => {
  const { backup } = loadBackup({
    fetch: async () => gzipResponse(new Uint8Array(), { ok: false, status: 500 })
  });

  await assert.rejects(() => backup.run(), /HTTP 500/);
});

test('a write failure surfaces the reason to the caller', async () => {
  const { backup } = loadBackup({
    fetch: async () => gzipResponse(jsonBody, { name: 'data.json' }),
    picker: async () => ({
      createWritable: async () => ({
        write() {
          throw new Error('disk is full');
        },
        close() {}
      })
    })
  });

  await assert.rejects(() => backup.run(), /disk is full/);
});

