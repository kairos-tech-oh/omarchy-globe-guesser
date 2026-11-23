#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const strip = (f) => fs.readFileSync(path.join(__dirname, "..", f), "utf8").replace(/^\.(pragma|import).*$/gm, "");
const ctx = {};
vm.runInNewContext(strip("Sanitise.js") + "\nthis.Sanitise = { plainOneLine };", ctx);
vm.runInNewContext(strip("RoundLogic.js") + "\nthis.L = { cappedCurl, parseCappedJson, placesUrl, clampRadius, attributionUrl, safeFileName, parseCandidates, chooseCandidate, ALLOWED_PHOTO_URL, REJECT_ARTICLE, REJECT_FILE };", ctx);
const F = ctx.L;

let failed = 0;
function check(name, cond, detail) {
  if (cond) console.log("ok   " + name);
  else { failed++; console.log("FAIL " + name + (detail === undefined ? "" : "  got " + JSON.stringify(detail))); }
}
function throws(fn) { try { fn(); return false; } catch (e) { return true; } }

const cmd = F.cappedCurl("https://en.wikipedia.org/w/api.php?x=1", 1000, 15, "ua/1");
check("cappedCurl: caps at cap+1 bytes", cmd.indexOf("1001") > 0, cmd);
check("cappedCurl: https only and no redirects", cmd[cmd.indexOf("--proto") + 1] === "=https" && !cmd.some((a) => /^--proto=/.test(a)) && !cmd.some((a) => /^-[A-Za-z]*L/.test(a) || /^--location/.test(a)), cmd);
check("cappedCurl: user agent and url passed as argv", cmd[cmd.indexOf("-A") + 1] === "ua/1" && cmd[cmd.length - 2] === "--" && cmd[cmd.length - 1] === "https://en.wikipedia.org/w/api.php?x=1");
check("cappedCurl: outer timeout exceeds curl's", cmd[3] === "20" && cmd[cmd.indexOf("--max-time") + 1] === "15", cmd);
const zero = F.cappedCurl("https://en.wikipedia.org/", 10, 0, "ua");
check("cappedCurl: a zero budget still has a deadline", zero[zero.indexOf("--max-time") + 1] === "1" && zero[3] === "6", zero);

check("parseCappedJson: blank body throws", throws(() => F.parseCappedJson(" ", 100)));
check("parseCappedJson: oversized body throws", throws(() => F.parseCappedJson('{"a":"' + "x".repeat(200) + '"}', 100)));
check("parseCappedJson: valid body parses", F.parseCappedJson('{"a":1}', 100).a === 1);

check("clampRadius: inside the range is unchanged", F.clampRadius(2500, 10000) === 2500);
check("clampRadius: clamps both ends", F.clampRadius(3, 10000) === 10 && F.clampRadius(50000, 10000) === 10000);
check("clampRadius: junk becomes the maximum", F.clampRadius("abc", 10000) === 10000 && F.clampRadius(NaN, 10000) === 10000);
const places = F.placesUrl(48.8584, 2.2945, 99999, 10000);
check("placesUrl: English Wikipedia geosearch", places.indexOf("https://en.wikipedia.org/w/api.php?") === 0 && places.indexOf("generator=geosearch") > 0);
check("placesUrl: coordinates to 5 places, radius clamped", places.indexOf("ggscoord=48.85840%7C2.29450") > 0 && places.indexOf("ggsradius=10000") > 0, places);
const attr = F.attributionUrl("Pont de l'Alma & Seine.jpg");
check("attributionUrl: file name is URL-encoded", attr.indexOf("titles=File%3APont%20de%20l'Alma%20%26%20Seine.jpg") > 0 && attr.indexOf(" ") < 0, attr);
check("attributionUrl: asks Commons", attr.indexOf("https://commons.wikimedia.org/w/api.php?") === 0);

check("safeFileName keeps apostrophes and ampersands", F.safeFileName("Sant'Andrea & co.jpg") === "Sant'Andrea & co.jpg");
check("safeFileName refuses control characters", F.safeFileName("a\nb.jpg") === "" && F.safeFileName("a\u0000.jpg") === "");
check("safeFileName refuses empty and over-long names", F.safeFileName("") === "" && F.safeFileName(null) === "" && F.safeFileName("x".repeat(241)) === "");

