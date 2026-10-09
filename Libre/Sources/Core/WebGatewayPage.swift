// WebGatewayPage.swift
// The one page the browser gateway serves. Everything is inline: no fonts, scripts, styles or
// images from anywhere else (the Mac may have no internet). User text is only ever set with
// textContent, never as HTML. Sizes are in rem so the phone's text size setting applies.

public enum GatewayPage {
    public static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Libre room</title>
<style>
:root { color-scheme: light dark; --bg:#f6f6f4; --fg:#1b1b1b; --muted:#555; --card:#fff; --accent:#0b5cad; --pasa:#e9f1fb; --mine:#dff3e4; --line:#d0d0d0; --btnfg:#fff; }
@media (prefers-color-scheme: dark) { :root { --bg:#111; --fg:#f2f2f2; --muted:#bbb; --card:#1d1d1d; --accent:#7fb6ff; --pasa:#13263d; --mine:#163321; --line:#444; --btnfg:#0b1a2e; } }
* { box-sizing: border-box; }
html { font-size: 100%; -webkit-text-size-adjust: 100%; }
body { margin:0; font-family: -apple-system, system-ui, "Segoe UI", Roboto, sans-serif; font-size:1.05rem; line-height:1.45; background:var(--bg); color:var(--fg); }
main { max-width: 44rem; margin: 0 auto; padding: 1rem; }
h1 { font-size:1.6rem; margin:.2rem 0 .6rem; }
h2 { font-size:1.2rem; margin:1rem 0 .4rem; }
label { display:block; font-weight:600; margin-top:.8rem; }
input, textarea, button { font: inherit; }
input, textarea { width:100%; padding:.7rem; border:1px solid var(--line); border-radius:.6rem; background:var(--card); color:var(--fg); }
button { min-height:2.9rem; padding:.6rem 1rem; border-radius:.6rem; border:0; background:var(--accent); color:var(--btnfg); font-weight:600; cursor:pointer; }
button.plain { background:transparent; color:var(--accent); border:1px solid var(--accent); }
a.button { display:inline-block; text-decoration:none; min-height:2.9rem; padding:.7rem 1rem; border-radius:.6rem; border:1px solid var(--accent); color:var(--accent); font-weight:600; }
.note { color:var(--muted); font-size:.95rem; }
.warn { border-left:.3rem solid #b26b00; padding:.4rem .7rem; background:var(--card); margin:.8rem 0; }
.error { color:#b00020; font-weight:600; }
@media (prefers-color-scheme: dark) { .error { color:#ff8a8a; } }
.row { display:flex; gap:.6rem; flex-wrap:wrap; align-items:center; margin-top:1rem; }
#log { list-style:none; padding:0; margin:0; }
#log li { background:var(--card); border:1px solid var(--line); border-radius:.7rem; padding:.6rem .8rem; margin:.5rem 0; overflow-wrap:anywhere; }
#log li.mine { background:var(--mine); }
#log li.pasa { background:var(--pasa); }
.who { font-weight:700; font-size:.95rem; }
.time { color:var(--muted); font-size:.85rem; margin-left:.4rem; }
.chips { display:flex; flex-wrap:wrap; gap:.4rem; margin-top:.4rem; }
.chip { font-size:.9rem; padding:.25rem .6rem; border-radius:1rem; border:1px solid var(--line); background:var(--bg); color:var(--fg); min-height:auto; font-weight:500; }
.excerpt { white-space:pre-wrap; font-size:.95rem; border-left:.25rem solid var(--accent); padding:.3rem .6rem; margin-top:.4rem; }
#composer { position:sticky; bottom:0; background:var(--bg); padding:.6rem 0; display:flex; gap:.5rem; align-items:flex-end; }
#composer textarea { min-height:2.9rem; max-height:9rem; }
.tasks li { margin:.3rem 0; }
.status { font-weight:700; }
.hidden { display:none !important; }
</style>
</head>
<body>
<main>
<section id="joinView" aria-labelledby="joinTitle">
  <h1 id="joinTitle">Join a Libre room</h1>
  <p class="note">Your phone must be on the same Wi-Fi as the Mac running Libre. No internet needed.</p>
  <form id="joinForm" autocomplete="off">
    <label for="room">Room name</label>
    <input id="room" name="room" required autocapitalize="characters">
    <div id="codeBox">
      <label for="code">Room code</label>
      <input id="code" name="code" autocapitalize="characters" spellcheck="false" placeholder="ABCD-EFGH">
      <p class="note">The code is on the Mac's join screen. Town Square needs no code.</p>
    </div>
    <label for="name">Your name</label>
    <input id="name" name="name" required maxlength="24" autocomplete="nickname">
    <p id="joinError" class="error" role="alert"></p>
    <div class="row">
      <button type="submit" id="joinButton">Join room</button>
      <a class="button" id="appLink" href="libre://join">Open in Libre app</a>
    </div>
    <p class="note">Have the Libre app on your iPhone? Tap Open in Libre app and type the code there.</p>
  </form>
  <div class="warn"><strong>Plain web page.</strong> This page is not encrypted. People on the same Wi-Fi could read what you send here. The Libre app on iPhone is encrypted.</div>
</section>

<section id="chatView" class="hidden" aria-labelledby="roomTitle">
  <h1 id="roomTitle">Room</h1>
  <p class="note"><span id="whoami"></span>. <span id="aiState"></span></p>
  <p class="note">Type <strong>@libre</strong> and a question to ask the AI on the Mac.</p>
  <ul id="log" aria-live="polite" aria-label="Messages"></ul>
  <p id="sendError" class="error" role="alert"></p>
  <form id="composer">
    <label for="text" class="hidden">Message</label>
    <textarea id="text" rows="1" placeholder="Message, or @libre question" aria-label="Message"></textarea>
    <button type="submit">Send</button>
  </form>
  <h2>Tasks</h2>
  <p class="note">Read only here. Owners mark tasks done in the Libre app.</p>
  <ul id="tasks" class="tasks"></ul>
  <div class="row"><button class="plain" id="leave" type="button">Leave room</button></div>
  <div class="warn">Plain web page on your local Wi-Fi. Not encrypted.</div>
</section>
</main>
<script>
(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var token = sessionStorage.getItem("pasaToken");
  var since = 0, timer = null, seen = {};
  var params = new URLSearchParams(location.search);
  var roomParam = params.get("room") || "";
  $("room").value = roomParam;
  function appHref(room) { return "libre://join?room=" + encodeURIComponent(room) + "&v=1"; }
  function syncRoom() {
    var r = $("room").value.trim();
    $("appLink").href = appHref(r);
    $("codeBox").classList.toggle("hidden", r.toLowerCase() === "town square");
  }
  $("room").addEventListener("input", syncRoom); syncRoom();
  if (roomParam) { $("name").focus(); }

  function api(method, path, body) {
    var headers = { "Content-Type": "application/json" };
    if (token) headers["Authorization"] = "Bearer " + token;
    return fetch(path, { method: method, headers: headers, body: body ? JSON.stringify(body) : undefined, cache: "no-store" })
      .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { return { status: r.status, body: j }; }); });
  }
  function showChat(room, me) {
    $("joinView").classList.add("hidden"); $("chatView").classList.remove("hidden");
    $("roomTitle").textContent = room; $("whoami").textContent = "You are " + me;
    document.title = room + " on Libre";
    poll();
  }
  function showJoin(msg) {
    token = null; sessionStorage.removeItem("pasaToken"); if (timer) clearTimeout(timer);
    $("chatView").classList.add("hidden"); $("joinView").classList.remove("hidden");
    $("joinError").textContent = msg || "";
  }
  $("joinForm").addEventListener("submit", function (e) {
    e.preventDefault();
    $("joinError").textContent = ""; $("joinButton").disabled = true; $("joinButton").textContent = "Checking...";
    api("POST", "/api/join", { room: $("room").value.trim(), code: $("code").value.trim(), name: $("name").value.trim() })
      .then(function (r) {
        if (r.status === 200) {
          token = r.body.token; sessionStorage.setItem("pasaToken", token);
          sessionStorage.setItem("pasaRoom", r.body.room); sessionStorage.setItem("pasaMe", r.body.name);
          $("code").value = ""; showChat(r.body.room, r.body.name);
        } else { $("joinError").textContent = r.body.error || "Could not join."; }
      })
      .catch(function () { $("joinError").textContent = "Cannot reach the Mac. Check you are on the same Wi-Fi."; })
      .then(function () { $("joinButton").disabled = false; $("joinButton").textContent = "Join room"; });
  });
  function fmtTime(ms) { try { return new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }); } catch (e) { return ""; } }
  function addMessage(m) {
    if (seen[m.id]) return; seen[m.id] = true;
    var li = document.createElement("li");
    if (m.mine) li.className = "mine"; if (m.pasa) li.className = "pasa";
    var who = document.createElement("span"); who.className = "who"; who.textContent = m.mine ? "You" : m.from;
    var t = document.createElement("span"); t.className = "time"; t.textContent = fmtTime(m.at);
    var p = document.createElement("div"); p.textContent = m.text;
    li.appendChild(who); li.appendChild(t); li.appendChild(p);
    var chips = document.createElement("div"); chips.className = "chips"; var excerpts = [];
    (m.rules || []).forEach(function (r) { var c = document.createElement("span"); c.className = "chip"; c.textContent = "Rule: " + r; chips.appendChild(c); });
    (m.docs || []).forEach(function (d) {
      var b = document.createElement("button"); b.type = "button"; b.className = "chip";
      b.textContent = d.title + (d.page ? ", p. " + d.page : "") + (d.version > 1 ? ", v" + d.version : "");
      b.setAttribute("aria-expanded", "false");
      var ex = document.createElement("div"); ex.className = "excerpt hidden"; ex.textContent = d.excerpt;
      b.addEventListener("click", function () { var open = ex.classList.toggle("hidden") === false; b.setAttribute("aria-expanded", open ? "true" : "false"); });
      chips.appendChild(b); excerpts.push(ex);
    });
    if (chips.childNodes.length) li.appendChild(chips);
    excerpts.forEach(function (ex) { li.appendChild(ex); });
    var nearBottom = (window.innerHeight + window.scrollY) >= document.body.scrollHeight - 80;
    $("log").appendChild(li);
    if (nearBottom) window.scrollTo(0, document.body.scrollHeight);
  }
  function renderTasks(tasks) {
    var ul = $("tasks"); ul.textContent = "";
    if (!tasks.length) { var e = document.createElement("li"); e.textContent = "No tasks."; ul.appendChild(e); return; }
    tasks.forEach(function (t) {
      var li = document.createElement("li");
      var s = document.createElement("span"); s.className = "status"; s.textContent = t.status + ": ";
      li.appendChild(s); li.appendChild(document.createTextNode(t.title + ". Owner " + t.owner + (t.due ? ". Due " + t.due : "")));
      ul.appendChild(li);
    });
  }
  function poll() {
    if (!token) return;
    api("GET", "/api/state?since=" + since).then(function (r) {
      if (r.status === 401) { showJoin(r.body.error || "Please join again."); return; }
      if (r.status === 200) {
        (r.body.messages || []).forEach(addMessage);
        since = Math.max(since, r.body.seq || 0);
        renderTasks(r.body.tasks || []);
        $("aiState").textContent = r.body.ai || "";
      }
      timer = setTimeout(poll, 1500);
    }).catch(function () { $("aiState").textContent = "Cannot reach the Mac right now."; timer = setTimeout(poll, 4000); });
  }
  $("composer").addEventListener("submit", function (e) {
    e.preventDefault();
    var text = $("text").value.trim(); if (!text) return;
    $("sendError").textContent = "";
    api("POST", "/api/send", { text: text }).then(function (r) {
      if (r.status === 200) { $("text").value = ""; clearTimeout(timer); poll(); }
      else if (r.status === 401) { showJoin(r.body.error); }
      else { $("sendError").textContent = r.body.error || "Could not send."; }
    }).catch(function () { $("sendError").textContent = "Cannot reach the Mac. Your message was not sent."; });
  });
  $("text").addEventListener("keydown", function (e) { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); $("composer").requestSubmit(); } });
  $("leave").addEventListener("click", function () { api("POST", "/api/leave").then(function () { showJoin("You left the room."); }, function () { showJoin(""); }); });
  if (token) { showChat(sessionStorage.getItem("pasaRoom") || "Room", sessionStorage.getItem("pasaMe") || ""); }
})();
</script>
</body>
</html>
"""#
}
