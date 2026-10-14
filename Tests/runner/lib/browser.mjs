/**
 * Shared Playwright launch for the browser harnesses.
 *
 * Lane selection is by environment, so scripts/check.sh keeps calling the
 * runners with no arguments and gets the chromium lane:
 *
 *   CHALK_BROWSER   chromium (default) | webkit
 *
 * The webkit lane exists because the Mac app runs the engine in a WKWebView:
 * a webkit failure is closer to production truth than a chromium pass.
 */
import { chromium, webkit } from 'playwright';

export async function launchBrowser() {
  const name = process.env.CHALK_BROWSER ?? 'chromium';
  if (name !== 'chromium' && name !== 'webkit') {
    throw new Error(`CHALK_BROWSER must be "chromium" or "webkit", got ${JSON.stringify(name)}`);
  }
  if (name === 'chromium') {
    return { browser: await chromium.launch(), contextOptions: {}, tag: 'chromium' };
  }
  return { browser: await webkit.launch(), contextOptions: {}, tag: 'webkit' };
}
