"""Проверки резервирования на Linux с вымышленными XLSX в отдельных каталогах."""

from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import importlib.util
from io import BytesIO
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/backup-course-registry.py'
spec = importlib.util.spec_from_file_location('registry_backup', SCRIPT)
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)
NOW = datetime(2026, 11, 14, 19, 0, tzinfo=timezone.utc)


def sample_xlsx():
    stream = BytesIO()
    with zipfile.ZipFile(stream, 'w') as archive:
        for name in ('[Content_Types].xml', 'xl/workbook.xml',
                     'xl/worksheets/sheet1.xml', 'xl/worksheets/sheet2.xml',
                     'xl/worksheets/sheet3.xml'):
            archive.writestr(name, '<synthetic-test/>')
    return stream.getvalue()


class RegistryBackupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='course-registry-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.base.chmod(0o700)
        (self.base / 'backups').mkdir(mode=0o700)
        self.daily = self.base / 'backups/daily'
        self.daily.mkdir(mode=0o700)
        self.source = self.base / 'registry.xlsx'
        self.data = sample_xlsx()
        self.source.write_bytes(self.data)
        self.source.chmod(0o600)

    def seed_old(self):
        for number in range(20):
            old = NOW - timedelta(days=30 + number)
            path = self.daily / ('registry-' + old.strftime('%Y%m%dT%H%M%SZ-') + f'{number:08x}.xlsx')
            path.write_bytes(self.data)
            path.chmod(0o600)

    def copies(self):
        return [p for p in self.daily.iterdir() if backup.NAME.fullmatch(p.name)]

    def test_snapshot_preserves_source_and_permissions(self):
        original = self.source.stat()
        result = backup.snapshot(self.base, now=NOW)
        copied = self.daily / result['snapshot']
        self.assertEqual(copied.read_bytes(), self.data)
        self.assertEqual(stat.S_IMODE(copied.stat().st_mode), 0o600)
        self.assertEqual(self.source.stat().st_mtime_ns, original.st_mtime_ns)
        self.assertEqual(self.source.read_bytes(), self.data)
        self.assertEqual(result['sha256'], hashlib.sha256(self.data).hexdigest())
        self.assertFalse(result['prune_enabled'])

    def test_two_runs_create_separate_files(self):
        first = backup.snapshot(self.base, now=NOW)
        second = backup.snapshot(self.base, now=NOW)
        self.assertNotEqual(first['snapshot'], second['snapshot'])
        self.assertEqual(len(self.copies()), 2)

    def test_bad_xlsx_preserves_existing_copies(self):
        self.seed_old()
        self.source.write_bytes(b'not an xlsx')
        with self.assertRaises(zipfile.BadZipFile):
            backup.snapshot(self.base, now=NOW, prune_days=14)
        self.assertEqual(len(self.copies()), 20)

    def test_open_permissions_are_rejected(self):
        self.source.chmod(0o644)
        with self.assertRaises(ValueError):
            backup.snapshot(self.base, now=NOW)
        self.assertEqual(self.copies(), [])

    def test_source_symlink_is_rejected(self):
        self.source.rename(self.base / 'original.xlsx')
        self.source.symlink_to(self.base / 'original.xlsx')
        with self.assertRaises(ValueError):
            backup.snapshot(self.base, now=NOW)
        self.assertEqual(self.copies(), [])

    def test_destination_symlink_is_rejected(self):
        self.daily.rename(self.base / 'original-daily')
        self.daily.symlink_to(self.base / 'original-daily', target_is_directory=True)
        with self.assertRaises(ValueError):
            backup.snapshot(self.base, now=NOW)

    def test_parallel_run_is_rejected(self):
        lock = self.daily / '.backup.lock'
        fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                backup.snapshot(self.base, now=NOW)
        finally:
            os.close(fd)
        self.assertEqual(self.copies(), [])

    def test_existing_filename_is_not_overwritten(self):
        existing = self.daily / ('registry-' + NOW.strftime('%Y%m%dT%H%M%SZ-') + 'deadbeef.xlsx')
        existing.write_bytes(self.data)
        existing.chmod(0o600)
        with patch.object(backup.uuid, 'uuid4') as identifier:
            identifier.return_value.hex = 'deadbeef' * 4
            with self.assertRaises(FileExistsError):
                backup.snapshot(self.base, now=NOW)
        self.assertEqual(existing.read_bytes(), self.data)
        self.assertEqual(len(self.copies()), 1)
        self.assertEqual(list(self.daily.glob('.pending-*')), [])

    def test_default_never_prunes(self):
        self.seed_old()
        result = backup.snapshot(self.base, now=NOW)
        self.assertEqual(len(self.copies()), 21)
        self.assertEqual(result['deleted'], 0)
        self.assertEqual(result['old_candidates'], 7)

    def test_explicit_pruning_keeps_fourteen_and_unrelated_file(self):
        self.seed_old()
        unrelated = self.daily / 'manual-keep.xlsx'
        unrelated.write_bytes(b'not a managed snapshot')
        result = backup.snapshot(self.base, now=NOW, prune_days=14)
        self.assertEqual(result['deleted'], 7)
        self.assertEqual(len(self.copies()), 14)
        self.assertEqual(unrelated.read_bytes(), b'not a managed snapshot')
        self.assertEqual(self.source.read_bytes(), self.data)

    def test_bad_retention_is_rejected_before_writing(self):
        with self.assertRaises(ValueError):
            backup.snapshot(self.base, now=NOW, prune_days=0)
        self.assertEqual(self.copies(), [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
