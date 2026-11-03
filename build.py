#!/usr/bin/env python3
"""打包路由器端：先打升级程序 dist/doti-updater_<版本>-1_all.ipk，再打主程序 dist/doti_<版本>-1_all.ipk。
加 --apk 再打 OpenWrt 25.x 用的 dist/doti-updater-<版本>-r1.apk、dist/doti-<版本>-r1.apk（要 apk-tools 3 的 apk mkpkg）。

纯脚本包，不需要 OpenWrt SDK；版本号取自 files/usr/sbin/doti 的 VERSION。
局域网接口的 /www-doti/{pub,admin}/doti/<接口> 是指向 /usr/libexec/doti/cgi 的符号链接，在这里生成。
升级程序包放进主程序的 /usr/share/doti/doti-updater.ipk（apk 包里放 doti-updater.apk），主程序服务启动时没装就补装。
"""
import gzip, io, os, re, shutil, subprocess, sys, tarfile, tempfile
import blocklist

HERE = os.path.dirname(os.path.abspath(__file__))
# 可复现构建：固定文件时间和 gzip 头（SOURCE_DATE_EPOCH 可覆盖）
MTIME = int(os.environ.get('SOURCE_DATE_EPOCH') or 1767225600)
FILES = os.path.join(HERE, 'files')
VERSION = re.search(r"const VERSION = '([^']+)'", open(os.path.join(FILES, 'usr/sbin/doti')).read()).group(1)
PKG, FULL = 'doti', f'{VERSION}-1'
EXEC = ('usr/sbin/', 'usr/libexec/doti/', 'etc/init.d/', 'etc/uci-defaults/')
CGI = '/usr/libexec/doti/cgi'
PUB = ['hello', 'look']
ADMIN = ['claim', 'backup', 'join', 'status', 'settings', 'today', 'wifi', 'usage', 'summary', 'speed', 'device', 'parents', 'unbind', 'time']

CONTROL = f"""Package: {PKG}
Version: {FULL}
Depends: libc, ucode, ucode-mod-fs, uhttpd, nftables, firewall4, uclient-fetch, ca-bundle
Section: net
Architecture: all
Maintainer: 一点守护
Description: 一点守护·孩子上网时间管理：孩子网络用一会儿、慢一会儿，到点只限速不断网。家长在微信小程序「一点守护」里管理。
"""
# OpenWrt 22.03 以下中止安装
PREINST = """#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
v=""
[ -r "${IPKG_INSTROOT}/etc/openwrt_release" ] && . "${IPKG_INSTROOT}/etc/openwrt_release" && v="$DISTRIB_RELEASE"
case "$v" in SNAPSHOT|"") exit 0 ;; esac
maj=${v%%.*}; rest=${v#*.}; min=${rest%%.*}
case "$maj$min" in *[!0-9]*) exit 0 ;; esac
if [ "$maj" -lt 22 ] || { [ "$maj" -eq 22 ] && [ "$min" -lt 3 ]; }; then
	echo "一点守护需要 OpenWrt 22.03 及以上（当前 $v）。安装已终止。" >&2
	exit 1
fi
exit 0
"""
# 装完让路由器管理页（LuCI）认出新菜单
POSTINST = """#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
exit 0
"""
# 停服务、删三张表
PRERM = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/doti stop 2>/dev/null
/etc/init.d/doti disable 2>/dev/null
for t in doti doti_limit doti_dns; do nft delete table inet $t 2>/dev/null; done
exit 0
"""


def info(name, size, mode, kind=tarfile.REGTYPE, link=''):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mode, ti.type, ti.linkname = size, mode, kind, link
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = 'root'
    ti.mtime = MTIME
    return ti


def targz(entries):
    buf = io.BytesIO()
    with gzip.GzipFile(filename='', mode='wb', fileobj=buf, mtime=0, compresslevel=9) as gz, \
            tarfile.open(fileobj=gz, mode='w', format=tarfile.GNU_FORMAT) as t:
        for e in entries:
            name, data, mode = e[:3]
            if len(e) > 3:
                t.addfile(info(name, 0, 0o777, tarfile.SYMTYPE, e[3]))
            elif data is None:
                t.addfile(info(name, 0, mode, tarfile.DIRTYPE))
            else:
                t.addfile(info(name, len(data), mode), io.BytesIO(data))
    return buf.getvalue()


# apk 包的脚本：和 OpenWrt 自己的 apk 包一样，带上包名调 default_postinst / default_prerm（要包里的 /lib/apk/packages/<包>.list）。
# apk 升级时不跑旧包的卸载脚本，所以升级后要自己重启服务
def apk_scripts(name, extra_post='', extra_prerm='', restart=''):
    head = f"""#!/bin/sh
