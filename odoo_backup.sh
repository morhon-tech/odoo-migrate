#!/bin/bash
# ====================================================
# odoo_backup.sh - Odoo智能备份脚本（严格版本记录版）
# 强制记录：Python版本、Odoo版本、PostgreSQL版本
# 输出：单个ZIP文件，包含版本元数据
# ====================================================

set -e
echo "========================================"
echo "    Odoo 生产环境智能备份（严格版）"
echo "========================================"

# 1. 环境检测与版本记录
echo "[阶段1] 记录系统版本信息..."
write_metadata() {
    cat > "$1" << META
# ===== Odoo 环境版本元数据 =====
备份时间: $(date)
原服务器: $(hostname)
系统: $(lsb_release -ds 2>/dev/null || uname -a)

# 关键版本信息
PYTHON_VERSION: $(python3 --version 2>/dev/null | cut -d' ' -f2 || echo "未知")
POSTGRESQL_VERSION: $(psql --version 2>/dev/null | cut -d' ' -f3 || echo "未知")
META
}

# 2. 智能探测Odoo进程
echo "[阶段2] 探测Odoo运行实例..."
ODOO_PID=$(ps aux | grep "odoo-bin" | grep -v grep | head -1 | awk '{print $2}')
if [ -z "$ODOO_PID" ]; then
    echo "[错误] 未找到运行的Odoo进程"
    echo "请确保Odoo正在运行或使用 -c 指定配置文件"
    exit 1
fi

# 提取关键路径
CONF_FILE=$(ps -p $ODOO_PID -o cmd= | grep -o "\-c [^ ]*" | cut -d' ' -f2)
if [ ! -f "$CONF_FILE" ]; then
    echo "[错误] 无法定位配置文件: $CONF_FILE"
    exit 1
fi

# 3. 解析配置信息
echo "[阶段3] 解析配置文件..."
DB_NAME=$(grep -E "^db_name\s*=" "$CONF_FILE" | head -1 | cut -d'=' -f2 | tr -d ' ' | tr -d '\r')
DATA_DIR=$(grep -E "^data_dir\s*=" "$CONF_FILE" | head -1 | cut -d'=' -f2 | tr -d ' ' | tr -d '\r')
HTTP_PORT=$(grep -E "^http_port\s*=" "$CONF_FILE" | head -1 | cut -d'=' -f2 | tr -d ' ' | tr -d '\r' || echo "8069")

echo "  数据库: $DB_NAME"
echo "  数据目录: ${DATA_DIR:-未设置}"
echo "  HTTP端口: $HTTP_PORT"

# 4. 创建备份目录结构
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
TEMP_DIR="/tmp/odoo_backup_$BACKUP_DATE"
echo "[阶段4] 创建备份目录: $TEMP_DIR"
mkdir -p $TEMP_DIR/{database,filestore,source,config,dependencies,fonts,metadata}

# 5. 强制获取并记录Odoo版本（关键！）
echo "[阶段5] 获取Odoo精确版本..."
ODOO_BIN_PATH=$(ps -p $ODOO_PID -o cmd= | awk '{print $2}')
if [ -f "$ODOO_BIN_PATH" ]; then
    ODOO_VERSION=$("$ODOO_BIN_PATH" --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+' || echo "未知")
    echo "  检测到Odoo版本: ${ODOO_VERSION:-未知}"
    
    # 记录到元数据
    echo "ODOO_VERSION: $ODOO_VERSION" >> "$TEMP_DIR/metadata/versions.txt"
    echo "ODOO_BIN_PATH: $ODOO_BIN_PATH" >> "$TEMP_DIR/metadata/versions.txt"
    
    # 记录完整的版本输出
    "$ODOO_BIN_PATH" --version > "$TEMP_DIR/metadata/odoo_version_full.txt" 2>/dev/null || true
else
    echo "[警告] 无法获取Odoo二进制路径，版本检测失败"
    ODOO_VERSION="未知"
fi

# 6. 记录其他版本信息
write_metadata "$TEMP_DIR/metadata/system_info.txt"
echo "PYTHON_EXACT_VERSION: $(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")' 2>/dev/null || echo "未知")" >> "$TEMP_DIR/metadata/versions.txt"

