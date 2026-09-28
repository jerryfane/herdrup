// Renders a guest invite from the URL fragment, which never reaches the server.
// The payload is b64url(JSON) as defined in the guest access contract. Every field is
// written with textContent, and only a b64url fragment is ever placed in the app link.
"use strict";

(function () {
  var APP_LINK = "herdrup://guest-invite#";
  var B64URL = /^[A-Za-z0-9_-]+$/;
  var $ = function (id) { return document.getElementById(id); };

  function decode(fragment) {
    var base64 = fragment.replace(/-/g, "+").replace(/_/g, "/");
    var binary = atob(base64 + "===".slice((base64.length + 3) % 4));
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  }

  function isText(value) {
    return typeof value === "string" && value.length > 0 && value.length <= 200;
  }

  function validInvite(invite) {
    return invite !== null && typeof invite === "object" && invite.v === 1 &&
      isText(invite.machine_label) && isText(invite.owner_name) && isText(invite.agent_name) &&
      isText(invite.guest_name) && typeof invite.expires_unix === "number";
  }

  function problem(text) {
    var el = $("problem");
    el.textContent = text;
    el.hidden = false;
  }

  function expiryText(expiresUnix) {
    var seconds = expiresUnix - Date.now() / 1000;
    if (seconds <= 0) return null;
    var hours = Math.floor(seconds / 3600);
    if (hours >= 1) return "Works once · expires in " + hours + " h";
    return "Works once · expires in " + Math.max(1, Math.floor(seconds / 60)) + " min";
  }

  // Following another invite link while this page is open changes only the hash.
  window.addEventListener("hashchange", function () { location.reload(); });

  var fragment = location.hash.replace(/^#/, "");
  if (fragment === "") {
    problem("This page opens HerdrUp invites. The link you followed has no invite in it. Ask for the link again.");
    return;
  }
  if (!B64URL.test(fragment)) {
    problem("This invite link is damaged. Ask for the link again, or paste the whole link into HerdrUp.");
    return;
  }

  var open = $("open");
  open.href = APP_LINK + fragment;
  open.hidden = false;

  var invite;
  try {
    invite = decode(fragment);
  } catch (e) {
    invite = null;
  }
  if (!validInvite(invite)) {
    problem("This invite link looks incomplete. Try opening it in HerdrUp, or ask for the link again.");
    return;
  }

  document.title = invite.owner_name + " shared " + invite.agent_name + " with you · HerdrUp";
  $("avatar").textContent = Array.from(invite.agent_name)[0].toUpperCase();
  $("title").textContent = invite.owner_name + " shared " + invite.agent_name + " with you";
  $("lead").textContent = "You'll be able to watch it work and send it messages and files from this phone.";
  $("machine").textContent = invite.machine_label;
  $("agent").textContent = invite.agent_name;
  $("guest").textContent = invite.guest_name;
  $("note-agent").textContent = invite.agent_name;
  $("note-prefix").textContent = invite.guest_name + " (via HerdrUp):";
  $("note-owner").textContent = invite.owner_name;

  var expiry = $("expiry");
  var remaining = expiryText(invite.expires_unix);
  if (remaining === null) {
    expiry.textContent = "This invite has expired. Ask " + invite.owner_name + " for a new one.";
    expiry.classList.add("expired");
  } else {
    expiry.textContent = remaining;
  }
  $("details").hidden = false;
})();