[ -s ${{IPKG_INSTROOT}}/lib/functions.sh ] || exit 0
. ${{IPKG_INSTROOT}}/lib/functions.sh
export root="${{IPKG_INSTROOT}}"
export pkgname="{name}"
"""
    post = head + 'default_postinst\n' + extra_post + 'exit 0\n'
    upgrade = head.replace('#!/bin/sh\n', '#!/bin/sh\nexport PKG_UPGRADE=1\n') + 'default_postinst\n' + extra_post + restart + 'exit 0\n'
    prerm = '#!/bin/sh\n[ -n "${IPKG_INSTROOT}" ] && exit 0\n' + extra_prerm + 'exit 0\n'
    return post, upgrade, prerm


UFILES = os.path.join(HERE, 'updater', 'files')
UVERSION = re.search(r"const VERSION = '([^']+)'", open(os.path.join(UFILES, 'usr/share/doti-updater/doti-update.uc')).read()).group(1)
UCONTROL = f"""Package: doti-updater
Version: {UVERSION}-1
Depends: libc, ucode, ucode-mod-fs, uclient-fetch, ca-bundle, usign
Section: net
Architecture: all
Maintainer: 一点守护
Description: 一点守护升级程序：每日报到、在线升级（验签、体检、回滚）。
"""
UPOSTINST = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/doti-updater enable
/etc/init.d/doti-updater restart
exit 0
"""
# 不删 /etc/doti-updater
UPRERM = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/doti-updater stop 2>/dev/null
/etc/init.d/doti-updater disable 2>/dev/null
exit 0
"""


def tree(base, exec_prefixes):
    out, size = [], 0
    for root, dirs, files in os.walk(base):
        dirs.sort()
        rel = os.path.relpath(root, base)
        if rel != '.':
            out.append(('./' + rel + '/', None, 0o755))
        for f in sorted(files):
            if f.startswith('.'):
                continue
            p = os.path.join(root, f)
            r = os.path.relpath(p, base)
            data = open(p, 'rb').read()
            size += len(data)
            out.append(('./' + r, data, 0o755 if r.startswith(exec_prefixes) else 0o644))
    return out, size


def with_parents(entries):
    have = {e[0] for e in entries if e[0].endswith('/')}
    need = set()
    for e in entries:
        parts = e[0].rstrip('/').split('/')[:-1]
        for i in range(2, len(parts) + 1):
            d = '/'.join(parts[:i]) + '/'
            if d not in have:
                need.add(d)
    dirs = [e for e in entries if e[0].endswith('/')] + [(d, None, 0o755) for d in need]
    return sorted(dirs, key=lambda e: (e[0].count('/'), e[0])) + [e for e in entries if not e[0].endswith('/')]


def ipk(path, control, scripts, data):
    data = with_parents(data)
    ctl = targz([('./', None, 0o755), ('./control', control.encode(), 0o644)] + [('./' + n, b.encode(), 0o755) for n, b in scripts])
    dat = targz([('./', None, 0o755)] + data)
    with open(path, 'wb') as f:
        f.write(targz([('./debian-binary', b'2.0\n', 0o644), ('./data.tar.gz', dat, 0o644), ('./control.tar.gz', ctl, 0o644)]))


APK_INFO = {'arch': 'noarch', 'license': 'GPL-3.0-only', 'origin': 'doti', 'url': 'https://github.com/xautlx/doti-kids-router', 'maintainer': '一点守护'}


def apk(path, name, version, depends, desc, scripts, data):
    """用 apk mkpkg 打 apk 包：文件摆进临时目录（时间统一成 MTIME，可复现），加上 OpenWrt 要的文件清单"""
    data = with_parents(data)
    with tempfile.TemporaryDirectory() as td:
        root, sd = os.path.join(td, 'root'), os.path.join(td, 'scripts')
        os.makedirs(root); os.makedirs(sd)
        files = []
        for e in data:
            p = os.path.join(root, e[0][2:])
            if len(e) > 3:
                os.symlink(e[3], p); files.append('/' + e[0][2:])
            elif e[1] is None:
                os.makedirs(p, exist_ok=True); os.chmod(p, 0o755)
            else:
                open(p, 'wb').write(e[1]); os.chmod(p, e[2]); files.append('/' + e[0][2:])
        lst = f'/lib/apk/packages/{name}.list'
        os.makedirs(os.path.join(root, 'lib/apk/packages'), exist_ok=True)
        open(root + lst, 'w').write('\n'.join(sorted(files + [lst])) + '\n')
        args = ['apk', 'mkpkg', '--files', root, '--output', path,
                '--info', f'name:{name}', '--info', f'version:{version}-r1', '--info', f'description:{desc}',
                '--info', 'depends:' + ' '.join(depends)]
        for k, v in APK_INFO.items():
            args += ['--info', f'{k}:{v}']
        for t, body in scripts:
            sp = os.path.join(sd, t)
            open(sp, 'w').write(body); os.chmod(sp, 0o755)
            args += ['--script', f'{t}:{sp}']
        for dp, dirs, fs_ in os.walk(root, topdown=False):
            for n in fs_ + dirs:
                os.utime(os.path.join(dp, n), (MTIME, MTIME), follow_symlinks=False)
        os.utime(root, (MTIME, MTIME))
        subprocess.run(args, check=True)


def build_updater():
    data, size = tree(UFILES, ('usr/sbin/', 'etc/init.d/'))
    out = os.path.join(HERE, 'dist', f'doti-updater_{UVERSION}-1_all.ipk')
    ipk(out, UCONTROL + f'Installed-Size: {size}\n', [('postinst', UPOSTINST), ('prerm', UPRERM)], data)
    print(out, f'{os.path.getsize(out)} 字节')
    return out


def data_entries(upd, upd_name='doti-updater.ipk'):
    out, size = tree(FILES, EXEC)
    for d in ['./www-doti/', './www-doti/pub/', './www-doti/pub/doti/', './www-doti/admin/', './www-doti/admin/doti/']:
        out.append((d, None, 0o755))
    out += [('./www-doti/pub/doti/' + e, None, 0, CGI) for e in PUB]
    out += [('./www-doti/admin/doti/' + e, None, 0, CGI) for e in ADMIN]
    with tempfile.TemporaryDirectory() as bd:
        blocklist.generate(bd)
        out.append(('./usr/share/doti/blocklist/', None, 0o755))
        for f in sorted(os.listdir(bd)):
            b = open(os.path.join(bd, f), 'rb').read()
            out.append(('./usr/share/doti/blocklist/' + f, b, 0o644))
            size += len(b)
    cu = os.environ.get('DOTI_CLOUD_URL') or (open(os.path.join(HERE, 'cloud.url')).read().strip() if os.path.exists(os.path.join(HERE, 'cloud.url')) else '')
    if cu:
        out.append(('./usr/share/doti/cloud', (cu + '\n').encode(), 0o644))
    # 备用云端地址（主地址网络不通时用）
    bp = os.path.join(HERE, 'cloud-backup.url')
    if not os.environ.get('DOTI_CLOUD_URL') and os.path.exists(bp):
        out.append(('./usr/share/doti/cloud-backup', (open(bp).read().strip() + '\n').encode(), 0o644))
    else:
        print('提醒：没有云端地址（DOTI_CLOUD_URL 或 device/cloud.url），这个包连不上云端')
    v = (VERSION + '\n').encode()
    out.append(('./usr/share/doti/version', v, 0o644))
    ub = open(upd, 'rb').read()
    out.append(('./usr/share/doti/' + upd_name, ub, 0o644))
    size += len(ub)
    return out, size + len(v)


DEPENDS = re.search(r'^Depends: (.*)$', CONTROL, re.M).group(1).split(', ')
UDEPENDS = re.search(r'^Depends: (.*)$', UCONTROL, re.M).group(1).split(', ')
DESC = re.search(r'^Description: (.*)$', CONTROL, re.M).group(1)
UDESC = re.search(r'^Description: (.*)$', UCONTROL, re.M).group(1)
# 主程序 apk 包的安装后脚本：同 ipk 的 POSTINST
APK_POST_EXTRA = """[ -n "${IPKG_INSTROOT}" ] && exit 0
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
/etc/init.d/rpcd reload 2>/dev/null
"""


def build_apk():
    if not shutil.which('apk'):
        sys.exit('打 apk 包要 apk-tools 3（apk mkpkg），本机没有；GitHub Actions 在 Alpine 容器里打')
    data, _ = tree(UFILES, ('usr/sbin/', 'etc/init.d/'))
    post, upgrade, prerm = apk_scripts('doti-updater', restart='/etc/init.d/doti-updater restart\n', extra_prerm=UPRERM.split('\n', 2)[2].rsplit('exit 0', 1)[0])
    uout = os.path.join(HERE, 'dist', f'doti-updater-{UVERSION}-r1.apk')
    apk(uout, 'doti-updater', UVERSION, UDEPENDS, UDESC, [('post-install', post), ('post-upgrade', upgrade), ('pre-deinstall', prerm)], data)
    print(uout, f'{os.path.getsize(uout)} 字节')
    data, _ = data_entries(uout, 'doti-updater.apk')
    post, upgrade, prerm = apk_scripts(PKG, extra_post=APK_POST_EXTRA, restart='/etc/init.d/doti restart\n', extra_prerm=PRERM.split('\n', 2)[2].rsplit('exit 0', 1)[0])
    out = os.path.join(HERE, 'dist', f'{PKG}-{VERSION}-r1.apk')
    apk(out, PKG, VERSION, DEPENDS, DESC, [('pre-install', PREINST), ('post-install', post), ('post-upgrade', upgrade), ('pre-deinstall', prerm)], data)
    print(out, f'{os.path.getsize(out)} 字节，{len([d for d in data if d[1] is not None])} 个文件')


def main():
    os.makedirs(os.path.join(HERE, 'dist'), exist_ok=True)
    upd = build_updater()
    data, size = data_entries(upd)
    out = os.path.join(HERE, 'dist', f'{PKG}_{FULL}_all.ipk')
    ipk(out, CONTROL + f'Installed-Size: {size}\n', [('preinst', PREINST), ('postinst', POSTINST), ('prerm', PRERM)], data)
    print(out, f'{os.path.getsize(out)} 字节，{len([d for d in data if d[1] is not None])} 个文件')
    if '--apk' in sys.argv[1:]:
        build_apk()


if __name__ == '__main__':
    sys.exit(main())
