# 项目协作说明

## 项目概览

本仓库是一个面向 Ubuntu GPU 裸金属服务器交付场景的运维脚本项目。核心目标是在新机器接收后，用自动化方式完成 GPU 软件栈初始化和数据盘挂载。

当前仓库结构很精简：

- `README.md`：中文使用说明、安全策略、参数说明和验收建议。
- `scripts/provision_gpu_baremetal.sh`：核心 Bash 脚本。

## 核心脚本

主脚本是 `scripts/provision_gpu_baremetal.sh`。它默认目标为：

- NVIDIA Driver 主版本：`580`
- CUDA Toolkit：`13.0`
- 数据盘挂载前缀：`/data`，最终挂载点形如 `/data1`、`/data2`
- 空白盘格式化文件系统：`ext4`
- 默认启用 NVIDIA/CUDA 包版本锁定
- 默认是 dry-run 预演模式，不加 `--yes` 不会真正修改系统

常见运行方式：

```bash
chmod +x scripts/provision_gpu_baremetal.sh

sudo scripts/provision_gpu_baremetal.sh
sudo scripts/provision_gpu_baremetal.sh --yes --reboot
sudo scripts/provision_gpu_baremetal.sh --fabricmanager --yes --reboot
sudo scripts/provision_gpu_baremetal.sh --format-empty --confirm-format-empty --yes --reboot
```

## 支持环境

脚本当前只面向标准交付环境：

- Ubuntu `22.04` 或 `24.04`
- x86_64/amd64 架构
- 使用 NVIDIA 官方 CUDA apt 公网源

脚本会拒绝非 Ubuntu、非目标 Ubuntu 版本、非 x86_64/amd64 架构等环境。

## 主要能力

脚本会按顺序完成以下工作：

- 解析参数并校验输入。
- 要求 root 权限运行。
- 检测 Ubuntu 版本和系统架构。
- 检测 Secure Boot，开启时停止执行。
- 记录当前 `nvidia-smi`、`nvcc` 和已安装 NVIDIA/CUDA 包状态。
- 检测 GPU 上是否有活跃计算进程；正式执行时如有进程会停止，除非传入 `--force`。
- 检测并卸载旧的 NVIDIA `.run` 驱动安装痕迹。
- 解除旧的 NVIDIA/CUDA `apt-mark hold`，并删除旧版本锁定文件。
- 安装基础依赖、配置 NVIDIA CUDA apt 源。
- 安装目标驱动和 CUDA Toolkit。
- 自动检测 NVSwitch，并在需要时安装 Fabric Manager 或 NVLink 包。
- 可选安装 NVIDIA Container Toolkit。
- 默认锁定已安装的 NVIDIA/CUDA 相关包，避免普通 `apt upgrade` 自动升级。
- 扫描未挂载数据盘，按规则挂载或跳过。
- 执行增强验收并输出交付摘要。
- 根据参数决定是否自动重启。

## 数据盘处理规则

磁盘处理是高风险区域，修改相关逻辑时要特别谨慎。

当前规则：

- 系统盘会被跳过。
- 已挂载磁盘或分区会被跳过。
- 有普通可挂载文件系统的未挂载磁盘或分区，会直接挂载，不格式化。
- LVM、RAID、LUKS、swap 等非普通文件系统签名会被跳过。
- 完全空白磁盘默认跳过。
- 只有同时传入 `--format-empty --confirm-format-empty` 时，才允许对空白盘分区和格式化。
- 挂载使用 UUID 写入 `/etc/fstab`，选项包含 `nofail`。
- 第一次修改 `/etc/fstab` 前会备份为 `/etc/fstab.backup.<时间戳>`。
- 挂载点会自动选择未占用的 `/data1`、`/data2` 等路径。

## Fabric Manager 与 NVSwitch

脚本的 Fabric Manager 策略如下：

- `--fabricmanager`：强制安装。
- `--no-fabricmanager`：强制不安装。
- 默认 `auto`：通过 `lspci` 检测 NVSwitch，检测到后安装。
- 普通 NVSwitch 系统使用 `cuda-drivers-fabricmanager-<driver>`。
- B100/B200/B300/Blackwell 等第四代 NVSwitch 系统使用 `nvidia-open-<driver>` 和 `nvlink5-<driver>`。
- 安装前后都会校验驱动包与 Fabric Manager/NVLink 包的上游小版本一致。

## 版本锁定

正式执行后默认启用两层锁定：

- 对已安装的 NVIDIA/CUDA 相关包执行 `apt-mark hold`。
- 写入 `/etc/apt/preferences.d/nvidia-cuda-version-lock.pref`，把相关包固定在当前安装版本。

如需主动升级，应先移除锁定文件并解除 hold，再重新运行脚本安装新目标版本。

## 日志与验收

脚本日志写入：

```text
/var/log/gpu-baremetal-provision.log
```

正式执行后会自动运行增强验收，包括：

- `nvidia-smi`
- `nvcc --version`
- `nvidia-smi topo -m`
- persistence mode 状态
- MIG 状态
- Fabric Manager 服务状态
- NVIDIA/CUDA hold 状态
- `lsblk -f`
- `findmnt --verify`
- 交付摘要

README 建议重启后再人工执行同类命令确认。

## 修改注意事项

- 保持脚本默认 dry-run 行为，不要让未传入 `--yes` 的运行产生系统修改。
- 涉及格式化、分区、`/etc/fstab`、驱动卸载、重启的改动都属于高风险改动，需要优先保留现有防护。
- 不要降低 `--format-empty` 必须搭配 `--confirm-format-empty` 的安全门槛。
- 不要默认启用 `--force` 行为；活跃 GPU 任务应继续阻止正式升级。
- 修改 NVIDIA 包名、Fabric Manager/NVLink 逻辑时，需要同时考虑普通 NVSwitch 和第四代 NVSwitch 分支。
- 修改版本锁定逻辑时，要同时考虑 `apt-mark hold` 和 apt preferences 文件。
- 当前 README 是 UTF-8 中文文档；在 Windows PowerShell 中读取时建议显式使用 UTF-8，避免出现乱码。

## 建议验证

本仓库没有发现自动化测试框架。修改脚本后至少建议做：

```bash
bash -n scripts/provision_gpu_baremetal.sh
shellcheck scripts/provision_gpu_baremetal.sh
sudo scripts/provision_gpu_baremetal.sh
```

其中 `sudo scripts/provision_gpu_baremetal.sh` 是 dry-run，用于检查将要执行的动作。只有在真实目标机器并确认输出无误后，才应添加 `--yes`。
