/* Fernlet link probe — fernlet.com/probe/
   Temporary, like the page. Measures the part of this page's address after the # and says
   whether the test payload inside it arrived whole. The answer is written into the page as
   text. No cookies, no storage, no network requests.

   A test link is /probe/#v1.<base64url payload>, and the payload checks itself:
     payload = "FLP1" | UInt32BE(payload byte count) | SHA-256(body) | body
   The probe app and the link generator apply the same rules. */
(function () {
  "use strict";

  var PREFIX = "v1.";
  var HEADER_BYTES = 40;
  var MAGIC = [0x46, 0x4c, 0x50, 0x31]; /* "FLP1" */

  var out = document.getElementById("probe-result");
  if (!out || !window.crypto || !window.crypto.subtle || !window.TextEncoder) return;

  function hex(buffer) {
    var bytes = new Uint8Array(buffer), text = "";
    for (var i = 0; i < bytes.length; i++) text += (bytes[i] < 16 ? "0" : "") + bytes[i].toString(16);
    return text;
  }

  function sha256(bytes) {
    return window.crypto.subtle.digest("SHA-256", bytes);
  }

  /* Unpadded base64url to bytes. The caller has already checked the alphabet and the length. */
  function decode(text) {
    var standard = text.replace(/-/g, "+").replace(/_/g, "/");
    while (standard.length % 4) standard += "=";
    var binary = window.atob(standard), bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  /* Resolves to the sentence that describes the payload. */
  function verdict(fragment) {
    if (fragment.indexOf(PREFIX) !== 0) return Promise.resolve("It is not a test link: no v1. prefix.");
    var text = fragment.slice(PREFIX.length);
    var bad = text.search(/[^A-Za-z0-9_-]/);
    if (bad !== -1) return Promise.resolve("The test payload is damaged: not base64url at character " + bad + ".");
    if (text.length % 4 === 1) return Promise.resolve("The test payload is damaged: base64url length is impossible.");
    var payload = decode(text);
    var hasMagic = payload.length >= HEADER_BYTES && MAGIC.every(function (byte, i) { return payload[i] === byte; });
    if (!hasMagic) return Promise.resolve("It is not a test link: no FLP1 header.");
    var declared = ((payload[4] << 24) | (payload[5] << 16) | (payload[6] << 8) | payload[7]) >>> 0;
    if (declared !== payload.length) {
      return Promise.resolve("The test payload is damaged: length: link says " + declared + " bytes, "
        + payload.length + " arrived.");
    }
    return sha256(payload.subarray(HEADER_BYTES)).then(function (digest) {
      var same = hex(digest) === hex(payload.subarray(8, HEADER_BYTES));
      return same
        ? "The test payload arrived whole (" + payload.length + " bytes)."
        : "The test payload is damaged: digest mismatch.";
    });
  }

  function measure() {
    var address = window.location.href, hash = address.indexOf("#");
    var fragment = hash === -1 ? "" : address.slice(hash + 1);
    if (!fragment) {
      out.textContent = "This address has nothing after the #, so there is nothing to measure.";
      return;
    }
    Promise.all([sha256(new TextEncoder().encode(fragment)), verdict(fragment)]).then(function (results) {
      out.textContent = "Arrived: " + fragment.length + " characters after the #. SHA-256 starts "
        + hex(results[0]).slice(0, 16) + ". " + results[1];
    });
  }

  window.addEventListener("hashchange", measure);
  measure();
})();
