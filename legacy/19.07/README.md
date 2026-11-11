# 旧版 OpenWrt 19.07 的 ipk（legacy）

给还跑 `opkg` / ipk 的老机器准备的兼容构建。目标机是京东云 AX1800 Pro
（JDCloud RE-SS-01，IPQ6018），固件 QWRT R24.5.1（实为 OpenWrt
19.07-SNAPSHOT），内核 Linux **4.4.60**，aarch64。

新版 apk 那条路（`.github/workflows/build-apk.yml`，ImmortalWrt + JS 页面）
不受这里任何东西影响：主树的运行包与 JS 页面原样保留，legacy 只在
ipk 构建那一步才换上下面这几件。

## 为什么需要这一份

| 拦住的地方 | 原因 | 这一份的做法 |
|---|---|---|
| 原厂 `multiapd` 起不来 | 私有 `libc.so.6` 是 Buildroot glibc 2.26，最低内核标 **5.4.0**，4.4.60 上加载器直接 `FATAL: kernel too old`，退出码 127 | 同一版 glibc 2.26（Buildroot 2018.02.12 的快照 `glibc-2.26-193`）按 `--enable-kernel=4.4.0` 重编，成套换掉 `ld-linux.so.3`、`libc.so.6`、`libdl.so.2`、`libm.so.6`、`libpthread.so.0` |
| LuCI 页面打不开 | 19.07 的 LuCI 只认 Lua controller，不读 `menu.d`，也没有新版 JS view 框架 | `luasrc/` 里的 Lua controller + CBI + `.htm` 模板，文案复用原 `.po` 的 msgid |
| 启动器在 4.4 上失败 | `ns-run` 无条件调 `close_range()`，那是 Linux 5.9 才有的调用，4.4 回 ENOSYS | `patches/` 两处改动：ENOSYS 时逐个关 fd；先 `uname()` 看版本，低于 5.9 根本不发起这个调用 |
| 失败时每 5 秒重拉 | init 只看 `CONFIG_COMPAT`，看不出加载器拒内核 | `openwrt/zte-mesh/files/zte-mesh.init` 的 `runtime_ready()`：启动前用私有加载器 `--list` 验三个原厂程序，失败就写明原因拒绝启动（主树与 ipk 共用这一处） |

工具链按原厂 ELF 的真实 ABI 选：`e_flags 0x5000200`（EABI5、软浮点）、
无 `Tag_ABI_VFP_args`、解释器 `/lib/ld-linux.so.3`，所以是
**arm-linux-gnueabi**，不是 gnueabihf。只改 ELF ABI tag、屏蔽内核版本
检查的做法不在这里——那是伪造兼容。

## 这一份的来源与校验

`zte-mesh-runtime-legacy.tar.gz` 是提交的运行包（`openwrt/zte-mesh/`
那份）换入下面六个文件后重生成的，包内 `SHA256SUMS` 已同步：

| 文件 | sha256（包内） | 说明 |
|---|---|---|
| `root/lib/ld-linux.so.3` | `68f0da66…` | 重编 glibc 的加载器 |
| `root/lib/libc.so.6` | `76e0afc2…` | ABI tag **4.4.0**（原厂是 5.4.0） |
| `root/lib/libdl.so.2` | `4024dde9…` | 同上 |
| `root/lib/libm.so.6` | `d53afc8d…` | 同上 |
| `root/lib/libpthread.so.0` | `9d5bcca0…` | 同上 |
| `ns-run.c` | `37433752…` | 两处补丁都打上的源码 |

重编所用的工具链与参数：ARM 官方 GNU-A 8.3-2019.03（gcc 8.3.0、
binutils 2.32）；Linux 头文件 linux-4.4.302；configure
`--host=arm-linux-gnueabi --prefix=/usr --enable-kernel=4.4.0
--with-headers=<4.4 headers>/include --disable-werror --disable-nls
libc_cv_forced_unwind=yes libc_cv_c_cleanup=yes`。原厂二进制最高只
要 `GLIBC_2.17`，无 `GLIBC_PRIVATE` 引用，重编的 2.26 全覆盖。

`tools/build-glibc-legacy.sh` 能从源码把这六个文件与这份 tarball
完整重做一遍（下载地址与 sha256 都写在脚本里）；CI 的 ipk 构建
不跑它，直接用这里提交的这份 tarball——它是 2026-11-11 在真机上
验证过的那份字节。

## 在真机上验证过什么（2026-11-11，QWRT 4.4.60）

- 私有加载器 `--list db-engine-probe` / `multiapd` / `zte-meshctl`
  全部 rc=0（之前就是第一条报 `FATAL: kernel too old`）。
- 控制器跑起来了，`logread` 里没有 `kernel too old`，也没有
  `close-inherited-fds errno=38`。
- LuCI 登录页、总览页、「网络 → 中兴组网」能打开，重复刷新正常；
  装完要清一次 `/tmp/luci-indexcache` 与 `/tmp/luci-modulecache`
  （旧缓存里是坏掉的 `index()`）。

尚未验证：控制器持续跑数分钟以上、状态持续更新；实际组网发现节点、
取得新鲜状态；QCAWIFI 闭源驱动下 `wlan-sync` 写
`/etc/config/wireless` 是否生效。qemu 里的 `--list` 成功不能代替
真机那一项（qemu 看到的是宿主内核版本）。

## 怎么拿到 ipk

Actions → **Build packages (apk + legacy ipk)** → Run workflow，
勾上 `Build the legacy OpenWrt 19.07 .ipk packages`，产物是 artifact
`zte-mesh-ipk-19.07`（三个 ipk + `SHA256SUMS.txt`）。版本号是仓库里
两份 Makefile 的 `PKG_RELEASE`（现在是 29），要发新版先改那两行
再跑 workflow。apk 那一份由同一个 workflow 里另一 job 出，
见主 [README](../../README.md)。

装机（正常升级，不用 `--force-reinstall`，配置是 conffile 会保留）：

```sh
cp /etc/config/zte_mesh /tmp/zte_mesh.bak   # 先备份
scp zte-mesh_0.1.0-29_all.ipk luci-app-zte-mesh_0.1.0-29_all.ipk \
    luci-i18n-zte-mesh-zh-cn_0.1.0-29_all.ipk SHA256SUMS.txt root@192.168.13.2:/tmp/zte-ipk29/
ssh root@192.168.13.2 'cd /tmp/zte-ipk29 && sha256sum -c SHA256SUMS.txt && \
  opkg install zte-mesh_0.1.0-29_all.ipk luci-app-zte-mesh_0.1.0-29_all.ipk \
  luci-i18n-zte-mesh-zh-cn_0.1.0-29_all.ipk && \
  rm -f /tmp/luci-indexcache && rm -rf /tmp/luci-modulecache && \
  /etc/init.d/zte-mesh restart'
```

装完先跑这一条（之前就是它报 `FATAL`）：

```sh
/usr/lib/zte-mesh/root/lib/ld-linux.so.3 \
  --library-path /usr/lib/zte-mesh/root/lib \
  --list /usr/lib/zte-mesh/root/bin/db-engine-probe; echo rc=$?
```

期望 rc=0。再等 3 分钟看
`logread | grep -e zte-mesh -e ZTE_DB -e "kernel too old" | tail -30`
与 `ubus call luci.zte-mesh status`（要求 running/attached 持续 true、
state 持续更新，不能只看一瞬间）。

组网验证不向现有子路由下发占位 SSID、密码或其他临时配置；涉及真实
无线变更另行确认。
