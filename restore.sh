#!/bin/bash



set -euo pipefail  # 严格错误处理

# === 配置区域 ===
# 默认挂载点（请根据实际情况修改）
DEFAULT_BACKUP_DIR="/media/duidi/F0621C45E2148083"
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"

# 设备路径（Orin Nano 常见配置）
SYSTEM_DEVICE="${SYSTEM_DEVICE:-}"
DATA_DEVICE="${DATA_DEVICE:-}"
ENABLE_DATA_RESTORE="${ENABLE_DATA_RESTORE:-auto}"  # auto|yes|no
STRICT_CHECKSUM="${STRICT_CHECKSUM:-yes}"            # yes|no

# 镜像文件（可通过环境变量覆盖，不传则自动选取最新镜像）
SYSTEM_IMG="${SYSTEM_IMG:-}"
DATA_IMG="${DATA_IMG:-}"

# 日志文件
LOG_FILE="$BACKUP_DIR/restore_$(date +%F_%H-%M-%S).log"

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
    local cmds=(dd gunzip gzip md5sum findmnt lsblk blockdev awk grep tee)
    local c
    for c in "${cmds[@]}"; do
        require_command "$c"
    done
}

check_file() {
    local file=$1
    local name=$2
    
    if [ ! -f "$file" ]; then
        error_exit "$name 镜像文件不存在: $file"
    fi
    
    if [ ! -r "$file" ]; then
        error_exit "无法读取 $name 镜像文件: $file"
    fi
    
    local size=$(du -h "$file" | cut -f1)
    log "✅ $name 镜像文件检查通过，大小: $size"
}

check_device() {
    local device=$1
    local name=$2
    
    if [ ! -b "$device" ]; then
        error_exit "$name 设备 $device 不存在"
    fi
    
    if [ ! -w "$device" ]; then
        error_exit "无法写入 $name 设备 $device，请检查权限"
    fi
    
    log "✅ $name 设备 $device 检查通过"
}

find_latest_image() {
    local pattern=$1
    local latest_file

    latest_file=$(ls -1t $pattern 2>/dev/null | head -n 1 || true)
    if [ -n "$latest_file" ] && [ -f "$latest_file" ]; then
        echo "$latest_file"
        return 0
    fi

    return 1
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

resolve_images() {
    if [ -z "$SYSTEM_IMG" ]; then
        SYSTEM_IMG=$(find_latest_image "$BACKUP_DIR/orin_nano_system_backup_*.img.gz" || true)
    fi

    if [ -z "$SYSTEM_IMG" ]; then
        error_exit "未找到系统盘镜像，请设置 SYSTEM_IMG 或检查备份目录"
    fi

    if [ -z "$DATA_IMG" ]; then
        DATA_IMG=$(find_latest_image "$BACKUP_DIR/orin_nano_data_backup_*.img.gz" || true)
    fi
}

should_restore_data_device() {
    case "$ENABLE_DATA_RESTORE" in
        yes)
            if [ -z "$DATA_DEVICE" ] || [ -z "$DATA_IMG" ]; then
                error_exit "ENABLE_DATA_RESTORE=yes 时必须设置 DATA_DEVICE 且存在 DATA_IMG"
            fi
            return 0
            ;;
        no)
            return 1
            ;;
        auto)
            if [ -n "$DATA_IMG" ] && [ -b "$DATA_DEVICE" ] && [ -w "$DATA_DEVICE" ]; then
                return 0
            fi
            return 1
            ;;
        *)
            error_exit "ENABLE_DATA_RESTORE 仅支持 auto|yes|no，当前值: $ENABLE_DATA_RESTORE"
            ;;
    esac
}

verify_checksum() {
    local file=$1
    local sidecar="${file}.md5"

    if [ -f "$sidecar" ]; then
        log "🔐 使用镜像同名校验文件验证: $sidecar"
        if md5sum -c "$sidecar" --status; then
            log "✅ 校验和验证通过"
        else
            if [ "$STRICT_CHECKSUM" = "yes" ]; then
                error_exit "校验和验证失败: $file"
            fi
            log "⚠️  校验和验证失败，但 STRICT_CHECKSUM=no，继续执行"
        fi
    else
        if [ "$STRICT_CHECKSUM" = "yes" ]; then
            error_exit "未找到校验文件: $sidecar（可设置 STRICT_CHECKSUM=no 跳过）"
        fi
        log "⚠️  未找到校验文件，已按 STRICT_CHECKSUM=no 跳过"
    fi
}

get_meta_value() {
    local image_file=$1
    local key=$2
    local meta_file="${image_file}.meta"

    if [ ! -f "$meta_file" ]; then
        return 1
    fi

    awk -F'=' -v k="$key" '$1==k {print $2}' "$meta_file" | head -n 1
}