const ok = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Eiffel.jpg/1280px-Eiffel.jpg?utm_source=x&a=1";
check("photo URL: a Commons thumbnail is allowed", F.ALLOWED_PHOTO_URL.test(ok));
check("photo URL: lookalike host refused", !F.ALLOWED_PHOTO_URL.test("https://upload.wikimedia.org.evil.example/wikipedia/commons/a.jpg"));
check("photo URL: other path refused", !F.ALLOWED_PHOTO_URL.test("https://upload.wikimedia.org/wikipedia/en/a.jpg"));
check("photo URL: http, spaces and newlines refused", !F.ALLOWED_PHOTO_URL.test(ok.replace("https", "http")) && !F.ALLOWED_PHOTO_URL.test(ok + " x") && !F.ALLOWED_PHOTO_URL.test(ok + "\nx"));
check("photo URL: over 700 characters refused", !F.ALLOWED_PHOTO_URL.test("https://upload.wikimedia.org/wikipedia/commons/" + "a".repeat(701)));

check("reject article: events and lists", ["Battle of Hastings", "List of bridges", "2011 Tohoku earthquake", "HMS Belfast"].every((t) => F.REJECT_ARTICLE.test(t)));
check("reject article: real places pass", !["Eiffel Tower", "Shibuya Crossing", "Charles Bridge"].some((t) => F.REJECT_ARTICLE.test(t)));
check("reject file: maps, flags, crests", ["Paris map.jpg", "Flag of France.png", "Coat of arms of Lyon.png", "Wappen Bern.jpg"].every((f) => F.REJECT_FILE.test(f)));
check("reject file: ordinary photos pass", !["Eiffel tower at night.jpg", "Tower Bridge 2019.jpg"].some((f) => F.REJECT_FILE.test(f)));

const page = (o) => Object.assign({ title: "Charles Bridge", pageimage: "Charles Bridge view.jpg",
  thumbnail: { source: ok, width: 1280, height: 853 }, coordinates: [{ lat: 50.0865, lon: 14.4114 }] }, o);
const reply = (pages) => JSON.stringify({ query: { pages } });
const one = F.parseCandidates(reply([page({})]), 1 << 20, 60);
check("parseCandidates: a good page becomes a candidate", one.length === 1 && one[0].file === "Charles Bridge view.jpg" && one[0].lat === 50.0865, one);
check("parseCandidates: place word, landscape and size score 4", one[0].score === 4, one[0]);
const skipped = F.parseCandidates(reply([
  null, "x",
  page({ thumbnail: null }), page({ coordinates: [] }),
  page({ pageimage: "Crest.svg" }), page({ pageimage: "Charles Bridge view.gif" }), page({ pageimage: "Bridge\n.jpg" }),
  page({ title: "Battle of Prague" }), page({ pageimage: "Prague map.jpg" }),
  page({ thumbnail: { source: ok, width: 600, height: 853 } }),
  page({ coordinates: [{ lat: 95, lon: 0 }] }), page({ coordinates: [{ lat: "x", lon: 0 }] }),
  page({ thumbnail: { source: "https://evil.example/a.jpg", width: 1280, height: 853 } }),
  page({ title: "" })
]), 1 << 20, 60);
check("parseCandidates: every unusable page is skipped", skipped.length === 0, skipped);
check("parseCandidates: close-ups score lower", F.parseCandidates(reply([page({ pageimage: "Bridge statue detail.jpg", title: "Prague" })]), 1 << 20, 60)[0].score < one[0].score);
check("parseCandidates: caps the candidate count", F.parseCandidates(reply(Array(10).fill(page({}))), 1 << 20, 3).length === 3);
check("parseCandidates: titles are sanitised", F.parseCandidates(reply([page({ title: "Bridge <img src=x>" })]), 1 << 20, 60)[0].title.indexOf("<") < 0);
check("parseCandidates: no pages is empty", F.parseCandidates('{"query":{}}', 100, 60).length === 0);
check("parseCandidates: over the byte cap throws", throws(() => F.parseCandidates(reply([page({})]), 50, 60)));

const cands = [{ score: 4, id: "a" }, { score: 3, id: "b" }, { score: 1, id: "c" }, { score: -2, id: "d" }];
const picks = new Set();
for (let i = 0; i < 400; i++) picks.add(F.chooseCandidate(cands, Math.random).id);
check("chooseCandidate: only picks within one point of the best", [...picks].sort().join("") === "ab", [...picks]);
check("chooseCandidate: low random picks the first eligible", F.chooseCandidate(cands, () => 0).id === "a" && F.chooseCandidate(cands, () => 0.99).id === "b");

console.log(failed === 0 ? "\nall round checks passed" : "\n" + failed + " round check(s) failed");
process.exit(failed === 0 ? 0 : 1);
