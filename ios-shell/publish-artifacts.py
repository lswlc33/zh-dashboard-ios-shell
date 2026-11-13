#!/usr/bin/env python3
"""CI 产物移交闸门：比对已发布高水位后，把 App/清单/图标三件资产写入产物仓库工作树。

不联网、不提交、不推送：提交与推送由 workflow 在 action=publish 时执行。
闸门只认「build 严格前进」，因此普通源码推送（未升号）不会覆盖已发布字节；回退直接 BLOCKED。
"""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import shutil
import sys

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('zeeho_build_support', ROOT / 'build-support.py')
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
require = support.require


def sha256_file(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def version_tuple(text):
    return tuple(int(part) for part in (text.split('.') + ['0'])[:3])


def published(artifact_root):
    """读产物仓库当前清单；只接受本项目身份，缺清单却已有 IPA 时必须人工检查。"""
    app = artifact_root / 'app'
    path = app / support.VERSION_NAME
    if not path.exists():
        require(not (app / support.IPA_NAME).exists(),
                'Published IPA exists without version2.json; inspect the artifact repo before continuing')
        return None
    require(path.stat().st_size <= 32_768, 'Existing version2.json exceeds the release limit')
    old = support.from_source(support.load_json(path))
    for key, value in {'bundleIdentifier': support.BUNDLE_ID, 'minimumIOS': support.MINIMUM_IOS,
                       'architecture': 'arm64', 'installer': 'TrollStore', 'file': support.IPA_NAME}.items():
        require(old.get(key) == value, 'Existing iOS release contract mismatch: ' + key)
    require(type(old.get('size')) is int and 0 < old['size'] <= support.MAX_IPA_BYTES,
            'Invalid published size')
    return old


def decide(new, old):
    """返回 (action, reason)。action 只有 publish / skip，回退与身份不符一律抛错。"""
    if old is None:
        return 'publish', 'first-ios-release'
    previous = (version_tuple(old['version']), int(old['build']))
    candidate = (version_tuple(new['version']), int(new['build']))
    require(candidate[0] >= previous[0], 'iOS version rollback is forbidden')
    require(candidate[1] >= previous[1], 'iOS build rollback is forbidden')
    if candidate == previous:
        # 同一个版本号/build 只能对应同一份 IPA 字节；否则说明源码变了但没升号。
        if new['sha256'] == old['sha256'] and new['size'] == old['size']:
            return 'skip', 'already-published: bytes identical to the published release'
        return 'skip', ('version-not-bumped: published ' + old['version'] + ' (' + old['build'] + ')'
                        ' is kept; bump Info.plist version/build to publish this build')
    require(candidate[1] > previous[1], 'A published build number cannot be reused')
    return 'publish', 'advanced: ' + old['version'] + ' (' + old['build'] + ') -> ' + new['version'] + ' (' + new['build'] + ')'


def apply_assets(artifact_dir, artifact_root, icon):
    """只写三件正式资产；Android 清单 / APK 与其他文件一概不碰。"""
    artifact_dir, artifact_root = pathlib.Path(artifact_dir), pathlib.Path(artifact_root)
    app = artifact_root / 'app'
    app.mkdir(parents=True, exist_ok=True)
    source_ipa = artifact_dir / support.IPA_NAME
    require(source_ipa.stat().st_size <= support.MAX_IPA_BYTES, 'IPA exceeds the client download gate')
    for source, target in ((source_ipa, app / support.IPA_NAME),
                           (artifact_dir / support.VERSION_NAME, app / support.VERSION_NAME),
                           (pathlib.Path(icon), app / support.SOURCE_ICON_NAME)):
        require(source.is_file(), 'Missing release asset: ' + str(source))
        shutil.copyfile(source, target)
    # 复制后回读，确保落盘字节与清单提供的哈希一致。
    metadata = support.from_source(support.load_json(app / support.VERSION_NAME))
    require(sha256_file(app / support.IPA_NAME) == metadata['sha256'] and
            (app / support.IPA_NAME).stat().st_size == metadata['size'],
            'Copied IPA does not match its version2.json')
    return metadata


def gate(artifact_dir, artifact_root, icon):
    artifact_dir, artifact_root = pathlib.Path(artifact_dir), pathlib.Path(artifact_root)
    require({path.name for path in artifact_dir.iterdir()} == set(support.PUBLISHED_ARTIFACTS),
            'CI artifact directory must contain exactly the five release files')
    ipa = artifact_dir / support.IPA_NAME
    artifact_source = support.from_source(support.load_json(artifact_dir / support.VERSION_NAME))
    require(sha256_file(ipa) == artifact_source['sha256'] and ipa.stat().st_size == artifact_source['size'],
            'Artifact IPA bytes differ from its own version2.json')
    old = published(artifact_root)
    action, reason = decide(artifact_source, old)
    result = {'action': action, 'reason': reason, 'previous': old, 'metadata': artifact_source}
    if action == 'publish':
        result['metadata'] = apply_assets(artifact_dir, artifact_root, icon)
    print(json.dumps({key: result[key] for key in ('action', 'reason', 'metadata')},
                     ensure_ascii=False, indent=2))
    return result


def self_test():
    """纯内存闸门判定：不写产物、不用真实 IPA，供源码契约在 CI 构建前跑。"""
    def meta(version, build, sha, size=1):
        return {'version': version, 'build': str(build), 'sha256': sha * 64, 'size': size}
    assert decide(meta('1.1.2', 49, 'a'), None)[0] == 'publish'
    assert decide(meta('1.1.2', 50, 'b'), meta('1.1.2', 49, 'a'))[0] == 'publish'
    assert decide(meta('1.1.3', 50, 'c'), meta('1.1.2', 49, 'a'))[0] == 'publish'
    assert decide(meta('1.1.2', 49, 'a'), meta('1.1.2', 49, 'a')) == \
        ('skip', 'already-published: bytes identical to the published release')
    assert decide(meta('1.1.2', 49, 'b'), meta('1.1.2', 49, 'a'))[0] == 'skip'
    for bad, label in ((meta('1.1.2', 48, 'a'), 'build'), (meta('1.1.1', 49, 'a'), 'version')):
        try:
            decide(bad, meta('1.1.2', 49, 'a'))
        except ValueError as error:
            assert label in str(error).lower(), str(error)
        else:
            raise AssertionError('Rollback must be blocked: ' + label)
    print('publish gate self-test passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact-dir')
    parser.add_argument('--artifact-root')
    parser.add_argument('--icon')
    parser.add_argument('--report')
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    require(args.artifact_dir and args.artifact_root and args.icon,
            'Provide --artifact-dir, --artifact-root and --icon')
    result = gate(args.artifact_dir, args.artifact_root, args.icon)
    if args.report:
        pathlib.Path(args.report).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n',
                                             encoding='utf-8')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print('BLOCKED: ' + str(error), file=sys.stderr)
        sys.exit(2)