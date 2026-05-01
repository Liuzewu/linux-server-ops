# GPU 裸金属服务器初始化脚本

这个目录提供一个 Ubuntu GPU 裸金属服务器接收后的自动化脚本，用来完成两件事：

- 默认安装或升级到 NVIDIA Driver 580 + CUDA Toolkit 13.0
- 自动发现未挂载的数据盘，写入 `/etc/fstab` 并挂载到 `/data1`、`/data2` 等目录

脚本默认是安全预演模式，不会真正修改系统。确认输出无误后再加 `--yes` 执行。

## 快速使用

```bash
chmod +x scripts/provision_gpu_baremetal.sh

sudo scripts/provision_gpu_baremetal.sh
sudo scripts/provision_gpu_baremetal.sh --yes --reboot
```

默认目标就是：

```text
Driver: 580
CUDA:   13.0
```

如果你是 A100/A800/H100 8 卡 HGX/SXM/NVSwitch 机器，建议显式开启 Fabric Manager：

```bash
sudo scripts/provision_gpu_baremetal.sh --fabricmanager --yes --reboot
```

如果新机器的数据盘完全空白，需要脚本帮你分区和格式化：

```bash
sudo scripts/provision_gpu_baremetal.sh --format-empty --confirm-format-empty --yes --reboot
```

为了避免误格式化，格式化空白盘必须同时带 `--format-empty --confirm-format-empty`。

## 常用参数

```text
--driver VERSION       NVIDIA 驱动主版本，默认 580
--cuda VERSION         CUDA Toolkit 版本，默认 13.0
--mount-base PATH      数据盘挂载目录前缀，默认 /data，结果为 /data1、/data2
--fs TYPE              空白盘格式化文件系统，支持 ext4 或 xfs，默认 ext4
--format-empty         允许格式化没有文件系统的空白数据盘
--fabricmanager        强制安装 NVIDIA Fabric Manager
--no-fabricmanager     不安装 NVIDIA Fabric Manager
--install-container    同时安装 NVIDIA Container Toolkit
--no-lock              安装后不锁定 NVIDIA/CUDA 包版本
--force                检测到 GPU 任务仍继续升级，仅建议维护窗口使用
--confirm-format-empty 与 --format-empty 配套使用，确认允许格式化空白盘
--yes                  真正执行修改；不加时只预演
--reboot               执行完成后自动重启
```

## 安全策略

- 不加 `--yes` 时只打印将要执行的动作。
- 支持两类场景：纯 Ubuntu 新系统安装；已有 550/12.4 等旧版本时升级到目标版本。
- 仅支持标准交付环境 Ubuntu 22.04/24.04 x86_64。
- 如果检测到 Secure Boot 开启，脚本会停止；需要先在 BIOS/UEFI 关闭，或人工处理 MOK 内核模块签名。
- 正式执行前会检查 NVIDIA 官方 CUDA apt 源连通性；脚本默认使用公网源，不内置离线源逻辑。
- 正式执行前会记录当前 `nvidia-smi`、`nvcc` 和已安装 NVIDIA/CUDA 包。
- 如果检测到 GPU 上还有计算进程，正式执行会停止；只有显式加 `--force` 才会继续。
- 如果检测到旧驱动是 NVIDIA `.run` 安装方式，会先用 `nvidia-installer --uninstall --silent` 卸载，再交给 apt 安装目标版本。
- 正式执行前会解除旧的 NVIDIA/CUDA `apt-mark hold`，并移除脚本旧锁定文件，避免旧版本阻塞升级。
- 系统盘会被跳过。
- 已挂载的磁盘会被跳过。
- 有文件系统但未挂载的数据盘会直接挂载，不格式化。
- LVM、RAID、LUKS、swap 等非普通文件系统签名会被跳过，不会自动挂载或格式化。
- 完全空白的数据盘默认跳过；必须同时加 `--format-empty --confirm-format-empty` 才会分区和格式化。
- 挂载使用磁盘 UUID 写入 `/etc/fstab`，并带 `nofail`，避免数据盘异常时卡住开机。
- 自动选择未占用的 `/data1`、`/data2` 等挂载点，避开已有挂载点和 `/etc/fstab` 记录。
- 第一次修改 `/etc/fstab` 前会自动备份为 `/etc/fstab.backup.<时间戳>`。
- 默认自动检测 NVSwitch；检测到时安装 Fabric Manager 相关包，并校验它与驱动小版本一致。
- B100/B200/B300/Blackwell 这类第四代 NVSwitch 系统会改用 `nvidia-open-<driver>` + `nvlink5-<driver>`。
- 默认锁定 NVIDIA/CUDA 相关包版本，避免普通 `apt upgrade` 自动升级驱动或 CUDA。
- 增强验收默认开启，会输出 GPU 数量、NVLink 拓扑、persistence mode、MIG 状态、Fabric Manager 状态、磁盘挂载和版本锁定摘要。
- 日志写入 `/var/log/gpu-baremetal-provision.log`。

