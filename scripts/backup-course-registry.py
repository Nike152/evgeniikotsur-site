"""Закрытые снимки реестра: без изменения источника и удаления по умолчанию."""

import argparse
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
from io import BytesIO
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import uuid
import zipfile

BASE = Path('/var/lib/course-admin/2026-11-28')
NAME = re.compile(r'^registry-(\d{8}T\d{6}Z)-[0-9a-f]{8}\.xlsx$')
MAX_BYTES = 20 * 1024 * 1024


def closed_path(path, directory=False):
    """Не следуем ссылкам и не принимаем открытые другим пользователям файлы."""
    info = path.lstat()
    expected = 0o700 if directory else 0o600
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (not kind(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != expected or path.resolve() != path):
        raise ValueError('Неподходящий тип, владелец, путь или права: ' + path.name)
    return info


def check_xlsx(data):
    if not data or len(data) > MAX_BYTES:
        raise ValueError('Пустой или слишком большой реестр')
    with zipfile.ZipFile(BytesIO(data)) as archive:
        if sum(entry.file_size for entry in archive.infolist()) > MAX_BYTES:
            raise ValueError('Слишком большой распакованный реестр')
        expected = {'[Content_Types].xml', 'xl/workbook.xml'}
        expected.update(f'xl/worksheets/sheet{i}.xml' for i in (1, 2, 3))
        if not expected.issubset(archive.namelist()) or archive.testzip() is not None:
            raise ValueError('Повреждённый XLSX или отсутствуют ожидаемые листы')


def eligible_copies(directory, now, days):
    """Отбираем только собственные датированные снимки; сохраняем минимум 14."""
    copies = []
    for path in directory.iterdir():
        match = NAME.fullmatch(path.name)
        if not match:
            continue
        closed_path(path)
        created = datetime.strptime(match[1], '%Y%m%dT%H%M%SZ').replace(tzinfo=timezone.utc)
        copies.append((created, path.name, path))
    copies.sort(reverse=True)
    cutoff = now - timedelta(days=days)
    return [path for created, _, path in copies[14:] if created < cutoff]


def snapshot(base=BASE, now=None, prune_days=None):
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None or (prune_days is not None and not 1 <= prune_days <= 3650):
        raise ValueError('Неверная дата или срок хранения')
    now = now.astimezone(timezone.utc)
    base = Path(base)
    closed_path(base, directory=True)
    closed_path(base / 'backups', directory=True)
    directory = base / 'backups/daily'
    closed_path(directory, directory=True)
    source = base / 'registry.xlsx'
    original = closed_path(source)
    lock_fd = os.open(directory / '.backup.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        closed_path(directory / '.backup.lock')
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            if before.st_ino != original.st_ino or before.st_dev != original.st_dev:
                raise RuntimeError('Реестр изменён перед чтением')
            data = stream.read(MAX_BYTES + 1)
            after = os.fstat(stream.fileno())
        current = closed_path(source)
        if ((before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns)
                or (before.st_ino, before.st_dev, before.st_mtime_ns)
                != (current.st_ino, current.st_dev, current.st_mtime_ns)):
            raise RuntimeError('Реестр изменяется: повторите копирование после сохранения')
        check_xlsx(data)
        digest = hashlib.sha256(data).hexdigest()
        filename = 'registry-' + now.strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8] + '.xlsx'
        target = directory / filename
        temp_fd, temp_name = tempfile.mkstemp(prefix='.pending-', dir=directory)
        temporary = Path(temp_name)
        try:
            with os.fdopen(temp_fd, 'wb') as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            closed_path(temporary)
            copied = temporary.read_bytes()
            check_xlsx(copied)
            if hashlib.sha256(copied).hexdigest() != digest:
                raise RuntimeError('Контрольная сумма копии не совпала')
            # Жёсткая ссылка создаёт готовый файл атомарно и не заменяет существующий.
            os.link(temporary, target, follow_symlinks=False)
        finally:
            temporary.unlink(missing_ok=True)
        candidates = eligible_copies(directory, now, prune_days or 14)
        deleted = 0
        if prune_days is not None:
            for path in candidates:
                closed_path(path)
                path.unlink()
                deleted += 1
        directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        return {'snapshot': filename, 'bytes': len(data), 'sha256': digest,
                'source_modified': False, 'prune_enabled': prune_days is not None,
                'retention_days': prune_days, 'old_candidates': len(candidates), 'deleted': deleted}
    finally:
        os.close(lock_fd)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prune-days', type=int, default=None,
                        help='Явно включить удаление старых снимков после согласования срока')
    arguments = parser.parse_args()
    print(json.dumps(snapshot(prune_days=arguments.prune_days), ensure_ascii=False))
