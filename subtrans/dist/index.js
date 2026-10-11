// Subtitle Translate (on-device): when a file has bitmap subtitles but none in the target language,
// run ~/.local/bin/subtrans (Vision OCR + Apple Translation) and load its .srt while it is still being written.
const { core, event, mpv, utils, console, menu, preferences, file } = iina;

const HELPER = utils.resolvePath("~/.local/bin/subtrans"); // build: swiftc -O helper/subtrans.swift -o ~/.local/bin/subtrans
const LANG3 = { en: "eng", es: "spa", fr: "fre", de: "ger", it: "ita", pt: "por", ja: "jpn", zh: "chi", ko: "kor", ru: "rus" };

let job = null; // { path, out, trackId, running }

function target() {
  return preferences.get("target") || "en";
}

function hash(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  return h.toString(16);
}

function tracks() {
  return (mpv.getNative("track-list") || []).filter((t) => t.type === "sub");
}

function hasTargetSubs() {
  const t = target();
  return tracks().some((s) => !s.image && (s.lang === t || s.lang === LANG3[t]) && s["external-filename"] !== (job && job.out));
}

function hasBitmapSubs() {
  return tracks().some((s) => s.codec === "dvd_subtitle");
}

function ourTrackId() {
  const s = tracks().find((t) => t["external-filename"] === job.out);
  return s ? s.id : null;
}

function attachOrReload() {
  if (!job || !file.exists(job.out)) return;
  if (job.trackId == null) {
    mpv.command("sub-add", [job.out, "select", `${target().toUpperCase()} (on-device)`, target()]);
    job.trackId = ourTrackId();
  } else {
    mpv.command("sub-reload", [String(job.trackId)]);
  }
}

async function translate(manual) {
  const path = mpv.getString("path");
  if (!path || /^[a-z]+:\/\//i.test(path)) return manual && core.osd("Subtitle Translate: local files only");
  if (!file.exists(HELPER)) return core.osd("Subtitle Translate: helper missing at ~/.local/bin/subtrans");
  if (!hasBitmapSubs()) return manual && core.osd("Subtitle Translate: no bitmap subtitles to translate");
  if (!manual && hasTargetSubs()) return;
  if (job && job.path === path && job.running) return;

  const dir = utils.resolvePath("@data/cache");
  await utils.exec("/bin/mkdir", ["-p", dir]);
  const out = `${dir}/${hash(path)}.${target()}.srt`;
  job = { path, out, trackId: null, running: true };
  const me = job;

  const from = Math.max(0, Math.floor(mpv.getNumber("time-pos") || 0));
  core.osd(`Subtitle Translate: translating from ${Math.floor(from / 60)}:${String(from % 60).padStart(2, "0")}…`);
  console.log(`subtrans ${path} -> ${out} from ${from}s`);

  const poll = setInterval(() => {
    if (job !== me || mpv.getString("path") !== me.path) return clearInterval(poll);
    attachOrReload();
  }, 3000);

  const res = await utils.exec(HELPER, [path, out, "--to", target(), "--from", String(from)]);
  clearInterval(poll);
  me.running = false;
  if (job !== me || mpv.getString("path") !== me.path) return;
  if (res.status !== 0) {
    console.log(`subtrans failed: ${res.stderr}`);
    return core.osd(`Subtitle Translate failed: ${(res.stderr || "").trim().split("\n").pop()}`);
  }
  attachOrReload();
  core.osd("Subtitle Translate: done");
}

event.on("iina.file-loaded", () => {
  job = null;
  if (preferences.get("auto")) setTimeout(() => translate(false), 1500); // let track-list settle
});

menu.addItem(menu.item("Translate subtitles now", () => translate(true)));
const autoItem = menu.item("Auto-translate when no subtitles in my language", () => {
  preferences.set("auto", !preferences.get("auto"));
  autoItem.selected = !!preferences.get("auto");
});
autoItem.selected = !!preferences.get("auto");
menu.addItem(autoItem);
