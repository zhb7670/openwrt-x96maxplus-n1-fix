# OpenWrt X96Max+ / N1 编译修正版

针对 [`zhb7670/OpenWrt-X96MaxPlus-N1-flippy`](https://github.com/zhb7670/OpenWrt-X96MaxPlus-N1-flippy) 的 `build.yml` 四连败所做的修正版。
**原仓库未被修改**，本仓库为独立副本。

---

## 根因结论（已读真实编译日志实证，527KB / 6414 行）

**编译其实完全成功了**，是校验步骤自己把成功判成了失败。

日志末尾依次出现且全部成功：
```
make[2] target/install
make[2] package/index
make[2] json_overview_image_info
make[2] checksum          ← 编译流程完整走完
```
全日志**无任何** `Build failed` / `make: *** Error N` 真实报错。

紧接着校验步骤立刻失败：
```
ls: cannot access 'bin/targets/armvirt/64/': No such file or directory
::error::没有生成 rootfs，编译未成功
```

**即：固件编出来了，只是没在脚本写死的那条路径下。**

---

## 本版5 处修复

| # | 修复项| 说明 |
|---|---|---|
| **1** | **产物探测不再硬编码路径** ★核心 | 原版写死 `bin/targets/armvirt/64/*rootfs.tar.gz`，但该目录层级随 LEDE master 变动 → 改为 `find bin -name '*rootfs*.tar.gz'` 并**打印 `bin/` 目录树**，路径再变也能立刻看到真实落点 |
| **2** | **锁定 LEDE commit** | 原版 `git clone --depth 1 -b master` 不锁 commit。LEDE 在 2026-10-11/12 更新（`ff7be3fa21`），而前3 次失败都在 10-12 → 上游漂移导致随机失败。现锁定 `ff7be3fa21`（可用 `lede_commit` 输入覆盖） |
| **3** | **编译失败不再被掩盖** | 原版 `make -j$(nproc) \|\| make -j1 V=s` 会用串行重跑掩盖首次错误、且浪费 1 小时。现改为 `tee /tmp/build.log` + 失败时打印真实错误摘要 |
| **4** | **始终上传 build.log** | `if: always()` 上传日志，以后失败可直接下载查看，不用再猜 |
| **5** | **消除 kmod-oaf 递归依赖告警** | `destan19/OpenAppFilter` 的 Kconfig 里 `kmod-oaf` 自我 select，导致 `make defconfig` 报 `recursive dependency detected`（非致命，但会跳过该符号）→ 显式剔除该行 |

### 保留原版的正确修复
- 删除 `CONFIG_TARGET_OPTIMIZATION`（ARM 参数污染 host 版 libgcc 编译）
- PassWall 地址 `xiaorouji/` → `Openwrt-Passwall/`（旧仓库已迁移，不换会丢两个插件）
- 依赖安装包补全 + 未知符号容错 + 最终自检

---

## 四次失败演进（供对照）

| # | Run ID | 失败步骤 | 定性 |
|---|---|---|---|
| 1 | 38266671458 | 安装编译依赖 | 1 分钟挂，环境问题 |
| 2 | 38267549347 | 编译 | 29 分钟后失败（LEDE 漂移） |
| 3 | 38272444088 | 编译 | 33 分钟后失败 |
| 4 | 38278107848 | 校验产物存在 | ⚠️ 编译 2h18m **成功**，但路径判错 |

失败点一路后移 =逐个排坑。**前3 次是真编译失败（LEDE 漂移），第 4 次修好后就只剩路径问题了。**

---

## 使用方法

1. Actions → `Build OpenWrt for N1 & X96Max+ (fixed)` → **Run workflow**
2. 输入：
   - `kernel_version`：默认 `6.1.y`（自动解析为 6.1.163）
   - `openwrt_ver`：默认 `R24.1.13`
   - `lede_commit`：留空则用内置的 `ff7be3fa21`
3. 约 3~5 小时后产物发布到 Release `OpenWrt-Flippy-Fixed`：
   - `openwrt_s905d_n1_R24.1.13_k6.1.163.img.gz`（N1）
   - `openwrt_s905x3_multi_R24.1.13_k6.1.163.img.gz`（X96Max+）

### 首次跑通后建议
把 `env.LEDE_FALLBACK_COMMIT` 换成你验证过的 commit，锁定可复现构建。

---

## 插件版本说明

插件集来自 haiibo `armv8-plus.config` + `diy-script.sh`，**实时拉取、不锁版本**，
因此本工作流产出的插件是**编译当日**的 LEDE master + 各第三方源最新版，
比复用 haiibo 2024-01 rootfs 的方案新得多。

其中 4 个插件被上游 `diy-script.sh` 钉在 `openwrt-18.06` 老分支（属旧代版本）：
`luci-app-serverchan`、`luci-app-eqos`、`luci-theme-edge`、`luci-theme-argon`。