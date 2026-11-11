// В публикацию попадает только явный список общедоступных файлов.
import { mkdir, copyFile, readdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const files = [
  'index.html', 'offer.html', 'privacy.html', 'css/style.css', 'js/main.js', 'course-schedule.ics',
  'robots.txt', 'sitemap.xml', 'calc/index.html',
  'images/course-mark.svg', 'images/course-drawing.svg',
  'images/course-detail.svg', 'images/course-social.png'
];
const output = resolve(root, 'dist', 'course');
// Не публикуем случайно оставленные файлы и не удаляем их автоматически.
async function checkExisting(directory, prefix = '') {
  let entries;
  try { entries = await readdir(directory, { withFileTypes: true }); }
  catch (error) { if (error.code === 'ENOENT') return; throw error; }
  for (const entry of entries) {
    const name = prefix + entry.name;
    if (entry.isSymbolicLink()) throw new Error('Ссылка в папке публикации: ' + name);
    if (entry.isDirectory()) await checkExisting(resolve(directory, entry.name), name + '/');
    else if (!files.includes(name)) throw new Error('Посторонний файл в папке публикации: ' + name);
  }
}
await checkExisting(output);
for (const file of files) {
  const destination = resolve(output, file);
  await mkdir(dirname(destination), { recursive: true });
  if (file.endsWith('.png')) {
    await copyFile(resolve(root, file), destination);
  } else {
    let content = (await readFile(resolve(root, file), 'utf8')).replace(/\r\n/g, '\n');
    if (file.endsWith('.ics')) content = content.replace(/\n/g, '\r\n');
    await writeFile(destination, content, 'utf8');
  }
}
console.log('Готовая папка публикации: ' + output);
console.log('Файлов: ' + files.length);
