#!/usr/bin/env python3
"""共享屏蔽名单 → dnsmasq 配置。打包和发布名单时在这里一次处理好，路由器上不再合并、去重。

源文件 blocklist/<分类>.txt：一行一个域名，# 后是注释。输出到指定目录：
  base.conf      加密 DNS 探测域名、常见 DoH 服务域名（回「不存在」）
  <分类>.conf    address=/域名/192.0.2.1 和 ::（屏蔽域名及其所有子域名）
  manifest.json  { ver, files: { 分类: { n, sha256 } } }
用法：python3 blocklist.py <输出目录>
"""
import hashlib, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'blocklist')
CATS = ['always', 'game', 'shortvideo', 'video']
CANARY = ['use-application-dns.net', 'mask.icloud.com', 'mask-h2.icloud.com']
DOH_NAMES = ['dns.google', 'dns.google.com', 'cloudflare-dns.com', 'mozilla.cloudflare-dns.com', 'one.one.one.one', 'dns.quad9.net',
             'doh.pub', 'dot.pub', 'dns.alidns.com', 'doh.360.cn', 'dot.360.cn', 'dns.adguard.com', 'dns.adguard-dns.com', 'doh.opendns.com', 'dns.nextdns.io']
DOMAIN = re.compile(r'^[a-z0-9-]+(\.[a-z0-9-]+)+$')


def clean(d):
    """和路由器 settings.cleanDomain 同一套规则；不合法返回 None"""
    d = d.strip().lower()
    if d.startswith('*.'):
        d = d[2:]
    d = d.rstrip('.')
    if not (3 <= len(d) <= 253) or not DOMAIN.match(d):
        return None
    if any(not (1 <= len(p) <= 63) or p.startswith('-') or p.endswith('-') for p in d.split('.')):
        return None
    return d


def load(cat):
    out = set()
    for line in open(os.path.join(SRC, cat + '.txt'), encoding='utf-8'):
        d = clean(line.split('#', 1)[0])
        if d:
            out.add(d)
    return sorted(d for d in out if not any('.'.join(d.split('.')[i:]) in out for i in range(1, d.count('.') + 1)))


def conf(domains):
    return ''.join(f'address=/{d}/192.0.2.1\naddress=/{d}/::\n' for d in domains)


def generate(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    ver = int(open(os.path.join(SRC, 'VERSION')).read().strip())
    files = {'base': ''.join(f'address=/{d}/\n' for d in CANARY + DOH_NAMES)}
    n = {'base': len(CANARY) + len(DOH_NAMES)}
    for c in CATS:
        ds = load(c)
        files[c], n[c] = conf(ds), len(ds)
    man = {'ver': ver, 'files': {}}
    for c, text in files.items():
        assert re.fullmatch(r'[a-z0-9.:/=\n-]*', text), c
        open(os.path.join(out_dir, c + '.conf'), 'w').write(text)
        man['files'][c] = {'n': n[c], 'sha256': hashlib.sha256(text.encode()).hexdigest()}
    json.dump(man, open(os.path.join(out_dir, 'manifest.json'), 'w'), ensure_ascii=False, indent=1)
    return man


if __name__ == '__main__':
    m = generate(sys.argv[1])
    print('名单 v%d：' % m['ver'] + '，'.join(f'{c} {v["n"]}' for c, v in m['files'].items()))
