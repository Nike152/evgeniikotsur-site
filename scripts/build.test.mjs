// Выпуск должен одинаково собираться из исходников Windows и Linux.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, copyFile, rm, realpath } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const publicFiles = [
  'index.html', 'offer.html', 'css/style.css', 'js/main.js', 'course-schedule.ics',
  'robots.txt', 'sitemap.xml', 'calc/index.html',
  'images/course-mark.svg', 'images/course-drawing.svg',
  'images/course-detail.svg', 'images/course-social.png'
];

test('сборка из LF и CRLF даёт одинаковые файлы и корректный календарь', async (context) => {
  await mkdir(resolve(root, 'dist'), { recursive: true });
  const fixtureParent = await realpath(resolve(root, 'dist'));
  const fixtures = [];
  context.after(async () => {
    for (const fixture of fixtures) {
      const target = await realpath(fixture);
      assert.equal(dirname(target), fixtureParent);
      assert.match(target.slice(fixtureParent.length + 1), /^build-check-/);
      await rm(target, { recursive: true });
    }
  });

  for (const ending of ['\n', '\r\n']) {
    const fixture = await mkdtemp(resolve(fixtureParent, 'build-check-'));
    fixtures.push(fixture);
    await mkdir(resolve(fixture, 'scripts'));
    await copyFile(resolve(root, 'scripts/build.mjs'), resolve(fixture, 'scripts/build.mjs'));
    for (const file of publicFiles) {
      const destination = resolve(fixture, file);
      await mkdir(dirname(destination), { recursive: true });
      let bytes = await readFile(resolve(root, file));
      if (!file.endsWith('.png')) {
        bytes = Buffer.from(bytes.toString('utf8').replace(/\r?\n/g, ending));
      }
      await writeFile(destination, bytes);
    }
    execFileSync(process.execPath, [resolve(fixture, 'scripts/build.mjs')], { cwd: fixture });
  }

  for (const file of publicFiles) {
    const first = await readFile(resolve(fixtures[0], 'dist/course', file));
    const second = await readFile(resolve(fixtures[1], 'dist/course', file));
    assert.deepEqual(first, second, file + ' зависит от системы сборки');
    if (file.endsWith('.png')) {
      assert.deepEqual(first, await readFile(resolve(root, file)), 'PNG изменился при сборке');
    }
  }
  const calendar = await readFile(resolve(fixtures[0], 'dist/course/course-schedule.ics'), 'utf8');
  assert.ok(calendar.includes('\r\n'), 'В календаре отсутствуют CRLF');
  assert.ok(!calendar.replaceAll('\r\n', '').includes('\n'), 'В календаре остались одиночные LF');
  assert.equal(calendar.match(/BEGIN:VEVENT/g).length, 5);
});