check_target_size() {
    local image_file=$1
    local device=$2
    local device_name=$3

    local source_size_bytes
    source_size_bytes=$(get_meta_value "$image_file" "SOURCE_SIZE_BYTES" || true)
    if [ -z "$source_size_bytes" ]; then
        log "⚠️  未找到镜像元数据中的 SOURCE_SIZE_BYTES，跳过容量预检查"
        return
    fi

    local target_size_bytes
    target_size_bytes=$(blockdev --getsize64 "$device" 2>/dev/null || true)
    [ -n "$target_size_bytes" ] || error_exit "无法读取 $device_name 容量"

    if [ "$target_size_bytes" -lt "$source_size_bytes" ]; then
        error_exit "$device_name 容量不足。目标: ${target_size_bytes}B，镜像来源盘: ${source_size_bytes}B"
    fi

    log "✅ $device_name 容量校验通过"
}

restore_device() {
    local image_file=$1
    local device=$2
    local device_name=$3
    
    log "🔄 开始还原 $device_name ($device)..."
    log "📂 镜像文件: $image_file"
    
    # 验证校验和
    verify_checksum "$image_file"

    # 目标盘容量预检查
    check_target_size "$image_file" "$device" "$device_name"
    
    # 获取设备信息
    local device_size=$(blockdev --getsize64 "$device" 2>/dev/null || echo "未知")
    if [ "$device_size" != "未知" ]; then
        device_size=$((device_size / 1024 / 1024))
        log "📊 目标设备大小: ${device_size}MB"
    fi
    
    # 执行还原
    log "⚡ 正在还原 $device_name..."
    if gunzip -c "$image_file" | dd of="$device" bs=4M status=progress 2>>"$LOG_FILE"; then
        log "✅ $device_name 还原完成"
    else
        error_exit "$device_name 还原过程中发生错误"
    fi
}

countdown() {
    local seconds=$1
    while [ $seconds -gt 0 ]; do
        echo -ne "⏱️  ${seconds} 秒后继续...\r"
        sleep 1
        seconds=$((seconds - 1))
    done
    echo -e "⏱️  继续执行...           "
}

# === 主程序 ===
echo "🔄 Jetson Orin Nano 系统还原工具 v3.0"
echo "📅 还原时间: $(date)"
echo "==========================================="

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    error_exit "请使用 sudo 运行此脚本"
fi

check_dependencies
resolve_system_device
validate_devices

log "🎯 备份目录: $BACKUP_DIR"
log "🎯 系统设备: $SYSTEM_DEVICE"
log "🎯 数据设备: $DATA_DEVICE (策略: $ENABLE_DATA_RESTORE)"
log "🎯 校验策略: STRICT_CHECKSUM=$STRICT_CHECKSUM"

# 自动解析镜像
resolve_images
log "📂 系统盘镜像: $SYSTEM_IMG"
if [ -n "$DATA_IMG" ]; then
    log "📂 数据盘镜像: $DATA_IMG"
else
    log "ℹ️ 未找到数据盘镜像，将仅还原系统盘"
fi

# 文件存在性检查
check_file "$SYSTEM_IMG" "系统盘"
if [ -n "$DATA_IMG" ]; then
    check_file "$DATA_IMG" "数据盘"
fi

# 设备检查
check_device "$SYSTEM_DEVICE" "系统盘"
if should_restore_data_device; then
    check_device "$DATA_DEVICE" "数据盘"
    restore_data=true
else
    restore_data=false
    log "ℹ️ 未启用或未满足数据盘还原条件，跳过第二块盘还原"
fi

# === 最终确认 ===
echo ""
echo "⚠️ ⚠️ ⚠️  危险操作警告  ⚠️ ⚠️ ⚠️"
echo ""
echo "您即将执行系统还原操作，这将："
echo "🔥 完全覆盖系统盘 ($SYSTEM_DEVICE) 上的所有数据"
if [ "$restore_data" = true ]; then
    echo "🔥 完全覆盖数据盘 ($DATA_DEVICE) 上的所有数据"
fi
echo "🔥 无法撤销此操作"
echo ""
echo "📂 将使用以下镜像文件:"
echo "   - 系统盘: $SYSTEM_IMG"
if [ "$restore_data" = true ]; then
    echo "   - 数据盘: $DATA_IMG"
fi
echo ""

read -p "❓ 请输入 'YES' (全大写) 确认操作: " confirm

if [ "$confirm" != "YES" ]; then
    log "🚫 操作已取消"
    echo "🚫 操作已取消"
    exit 0
fi

log "⚠️  用户确认开始还原操作"

# 给用户最后5秒考虑时间
echo ""
echo "⏱️  最后确认倒计时..."
countdown 5

# 执行还原
restore_device "$SYSTEM_IMG" "$SYSTEM_DEVICE" "系统盘"

echo ""
echo "⚠️  系统盘还原完成"
echo ""

if [ "$restore_data" = true ]; then
    read -p "❓ 继续还原数据盘？(y/N): " continue_data
    if [[ "$continue_data" =~ ^[Yy]$ ]]; then
        restore_device "$DATA_IMG" "$DATA_DEVICE" "数据盘"
    else
        log "⏸️  用户选择跳过数据盘还原"
        echo "⏸️  数据盘还原已跳过"
    fi
fi

# 同步磁盘缓存
log "💾 同步磁盘缓存..."
sync

log "🎉 还原操作完成！"
echo ""
echo "✅ 还原完成！"
echo "📁 日志文件: $LOG_FILE"
echo ""
echo "💡 建议手动重启系统以确保所有更改生效"
echo "💻 重启命令: sudo reboot"