# 7. 备份数据库（使用与版本兼容的参数）
echo "[阶段6] 备份PostgreSQL数据库..."
DB_DUMP_FILE="$TEMP_DIR/database/dump.sql"
# 使用最兼容的参数，避免版本问题
BACKUP_CMD="pg_dump \"$DB_NAME\" --no-owner --no-acl --encoding=UTF-8 --schema=public"

if sudo -u postgres sh -c "$BACKUP_CMD" > "$DB_DUMP_FILE" 2>/dev/null; then
    DUMP_SIZE=$(du -h "$DB_DUMP_FILE" | cut -f1)
    echo "  数据库备份完成: $DUMP_SIZE"
    
    # 在SQL文件头部添加版本注释
    sed -i "1i-- PostgreSQL Dump\n-- Source: $DB_NAME\n-- Odoo Version: $ODOO_VERSION\n-- Dump time: $(date)\n" "$DB_DUMP_FILE"
else
    echo "[错误] 数据库备份失败"
    echo "尝试手动命令: sudo -u postgres pg_dump $DB_NAME --no-owner --no-acl --encoding=UTF-8"
    exit 1
fi

# 8. 备份文件存储
echo "[阶段7] 备份文件存储..."
if [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR/filestore/$DB_NAME" ]; then
    FILESTORE_SRC="$DATA_DIR/filestore/$DB_NAME"
    FILESTORE_COUNT=$(find "$FILESTORE_SRC" -type f | wc -l)
    cp -r "$FILESTORE_SRC" "$TEMP_DIR/filestore/"
    echo "  文件数: $FILESTORE_COUNT"
else
    # 尝试常见路径
    for path in "/var/lib/odoo/filestore/$DB_NAME" "$HOME/.local/share/Odoo/filestore/$DB_NAME"; do
        if [ -d "$path" ]; then
            cp -r "$path" "$TEMP_DIR/filestore/"
            echo "  从 $path 备份文件存储"
            break
        fi
    done
fi

# 9. 备份源代码和自定义模块
echo "[阶段8] 备份源码与模块..."
ODOO_DIR=$(dirname "$ODOO_BIN_PATH")
if [ -d "$ODOO_DIR" ]; then
    # 备份核心源码（排除缓存文件）
    find "$ODOO_DIR" -maxdepth 1 -type f -name "*.py" -o -name "odoo-bin" | \
        xargs -I {} cp {} "$TEMP_DIR/source/" 2>/dev/null || true
    
    # 备份odoo核心addons
    if [ -d "$ODOO_DIR/odoo/addons" ]; then
        mkdir -p "$TEMP_DIR/source/odoo_core_addons"
        find "$ODOO_DIR/odoo/addons" -maxdepth 2 -name "__manifest__.py" | head -5 | \
            xargs -I {} cp --parents {} "$TEMP_DIR/source/odoo_core_addons/" 2>/dev/null || true
    fi
fi

# 10. 备份自定义模块
echo "[阶段9] 备份自定义模块..."
ADDONS_PATH=$(grep -E "^addons_path\s*=" "$CONF_FILE" | head -1 | cut -d'=' -f2 | tr -d '\r')
IFS=',' read -ra ADDR <<< "$ADDONS_PATH"
for path in "${ADDR[@]}"; do
    clean_path=$(echo "$path" | tr -d ' ' | tr -d '\r')
    # 跳过标准Odoo路径，只备份自定义目录
    if [[ "$clean_path" != *"odoo/addons"* ]] && [ -d "$clean_path" ]; then
        dir_name=$(basename "$clean_path")
        cp -r "$clean_path" "$TEMP_DIR/source/custom_${dir_name}" 2>/dev/null || true
        echo "  备份模块: $dir_name"
    fi
done

# 11. 智能分析Python依赖
echo "[阶段10] 分析Python依赖..."
DEP_REPORT="$TEMP_DIR/dependencies/requirements_analysis.txt"
echo "# Odoo依赖分析报告" > "$DEP_REPORT"
echo "# Odoo版本: $ODOO_VERSION" >> "$DEP_REPORT"
echo "# 生成时间: $(date)" >> "$DEP_REPORT"
echo "" >> "$DEP_REPORT"

# 获取当前Python环境的所有包
PYTHON_PATH=$(ps -p $ODOO_PID -o cmd= | awk '{print $1}')
if [ -f "$(dirname "$PYTHON_PATH")/activate" ]; then
    # 虚拟环境
    source "$(dirname "$PYTHON_PATH")/activate"
    echo "# 虚拟环境包列表" >> "$DEP_REPORT"
    pip freeze >> "$DEP_REPORT" 2>&1 || echo "# 无法获取pip列表" >> "$DEP_REPORT"
    deactivate
else
    # 系统Python
    echo "# 系统Python包列表" >> "$DEP_REPORT"
    pip3 freeze >> "$DEP_REPORT" 2>&1 || echo "# 无法获取pip3列表" >> "$DEP_REPORT"
fi

# 12. 收集中文字体
echo "[阶段11] 收集中文字体..."
FONT_PATHS=(
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc"
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
)
for font_path in "${FONT_PATHS[@]}"; do
    if [ -f "$font_path" ]; then
        cp "$font_path" "$TEMP_DIR/fonts/"
    fi
done

# 13. 备份配置文件和服务文件
cp "$CONF_FILE" "$TEMP_DIR/config/"
[ -f "/etc/systemd/system/odoo.service" ] && \
    cp "/etc/systemd/system/odoo.service" "$TEMP_DIR/config/" 2>/dev/null || true

# 14. 创建恢复说明
cat > "$TEMP_DIR/RESTORE_INSTRUCTIONS.md" << EOF
# Odoo 恢复说明

## 备份信息
- Odoo版本: $ODOO_VERSION
- 数据库: $DB_NAME
- 原HTTP端口: $HTTP_PORT
- 备份时间: $(date)

## 恢复选项

### 1. 源码恢复（推荐，与原环境一致）
\`\`\`bash
./restore_odoo.sh
\`\`\`

### 2. Docker恢复（容器化部署）
\`\`\`bash
./restore_odoo_docker.sh
\`\`\`

## 重要提醒
1. 恢复前请确认新服务器的PostgreSQL版本 >= 原服务器版本
2. 如果使用Docker恢复，确保已安装Docker和Docker Compose
3. 恢复后运行 \`./configure_nginx.sh\` 配置域名访问
EOF

# 15. 打包为单个ZIP文件
ZIP_FILE="$HOME/odoo_backup_$BACKUP_DATE.zip"
echo "[阶段12] 创建打包文件: $(basename "$ZIP_FILE")"
cd /tmp && zip -rq "$ZIP_FILE" "$(basename "$TEMP_DIR")"

# 16. 清理与验证
BACKUP_SIZE=$(du -h "$ZIP_FILE" | cut -f1)
echo "[阶段13] 验证备份文件..."
if [ -f "$ZIP_FILE" ]; then
    echo "========================================"
    echo "✅ 备份成功完成！"
    echo "========================================"
    echo "备份文件: $ZIP_FILE"
    echo "文件大小: $BACKUP_SIZE"
    echo "Odoo版本: $ODOO_VERSION"
    echo ""
    echo "下一步操作:"
    echo "1. 将ZIP文件复制到新服务器"
    echo "2. 运行恢复脚本（与ZIP文件同目录）"
    echo "3. 建议使用源码恢复: ./restore_odoo.sh"
    echo "========================================"
else
    echo "[错误] 打包文件创建失败"
    exit 1
fi

# 清理临时文件
rm -rf "$TEMP_DIR"