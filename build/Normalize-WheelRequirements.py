"""Replace direct source references with the identity of their built wheel."""
from email.parser import BytesParser
from pathlib import Path
import re
import sys
import zipfile


def normalize(requirements, wheelhouse, destination):
    versions = {}
    for path in wheelhouse.glob('*.whl'):
        with zipfile.ZipFile(path) as wheel:
            metadata = BytesParser().parsebytes(wheel.read(next(
                name for name in wheel.namelist() if name.endswith('.dist-info/METADATA'))))
        versions[re.sub(r'[-_.]+', '-', metadata['Name']).lower()] = metadata['Version']
    lines = []
    for line in requirements.read_text(encoding='utf-8-sig').splitlines():
        match = re.match(r'^([A-Za-z0-9_.-]+)\s*@\s*\S+(.*)$', line)
        if match:
            name = re.sub(r'[-_.]+', '-', match[1]).lower()
            line = f'{name}=={versions[name]}{match[2]}'
        lines.append(line)
    destination.write_text('\n'.join(lines) + '\n', encoding='utf-8')


if __name__ == '__main__':
    normalize(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
