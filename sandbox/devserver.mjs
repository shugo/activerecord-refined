// Static server for local use.  It also accepts a POST to /__result so a
// headless browser running browser-check.html can report back.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, normalize, join } from 'node:path';

const PORT = Number(process.env.PORT ?? 8000);
const ROOT = process.cwd();

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.rb': 'text/plain; charset=utf-8',
  '.wasm': 'application/wasm',
};

createServer(async (req, res) => {
  if (req.url === '/__result') {
    let body = '';
    for await (const chunk of req) body += chunk;
    console.log('RESULT ' + body);
    res.writeHead(204).end();
    return;
  }

  const rel = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(/^(\.\.[/\\])+/, '');
  const path = join(ROOT, rel === '/' ? 'index.html' : rel);

  try {
    const data = await readFile(path);
    res.writeHead(200, { 'Content-Type': TYPES[extname(path)] ?? 'application/octet-stream' });
    res.end(data);
  } catch {
    res.writeHead(404).end('not found');
  }
}).listen(PORT, () => console.log(`listening on http://localhost:${PORT}`));
