'use strict';

// A loopback bridge to the SpektraLab engine. Its only write
// is a private temporary PNG used as the source for the engine.
const http = require('http');
const fs = require('fs');
const fsp = require('fs/promises');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { spawn, execFile } = require('child_process');
const { promisify } = require('util');
const runFile = promisify(execFile);

const FORMATS = new Set(['135', '135_half', '120_645', '120_6x6', '120_6x7']);
const MAX_REQUEST = 100 * 1024 * 1024;
const MAX_FRAME = 256 * 1024 * 1024;

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const name = Buffer.from(type, 'ascii');
  const result = Buffer.allocUnsafe(data.length + 12);
  result.writeUInt32BE(data.length, 0);
  name.copy(result, 4);
  data.copy(result, 8);
  result.writeUInt32BE(crc32(Buffer.concat([name, data])), data.length + 8);
  return result;
}

function encodePng(image, pixels) {
  const { width, height, row_bytes: stride, format } = image;
  if (format !== 'rgba8' || !Number.isSafeInteger(width) || !Number.isSafeInteger(height) ||
      width < 1 || height < 1 || width * height > 60000000 || stride < width * 4 ||
      pixels.length !== stride * height) throw new Error('引擎返回的图片格式或尺寸无效');
  const rows = Buffer.allocUnsafe((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    const offset = y * (width * 4 + 1);
    rows[offset] = 0;
    pixels.copy(rows, offset + 1, y * stride, y * stride + width * 4);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; ihdr[9] = 6; // 8-bit RGBA
  return Buffer.concat([Buffer.from('89504e470d0a1a0a', 'hex'), pngChunk('IHDR', ihdr),
    pngChunk('sRGB', Buffer.from([0])), pngChunk('IDAT', zlib.deflateSync(rows)),
    pngChunk('IEND', Buffer.alloc(0))]);
}

function hostPaths() {
  const root = path.resolve(__dirname, '..');
  // The upstream portable package places the executable at its root and the
  // engine under host/engine. The build-stage layout keeps them together.
  const override = process.env.SPEKTRALAB_HOST_DIR;
  const candidates = override
    ? [[override, path.join(override, 'engine')], [override, path.join(override, 'host', 'engine')]]
    : [[path.join(root, 'runtime'), path.join(root, 'runtime', 'host', 'engine')],
      [root, path.join(root, 'host', 'engine')], [path.join(root, 'host'), path.join(root, 'host', 'engine')]];
  for (const [base, resources] of candidates) {
    const executable = ['spektralab-host.exe', 'spektralab-host-x86_64-pc-windows-msvc.exe']
      .map(name => path.join(base, name)).find(p => fs.existsSync(p));
    if (executable && fs.existsSync(resources)) return { executable, resources };
  }
  throw new Error('找不到 SpektraLab 引擎或资源，请重新安装程序。');
}

class Host {
  constructor(executable, resources) {
    this.child = spawn(executable, ['--resources', resources], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    this.buffer = Buffer.alloc(0); this.next = 1; this.pending = new Map(); this.stderr = '';
    this.child.stdout.on('data', data => this.read(data));
    this.child.stderr.on('data', data => { this.stderr = (this.stderr + data.toString()).slice(-4096); });
    this.child.on('error', err => this.fail(err));
    this.child.on('exit', code => this.fail(new Error(`引擎已退出 (${code})${this.stderr ? ': ' + this.stderr : ''}`)));
  }
  fail(error) {
    for (const request of this.pending.values()) { clearTimeout(request.timer); request.reject(error); }
    this.pending.clear();
  }
  read(data) {
    this.buffer = Buffer.concat([this.buffer, data]);
    while (this.buffer.length >= 8) {
      const headerLength = this.buffer.readUInt32LE(0), payloadLength = this.buffer.readUInt32LE(4);
      if (headerLength > 1024 * 1024 || payloadLength > MAX_FRAME) {
        this.fail(new Error('引擎返回的数据过大')); this.child.kill(); return;
      }
      const frameLength = 8 + headerLength + payloadLength;
      if (this.buffer.length < frameLength) return;
      let header;
      try { header = JSON.parse(this.buffer.toString('utf8', 8, 8 + headerLength)); }
      catch { this.fail(new Error('无法读取引擎响应')); this.child.kill(); return; }
      const payload = this.buffer.subarray(8 + headerLength, frameLength);
      this.buffer = this.buffer.subarray(frameLength);
      const request = this.pending.get(header.id);
      if (!request) continue; // progress events have no matching request id
      this.pending.delete(header.id); clearTimeout(request.timer);
      if (header.ok) request.resolve({ result: header.result, payload });
      else request.reject(new Error(header.error?.message || '引擎处理失败'));
    }
  }
  call(method, params = {}) {
    return new Promise((resolve, reject) => {
      if (!this.child.stdin.writable) return reject(new Error('引擎未启动'));
      const id = this.next++;
      const header = Buffer.from(JSON.stringify({ id, method, params }));
      const prefix = Buffer.alloc(8); prefix.writeUInt32LE(header.length, 0);
      const timer = setTimeout(() => { this.pending.delete(id); this.child.kill(); reject(new Error('引擎处理超时')); }, 180000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(Buffer.concat([prefix, header]), error => {
        if (error && this.pending.has(id)) { clearTimeout(timer); this.pending.delete(id); reject(error); }
      });
    });
  }
  async close() {
    try { await Promise.race([this.call('shutdown'), new Promise(r => setTimeout(r, 1000))]); }
    catch { /* already stopped */ }
    this.child.kill();
  }
}

// Edge lettering follows the Windows engine's stock convention for each gauge.
const filmStocks = new Map([
  ['kodak_portra_400', { edge: 'KODAK PORTRA 400', paper: 'kodak_portra_endura' }],
  ['kodak_portra_160', { edge: 'KODAK PORTRA 160', paper: 'kodak_portra_endura' }],
  ['kodak_portra_800', { edge: 'KODAK PORTRA 800-3', edge120: 'KODAK PORTRA 800', paper: 'kodak_portra_endura' }],
  ['kodak_ektar_100', { edge: 'KODAK EKTAR 100', paper: 'kodak_portra_endura' }],
  ['kodak_gold_200', { edge: 'KODAK GB 200-7', edge120: 'KODAK 200', paper: 'kodak_portra_endura' }],
  ['kodak_ultramax_400', { edge: 'KODAK GC 400', paper: 'kodak_portra_endura' }],
  ['fujifilm_pro_400h', { edge: 'PRO400H', edge120: 'FUJI PRO400H', paper: 'fujifilm_crystal_archive_typeii' }],
  ['fujifilm_c200', { edge: 'FUJI 200', paper: 'fujifilm_crystal_archive_typeii' }],
  ['fujifilm_xtra_400', { edge: 'S-400', edge120: 'FUJI S-400', paper: 'fujifilm_crystal_archive_typeii' }],
  ['fujifilm_provia_100f', { edge: 'FUJI RDPIII', paper: 'fujifilm_crystal_archive_typeii', scanFilm: true }],
  ['fujifilm_velvia_100', { edge: 'RVP100', edge120: 'FUJI RVP100', paper: 'fujifilm_crystal_archive_typeii', scanFilm: true }],
  ['cinestill_800t', { edge: 'CINESTILL 800T', paper: 'kodak_2383' }],
]);

async function render(imageUrl, format, frameNumber, filmStock = 'kodak_portra_400') {
  if (!FORMATS.has(format)) throw new Error('不支持这个胶片画幅');
  const stock = filmStocks.get(filmStock);
  if (!stock) throw new Error('请选择列表中的胶卷型号');
  if (!Number.isInteger(frameNumber) || frameNumber < 1 || frameNumber > 99) throw new Error('张数请输入 1 到 99');
  if (typeof imageUrl !== 'string' || !imageUrl.startsWith('data:image/png;base64,')) throw new Error('请提供 PNG 格式的图片数据');
  const bytes = Buffer.from(imageUrl.slice(22), 'base64');
  if (bytes.length < 24 || bytes.length > MAX_REQUEST || !bytes.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))) throw new Error('图片数据无效');
  const temp = await fsp.mkdtemp(path.join(os.tmpdir(), 'film-border-'));
  let host;
  try {
    const input = path.join(temp, 'source.png');
    await fsp.writeFile(input, bytes);
    const params = { overscan_active: true, overscan_format: format, overscan_frame_seed: 1234, overscan_frame_number: frameNumber,
      film_stock: stock.engineStock || filmStock, print_stock: stock.paper, scan_film: stock.scanFilm || false,
      overscan_edge_text: (format.startsWith('120_') && stock.edge120) || stock.edge,
      auto_exposure: false, grain_active: false, glare_active: false, halation_active: false };
    if (process.platform === 'darwin') {
      const runtime = process.env.SPEKTRALAB_MAC_DIR || path.join(__dirname, '..', 'runtime');
      const output = path.join(temp, 'border.png');
      let result;
      try {
        const { stdout } = await runFile(path.join(runtime, 'FilmEngine'),
          [input, output, JSON.stringify(params), path.join(runtime, 'engine')], { timeout: 180000 });
        result = JSON.parse(stdout);
      } catch (error) {
        throw new Error((error.stderr || '').trim() || error.message || 'Mac 引擎处理失败');
      }
      if (!Array.isArray(result.gate) || result.gate.length !== 8) throw new Error('引擎没有返回有效的胶片片门');
      const border = (await fsp.readFile(output)).toString('base64');
      return { width: result.width, height: result.height, gate: result.gate, border: `data:image/png;base64,${border}` };
    }
    const { executable, resources } = hostPaths();
    host = new Host(executable, resources);
    const hello = (await host.call('hello')).result;
    if (!hello?.backend?.available) throw new Error(hello?.backend?.error || '没有可用的 Vulkan 显卡或驱动');
    const opened = (await host.call('open', { path: input, params })).result;
    const session = opened.session;
    const rendered = await host.call('render_view', { session, tier: 'full', display: 'srgb', generation: 1 });
    const geometry = (await host.call('overscan_geometry', { session })).result;
    if (!geometry?.valid || !Array.isArray(geometry.gates?.[0]) || geometry.gates[0].length !== 8) throw new Error('引擎没有返回有效的胶片片门');
    const border = encodePng(rendered.result.image, rendered.payload).toString('base64');
    return { width: rendered.result.image.width, height: rendered.result.image.height,
      gate: geometry.gates[0], border: `data:image/png;base64,${border}` };
  } finally {
    if (host) await host.close();
    await fsp.rm(temp, { recursive: true, force: true });
  }
}

function createServer() {
  return http.createServer(async (req, res) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) {
      try { const html = await fsp.readFile(path.join(__dirname, 'index.html')); res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(html); }
      catch { res.writeHead(404); res.end('Missing index.html'); }
      return;
    }
    if (req.method !== 'POST' || req.url !== '/render') { res.writeHead(404); res.end(); return; }
    const origin = req.headers.origin;
    if ((origin && origin !== `http://${req.headers.host}`) || !/^application\/json\b/i.test(req.headers['content-type'] || '')) {
      res.writeHead(403); res.end('Forbidden'); return;
    }
    try {
      let size = 0; const chunks = [];
      for await (const chunk of req) { size += chunk.length; if (size > MAX_REQUEST) throw new Error('图片过大'); chunks.push(chunk); }
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      const result = await render(body.image, body.format, body.frameNumber, body.filmStock);
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(result));
    } catch (error) {
      res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' }); res.end(JSON.stringify({ error: error.message || '处理失败' }));
    }
  });
}

if (require.main === module) createServer().listen(0, '127.0.0.1', function () {
  const url = `http://127.0.0.1:${this.address().port}/`;
  console.log(url);
  if (process.platform === 'win32') {
    // The URL contains only a loopback address and our own numeric port.
    const browser = spawn('rundll32.exe', ['url.dll,FileProtocolHandler', url],
      { detached: true, stdio: 'ignore', windowsHide: true });
    browser.on('error', () => console.error('无法自动打开浏览器，请手动打开上面的地址。'));
    browser.unref();
  } else if (process.platform === 'darwin') {
    const browser = spawn('/usr/bin/open', [url], { detached: true, stdio: 'ignore' });
    browser.on('error', () => console.error('无法自动打开浏览器，请手动打开上面的地址。'));
    browser.unref();
  }
});

module.exports = { createServer, encodePng, crc32, render };
