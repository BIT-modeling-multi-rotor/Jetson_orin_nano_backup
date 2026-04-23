# host_restore.sh 使用说明（Ubuntu 20.04）

本文说明如何在主机侧使用 host_restore.sh 恢复由 backup.sh 生成的镜像文件。

## 1. 适用范围

- 脚本：host_restore.sh
- 主机系统：Ubuntu 20.04
- 镜像文件格式：
  - orin_nano_system_backup_*.img.gz
  - orin_nano_data_backup_*.img.gz（可选）
- 配套文件支持：
  - .md5
  - .meta（使用 SOURCE_SIZE_BYTES 做目标盘容量预检查）

重要说明：

- host_restore.sh 只能写入“主机可见的块设备”。
- 如果 Orin Nano 处于恢复模式，但目标存储没有作为块设备暴露给主机，则该脚本无法直接写入。

## 2. Ubuntu 20.04 虚拟机可行性确认

结论：可以在 Ubuntu 20.04 虚拟机中完成镜像拷贝，但必须满足以下前提。

- 虚拟机已开启 USB 直通，并且在整个写盘过程中不会掉线。
- 目标盘在虚拟机内可见为块设备（例如 /dev/nvme0n1 或 /dev/sdX）。
- 目标盘及其分区未被挂载。
- 虚拟机磁盘与内存资源充足，宿主机电源管理不会中断 USB 设备。

如果以上条件任一不满足，建议改用原生 Ubuntu 主机执行，以避免中途中断导致恢复失败。



## 3. 环境准备

在 Ubuntu 主机或 Ubuntu 20.04 虚拟机中执行：

```bash
sudo apt-get update
sudo apt-get install -y coreutils findutils util-linux gzip
```

赋予脚本可执行权限：

```bash
chmod +x host_restore.sh
```

## 4. 变量说明

必填变量：

- SYSTEM_DEVICE：系统盘目标设备，例如 /dev/nvme0n1

可选变量：

- BACKUP_DIR：镜像目录（默认 /mnt/backup）
- SYSTEM_IMG：显式指定系统镜像；不填则自动选择 BACKUP_DIR 下最新系统镜像
- ENABLE_DATA_RESTORE：auto|yes|no（默认 no）
- DATA_DEVICE：当 ENABLE_DATA_RESTORE=yes 时必须设置
- DATA_IMG：可选，不填则自动选择最新数据镜像
- STRICT_CHECKSUM：yes|no（默认 yes）
- ASSUME_YES：yes|no（默认 no）
- LOG_FILE：自定义日志文件路径（默认写入 BACKUP_DIR）

## 5. 典型操作流程

1. 识别设备：

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

1. 卸载目标盘分区（示例）：

```bash
sudo umount /dev/nvme0n1p1
sudo umount /dev/nvme0n1p2
```

1. 仅恢复系统盘：

```bash
sudo env \
  BACKUP_DIR=/mnt/backup \
  SYSTEM_DEVICE=/dev/nvme0n1 \
  ENABLE_DATA_RESTORE=no \
  STRICT_CHECKSUM=yes \
  ./host_restore.sh
```

1. 同时恢复系统盘和数据盘：

```bash
sudo env \
  BACKUP_DIR=/mnt/backup \
  SYSTEM_DEVICE=/dev/nvme0n1 \
  DATA_DEVICE=/dev/sdb \
  ENABLE_DATA_RESTORE=yes \
  STRICT_CHECKSUM=yes \
  ./host_restore.sh
```

1. 无交互模式（仅 CI/批量场景）：

```bash
sudo env \
  BACKUP_DIR=/mnt/backup \
  SYSTEM_DEVICE=/dev/nvme0n1 \
  ASSUME_YES=yes \
  ./host_restore.sh
```

## 6. 安全规则

- 请对整盘节点恢复（例如 /dev/nvme0n1），不要写入分区节点。
- 写入前确认目标盘未挂载。
- 输入 YES 前务必核对“镜像文件”和“目标设备”的对应关系。
- dd 写入期间保持供电稳定，不要中断。

## 7. 恢复后验证

```bash
sync
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

设备启动后验证根分区来源：

```bash
findmnt -no SOURCE /
```

## 8. 常见错误

- target or its partitions are mounted：目标盘或其分区仍在挂载，先全部卸载。
- Checksum sidecar not found：未找到同名 md5 文件；仅在可接受风险时设置 STRICT_CHECKSUM=no。
- target too small：目标盘小于 .meta 中 SOURCE_SIZE_BYTES，需更换更大目标盘。