## 版本锁定

脚本正式执行后默认会做两层锁定：

- 对已安装的 NVIDIA/CUDA 相关包执行 `apt-mark hold`
- 写入 `/etc/apt/preferences.d/nvidia-cuda-version-lock.pref`，把这些包固定在当前安装版本

后续如果确实要主动升级，先解锁：

```bash
sudo rm -f /etc/apt/preferences.d/nvidia-cuda-version-lock.pref
sudo apt-mark unhold $(apt-mark showhold | grep -E '^(cuda-|libcuda|libnvidia-|nvidia-|nsight-)')
```

然后再重新运行脚本安装新的目标版本。

## 旧 `.run` 驱动

有些机器的旧 driver 不是 apt 安装，而是通过 NVIDIA `.run` 文件安装。脚本会检测 `nvidia-installer`，正式执行时先卸载旧 `.run` 驱动：

```bash
nvidia-installer --uninstall --silent
```

然后再安装 apt 源里的 Driver 580、CUDA 13.0 和 Fabric Manager/NVLink 包。这样后续版本锁定、升级、卸载都能由 apt 管理。

## Fabric Manager

多卡 NVSwitch 机器通常需要 Fabric Manager，例如部分 SXM/HGX 服务器。脚本默认会自动检测 NVSwitch，检测到就安装：

```bash
cuda-drivers-fabricmanager-<driver>
```

如果检测到 B100/B200/B300/Blackwell 这类第四代 NVSwitch 机器，则改用：

```bash
nvidia-open-<driver>
nvlink5-<driver>
```

如果你已经知道客户机器需要 Fabric Manager，可以直接强制开启：

```bash
sudo scripts/provision_gpu_baremetal.sh --fabricmanager --yes --reboot
```

安装后脚本会校验驱动包与 Fabric Manager/NVLink 包的上游小版本是否一致，例如都为 `580.xxx.xx`。

## 推荐验收

脚本正式执行后会自动做增强验收并在日志末尾输出交付摘要。重启后建议再人工确认：

```bash
nvidia-smi
nvcc --version
nvidia-smi topo -m
nvidia-smi -q -d PERSISTENCE_MODE
nvidia-smi -q | grep -Ei 'MIG Mode|Current MIG'
systemctl status nvidia-fabricmanager --no-pager
apt-mark showhold | grep -E '^(cuda-|libcuda|libnvidia-|nvidia-|nsight-)'
lsblk -f
findmnt --verify
```

查看完整交付日志：

```bash
less /var/log/gpu-baremetal-provision.log
```

## 注意

这个脚本当前面向 Ubuntu 22.04/24.04 x86_64。不同云厂商或 IDC 镜像可能预装了旧驱动，驱动切换后通常需要重启一次才能让内核模块完全生效。
