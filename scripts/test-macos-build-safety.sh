#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repo_root" <<'PY'
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile

source = Path(sys.argv[1])
archive_name = 'DragonCodexBoot-0.2.0-macos-arm64-with-video.zip'
with tempfile.TemporaryDirectory(prefix='dragon-macos-build-safety.', dir='/private/tmp') as temporary:
    root = Path(temporary)
    template = root / 'template'
    (template / 'scripts').mkdir(parents=True)
    for script in source.glob('scripts/*macos*.sh'):
        shutil.copy2(script, template / 'scripts' / script.name)
    inputs = [
        'src/macos/Info.plist', 'src/macos/PlaybackProgressWatchdog.swift',
        'src/macos/main.swift', 'src/macos/icon.swift',
        'macos/Sources/DragonCodexBootCore/TrustedApplication.swift',
        'macos/Sources/DragonCodexBootCore/LauncherConfiguration.swift',
        'macos/Sources/DragonCodexBootMac/main.swift',
        'docs/MACOS-STANDALONE.md', 'config/launcher.macos.example.json',
        'media/MEDIA_NOTICE.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
    ]
    for relative in inputs:
        destination = template / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / relative, destination)
    (template / 'VERSION').write_text('0.2.0\n')
    (template / 'media/startup.mp4').write_bytes(b'public media fixture\n')
    binary = root / 'bin'
    binary.mkdir()
    (binary / 'swiftc').write_text('''#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
Path(os.environ['MACOS_BUILD_TEST_EVENT']).write_text('compiler reached')
if os.environ.get('MACOS_BUILD_TEST_REJECT') == '1': sys.exit(77)
output = sys.argv[sys.argv.index('-o') + 1]
shutil.copyfile('/bin/echo', output)
os.chmod(output, 0o755)
''')
    (binary / 'xcrun').write_text('''#!/usr/bin/env python3
import os, sys
from pathlib import Path
if sys.argv[1] == 'swiftc':
    os.execv(str(Path(__file__).parent / 'swiftc'), ['swiftc'] + sys.argv[2:])
elif sys.argv[1] == 'swift':
    Path(sys.argv[-1] + '.icns').write_bytes(b'icon fixture')
else: sys.exit(99)
''')
    for command in binary.iterdir(): command.chmod(0o755)
    environment = os.environ.copy()
    environment.update(PATH=str(binary) + os.pathsep + environment['PATH'],
                       MACOS_SIGNING_IDENTITY='', MACOS_NOTARY_PROFILE='')
    event = root / 'event'
    environment['MACOS_BUILD_TEST_EVENT'] = str(event)
    victim = root / 'outside-checkout'
    victim.mkdir()
    secret = victim / 'private.txt'
    secret.write_bytes(b'private data must not be read or changed\n')

    def fresh():
        checkout = root / 'checkout'
        if checkout.exists(): shutil.rmtree(checkout)
        shutil.copytree(template, checkout)
        event.unlink(missing_ok=True)
        return checkout

    def invoke(checkout, entry='package-macos.sh', arguments=(), reject=False, permissive_umask=False):
        current = environment.copy()
        current['MACOS_BUILD_TEST_REJECT'] = '1' if reject else '0'
        return subprocess.run(['bash', str(checkout / 'scripts' / entry), *arguments],
                              env=current, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT,
                              preexec_fn=(lambda: os.umask(0)) if permissive_umask else None)

    def rejected(checkout, entry='package-macos.sh', arguments=()):
        result = invoke(checkout, entry, arguments, reject=True)
        assert result.returncode != 0, result.stdout
        assert not event.exists(), 'Unsafe input reached compiler:\n' + result.stdout
        assert secret.read_bytes() == b'private data must not be read or changed\n'

    # Every copied fixed input, including the optional integration media, rejects links.
    for variant, linked_inputs in [
        ('standalone', ['media/startup.mp4', 'src/macos/Info.plist', 'LICENSE',
                        'THIRD_PARTY_NOTICES.md', 'media/MEDIA_NOTICE.md',
                        'docs/MACOS-STANDALONE.md', 'VERSION']),
        ('integration', ['media/startup.mp4', 'config/launcher.macos.example.json',
                         'LICENSE', 'THIRD_PARTY_NOTICES.md', 'media/MEDIA_NOTICE.md']),
    ]:
        for relative in linked_inputs:
            checkout = fresh()
            target = checkout / relative
            target.unlink()
            target.symlink_to(secret)
            rejected(checkout, arguments=('--variant', variant))
    for variant in ['standalone', 'integration']:
        checkout = fresh()
        (checkout / 'media/startup.mp4').unlink()
        (checkout / 'media/startup.mp4').symlink_to(victim / 'missing.mp4')
        rejected(checkout, arguments=('--variant', variant))
        checkout = fresh()
        shutil.rmtree(checkout / 'media')
        (checkout / 'media').symlink_to(victim, target_is_directory=True)
        rejected(checkout, arguments=('--variant', variant))

    # Native rm/cp must not touch output ancestors or app links outside the checkout.
    for bad_output in ['build', 'build/macos', 'build/macos/Dragon Codex Boot.app',
                       'build/DragonCodexBoot.app']:
        checkout = fresh()
        target = checkout / bad_output
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(victim, target_is_directory=True)
        entry = 'build-macos.sh' if bad_output.endswith('DragonCodexBoot.app') else 'build-macos-standalone.sh'
        rejected(checkout, entry)
    checkout = fresh()
    (checkout / 'build/macos').mkdir(parents=True)
    (checkout / 'build/macos/DragonCodexBootMac').symlink_to(secret)
    rejected(checkout, 'build-macos.sh')
    for directory in ['build', 'build/macos', 'dist']:
        checkout = fresh()
        target = checkout / directory
        target.mkdir(parents=True)
        target.chmod(0o777)
        rejected(checkout)
        target.chmod(0o755)
    checkout = fresh()
    (checkout / 'dist').symlink_to(victim, target_is_directory=True)
    rejected(checkout)

    # Existing ZIP/hash directories and links must fail before building or publishing.
    for output in [archive_name, archive_name + '.sha256']:
        for kind in ['directory', 'link', 'dangling-link']:
            checkout = fresh()
            target = checkout / 'dist' / output
            target.parent.mkdir()
            if kind == 'directory': target.mkdir()
            else: target.symlink_to(secret if kind == 'link' else victim / 'missing')
            rejected(checkout)

    # Real filesystem/codesign/ditto packaging, with only compiler/icon substitutes.
    checkout = fresh()
    for variant, output in [('standalone', archive_name),
                            ('integration', 'DragonCodexBoot-0.2.0-macos-' + os.uname().machine + '-integration.zip')]:
        result = invoke(checkout, arguments=('--variant', variant, '--mode', 'local'), permissive_umask=True)
        assert result.returncode == 0, result.stdout
        archive = checkout / 'dist' / output
        with zipfile.ZipFile(archive) as packaged:
            member = ('Dragon Codex Boot.app/Contents/Resources/startup.mp4' if variant == 'standalone'
                      else 'DragonCodexBoot.app/Contents/Resources/media/startup.mp4')
            assert packaged.read(member) == b'public media fixture\n'
        subprocess.run(['shasum', '-a', '256', '-c', output + '.sha256'],
                       cwd=checkout / 'dist', check=True)
    for directory in [checkout / 'build', checkout / 'dist',
                      *[candidate for candidate in (checkout / 'build').rglob('*') if candidate.is_dir()]]:
        assert directory.stat().st_mode & 0o077 == 0, 'Caller umask exposed build directory: ' + str(directory)

    # A failed second publish must restore the previous matching archive/hash pair.
    previous_archive = (checkout / 'dist' / archive_name).read_bytes()
    previous_hash = (checkout / 'dist' / (archive_name + '.sha256')).read_bytes()
    (checkout / 'media/startup.mp4').write_bytes(b'updated public media fixture\n')
    (binary / 'mv').write_text('''#!/usr/bin/env bash
if [[ "$1" == -f && "$2" == *.zip.sha256 ]]; then exit 88; fi
exec /bin/mv "$@"
''')
    (binary / 'mv').chmod(0o755)
    result = invoke(checkout)
    assert result.returncode != 0, result.stdout
    assert (checkout / 'dist' / archive_name).read_bytes() == previous_archive
    assert (checkout / 'dist' / (archive_name + '.sha256')).read_bytes() == previous_hash
    subprocess.run(['shasum', '-a', '256', '-c', archive_name + '.sha256'],
                   cwd=checkout / 'dist', check=True)
    assert not list((checkout / 'dist').glob('.macos-package-*'))
    print('PASS: linked inputs, unsafe output parents and invalid ZIP/hash targets rejected; both app variants package normally.')
PY
