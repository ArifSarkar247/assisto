// Render proof screenshots of the Assisto Map with MapLibre Native (the same engine as the
// Android app) straight from the built PMTiles, fonts and sprites. CI only.
//   node render_shots.mjs TILES_DIR ASSETS_DIR OUT_DIR
// TILES_DIR: bd_*.pmtiles; ASSETS_DIR: style/, fonts/, sprites/ (from the assets job).
import fs from "node:fs";
import path from "node:path";
import mbgl from "@maplibre/maplibre-gl-native";
import { PMTiles } from "pmtiles";
import { PNG } from "pngjs";

const [tilesDir, assetsDir, outDir] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });

class FileSource {
  constructor(p) { this.p = p; this.fd = fs.openSync(p, "r"); }
  getKey() { return this.p; }
  async getBytes(offset, length) {
    const buf = Buffer.alloc(length);
    const n = fs.readSync(this.fd, buf, 0, length, offset);
    return { data: buf.buffer.slice(buf.byteOffset, buf.byteOffset + n) };
  }
}

const archives = {};
for (const name of ["bd_base", "bd_buildings", "bd_places", "bd_terrain"]) {
  const f = path.join(tilesDir, `${name}.pmtiles`);
  if (fs.existsSync(f)) archives[name] = new PMTiles(new FileSource(f));
}
const srcFile = { assisto_base: "bd_base", assisto_buildings: "bd_buildings", assisto_places: "bd_places", assisto_terrain: "bd_terrain" };

async function localStyle(file) {
  const st = JSON.parse(fs.readFileSync(path.join(assetsDir, "style", file), "utf8"));
  for (const [id, src] of Object.entries(st.sources)) {
    const a = archives[srcFile[id]];
    if (!a) { delete st.sources[id]; st.layers = st.layers.filter((l) => l.source !== id); continue; }
    const h = await a.getHeader();
    delete src.url;
    src.tiles = [`local://${srcFile[id]}/{z}/{x}/{y}`];
    src.minzoom = h.minZoom; src.maxzoom = h.maxZoom;
  }
  const theme = file.includes("night") ? "night" : "light";
  st.sprite = `local://sprites/${theme}`;
  st.glyphs = "local://fonts/{fontstack}/{range}.pbf";
  return st;
}

let misses = 0;
function request(req, cb) {
  const u = req.url.replace("local://", "");
  const parts = u.split("/");
  if (archives[parts[0]]) {
    const [name, z, x, y] = parts;
    archives[name].getZxy(+z, +x, +y).then((r) => {
      if (!r || !r.data) return cb();
      cb(null, { data: Buffer.from(r.data) });
    }).catch((e) => cb(e));
    return;
  }
  let file;
  if (parts[0] === "fonts") file = path.join(assetsDir, "fonts", decodeURIComponent(parts[1]).split(",")[0], parts[2]);
  else if (parts[0] === "sprites") file = path.join(assetsDir, "sprites", "v1", parts[1]);
  if (file && fs.existsSync(file)) return cb(null, { data: fs.readFileSync(file) });
  misses += 1;
  console.log("missing", req.url);
  cb();
}

const SHOTS = [
  // name, style, center [lon, lat], zoom, pitch, bearing
  ["dhaka_overview", 11, [90.4125, 23.7925], 0, 0],
  ["badda", 15.6, [90.4255, 23.7806], 55, -20],
  ["motijheel", 15.8, [90.4176, 23.7330], 55, 30],
  ["mirpur10_metro", 15.2, [90.3686, 23.8069], 45, 0],
  ["airport", 13.6, [90.3978, 23.8433], 30, 0],
  ["chattogram_hills", 10, [91.95, 22.55], 0, 0],
  ["bangladesh", 6.3, [90.3, 23.7], 0, 0],
];

const ratio = 2;
const report = [];
for (const theme of ["light", "night"]) {
  for (const lang of ["bn", "en"]) {
    const style = await localStyle(`assisto-${theme}-${lang}.json`);
    for (const [name, zoom, center, pitch, bearing] of SHOTS) {
      if (lang === "en" && !["motijheel", "dhaka_overview"].includes(name)) continue;
      const map = new mbgl.Map({ request, ratio });
      map.load(style);
      const width = 540, height = 960;
      const t0 = Date.now();
      const pixels = await new Promise((res, rej) =>
        map.render({ zoom, center, pitch, bearing, width, height }, (err, buf) => (err ? rej(err) : res(buf))));
      map.release();
      const png = new PNG({ width: width * ratio, height: height * ratio });
      png.data = Buffer.from(pixels);
      const out = path.join(outDir, `${name}_${theme}_${lang}.png`);
      fs.writeFileSync(out, PNG.sync.write(png));
      report.push({ shot: path.basename(out), ms: Date.now() - t0 });
      console.log("shot", out, Date.now() - t0, "ms");
    }
  }
}
fs.writeFileSync(path.join(outDir, "render_report.json"), JSON.stringify({ shots: report, missing_requests: misses }, null, 1));
if (misses > 0) console.log("WARNING missing requests:", misses);
