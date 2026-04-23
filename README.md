# Jetson_Orin_Nano_backup

> **北理工控制组 Jetson Orin Nano 备份教程**  


本项目提供了一套完整的 Jetson Orin Nano 系统备份和还原解决方案，包含两个核心脚本：

-  `backup.sh` - 系统备份脚本
-  `restore.sh` - 系统还原脚本

##  使用前准备

### 1. 文件格式转换

在 Jetson 上运行脚本前，需要将文件格式转换为 Unix 格式：

```bash
# 对于 backup.sh
vim backup.sh
:set ff=unix
:wq

# 对于 restore.sh
vim restore.sh
:set ff=unix
:wq
```

### 2. 配置备份路径与设备

通过环境变量设置备份 U 盘挂载点与目标设备（推荐）：

```bash
# 查看挂载点
df -h

# 典型 Orin Nano 设备
# SYSTEM_DEVICE: 系统盘（留空时脚本会自动从 / 反查整盘）
# DATA_DEVICE: 可选数据盘（默认留空，避免误操作）

export BACKUP_DIR="/your/actual/mount/point"
export SYSTEM_DEVICE=""
export DATA_DEVICE=""

# 可选：是否备份/还原第二块盘
# auto: 自动检测（默认）
# yes : 强制执行
# no  : 禁用
export ENABLE_DATA_BACKUP="auto"
export ENABLE_DATA_RESTORE="auto"

# v4 推荐：默认跳过空间检查（你可按需设为 no）
export IGNORE_SPACE_CHECK="yes"

# 还原时默认严格校验镜像同名 md5
# 若无 md5 文件可设为 no
export STRICT_CHECKSUM="yes"
```

##  使用方法

### 备份系统

```bash
sudo ./backup.sh
```

说明：
- 系统盘为必备备份对象。
- 第二块盘（如 NVMe）在 `ENABLE_DATA_BACKUP=auto` 时会自动检测并按条件备份。

### 还原系统

```bash
sudo ./restore.sh
```

说明：
- 若未设置 `SYSTEM_IMG` / `DATA_IMG`，脚本会自动选择备份目录中最新的镜像文件。
- 系统盘还原为必选；第二块盘还原按 `ENABLE_DATA_RESTORE` 策略决定。

##  重要注意事项

1. **文件位置**：脚本不要求放在根目录，任意路径可执行
2. **还原风险**：还原会覆盖目标盘全部数据，操作不可逆
3. **设备确认**：执行前务必使用 `lsblk` 核对 `SYSTEM_DEVICE` / `DATA_DEVICE`
4. **元数据与校验**：备份会额外生成 `.meta` 与 `.md5` 文件，请和镜像一起保存

##  项目结构

```
Jetson_Orin_Nano_backup/
 backup.sh
 restore.sh
 README.md
```

##  安全提醒

-  还原操作将完全覆盖目标设备上的所有数据
-  请确保重要数据已备份
-  操作前请仔细检查设备路径

##  支持

如有问题，请联系：
- 北理工控制组
- 陈炜：13395717389
- 或提交 GitHub Issue

##  许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

---

*本工具已适配 Jetson Orin Nano，使用前请确保您了解操作风险。*
