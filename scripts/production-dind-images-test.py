"""Exercise DinD retention across releases, retries and bounded filesystems."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('images', Path(__file__).resolve().parents[1] / 'deploy/production-dind-images.py')
images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(images)
GIB = 1024 ** 3


class RetentionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.data = self.root / 'bounded-dind'
        self.data.mkdir()
        self.state = self.root / 'deployed-images.json'
        self.host = 'unix:///run/dind/docker.sock'
        self.host_images = {}
        self.inner = {}
        self.containers = []
        self.removed = []
        self.free = 12 * GIB
        self.inodes = 100000
        self.checked = []
        self.current = self.add_image(1)
        self.previous = self.add_image(2)
        self.target = self.add_image(3, loaded=False)
        self.startup = self.current
        self.race = False
        self.enterContext(patch.object(images, 'docker', self.docker))
        self.enterContext(patch.object(images.os, 'statvfs', self.statvfs))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def add_image(self, number, loaded=True, tag=None, revision=None):
        revision = revision or f'{number:040x}'
        # Real release tags use the prefix, which must be distinct in this fixture.
        revision = f'{number:012x}' + revision[-28:]
        reference = tag or 'moonhub-runner:' + revision[:12]
        image = {'Id': 'sha256:' + revision, 'Size': 2 * GIB, 'RepoTags': [reference],
                 'Config': {'Labels': {'org.opencontainers.image.revision': revision}}}
        self.host_images[reference] = image
        if loaded:
            self.inner[reference] = image
        return reference

    def statvfs(self, directory):
        self.checked.append(directory)
        # The host has abundant space; only the actual DinD mount is bounded.
        return types.SimpleNamespace(f_bavail=self.free if directory == str(self.data) else 1000 * GIB,
                                     f_frsize=1, f_favail=self.inodes)

    def docker(self, args, host=None):
        if host is None:
            if args == ['ps', '-q']:
                return 'daemon'
            if args == ['inspect', 'daemon']:
                return json.dumps([{'Config': {'Hostname': 'dedicated-dind'}, 'Mounts': [
                    {'Source': '/run/dind', 'Destination': '/run/dind'},
                    {'Source': str(self.data), 'Destination': '/var/lib/docker'}]}])
        else:
            self.assertEqual(host, self.host)
            if args == ['info', '--format', '{{json .}}']:
                return json.dumps({'Name': 'dedicated-dind', 'DockerRootDir': '/var/lib/docker'})
            if args == ['ps', '-aq']:
                return '\n'.join(str(index) for index in range(len(self.containers)))
            if args[0] == 'inspect':
                return json.dumps([{'Image': self.inner[self.containers[int(index)]]['Id']} for index in args[1:]])
            if args[:2] == ['image', 'ls']:
                if '--no-trunc' in args:
                    return '\n'.join(image['Id'] for image in self.inner.values())
                return '\n'.join(self.inner)
            if args[:2] == ['image', 'rm']:
                self.assertEqual(len(args), 3, 'retention must never force removal')
                if self.race:
                    raise subprocess.CalledProcessError(1, ['docker', *args])
                self.removed.append(args[2])
                self.inner.pop(args[2])
                self.free += GIB
                return ''
        if args[:2] == ['image', 'inspect']:
            source = self.inner if host else self.host_images
            result = []
            for reference in args[2:]:
                found = source.get(reference) or next((image for image in source.values() if image['Id'] == reference), None)
                if found is None:
                    raise subprocess.CalledProcessError(1, ['docker', *args])
                result.append(found)
            return json.dumps(result)
        self.fail(f'Unexpected Docker operation: {host}, {args}')

    def journal(self, current=None, previous=None):
        images.save_state(str(self.state), current or self.current, previous or self.previous)

    def run_policy(self, operation):
        arguments = ['images.py', operation, '--socket', self.host, '--image', self.target,
                     '--current', self.current, '--startup', self.startup, '--state', str(self.state)]
        with patch('sys.argv', arguments):
            images.main()

    def test_first_upgrade_preserves_unknown_recovery_until_verified_commit(self):
        obsolete = self.add_image(4)
        self.run_policy('prepare')
        self.assertFalse(self.removed)
        self.assertFalse(self.state.exists())
        self.inner[self.target] = self.host_images[self.target]
        self.run_policy('commit')
        self.assertEqual(set(self.inner), {self.target, self.current})
        self.assertIn(obsolete, self.removed)
        self.assertEqual(json.loads(self.state.read_text()),
                         {'format': 1, 'current': self.target, 'previous': self.current})
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)

    def test_repeated_deployments_and_retries_keep_current_and_previous(self):
        self.journal()
        self.add_image(4)
        for number in range(5, 10):
            self.target = self.add_image(number, loaded=False)
            self.startup = self.current
            self.run_policy('prepare')
            self.assertEqual(set(self.inner), {self.current, self.previous})
            self.inner[self.target] = self.host_images[self.target]
            self.run_policy('commit')
            old_current = self.current
            self.assertEqual(set(self.inner), {self.target, old_current})
            self.current = self.target
            self.startup = self.current
            self.run_policy('prepare')
            self.run_policy('commit')
            self.assertEqual(json.loads(self.state.read_text())['previous'], old_current)
            self.assertEqual(set(self.inner), {self.current, old_current})
            self.previous = old_current

    def test_preimport_cleanup_reclaims_space_without_removing_candidate(self):
        self.journal()
        obsolete = self.add_image(4)
        self.inner[self.target] = self.host_images[self.target]
        self.free = GIB // 2
        self.run_policy('prepare')
        self.assertEqual(self.removed, [obsolete])
        self.assertIn(self.target, self.inner)
        self.assertEqual(self.checked, [str(self.data)])

    def test_in_use_images_unrelated_repositories_and_mismatched_labels_are_preserved(self):
        self.journal()
        in_use = self.add_image(4)
        self.containers = [in_use]
        unrelated = self.add_image(5, tag='another-project:latest')
        unlabelled = self.add_image(6)
        self.inner[unlabelled]['Config']['Labels'] = None
        mismatched = self.add_image(7, tag='moonhub-runner:ffffffffffff')
        self.run_policy('prepare')
        self.assertFalse(self.removed)
        self.assertTrue({in_use, unrelated, unlabelled, mismatched}.issubset(self.inner))

    def test_low_bytes_or_inodes_stop_before_import_and_preserve_journal(self):
        self.journal()
        before = self.state.read_bytes()
        for free, inodes in [(4 * GIB, 100000), (12 * GIB, 100)]:
            with self.subTest(free=free, inodes=inodes):
                self.free, self.inodes = free, inodes
                with self.assertRaisesRegex(ValueError, 'Insufficient DinD'):
                    self.run_policy('prepare')
                self.assertEqual(self.state.read_bytes(), before)
                self.assertFalse(self.removed)
                self.assertTrue(self.checked and all(path == str(self.data) for path in self.checked))

    def test_status_never_prunes_and_same_tag_with_wrong_revision_needs_import_space(self):
        self.journal()
        self.add_image(4)
        self.run_policy('check')
        self.assertFalse(self.removed)
        self.inner[self.target] = {**self.host_images[self.target], 'Config': {'Labels': {
            'org.opencontainers.image.revision': 'f' * 40}}}
        self.free = 2 * GIB
        with self.assertRaisesRegex(ValueError, 'Insufficient DinD'):
            self.run_policy('check')
        self.assertFalse(self.removed)

    def test_corrupt_state_and_changed_configuration_do_not_prune_recovery(self):
        obsolete = self.add_image(4)
        self.state.write_text('{"format":1}')
        with self.assertRaisesRegex(ValueError, 'Invalid image retention'):
            self.run_policy('prepare')
        self.assertFalse(self.removed)
        self.journal(current=obsolete)
        self.run_policy('prepare')
        self.assertFalse(self.removed)

    def test_unknown_data_mount_is_rejected_and_concurrent_references_are_not_forced(self):
        self.journal()
        self.add_image(4)
        real_docker = self.docker
        with patch.object(images, 'docker', lambda args, host=None: '[]' if host is None and args[0] == 'inspect' else real_docker(args, host)):
            with self.assertRaisesRegex(ValueError, 'resolve the DinD data mount'):
                self.run_policy('prepare')
        self.assertFalse(self.removed)
        self.race = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_policy('prepare')
        self.assertFalse(self.removed)


if __name__ == '__main__':
    unittest.main()
