(function (global) {
  // Downloads a timestamped gzip copy of the served data file. The name follows the file the server
  // actually reads, because the page only ever requests the data.json URL and a -DataFile value can
  // rename the underlying file.
  //
  // fetch decompresses a gzip response transparently, so the bytes handed to the caller are always
  // plain JSON and the copy is compressed here in every case. Writing the response bytes through
  // unchanged would store plain JSON under a .gz name whenever the served file was already
  // compressed, which is the case this has to survive.
  //
  // Where the file lands is chosen by the browser. When the File System Access API is available the
  // user gets a real save dialog and can pick any folder; otherwise the download falls back to the
  // anchor element and the browser decides, which is its configured download folder or a save dialog.
  function timestamp(date) {
    const pad = (value) => String(value).padStart(2, '0');
    // Windows rejects colons in file names, so the time part uses dashes.
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
      `_${pad(date.getHours())}-${pad(date.getMinutes())}-${pad(date.getSeconds())}`;
  }

  function servedFileName(response, dataUrl) {
    const header = response.headers.get('X-Data-File-Name');
    if (header) {
      try {
        return decodeURIComponent(header);
      } catch {
        return header;
      }
    }
    const segment = String(dataUrl).split('?')[0].split('/').filter(Boolean).pop();
    return segment || 'data.json';
  }

  // Backups are always gzip, so the served name only decides what the base looks like: the
  // timestamp goes before the whole extension chain, which keeps "contacts.json" readable as
  // "contacts_<stamp>.json.gz" and an already-compressed "people.gz" as "people_<stamp>.gz".
  function backupFileName(servedName, date) {
    const withoutGzip = String(servedName).replace(/\.gz$/i, '');
    const dot = withoutGzip.lastIndexOf('.');
    const base = dot > 0 ? withoutGzip.slice(0, dot) : withoutGzip;
    const format = dot > 0 ? withoutGzip.slice(dot) : '';
    return `${base}_${timestamp(date)}${format}.gz`;
  }

  async function gzip(bytes) {
    if (typeof global.CompressionStream !== 'function') {
      throw new Error('This browser cannot create gzip files.');
    }
    const compressed = new Blob([bytes]).stream().pipeThrough(new global.CompressionStream('gzip'));
    return new Uint8Array(await new Response(compressed).arrayBuffer());
  }

  function createDataBackup(options = {}) {
    const dataUrl = options.dataUrl || 'data.json';

    async function writeWithPicker(fileName, payload) {
      const handle = await global.showSaveFilePicker({
        suggestedName: fileName,
        types: [{ description: 'Gzip archive', accept: { 'application/gzip': [`.${fileName.split('.').pop()}`] } }]
      });
      const writable = await handle.createWritable();
      try {
        await writable.write(payload);
      } finally {
        await writable.close();
      }
    }

    function writeWithAnchor(fileName, payload) {
      const url = URL.createObjectURL(new Blob([payload], { type: 'application/gzip' }));
      const link = global.document.createElement('a');
      link.href = url;
      link.download = fileName;
      link.click();
      URL.revokeObjectURL(url);
    }

    async function run() {
      const response = await global.fetch(dataUrl, { cache: 'no-store' });
      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }
      const servedName = servedFileName(response, dataUrl);
      const sourceCompressed = response.headers.get('X-List-Loaded-From-Gzip') === 'true' || /\.gz$/i.test(servedName);
      const payload = await gzip(await response.arrayBuffer());
      const fileName = backupFileName(servedName, new Date());

      if (typeof global.showSaveFilePicker === 'function') {
        try {
          await writeWithPicker(fileName, payload);
        } catch (error) {
          if (error && error.name === 'AbortError') {
            if (typeof options.onCancel === 'function') options.onCancel(fileName);
            return null;
          }
          throw error;
        }
      } else {
        writeWithAnchor(fileName, payload);
      }

      const result = { fileName, byteLength: payload.byteLength, servedName, sourceCompressed };
      if (typeof options.onDone === 'function') options.onDone(result);
      return result;
    }

    return { run, backupFileName, timestamp };
  }

  global.Backup = { create: createDataBackup, backupFileName, timestamp };
})(window);