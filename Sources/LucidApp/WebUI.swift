/// Lucid's window: one page, with its styles and script inside it, so that nothing has to be
/// found on disk at run time. It talks only to the app that served it.
enum WebUI {
    static let page = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lucid</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='7' fill='%23151515'/%3E%3Cg fill='%23fff'%3E%3Crect x='5' y='12' width='3' height='8' rx='1.5'/%3E%3Crect x='10' y='8' width='3' height='16' rx='1.5'/%3E%3Crect x='14.5' y='5' width='3' height='22' rx='1.5'/%3E%3Crect x='19' y='8' width='3' height='16' rx='1.5'/%3E%3Crect x='24' y='12' width='3' height='8' rx='1.5'/%3E%3C/g%3E%3C/svg%3E">
<style>
:root {
  color-scheme: light dark;
  --page: #f5f5f5; --side: #e9e9e9; --card: #fbfbfb; --line: #dcdcdc; --text: #1f1f1f; --quiet: #6b6b6b;
  --accent: #2563eb; --accent-text: #ffffff; --selected: #d6d6d6; --good: #1f9d55; --warn: #c2410c; --field: #ffffff;
}
@media (prefers-color-scheme: dark) {
  :root {
    --page: #1e1e1e; --side: #262626; --card: #2a2a2a; --line: #3d3d3d; --text: #f0f0f0; --quiet: #a3a3a3;
    --accent: #5b8def; --accent-text: #0b1220; --selected: #3a3a3a; --good: #4ade80; --warn: #fb923c; --field: #1b1b1b;
  }
}
* { box-sizing: border-box; }
html, body { height: 100%; margin: 0; }
body { background: var(--page); color: var(--text); font: 14px/1.45 system-ui, "Segoe UI", sans-serif; display: flex; }
nav { width: 200px; flex: none; background: var(--side); display: flex; flex-direction: column; padding: 10px; }
nav button { all: unset; display: block; width: 100%; box-sizing: border-box; padding: 7px 10px; border-radius: 7px; cursor: pointer; color: var(--text); }
nav button:hover { background: var(--selected); }
nav button[aria-current="page"] { background: var(--selected); font-weight: 600; }
nav button:focus-visible, button:focus-visible, select:focus-visible, input:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
#status { margin-top: auto; padding: 8px 10px; color: var(--quiet); display: flex; align-items: center; gap: 8px; }
.dot { width: 9px; height: 9px; border-radius: 50%; background: var(--warn); flex: none; }
.dot.ready { background: var(--good); } .dot.starting { background: var(--quiet); }
main { flex: 1; overflow-y: auto; padding: 22px 16px 40px; }
.column { max-width: 660px; margin: 0 auto; }
h2 { font-size: 14px; margin: 22px 10px 7px; }
h2:first-child { margin-top: 0; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 9px; }
.row { display: flex; align-items: center; gap: 10px; padding: 9px 12px; border-top: 1px solid var(--line); min-height: 44px; }
.row:first-child { border-top: 0; }
.grow { flex: 1; min-width: 0; }
.note { color: var(--quiet); font-size: 13px; margin: 7px 10px 0; }
.small { color: var(--quiet); font-size: 12px; }
.warn { color: var(--warn); }
.wrap { overflow-wrap: anywhere; white-space: pre-wrap; }
button.plain, select, input[type="text"] {
  font: inherit; color: var(--text); background: var(--field); border: 1px solid var(--line); border-radius: 6px; padding: 4px 10px;
}
button.plain { cursor: pointer; white-space: nowrap; }
button.plain:hover { border-color: var(--quiet); }
button.plain:disabled { opacity: .5; cursor: default; }
button.link { all: unset; cursor: pointer; color: var(--accent); font-size: 13px; }
button.icon { all: unset; cursor: pointer; padding: 4px 6px; border-radius: 5px; color: var(--quiet); display: inline-grid; place-items: center; }
button.icon svg { width: 15px; height: 15px; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
button.icon:hover { background: var(--selected); color: var(--text); }
input[type="text"] { width: 100%; }
select { max-width: 320px; }
.segments { display: inline-flex; border: 1px solid var(--line); border-radius: 7px; overflow: hidden; }
.segments button { all: unset; padding: 4px 22px; cursor: pointer; border-left: 1px solid var(--line); }
.segments button:first-child { border-left: 0; }
.segments button[aria-pressed="true"] { background: var(--accent); color: var(--accent-text); }
.check { width: 22px; height: 22px; border-radius: 50%; border: 2px solid var(--quiet); flex: none; align-self: flex-start; margin-top: 2px; }
.check.done { border-color: var(--good); background: var(--good); position: relative; }
.check.done::after { content: ""; position: absolute; left: 6px; top: 2px; width: 5px; height: 10px; border: solid var(--card); border-width: 0 2px 2px 0; transform: rotate(45deg); }
.hero { display: flex; gap: 14px; align-items: center; padding: 14px; }
.hero .big { font-size: 18px; font-weight: 600; }
.badge { width: 34px; height: 34px; border-radius: 50%; flex: none; display: grid; place-items: center; color: #fff; font-weight: 700; background: var(--warn); }
.badge.ready { background: var(--good); }
progress { width: 100%; height: 8px; accent-color: var(--accent); }
.buttons { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
label.switch { display: flex; align-items: center; gap: 10px; width: 100%; cursor: pointer; }
label.switch span { flex: 1; }
input[type="checkbox"] { width: 17px; height: 17px; accent-color: var(--accent); }
.empty { color: var(--quiet); text-align: center; padding: 40px 10px; }
#lost { display: none; margin: auto; max-width: 420px; text-align: center; padding: 30px; }
</style>
</head>
<body>
<nav aria-label="Parts of Lucid">
  <div id="tabs"></div>
  <div id="status" role="status"><span class="dot" id="dot"></span><span id="status-text">Starting…</span></div>
</nav>
<main><div class="column" id="page"></div></main>
<div id="lost"><p><strong>This page has lost touch with Lucid.</strong></p><p>Open the window again from Lucid.</p></div>
<script>
"use strict";
const TABS = [["home", "Home"], ["models", "Models"], ["dictionary", "Dictionary"], ["history", "History"], ["settings", "Settings"], ["about", "About"]];
let state = null, shown = "", tab = "home", pending = null, turned = null;
const ui = { drafts: {}, renaming: null, lookup: null, lookingUp: false, adding: null, message: null, busy: {} };

// The key comes after the # in the address, which a browser never sends anywhere.
let key = null;
{
  const found = location.hash.match(/key=([0-9a-f]+)/);
  const wanted = location.hash.match(/^#([a-z]+)/);
  if (wanted && TABS.some(t => t[0] === wanted[1])) tab = wanted[1];
  try {
    if (found) sessionStorage.setItem("lucid-key", found[1]);
    key = found ? found[1] : sessionStorage.getItem("lucid-key");
  } catch (error) { key = found ? found[1] : null; }
  history.replaceState(null, "", "#" + tab);
}

const PENCIL = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M11.2 2.3l2.5 2.5-8 8-3.2.7.7-3.2z"/></svg>';
const BIN = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2.5 4.5h11M6.5 4.5v-2h3v2M4 4.5l.7 9h6.6l.7-9M6.7 7v4M9.3 7v4"/></svg>';
const MINUS = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6"/><path d="M5.2 8h5.6"/></svg>';
const esc = text => String(text ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

async function api(path, body) {
  const options = { headers: { "X-Lucid-Key": key || "" } };
  if (body !== undefined) { options.method = "POST"; options.body = JSON.stringify(body); options.headers["Content-Type"] = "application/json"; }
  const response = await fetch(path, options);
  const data = await response.json().catch(() => ({}));
  if (response.status === 403) { lost(); throw new Error(data.error || "Lost touch with Lucid."); }
  if (!response.ok) throw new Error(data.error || "Lucid could not do that.");
  return data;
}

function lost() {
  document.querySelector("nav").style.display = "none";
  document.querySelector("main").style.display = "none";
  document.getElementById("lost").style.display = "block";
}

// Sends one change, shows what went wrong if anything, then shows the new state.
async function act(path, body, quiet) {
  if (!quiet) ui.message = null;
  try { const done = await api(path, body); await refresh(); return done; }
  catch (error) { ui.message = error.message; draw(true); return null; }
}

async function refresh() {
  if (!key) return lost();
  try {
    state = await api("/api/state");
    // Lucid's menu can ask an open window to turn to one of its parts.
    const turn = state.goTo || {};
    if (turned === null) turned = turn.serial;
    else if (turn.serial !== turned) {
      turned = turn.serial;
      if (TABS.some(t => t[0] === turn.section) && turn.section !== tab) return go(turn.section);
    }
    draw(false);
  } catch (error) { /* Lucid may be restarting. Try again next time. */ }
}

// Drawing the page again must not disturb what is being typed.
function draw(force) {
  if (!state) return;
  const html = pages[tab]();
  if (!force && html === shown) return paintChrome();
  const active = document.activeElement, id = active && active.id, range = id && active.selectionStart != null ? [active.selectionStart, active.selectionEnd] : null;
  const main = document.querySelector("main"), top = main.scrollTop;
  document.getElementById("page").innerHTML = html;
  shown = html;
  main.scrollTop = top;
  if (id) { const again = document.getElementById(id); if (again) { again.focus(); if (range && again.setSelectionRange) try { again.setSelectionRange(range[0], range[1]); } catch (error) {} } }
  paintChrome();
}

function paintChrome() {
  document.getElementById("tabs").innerHTML = TABS.map(([id, title]) =>
    `<button data-tab="${id}" ${id === tab ? 'aria-current="page"' : ""}>${title}</button>`).join("");
  const s = state.status.state;
  document.getElementById("dot").className = "dot " + (s === "setup" ? "" : s);
  document.getElementById("status-text").textContent = s === "ready" ? "Ready" : s === "starting" ? "Starting…" : "Needs setup";
  document.title = "Lucid";
}

function go(next) { tab = next; ui.message = null; history.replaceState(null, "", "#" + tab); document.querySelector("main").scrollTop = 0; draw(true); }

const draft = id => ui.drafts[id] ?? "";
const field = (id, placeholder, enter) => `<input type="text" id="${id}" value="${esc(draft(id))}" placeholder="${esc(placeholder)}" autocomplete="off" spellcheck="false" ${enter ? `data-enter="${enter}"` : ""}>`;
const message = () => ui.message ? `<p class="note warn" role="alert">${esc(ui.message)}</p>` : "";
const options = (list, chosen) => list.map(([value, title]) => `<option value="${esc(value)}" ${value === chosen ? "selected" : ""}>${esc(title)}</option>`).join("");
const when = seconds => new Date(seconds * 1000).toLocaleString([], { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" });

const pages = {
  home() {
    const s = state.status, ready = s.state === "ready", latest = state.history[0];
    const checks = s.checks.map(check => `<div class="row">
        <span class="check ${check.done ? "done" : ""}" role="img" aria-label="${check.done ? "Done" : "Not done"}"></span>
        <div class="grow"><strong>${esc(check.title)}</strong><div class="small wrap">${esc(check.detail)}</div>
        ${check.progress != null ? `<progress value="${check.progress}" max="1"></progress><div class="buttons"><button class="plain" data-action="stop-setup">Stop</button></div>` : ""}
        ${!check.done && check.action ? `<div class="buttons" style="margin-top:6px"><button class="plain" data-action="setup" data-id="${esc(check.id)}">${esc(check.action)}</button></div>` : ""}
        </div></div>`).join("");
    const inUse = state.inUse.map(([label, value, where]) => `<div class="row"><span>${esc(label)}</span><span class="grow"></span>
        <span class="small" style="font-size:13px">${esc(value)}</span><button class="plain" data-tab="${where}">Change…</button></div>`).join("");
    let last = `<div class="row small">Nothing yet.${state.app.canDictate ? ` Hold ${esc(state.settings.hotkeyTitle)} and speak.` : ""}</div>`;
    if (latest) last = latest.text != null
      ? `<div class="row wrap">${esc(latest.text)}</div><div class="row"><button class="link" data-action="copy" data-text="${esc(latest.text)}">Copy</button>
         ${latest.original ? `<button class="link" data-action="copy" data-text="${esc(latest.original)}">Copy Original</button>` : ""}<span class="grow"></span><button class="link" data-tab="history">Show History</button></div>`
      : `<div class="row warn">The latest dictation failed. ${esc(latest.failure)}</div><div class="row"><span class="grow"></span><button class="link" data-tab="history">Show History</button></div>`;
    return `<div class="card hero"><div class="badge ${ready ? "ready" : ""}" aria-hidden="true">${ready ? "✓" : "!"}</div>
      <div><div class="big">${esc(s.headline)}</div><div class="small" style="font-size:13px">${esc(s.hint)}</div></div></div>
      ${message()}
      <h2>Setup</h2><div class="card">${checks}</div>
      <h2>In use</h2><div class="card">${inUse}</div>
      <h2>Latest dictation</h2><div class="card">${last}</div>`;
  },

  models() {
    const m = state.models, name = file => (m.installed.find(x => x.fileName === file) || {}).name || "Not installed";
    const pick = (kind, chosen, list, empty) => `<select data-choose="${kind}" aria-label="${kind}" ${list.length ? "" : "disabled"}>
        ${list.some(x => x.fileName === chosen) ? "" : `<option value="${esc(chosen)}" selected>${empty}</option>`}
        ${options(list.map(x => [x.fileName, x.name]), chosen)}</select>`;
    const speech = m.installed.filter(x => x.kind === "speech"), cleanup = m.installed.filter(x => x.kind === "cleanup");
    const general = cleanup.filter(x => x.style === "general");
    const rows = m.installed.map(x => ui.renaming === x.fileName
      ? `<div class="row"><div class="grow"><div class="buttons" style="flex-wrap:nowrap">${field("rename", x.originalName, "save-name")}
           <button class="plain" data-action="save-name">Save</button><button class="plain" data-action="cancel-name">Cancel</button></div>
           <div class="small" style="margin-top:4px">This changes the name Lucid shows, not the file. Leave it empty to go back to ${esc(x.originalName)}.</div></div></div>`
      : `<div class="row"><div class="grow"><div>${esc(x.name)}</div><div class="small">${esc(x.detail)}</div></div>
           ${x.canChangeStyle ? `<select data-style="${esc(x.fileName)}" aria-label="Prompt for ${esc(x.name)}" title="The input the model expects. S1-mini and other copies of it need the S1-mini format. Every other model takes Lucid's prompt.">${options([["general", "Lucid's prompt"], ["s1", "S1-mini format"]], x.style)}</select>` : ""}
           <button class="icon" data-action="rename" data-file="${esc(x.fileName)}" title="Rename ${esc(x.name)}" aria-label="Rename ${esc(x.name)}">${PENCIL}</button>
           <button class="icon" data-action="delete" data-file="${esc(x.fileName)}" data-name="${esc(x.name)}" title="Delete ${esc(x.name)}" aria-label="Delete ${esc(x.name)}">${BIN}</button></div>`).join("");
    const offer = o => {
      let side = `<button class="plain" data-action="download" data-file="${esc(o.fileName)}" data-repo="${esc(o.repo)}" data-path="${esc(o.path)}">Download</button>`;
      if (o.state === "downloading") side = `<button class="plain" data-action="stop" data-file="${esc(o.fileName)}">Stop</button>`;
      if (o.state === "installed") side = `<span class="small" style="font-size:13px">Downloaded</span><button class="icon" data-action="delete" data-file="${esc(o.fileName)}" data-name="${esc(o.title)}" title="Delete ${esc(o.title)}" aria-label="Delete ${esc(o.title)}">${BIN}</button>`;
      if (o.state === "partial") side = `${o.repo ? `<button class="plain" data-action="download" data-file="${esc(o.fileName)}" data-repo="${esc(o.repo)}" data-path="${esc(o.path)}">Resume</button>` : ""}
          <button class="plain" data-action="discard" data-file="${esc(o.fileName)}" title="Delete the part downloaded so far">Discard</button>`;
      return `<div class="row"><div class="grow"><div>${esc(o.title)}</div><div class="small">${esc(o.detail)}</div>
          ${o.state === "downloading" ? `<progress ${o.progress != null ? `value="${o.progress}"` : ""} max="1"></progress>` : ""}
          ${o.progressText ? `<div class="small">${esc(o.progressText)}</div>` : ""}</div>${side}</div>`;
    };
    let lookup = "";
    if (ui.lookup !== null) {
      const found = ui.lookup || {};
      lookup = `<div class="row"><div class="grow"><div class="small" style="margin-bottom:6px">Type a model's name, such as ggerganov/whisper.cpp, or paste a link to it or to one of its files. Lucid lists the files it can use.</div>
          <div class="buttons" style="flex-wrap:nowrap">${field("lookup", "owner/name, or a link", "look-up")}<button class="plain" data-action="look-up">Look Up</button><button class="plain" data-action="close-lookup">Close</button></div>
          ${ui.lookingUp ? `<div class="small" style="margin-top:6px">Looking up…</div>` : ""}
          ${found.error ? `<div class="small warn" style="margin-top:6px">${esc(found.error)}</div>` : ""}</div></div>
        ${(found.files || []).map(f => offer({ fileName: f.fileName, title: f.path, detail: (f.kind === "speech" ? "Speech" : "Cleanup") + " · " + f.size, repo: found.repo, path: f.path,
            state: (m.offers.find(o => o.fileName === f.fileName) || {}).state || (m.installed.some(x => x.fileName === f.fileName) ? "installed" : "available"),
            progress: (m.offers.find(o => o.fileName === f.fileName) || {}).progress, progressText: (m.offers.find(o => o.fileName === f.fileName) || {}).progressText })).join("")}
        ${found.repo ? `<div class="row small"><a href="${esc(found.page)}" target="_blank" rel="noopener noreferrer">Open ${esc(found.repo)} on Hugging Face</a><span class="grow"></span>Each model has its own licence, shown on its page.</div>` : ""}`;
    }
    const adding = ui.adding ? `<div class="row"><div class="grow"><div class="small" style="margin-bottom:6px">The full path of the ${ui.adding} model file on this computer:</div>
        <div class="buttons" style="flex-wrap:nowrap">${field("add-path", ui.adding === "speech" ? "…/ggml-small.en.bin" : "…/model.gguf", "add-path")}<button class="plain" data-action="add-path">Add</button><button class="plain" data-action="cancel-add">Cancel</button></div></div></div>` : "";
    return `<h2>Speech recognition</h2><div class="card"><div class="row"><span class="grow">Model</span>${pick("speech", m.speech, speech, "Not installed")}</div></div>
      <p class="note">Whisper models for whisper.cpp, named like ggml-small.en.bin. Smaller models are faster but mishear more. Lucid listens for English.</p>
      <h2>Cleanup</h2><div class="card"><div class="row"><span class="grow">Light</span>${pick("light", m.light, cleanup, "Not installed")}</div>
        <div class="row"><span class="grow">Medium</span>${pick("medium", m.medium, general, "None installed")}</div></div>
      <p class="note">Medium needs a model that uses Lucid's prompt. If a model adds words, answers a question or drops part of what you said, Lucid uses its rules instead, so a dictation is never lost.</p>
      <h2>Models on this computer</h2><div class="card">${rows || `<div class="row small">None yet. Download one below.</div>`}
        <div class="row"><div class="buttons grow"><button class="plain" data-action="add" data-kind="speech" ${ui.busy.add ? "disabled" : ""}>Add Speech Model…</button>
          <button class="plain" data-action="add" data-kind="cleanup" ${ui.busy.add ? "disabled" : ""}>Add Cleanup Model…</button><span class="grow"></span>
          ${state.app.canChooseFiles ? `<button class="plain" data-action="folder">Show Folder</button>` : ""}</div></div>
        ${adding}
        ${ui.busy.add ? `<div class="row small">Adding the model. A large one on another disk takes a while.</div>` : ""}
        ${m.notice ? `<div class="row small ${m.notice.isProblem ? "warn" : ""}" ${m.notice.isProblem ? 'role="alert"' : ""}>${esc(m.notice.text)}</div>` : ""}</div>
      ${m.notice && m.notice.text === ui.message ? "" : message()}
      <p class="note">These models use ${esc(m.totalSize)} of disk, in ${esc(m.folder)}. Lucid keeps its own copy of each model you add. A cleanup model must be a single .gguf file.</p>
      <h2>Download from Hugging Face</h2><div class="card">${m.offers.map(offer).join("")}
        ${ui.lookup === null ? `<div class="row"><button class="plain" data-action="open-lookup">Download Another Model…</button></div>` : lookup}</div>
      <p class="note">Downloads come straight from huggingface.co, and Lucid sends nothing else. A download that stops continues where it left off.</p>
      <div class="card" style="margin-top:18px"><div class="row small ${state.status.engineFailed ? "warn" : ""}">${esc(state.status.engineNote)}</div></div>`;
  },

  dictionary() {
    const d = state.dictionary;
    return `${d.problem ? `<div class="card"><div class="row warn" role="alert">${esc(d.problem)}</div></div>` : ""}
      <h2>Words to spell exactly</h2><div class="card">
        ${d.terms.map(term => `<div class="row"><span class="grow wrap">${esc(term)}</span><button class="icon" data-action="remove-term" data-text="${esc(term)}" title="Remove ${esc(term)}" aria-label="Remove ${esc(term)}">${MINUS}</button></div>`).join("")}
        <div class="row">${field("term", "Add a word or name", "add-term")}<button class="plain" data-action="add-term">Add</button></div></div>
      <p class="note">Names, products and jargon, written the way you want them. For example: GitHub.</p>
      <h2>Corrections</h2><div class="card">
        ${d.replacements.map(pair => `<div class="row"><span class="grow wrap">${esc(pair.from)} → ${esc(pair.to)}</span><button class="icon" data-action="remove-pair" data-from="${esc(pair.from)}" title="Remove this correction" aria-label="Remove the correction for ${esc(pair.from)}">${MINUS}</button></div>`).join("")}
        <div class="row">${field("heard", "Lucid hears")}<span aria-hidden="true">→</span>${field("correct", "Write instead", "add-pair")}<button class="plain" data-action="add-pair">Add</button></div></div>
      <p class="note">When Lucid keeps mishearing something, say what to write instead.</p>${message()}`;
  },

  history() {
    if (!state.history.length) return `<div class="empty"><strong>No dictations yet</strong>${state.app.canDictate ? `<div>Hold ${esc(state.settings.hotkeyTitle)} and speak.</div>` : ""}</div>`;
    return `<div class="card">${state.history.map(e => `<div class="row"><div class="grow">
        <div class="small">${esc(when(e.date))} · ${esc(e.app)}${e.seconds ? ` · ${esc(e.seconds)}` : ""}</div>
        ${e.text != null ? `<div class="wrap">${esc(e.text)}</div>${e.original ? `<div class="small wrap" style="font-size:13px">Original: ${esc(e.original)}</div>` : ""}`
                         : `<div class="warn">This dictation failed. ${esc(e.failure)}</div>`}
        <div class="buttons" style="margin-top:4px">
          ${e.text != null ? `<button class="link" data-action="copy" data-text="${esc(e.text)}">Copy</button>` : ""}
          ${e.original ? `<button class="link" data-action="copy" data-text="${esc(e.original)}">Copy Original</button>` : ""}
          ${e.hasAudio ? `<button class="link" data-action="retry" data-id="${e.id}" ${ui.busy[e.id] ? "disabled" : ""}>${ui.busy[e.id] ? "Retrying…" : "Retry"}</button>` : ""}
          <span class="grow"></span><button class="icon" data-action="forget" data-id="${e.id}" title="Delete this dictation" aria-label="Delete this dictation">${BIN}</button></div>
        </div></div>`).join("")}</div>${message()}
      <div class="buttons" style="margin:12px 10px 0"><span class="small grow" style="font-size:13px">Every dictation keeps its original wording.</span><button class="plain" data-action="clear-history">Clear History…</button></div>`;
  },

  settings() {
    const s = state.settings;
    return `${state.app.canDictate ? `<h2>Dictation key</h2><div class="card"><div class="row"><span class="grow">Hold to dictate</span><select data-setting="hotkey" aria-label="Hold to dictate">${options(s.hotkeys.map(k => [k.id, k.title]), s.hotkey)}</select></div>
        <div class="row small" style="font-size:13px">Hold the key and speak, then let go. Tap it twice to keep recording hands-free. Press Escape to cancel.</div></div>` : ""}
      <h2>Cleanup</h2><div class="card"><div class="row"><span class="grow">Level</span><span class="segments" role="group" aria-label="Cleanup level">
        ${[["off", "Off"], ["light", "Light"], ["medium", "Medium"]].map(([id, title]) => `<button data-action="level" data-id="${id}" aria-pressed="${s.level === id}">${title}</button>`).join("")}</span></div>
        <div class="row small" style="font-size:13px">${esc(s.levelNote)}</div></div>${message()}
      ${state.app.canDictate ? `<h2>While you speak</h2><div class="card"><div class="row"><label class="switch"><span>Show the words as you speak</span><input type="checkbox" data-setting="livePreview" ${s.livePreview ? "checked" : ""}></label></div>
        <div class="row small" style="font-size:13px">The pill shows the last few words Lucid has heard. This is a rough first hearing: the text that is inserted is worked out from the whole recording once you stop. It can add a moment to the wait after you let go.</div></div>` : ""}
      <h2>Privacy</h2><div class="card"><div class="row"><label class="switch"><span>Keep recordings of recent dictations</span><input type="checkbox" data-setting="keepRecordings" ${s.keepRecordings ? "checked" : ""}></label></div>
        <div class="row small" style="font-size:13px">The last 20 recordings stay on this computer for 7 days, so a failed dictation can be retried. Nothing you say leaves your computer.</div></div>
      <h2>${s.opensAtLogin != null ? "Startup" : "Engines"}</h2><div class="card">${s.opensAtLogin != null ? `<div class="row"><label class="switch"><span>Open Lucid when I sign in</span><input type="checkbox" data-setting="opensAtLogin" ${s.opensAtLogin ? "checked" : ""}></label></div>` : ""}
        <div class="row small ${state.status.engineFailed ? "warn" : ""}" style="font-size:13px">${esc(state.status.engineNote)}</div></div>`;
  },

  about() {
    const line = (label, value) => `<div class="row"><span class="grow">${label}</span><span class="small" style="font-size:13px">${esc(value)}</span></div>`;
    return `<h2>Lucid</h2><div class="card">${line("Version", state.app.version)}${line("Running on", state.app.system)}
        <div class="row small" style="font-size:13px">Lucid turns speech into clean text. Everything runs on this computer: no audio and no text is sent anywhere.</div></div>
      <h2>Built with</h2><div class="card">${line("Speech recognition", "Whisper large-v3-turbo")}${line("Cleanup", "S1-mini by Superwhisper")}${line("Cleanup at Medium", "Qwen 3.5 4B")}${line("Engines", "whisper.cpp and llama.cpp")}</div>
      <p class="note">Lucid is free software under the GNU General Public License, version 3.</p>`;
  },
};

const actions = {
  async copy(el) { try { await navigator.clipboard.writeText(el.dataset.text); const was = el.textContent; el.textContent = "Copied"; setTimeout(() => { el.textContent = was; }, 1200); } catch (error) { ui.message = "The text could not be copied."; draw(true); } },
  setup(el) { act("/api/setup/action", { id: el.dataset.id }); },
  "stop-setup"() { for (const o of state.models.offers) if (o.state === "downloading") api("/api/models/cancel", { fileName: o.fileName }); setTimeout(refresh, 300); },
  level(el) { act("/api/settings", { level: el.dataset.id }); },
  rename(el) { ui.renaming = el.dataset.file; ui.drafts.rename = (state.models.installed.find(x => x.fileName === el.dataset.file) || {}).name || ""; draw(true); const input = document.getElementById("rename"); if (input) { input.focus(); input.select(); } },
  "cancel-name"() { ui.renaming = null; draw(true); },
  async "save-name"() { if (await act("/api/models/rename", { fileName: ui.renaming, name: draft("rename") })) { ui.renaming = null; draw(true); } },
  async delete(el) {
    let text = `Delete ${el.dataset.name}?`;
    try { text += "\n\n" + (await api("/api/models/removal?file=" + encodeURIComponent(el.dataset.file))).message; } catch (error) {}
    if (confirm(text)) act("/api/models/remove", { fileName: el.dataset.file });
  },
  download(el) { act("/api/models/download", { fileName: el.dataset.file, repo: el.dataset.repo, path: el.dataset.path }); },
  stop(el) { act("/api/models/cancel", { fileName: el.dataset.file }); },
  discard(el) { act("/api/models/discard", { fileName: el.dataset.file }); },
  "open-lookup"() { ui.lookup = false; draw(true); const input = document.getElementById("lookup"); if (input) input.focus(); },
  "close-lookup"() { ui.lookup = null; draw(true); },
  async "look-up"() {
    if (!draft("lookup").trim()) return;
    ui.lookingUp = true; ui.lookup = false; draw(true);
    try { ui.lookup = await api("/api/models/lookup", { text: draft("lookup") }); } catch (error) { ui.lookup = { error: error.message }; }
    ui.lookingUp = false; draw(true);
  },
  async add(el) {
    if (!state.app.canChooseFiles) { ui.adding = el.dataset.kind; draw(true); const input = document.getElementById("add-path"); if (input) input.focus(); return; }
    ui.busy.add = true; draw(true);
    await act("/api/models/add", { kind: el.dataset.kind }); ui.busy.add = false; draw(true);
  },
  "cancel-add"() { ui.adding = null; draw(true); },
  async "add-path"() {
    if (!draft("add-path").trim()) return;
    ui.busy.add = true; draw(true);
    if (await act("/api/models/add", { kind: ui.adding, path: draft("add-path") })) { ui.adding = null; ui.drafts["add-path"] = ""; }
    ui.busy.add = false; draw(true);
  },
  folder() { act("/api/models/folder", {}); },
  async "add-term"() { if (draft("term").trim() && await act("/api/dictionary", { kind: "addTerm", text: draft("term") })) { ui.drafts.term = ""; draw(true); } },
  "remove-term"(el) { act("/api/dictionary", { kind: "removeTerm", text: el.dataset.text }); },
  async "add-pair"() { if (draft("heard").trim() && draft("correct").trim() && await act("/api/dictionary", { kind: "addReplacement", from: draft("heard"), to: draft("correct") })) { ui.drafts.heard = ""; ui.drafts.correct = ""; draw(true); } },
  "remove-pair"(el) { act("/api/dictionary", { kind: "removeReplacement", from: el.dataset.from }); },
  async retry(el) { ui.busy[el.dataset.id] = true; draw(true); const done = await act("/api/history/retry", { id: el.dataset.id }); delete ui.busy[el.dataset.id]; if (done && done.message) ui.message = done.message; draw(true); },
  forget(el) { act("/api/history/remove", { id: el.dataset.id }); },
  "clear-history"() { if (confirm("Delete all history and recordings?\n\nThis cannot be undone.")) act("/api/history/clear", {}); },
};

document.addEventListener("click", event => {
  const tabButton = event.target.closest("[data-tab]");
  if (tabButton) return go(tabButton.dataset.tab);
  const button = event.target.closest("[data-action]");
  if (button && !button.disabled && actions[button.dataset.action]) actions[button.dataset.action](button);
});
document.addEventListener("input", event => { if (event.target.matches('input[type="text"]')) ui.drafts[event.target.id] = event.target.value; });
document.addEventListener("keydown", event => {
  if (event.key === "Enter" && event.target.dataset && event.target.dataset.enter) { ui.drafts[event.target.id] = event.target.value; actions[event.target.dataset.enter](event.target); }
  if (event.key === "Escape" && ui.renaming) actions["cancel-name"]();
});
document.addEventListener("change", event => {
  const el = event.target;
  if (el.dataset.choose) act("/api/models/choose", { [el.dataset.choose]: el.value });
  else if (el.dataset.style) act("/api/models/style", { fileName: el.dataset.style, style: el.value });
  else if (el.dataset.setting) act("/api/settings", { [el.dataset.setting]: el.type === "checkbox" ? el.checked : el.value });
});

refresh();
setInterval(refresh, 1000);
</script>
</body>
</html>
"""#
}
