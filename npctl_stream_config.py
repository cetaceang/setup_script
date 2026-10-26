#!/usr/bin/env python3
"""Small Nginx lexer for conservative listener migration; preserves other text."""
import argparse
import json
import os
import re
import sys
from pathlib import Path

LOCAL_FALLBACK_MARKER = '# Managed by npctl local-only HTTPS fallback'


def tokens(text):
    i = 0
    while i < len(text):
        if text[i].isspace():
            i += 1
            continue
        if text[i] == '#':
            end = text.find('\n', i)
            i = len(text) if end < 0 else end + 1
            continue
        start = i
        if text[i] in '{};':
            i += 1
        else:
            quote = None
            while i < len(text):
                c = text[i]
                if c == '\\':
                    i += 2
                    continue
                if quote:
                    if c == quote:
                        quote = None
                elif c in '\"\'':
                    quote = c
                elif c.isspace() or c in '{};#':
                    break
                i += 1
            if quote:
                raise ValueError('不支持未闭合的配置引号')
        yield text[start:i], start, i


def directives(text):
    current = []
    for value, start, end in tokens(text):
        if value in (';', '{', '}'):
            if current:
                yield current, value, start, end
            current = []
        else:
            current.append((value, start, end))


def listeners(text):
    return [(parts, end) for parts, delimiter, _, end in directives(text)
            if delimiter == ';' and parts[0][0] == 'listen']


def https_server_count(text):
    current = []
    scopes = []
    servers = set()
    sequence = 0
    for value, _, _ in tokens(text):
        if value == '{':
            sequence += 1
            scopes.append((current[0] if current else '', sequence))
            current = []
        elif value == '}':
            if not scopes:
                raise ValueError('无法识别配置块结构')
            scopes.pop()
            current = []
        elif value == ';':
            if len(current) > 1 and current[0] == 'listen' and port(current[1]) in (443, 8443):
                if not scopes or scopes[-1][0] != 'server':
                    raise ValueError('HTTPS listen 不位于独立的 server 块内')
                servers.add(scopes[-1][1])
            current = []
        else:
            current.append(value)
    return len(servers)


def port(address):
    if address.isdecimal():
        return int(address)
    match = re.search(r':([0-9]+)$', address)
    return int(match[1]) if match else None


def local_only_fallback(text):
    if LOCAL_FALLBACK_MARKER not in text.splitlines():
        return False
    entries = listeners(text)
    if (https_server_count(text) != 1 or len(entries) != 1 or
            len(entries[0][0]) < 3 or entries[0][0][1][0] != '127.0.0.1:8443' or
            'ssl' not in [part[0] for part in entries[0][0][2:]]):
        raise ValueError('本地专用 HTTPS 回落站点的监听与标记不符，停止操作')
    return True


def migrate(paths, metadata_path, enable):
    metadata_file = Path(metadata_path)
    metadata = json.loads(metadata_file.read_text()) if metadata_file.exists() else {}
    if not isinstance(metadata, dict) or any(
            not isinstance(key, str) or not isinstance(value, list) or not value or
            any(not isinstance(item, str) for item in value)
            for key, value in metadata.items()):
        raise ValueError('HTTPS 监听备份元数据格式不兼容')
    pending = []
    for name in paths:
        path = Path(name)
        if path.is_symlink() or not path.is_file():
            raise ValueError(f'拒绝修改非常规站点文件: {name}')
        text = path.read_text()
        if local_only_fallback(text):
            # Landing-server HTTPS is independent of public Stream state.
            continue
        if https_server_count(text) != 1:
            raise ValueError(f'站点不包含唯一的受支持 HTTPS server 块: {name}')
        selected = []
        for parts, end in listeners(text):
            if len(parts) < 2:
                raise ValueError(f'无法识别 listen: {name}')
            address = parts[1][0]
            if port(address) not in (443, 8443):
                continue
            options = [v[0] for v in parts[2:]]
            if 'ssl' not in options or set(options) - {'ssl', 'http2', 'default_server', 'ipv6only=on'}:
                raise ValueError(f'HTTPS listen 含不支持的选项: {name}')
            if enable:
                if address == '127.0.0.1:8443':
                    continue
                if address not in ('443', '0.0.0.0:443', '[::]:443'):
                    raise ValueError(f'不支持的 HTTPS 监听地址: {name}')
            elif address != '127.0.0.1:8443':
                if port(address) == 443:
                    continue
                raise ValueError(f'发现不明 8443 监听: {name}')
            selected.append((parts, end))
        if not selected:
            # Already migrated, or a website without HTTPS: leave it byte-for-byte.
            continue
        if enable:
            metadata[str(path)] = [text[p[0][1]:end] for p, end in selected]
            all_options = {v[0] for parts, _ in selected for v in parts[2:]}
            replacement = 'listen 127.0.0.1:8443 ssl'
            if 'http2' in all_options:
                replacement += ' http2'
            if 'default_server' in all_options:
                replacement += ' default_server'
            replacement += ';'
        else:
            if len(selected) != 1:
                raise ValueError(f'本地 HTTPS 监听数量不兼容: {name}')
            replacement = '\n    '.join(metadata.get(str(path), ['listen 443 ssl http2;']))
        for index, (parts, end) in reversed(list(enumerate(selected))):
            text = text[:parts[0][1]] + (replacement if index == 0 else '') + text[end:]
        pending.append((path, text))
    # Validate the entire plan before writing any site.
    for path, text in pending:
        path.write_text(text)
    metadata_file.write_text(json.dumps(metadata, indent=2) + '\n')


def probe(dump_path, allowed_paths, managed_stream):
    allowed = {os.path.realpath(p) for p in allowed_paths}
    current = None
    sections = {}
    for line in Path(dump_path).read_text().splitlines(keepends=True):
        match = re.match(r'^# configuration file (.+):\s*$', line)
        if match:
            current = os.path.realpath(match[1])
            sections[current] = ''
        elif current:
            sections[current] += line
    if not sections:
        raise ValueError('无法解析 nginx -T 的实际配置路径')
    for name, text in sections.items():
        if name == os.path.realpath(managed_stream):
            continue
        if name in allowed:
            local_only_fallback(text)
        for parts, delimiter, _, _ in directives(text):
            if parts[0][0] == 'stream' and delimiter == '{':
                raise ValueError(f'检测到第三方 stream 配置，停止操作: {name}')
            if parts[0][0] == 'listen' and len(parts) > 1:
                if port(parts[1][0]) == 443 and name not in allowed:
                    raise ValueError(f'非 npctl 配置占用 443，停止操作: {name}')
                if port(parts[1][0]) == 8443 and name not in allowed:
                    raise ValueError(f'不明配置占用本地 HTTPS 8443，停止操作: {name}')


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    migration = sub.add_parser('migrate')
    migration.add_argument('direction', choices=('enable', 'disable'))
    migration.add_argument('metadata')
    migration.add_argument('paths', nargs='*')
    check = sub.add_parser('probe')
    check.add_argument('dump')
    check.add_argument('managed_stream')
    check.add_argument('paths', nargs='*')
    args = parser.parse_args()
    try:
        if args.command == 'migrate':
            migrate(args.paths, args.metadata, args.direction == 'enable')
        else:
            probe(args.dump, args.paths, args.managed_stream)
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
