// A failed upload is not permission to close Chrome while it is transferring.
// Let the user inspect/recover the existing draft, then close this window.
export function waitForBrowserClose(context) {
  return new Promise(resolve => {
    let interval;
    const done = () => { clearInterval(interval); resolve(); };
    context.once('close', done);
    context.browser()?.once('disconnected', done);
    interval = setInterval(() => {
      try { if (!context.pages().length) done(); } catch { done(); }
    }, 1000);
  });
}
