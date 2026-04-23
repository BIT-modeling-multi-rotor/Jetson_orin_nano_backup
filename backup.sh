#!/bin/bash



set -euo pipefail  # 严格错误处理

# === 配置区域 ===
# 默认挂载点（请根据实际情况修改）
DEFAULT_BACKUP_DIR="/media/xuanyi/火箭组"
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"

# 设备路径（Orin Nano 常见配置）
# - SYSTEM_DEVICE: 系统盘。留空时自动从根分区反查整盘
# - DATA_DEVICE: 可选扩展盘。默认留空，避免误备份到备份U盘
SYSTEM_DEVICE="${SYSTEM_DEVICE:-}"
DATA_DEVICE="${DATA_DEVICE:-}"
ENABLE_DATA_BACKUP="${ENABLE_DATA_BACKUP:-no}"  # auto|yes|no
IGNORE_SPACE_CHECK="${IGNORE_SPACE_CHECK:-yes}"    # yes|no

# 镜像文件名（含时间戳）
DATE=$(date +%F_%H-%M-%S)
SYSTEM_IMG="$BACKUP_DIR/orin_nano_system_backup_$DATE.img.gz"
DATA_IMG="$BACKUP_DIR/orin_nano_data_backup_$DATE.img.gz"

# 日志文件
LOG_FILE="$BACKUP_DIR/backup_$DATE.log"

# === 函数定义 ===
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "❌ 错误: $1"
    exit 1
}

require_command() {
    local cmd=$1
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error_exit "缺少依赖命令: $cmd"
    fi
}

check_dependencies() {
    local cmds=(dd gzip md5sum findmnt lsblk blockdev df awk tee)
    local c
    for c in "${cmds[@]}"; do
        require_command "$c"
    done
}

check_device() {
    local device=$1
    local name=$2
    
    if [ ! -b "$device" ]; then
        error_exit "$name 设备 $device 不存在"
    fi
    
    if [ ! -r "$device" ]; then
        error_exit "无法读取 $name 设备 $device，请检查权限"
    fi
    
    log "✅ $name 设备 $device 检查通过"
}

should_backup_data_device() {
    case "$ENABLE_DATA_BACKUP" in
        yes)
            if [ -z "$DATA_DEVICE" ]; then
                error_exit "ENABLE_DATA_BACKUP=yes 时必须设置 DATA_DEVICE"
            fi
            return 0
            ;;
        no)
            return 1
            ;;
        auto)
            if [ -n "$DATA_DEVICE" ] && [ -b "$DATA_DEVICE" ] && [ -r "$DATA_DEVICE" ]; then
                return 0
            fi
            return 1
            ;;
        *)
            error_exit "ENABLE_DATA_BACKUP 仅支持 auto|yes|no，当前值: $ENABLE_DATA_BACKUP"
            ;;
    esac
}

resolve_system_device() {
    if [ -n "$SYSTEM_DEVICE" ]; then
        check_device "$SYSTEM_DEVICE" "系统盘"
        return
    fi

    local root_source parent
    root_source=$(findmnt -no SOURCE / 2>/dev/null || true)
    [ -n "$root_source" ] || error_exit "无法检测根文件系统设备，请手动设置 SYSTEM_DEVICE"
    [ -b "$root_source" ] || error_exit "检测到根设备 $root_source 不是块设备，请手动设置 SYSTEM_DEVICE"

    parent=$(lsblk -no PKNAME "$root_source" 2>/dev/null | head -n 1 || true)
    if [ -n "$parent" ]; then
        SYSTEM_DEVICE="/dev/$parent"
    else
        SYSTEM_DEVICE="$root_source"
    fi

    [ -b "$SYSTEM_DEVICE" ] || error_exit "自动解析系统盘失败，请手动设置 SYSTEM_DEVICE"
    log "🔎 自动检测系统盘: $SYSTEM_DEVICE (根分区来源: $root_source)"
}

validate_devices() {
    if [ -n "$DATA_DEVICE" ] && [ "$DATA_DEVICE" = "$SYSTEM_DEVICE" ]; then
        error_exit "DATA_DEVICE 与 SYSTEM_DEVICE 不能相同: $SYSTEM_DEVICE"
    fi
}

