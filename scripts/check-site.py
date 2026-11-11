"""Проверка файлов публикации и согласованности календаря без внешних сервисов."""
from collections import Counter
from datetime import datetime
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit, unquote
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
VOID = {'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr'}


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.nodes = []
        self.stack = []

    def handle_starttag(self, tag, attrs):
        self.nodes.append((tag, dict(attrs)))
        if tag not in VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        assert self.stack and self.stack[-1] == tag, f'Неверное закрытие: {tag}'
        self.stack.pop()


def check_page(filename):
    source = (ROOT / filename).read_text(encoding='utf-8')
    page = Page()
    page.feed(source)
    assert not page.stack, f'{filename}: незакрытые элементы: {page.stack}'
    ids = [attrs['id'] for _, attrs in page.nodes if 'id' in attrs]
    assert all(count == 1 for count in Counter(ids).values()), f'{filename}: повторяющиеся id'
    assert sum(tag == 'h1' for tag, _ in page.nodes) == 1, f'{filename}: нужен один главный заголовок'

    references = 0
    for tag, attrs in page.nodes:
        for name in ['href', 'src']:
            if name not in attrs:
                continue
            link = urlsplit(attrs[name])
            if link.scheme:
                assert link.scheme in {'https', 'mailto'}, 'Недопустимая схема ссылки'
            elif link.path:
                target = (ROOT / unquote(link.path).lstrip('/')).resolve()
                assert target.is_relative_to(ROOT) and target.is_file(), f'Нет файла: {link.path}'
                references += 1
            elif link.fragment:
                assert unquote(link.fragment) in ids, f'{filename}: нет якоря: {link.fragment}'
                references += 1
        if tag == 'img':
            assert attrs.get('alt') and attrs.get('width') and attrs.get('height'), 'Изображение без описания или размеров'
        if attrs.get('target') == '_blank':
            assert {'noopener', 'noreferrer'} <= set(attrs.get('rel', '').split()), 'Новая вкладка без защиты'
        if 'aria-labelledby' in attrs:
            assert all(item in ids for item in attrs['aria-labelledby'].split()), 'Неверная подпись раздела'
    assert not any(tag == 'script' and not attrs.get('src') for tag, attrs in page.nodes), 'Найден встроенный скрипт'
    return source, page, references


source, page, references = check_page('index.html')
offer_source, _, offer_references = check_page('offer.html')
references += offer_references
privacy_source, _, privacy_references = check_page('privacy.html')
references += privacy_references

assert all(text in source for text in ['19 900', '24 900', '2026-11-21T10:00:00+03:00', '2026-11-28T10:00:00+03:00', '26 июня 2027']), 'Не совпадают подтверждённые условия'
assert '23 ноября' not in source, 'В лендинге осталась прежняя дата старта'
assert 'drive.google.com' not in source, 'Платные материалы не должны быть публичной ссылкой'
assert 'Черновик' not in offer_source and 'для утверждения' not in offer_source, 'В публичную оферту попали служебные пометки'
assert 'Черновик' not in privacy_source and 'для утверждения' not in privacy_source, 'В публичную политику попали служебные пометки'

for file in (ROOT / 'images').glob('course-*.svg'):
    ET.parse(file)
ET.parse(ROOT / 'sitemap.xml')

calendar_bytes = (ROOT / 'course-schedule.ics').read_bytes()
assert b'\r\n' in calendar_bytes, 'Календарь должен использовать CRLF'
assert all(len(line) <= 75 for line in calendar_bytes.split(b'\r\n')), 'Слишком длинная строка календаря'
calendar = calendar_bytes.decode('utf-8').replace('\r\n ', '')
assert calendar.count('BEGIN:VEVENT') == 5, 'В календаре должно быть пять занятий'
starts = [datetime.strptime(line[8:], '%Y%m%dT%H%M%SZ') for line in calendar.splitlines() if line.startswith('DTSTART:')]
ends = [datetime.strptime(line[6:], '%Y%m%dT%H%M%SZ') for line in calendar.splitlines() if line.startswith('DTEND:')]
assert starts[0] == datetime(2026, 11, 28, 7) and starts[-1] == datetime(2026, 12, 26, 7), 'Неверные даты календаря'
assert len({line for line in calendar.splitlines() if line.startswith('UID:')}) == 5, 'UID занятий должны различаться'
assert all(start.weekday() == 5 and start.hour == 7 and (end-start).total_seconds() == 10800 for start, end in zip(starts, ends)), 'Неверное время или длительность занятия'
assert all((b-a).days == 7 for a, b in zip(starts, starts[1:])), 'Занятия должны быть еженедельными'
print(f'Проверено: HTML, {references} внутренних ссылок, SVG, карта сайта, условия и календарь пяти занятий.')
