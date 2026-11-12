// Локальный просмотр: только файлы публикации, без доступа к документам и .git.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const serveBuild = process.argv.includes('--dist');
const root = serveBuild ? resolve(projectRoot, 'dist', 'course') : projectRoot;
const port = serveBuild ? 4318 : 4317;
const previewFiles = serveBuild ? [] : [
  ['/design/social-card.html', ['design/social-card.html', 'text/html; charset=utf-8']],
  ['/design/variant-b.html', ['design/variant-b.html', 'text/html; charset=utf-8']],
  ['/css/variant-b.css', ['css/variant-b.css', 'text/css; charset=utf-8']],
  ['/images/course-social.svg', ['images/course-social.svg', 'image/svg+xml']]
];
const allowed = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/index.html', ['index.html', 'text/html; charset=utf-8']],
  ['/offer.html', ['offer.html', 'text/html; charset=utf-8']],
  ['/privacy.html', ['privacy.html', 'text/html; charset=utf-8']],
  ['/css/style.css', ['css/style.css', 'text/css; charset=utf-8']],
  ['/css/fonts.css', ['css/fonts.css', 'text/css; charset=utf-8']],
  ...['onest-regular.ttf', 'onest-medium.ttf', 'plex-mono.ttf'].map((file) => ['/fonts/' + file, ['fonts/' + file, 'font/ttf']]),
  ...['OFL-Onest.txt', 'OFL-PlexMono.txt'].map((file) => ['/fonts/' + file, ['fonts/' + file, 'text/plain; charset=utf-8']]),
  ['/js/main.js', ['js/main.js', 'text/javascript; charset=utf-8']],
  ...previewFiles,
  ['/course-schedule.ics', ['course-schedule.ics', 'text/calendar; charset=utf-8']],
  ['/open-meeting.ics', ['open-meeting.ics', 'text/calendar; charset=utf-8']],
  ['/robots.txt', ['robots.txt', 'text/plain; charset=utf-8']],
  ['/sitemap.xml', ['sitemap.xml', 'application/xml; charset=utf-8']],
  ['/calc/', ['calc/index.html', 'text/html; charset=utf-8']],
  ['/calc/index.html', ['calc/index.html', 'text/html; charset=utf-8']],
  ...['course-drawing.svg', 'course-detail.svg', 'course-mark.svg', 'course-social.png', 'course-studio.webp', 'author-work-1280.webp', 'author-work-2400.webp', 'author-portrait-600.webp', 'author-portrait-1200.webp'].map((file) => ['/images/' + file, ['images/' + file, file.endsWith('.png') ? 'image/png' : file.endsWith('.webp') ? 'image/webp' : 'image/svg+xml']])
]);
const server = createServer(async (request, response) => {
  if (!['GET', 'HEAD'].includes(request.method)) {
    response.writeHead(405, { Allow: 'GET, HEAD' }); response.end(); return;
  }
  let url;
  try { url = new URL(request.url, 'http://localhost'); }
  catch { response.writeHead(400); response.end('Bad request'); return; }
  const entry = allowed.get(url.pathname);
  if (!entry) { response.writeHead(404); response.end('Not found'); return; }
  try {
    const bytes = await readFile(resolve(root, entry[0]));
    response.writeHead(200, { 'Content-Type': entry[1], 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', ...(url.searchParams.get('nojs') === '1' ? { 'Content-Security-Policy': "script-src 'none'" } : {}) });
    response.end(request.method === 'HEAD' ? undefined : bytes);
  } catch { response.writeHead(404); response.end('Not found'); }
});
server.listen(port, '127.0.0.1', () => console.log('Local: http://127.0.0.1:' + port));
