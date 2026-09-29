// The DOM-free part of the invite landing page, imported by i.js and by the tests.

// The Worker serves the page at /i/<payload> only when <payload> is b64url.
var INVITE_PATH = /^\/i\/([^/]+)$/;

/**
 * The invite payload of the page's URL: the path of /i/<payload>, else the fragment of the
 * older /i#<payload> links. Returns "" when the URL carries neither.
 * @param {string} pathname location.pathname
 * @param {string} hash location.hash
 * @returns {string}
 */
export function invitePayload(pathname, hash) {
  var match = INVITE_PATH.exec(pathname);
  return match !== null ? match[1] : hash.replace(/^#/, "");
}