get_device_size() {
    local device=$1
    local size=$(blockdev --getsize64 "$device" 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo $((size / 1024 / 1024))  # 转换为 MB
    else
        echo "未知"
    fi
}

check_space() {
    local required_mb=$1

    if [ "$IGNORE_SPACE_CHECK" = "yes" ]; then
        log "ℹ️ 已跳过空间检查（IGNORE_SPACE_CHECK=yes）"
        return
    fi

    local available_mb=$(df "$BACKUP_DIR" | awk 'NR==2 {print int($4/1024)}')
    
    if [ "$available_mb" -lt "$required_mb" ]; then
        error_exit "存储空间不足。需要: ${required_mb}MB，可用: ${available_mb}MB"
    fi
    
    log "✅ 存储空间检查通过。可用: ${available_mb}MB"
}

backup_device() {
    local device=$1
    local output_file=$2
    local device_name=$3
    
    log "📦 开始备份 $device_name ($device) 到 $output_file..."
    
    # 获取设备大小
    local device_size_bytes
    device_size_bytes=$(blockdev --getsize64 "$device" 2>/dev/null || true)
    [ -n "$device_size_bytes" ] || error_exit "无法获取 $device_name 容量"
    local device_size=$((device_size_bytes / 1024 / 1024))
    log "📊 $device_name 大小: ${device_size}MB"
    
    # 执行备份
    if dd if="$device" bs=4M status=progress 2>>"$LOG_FILE" | gzip -c > "$output_file"; then
        # 验证输出文件
        if [ -f "$output_file" ] && [ -s "$output_file" ]; then
            local backup_size=$(du -m "$output_file" | cut -f1)
            log "✅ $device_name 备份完成！压缩后大小: ${backup_size}MB"
            
            # 计算校验和
            local checksum=$(md5sum "$output_file" | cut -d' ' -f1)
            echo "$checksum  $output_file" > "${output_file}.md5"
            echo "$checksum  $output_file" >> "$BACKUP_DIR/checksums_$DATE.md5"
            log "🔐 校验和: $checksum"

            # 写入元数据，供恢复前校验目标盘容量
            cat > "${output_file}.meta" <<EOF
SOURCE_DEVICE=$device
SOURCE_SIZE_BYTES=$device_size_bytes
CREATED_AT=$(date '+%Y-%m-%d %H:%M:%S')
IMAGE_FILE=$output_file
EOF
            log "📝 元数据已生成: ${output_file}.meta"
        else
            error_exit "$device_name 备份失败，输出文件无效"
        fi
    else
        error_exit "$device_name 备份过程中发生错误"
    fi
}

# === 主程序 ===
echo "🚀 Jetson Orin Nano 系统备份工具 v3.0"
echo "📅 备份时间: $(date)"
echo "==========================================="

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    error_exit "请使用 sudo 运行此脚本"
fi

check_dependencies

# 检查备份目录
if [ ! -d "$BACKUP_DIR" ]; then
    error_exit "挂载目录 $BACKUP_DIR 不存在，请确认 U 盘已正确挂载"
fi

if [ ! -w "$BACKUP_DIR" ]; then
    error_exit "挂载目录 $BACKUP_DIR 不可写，请检查权限"
fi

resolve_system_device
validate_devices

log "🎯 备份目录: $BACKUP_DIR"
log "🎯 系统设备: $SYSTEM_DEVICE"
log "🎯 数据设备: $DATA_DEVICE (策略: $ENABLE_DATA_BACKUP)"
log "🎯 空间检查策略: IGNORE_SPACE_CHECK=$IGNORE_SPACE_CHECK"

# 设备检查
check_device "$SYSTEM_DEVICE" "系统盘"

# 计算所需空间（预估压缩比 50%）
system_size=$(get_device_size "$SYSTEM_DEVICE")
[ "$system_size" != "未知" ] || error_exit "无法获取系统盘容量，无法继续"
required_space=$((system_size / 2))

if should_backup_data_device; then
    check_device "$DATA_DEVICE" "数据盘"
    data_size=$(get_device_size "$DATA_DEVICE")
    [ "$data_size" != "未知" ] || error_exit "无法获取数据盘容量，无法继续"
    required_space=$((required_space + data_size / 2))
    backup_data=true
else
    backup_data=false
    log "ℹ️ 未启用或未检测到可读数据盘，跳过第二块盘备份"
fi

log "📊 预估所需空间: ${required_space}MB"
check_space "$required_space"

# 创建校验和文件
echo "# Jetson Orin Nano 备份校验和文件" > "$BACKUP_DIR/checksums_$DATE.md5"
echo "# 创建时间: $(date)" >> "$BACKUP_DIR/checksums_$DATE.md5"

# 执行备份
backup_device "$SYSTEM_DEVICE" "$SYSTEM_IMG" "系统盘"

if [ "$backup_data" = true ]; then
    backup_device "$DATA_DEVICE" "$DATA_IMG" "数据盘"
fi

# 同步文件系统
sync

log "🎉 所有备份完成！"
echo "📁 备份文件位置:"
echo "   - 系统盘: $SYSTEM_IMG"
if [ "$backup_data" = true ]; then
    echo "   - 数据盘: $DATA_IMG"
fi
echo "   - 日志: $LOG_FILE"
echo "   - 校验和: $BACKUP_DIR/checksums_$DATE.md5"
echo ""
echo "⚠️  请妥善保存备份文件和校验和文件！"