(function (global) {
  function createDataIntegrity(options = {}) {
    let version = null;
    let loadedFromGzip = false;
    let conflict = false;
    let checkError = false;
    let saving = false;
    let checking = false;
    let saveQueue = Promise.resolve();
    let timer = null;

    function notify() {
      if (typeof options.onChange === 'function') {
        options.onChange({
          conflict,
          checkError,
          saving
        });
      }
    }

    function markConflict() {
      if (conflict) return;
      conflict = true;
      notify();
      if (typeof options.onConflict === 'function') options.onConflict();
    }

    function setLoaded(response, wasLoadedFromGzip = false) {
      version = response.headers.get('ETag');
      loadedFromGzip = wasLoadedFromGzip || response.headers.get('X-List-Loaded-From-Gzip') === 'true';
    }

    async function check() {
      if (conflict || saving || checking || !version) return;
      checking = true;
      const checkedVersion = version;
      try {
        const response = await fetch(options.dataUrl || 'data.json', {
          method: 'HEAD',
          cache: 'no-store'
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const currentVersion = response.headers.get('ETag');
        if (!currentVersion) throw new Error('The server did not return a data version.');
        if (saving || version !== checkedVersion) return;
        checkError = false;
        if (currentVersion !== version) {
          markConflict();
        } else {
          notify();
        }
      } catch (error) {
        if (!saving && version === checkedVersion) {
          checkError = true;
          notify();
        }
      } finally {
        checking = false;
      }
    }

    function start() {
      if (timer !== null) return;
      timer = global.setInterval(check, options.interval || 5000);
      global.document.addEventListener('visibilitychange', () => {
        if (!global.document.hidden) check();
      });
    }

    function save(sendRequest) {
      const savePromise = saveQueue.then(async () => {
        if (conflict) return null;
        saving = true;
        notify();
        try {
          const response = await sendRequest({
            version,
            loadedFromGzip,
            headers: {
              'If-Match': version || '',
              'X-List-Loaded-From-Gzip': String(loadedFromGzip)
            }
          });
          if (response.status === 409 || response.status === 428) {
            markConflict();
          } else if (response.ok) {
            version = response.headers.get('ETag');
            checkError = false;
            notify();
          }
          return response;
        } finally {
          saving = false;
          notify();
        }
      });
      saveQueue = savePromise.catch(() => null);
      return savePromise;
    }

    return {
      setLoaded,
      start,
      check,
      save,
      get hasConflict() {
        return conflict;
      },
      get hasCheckError() {
        return checkError;
      }
    };
  }

  global.DataIntegrity = { create: createDataIntegrity };
})(window);
