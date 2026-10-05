(function (global) {
  let intentionalReload = false;

  function configure(options = {}) {
    if (!options.allowClientExit || !global.navigator.sendBeacon) return;

    global.addEventListener('pagehide', () => {
      if (!intentionalReload) {
        global.navigator.sendBeacon('client-exit', '');
      }
    });
  }

  function reloadPage() {
    intentionalReload = true;
    global.location.reload();
  }

  global.AppLifecycle = { configure, reloadPage };
})(window);
