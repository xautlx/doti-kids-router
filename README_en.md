# doti-kids-router · Doti (router side)

> Doti, made with heart. A little more care, a lot more room to grow.

[中文](README.md)

Doti is screen time for kids, handled by your OpenWrt router. The kids' internet **runs a while, then slows a while**, on its own — no fixed time slots to wait for. When time's up it just slows down and never cuts off, so messages and homework lookups still work. Parents manage everything from the WeChat mini program “一点守护”, and nothing gets installed on the kids' devices.

This repository is the router software (the `doti` package and the `doti-updater` updater), fully open source.

## Learn more and install

The overview, requirements, install and pairing steps, and how to verify the packages are all on the homepage and in the Quick Start:

| | GitHub Pages | Faster in China |
|---|---|---|
| Homepage | [xautlx.github.io/doti-kids-router](https://xautlx.github.io/doti-kids-router/?lang=en) | [doti.entdiy.xyz](https://doti.entdiy.xyz/?lang=en) |
| Quick Start | [xautlx.github.io/doti-kids-router/quick-start](https://xautlx.github.io/doti-kids-router/quick-start/?lang=en) | [doti.entdiy.xyz/quick-start](https://doti.entdiy.xyz/quick-start/?lang=en) |

Packages are in [Releases](../../releases) (also mirrored to the gitee repository of the same name).

## Build it yourself

```sh
python3 build.py         # → dist/doti_<version>-1_all.ipk, dist/doti-updater_<version>-1_all.ipk
python3 build.py --apk   # also dist/doti-<version>-r1.apk, dist/doti-updater-<version>-r1.apk (needs apk-tools 3, e.g. in Alpine 3.24)
```

Builds are reproducible: the same source produces the same file anywhere, which you can check against `SHA256SUMS` in Releases. Pushing a `v<version>` tag makes GitHub Actions build and publish to Releases; routers download online updates from there and verify the signed sha256.

## Layout

| Path | Contents |
|---|---|
| `files/` | Files the `doti` package installs on the router |
| `updater/` | The `doti-updater` updater |
| `build.py` | Build script |
| `install.sh` | Install script (detects the system, downloads the matching package, verifies and installs it) |

## License

[GPL-3.0](LICENSE).
