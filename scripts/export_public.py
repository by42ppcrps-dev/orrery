#!/usr/bin/env python3
"""Build a history-free public source package from an explicit source allowlist.
Never includes the checkout's local docs, credentials, build outputs or screenshots.
Errors identify file/category only; matching secret values are never printed.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {'Package.swift', 'LICENSE', 'CONTRIBUTING.md', 'CODE_OF_CONDUCT.md', 'SECURITY.md', 'build-app.sh', 'Install.command', '.orrery-gate.json'}
TREES = {'Sources', 'Tests', 'Resources', 'Remote', '.github', 'scripts', 'public'}
SKIP_PARTS = {'.git', '.build', 'build', '.swiftpm', '__pycache__', 'DerivedData', 'xcuserdata', '.DS_Store', 'node_modules', '.wrangler'}
EXTENSIONS = {'.swift', '.py', '.sh', '.md', '.yml', '.yaml', '.json', '.plist', '.pbxproj', '.xcscheme', '.icns', '.png', '.xcprivacy', '.js', '.toml'}
CODE_EXTENSIONS = {'Sources': {'.swift'}, 'Tests': {'.swift', '.py'}, 'scripts': {'.py', '.sh'}}
PUBLIC_ASSETS = {'Resources/AppIcon.icns', 'Remote/OrreryRemote/OrreryRemote/Assets.xcassets/AppIcon.appiconset/icon-1024.png'}
PATTERNS = {
    'private-home-path': re.compile(r'/' + r'Users/(?!Shared(?:/|\b)|someone(?:/|\b)|developer(?:/|\b)|me(?:/|\b))[^/\s"\']+'),
    'private-key': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'provider-token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}|xai-[A-Za-z0-9_-]{32,})\b'),
    'personal-signing-team': re.compile(r'(?:DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}|<key>teamID</key>\s*<string>[A-Z0-9]{10}</string>|TeamIdentifier=[A-Z0-9]{10})'),
    'embedded-signing-identity': re.compile(r'Apple (?:Development|Distribution): [^"\n]+\([A-Z0-9]{10}\)'),
    'credential-url': re.compile(r'https?://[^/\s"\']+:[^/\s"\']+@'),
}

def source_paths(root):
    for name in sorted(ROOT_FILES):
        path = root/name
        if not path.is_file() or path.is_symlink(): raise ValueError('Missing or unsafe required source: '+name)
        yield path
    for name in sorted(TREES):
        for path in sorted((root/name).rglob('*')):
            relative = path.relative_to(root)
            if any(part in SKIP_PARTS for part in relative.parts): continue
            if path.is_symlink(): raise ValueError('Symbolic link is not allowed: '+str(relative))
            if name in CODE_EXTENSIONS and path.suffix not in CODE_EXTENSIONS[name]: continue
            if path.suffix in {'.icns', '.png'} and str(relative) not in PUBLIC_ASSETS: continue
            if path.name in {'auth.json', 'credentials.json', 'connectors.json', '.env'}: continue
            if path.is_file() and path.suffix in EXTENSIONS:
                yield path

def scan(root, private_terms=()):
    findings=[]
    for path in sorted(root.rglob('*')):
        if path.is_symlink(): findings.append((str(path.relative_to(root)), 'symbolic-link')); continue
        if not path.is_file(): continue
        text=path.read_bytes().decode('utf-8',errors='replace')
        # The scanner and regression tests necessarily contain synthetic detection examples.
        # Their literal examples are split at runtime, so they still pass this same scan.
        for category, pattern in PATTERNS.items():
            matches=list(pattern.finditer(text))
            if category == 'credential-url' and 'Audit' in path.parts:
                matches=[m for m in matches if not re.match(r'https?://user:(?:pw|secret)@',m.group())]
            if matches: findings.append((str(path.relative_to(root)),category))
        public_text = text.replace('/by42ppcrps-dev/orrery', '/public-repository')
        for term in private_terms:
            if term and re.search(r'(?<![\w])'+re.escape(term)+r'(?![\w])',public_text,re.I):
                findings.append((str(path.relative_to(root)),'private-term'))
    return findings

def export(root, output, private_terms=()):
    # Use the same private, ignored list as the public push guard. Callers cannot forget it.
    private_terms = list(private_terms)
    terms_file = root / '.public-guard-terms'
    if terms_file.is_symlink(): raise ValueError('Unsafe private terms file')
    if terms_file.is_file():
        private_terms += [line.strip() for line in terms_file.read_text(encoding='utf-8').splitlines()
                          if line.strip() and not line.lstrip().startswith('#')]
    output=output.resolve()
    output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='orrery-public-') as directory:
        stage=Path(directory)/'Orrery'
        stage.mkdir()
        for source in source_paths(root):
            target=stage/source.relative_to(root)
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(source,target)
            target.chmod(0o755 if source.stat().st_mode & stat.S_IXUSR else 0o644)
        shutil.copyfile(root/'public/README.md',stage/'README.md')
        (stage/'.gitignore').write_text('.build/\nbuild/\n.swiftpm/\n*.dSYM/\n.DS_Store\n__pycache__/\nnode_modules/\n.wrangler/\n.public-guard-terms\ndocs/verification-*/\nscratchpad/\n.env\n.env.*\n*.p12\n*.mobileprovision\n*.provisionprofile\n')
        findings=scan(stage,private_terms)
        if findings: raise ValueError('Public export refused:\n'+'\n'.join(path+': '+category for path,category in findings))
        files={str(p.relative_to(stage)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(stage.rglob('*')) if p.is_file()}
        (stage/'PUBLIC-MANIFEST.json').write_text(json.dumps({'files':files,'contains_git_history':False},indent=2)+'\n')
        temporary=output.with_suffix('.pending.zip')
        try:
            with zipfile.ZipFile(temporary,'w',compression=zipfile.ZIP_DEFLATED) as archive:
                for path in sorted(stage.rglob('*')):
                    if path.is_file(): archive.write(path,Path('Orrery')/path.relative_to(stage))
            temporary.replace(output)
        finally: temporary.unlink(missing_ok=True)
    return len(files)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'build/Orrery-public-source.zip')
    parser.add_argument('--private-term',action='append',default=[])
    args=parser.parse_args()
    terms=args.private_term+([Path.home().name] if Path.home().name not in {"runner", "user", "developer", "someone", "root"} else [])
    try:
        count=export(ROOT,args.output,terms)
    except (OSError,ValueError) as error:
        parser.exit(1,str(error)+'\n')
    print(f'Public source package ready: {args.output}\n{count} files scanned; no history, local docs or account stores included.')
