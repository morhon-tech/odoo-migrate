#!/bin/bash
# ====================================================
# odoo-migrate.sh - Odoo迁移工具（优化版）
# 功能：备份、恢复（源码）、Nginx配置
# 使用：./odoo-migrate.sh [backup|restore|nginx|help]
# 
# 作者：Morhon Technology
# 维护：huwencai.com
# 项目：https://github.com/morhon-tech/odoo-migrate
# 许可：MIT License
# ====================================================

set -euo pipefail

# 脚本信息
SCRIPT_VERSION="2.3.0"

# 获取真实用户信息（即使使用sudo运行）
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")

# 脚本目录（使用真实用户的路径）
if [[ -n "${SUDO_USER:-}" ]]; then
    # 如果是sudo运行，获取原始脚本路径
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

TEMP_BASE="/tmp/odoo_migrate_$$"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "${GREEN}[成功]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }

# 清理函数
cleanup() {
    [[ -n "${TEMP_BASE:-}" && -d "$TEMP_BASE" ]] && rm -rf "$TEMP_BASE"
}
trap cleanup EXIT

# 显示帮助信息
show_help() {
    cat << EOF
======================================
    Odoo 迁移工具 v$SCRIPT_VERSION
======================================

使用方法:
  $0 backup              # 备份当前Odoo环境
  $0 restore             # 恢复到源码环境
  $0 nginx               # 配置Nginx反向代理
  $0 status              # 查看当前状态
  $0 help                # 显示此帮助信息

功能特性:
  ✓ 智能环境检测和版本记录
  ✓ 完整源码备份（包含修改）
  ✓ 源码方式恢复部署
  ✓ 自动Nginx配置和SSL证书
  ✓ 性能和安全优化

示例:
  ./odoo-migrate.sh backup           # 备份当前环境
  ./odoo-migrate.sh restore          # 源码方式恢复
  ./odoo-migrate.sh nginx            # 配置域名访问

EOF
}

# 检查系统要求
check_system() {
    log_info "检查系统环境..."
    
    # 检查是否为root或sudo运行
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        log_info "请使用: sudo $0 $*"
        exit 1
    fi
    
    # 检查是否为Ubuntu系统
    if ! command -v lsb_release &> /dev/null || ! lsb_release -i | grep -q "Ubuntu"; then
        log_error "此脚本仅支持Ubuntu系统"
        log_info "推荐使用Ubuntu 20.04 LTS或更高版本"
        exit 1
    fi
    
    # 检查Ubuntu版本
    local ubuntu_version
    ubuntu_version=$(lsb_release -r | cut -f2)
    local version_major=$(echo "$ubuntu_version" | cut -d. -f1)
    local version_minor=$(echo "$ubuntu_version" | cut -d. -f2)
    
    if [[ "$version_major" -lt 20 ]] || [[ "$version_major" -eq 20 && "$version_minor" -lt 4 ]]; then
        log_error "Ubuntu版本过低，需要20.04或更高版本"
        log_info "当前版本: $ubuntu_version"
        log_info "推荐使用Ubuntu 20.04 LTS或更高版本"
        exit 1
    fi
    
    log_success "检测到Ubuntu $ubuntu_version"
    if [[ "$ubuntu_version" == "20.04" ]] || [[ "$ubuntu_version" == "22.04" ]] || [[ "$ubuntu_version" == "24.04" ]]; then
        log_success "使用兼容的Ubuntu LTS版本"
    fi
    
    # 显示真实用户信息
    if [[ -n "${SUDO_USER:-}" ]]; then
        log_info "以sudo方式运行，真实用户: $REAL_USER"
    fi
    
    log_success "系统检查通过"
}

# 智能检测Odoo环境
detect_odoo_environment() {
    log_info "检测Odoo运行环境..."
    
    # 检测运行中的Odoo进程
    if ! ODOO_PID=$(pgrep -f "odoo-bin" | head -1); then
        log_error "未找到运行的Odoo进程，请确保Odoo正在运行"
        log_info "检查命令: ps aux | grep odoo-bin"
        log_info "启动命令: systemctl start odoo"
        return 1
    fi
    
    log_info "找到Odoo进程: PID $ODOO_PID"
    
    # 获取配置文件路径
    ODOO_CONF=$(ps -p "$ODOO_PID" -o cmd= | grep -o "\-c [^ ]*" | cut -d' ' -f2 || echo "")
    if [[ ! -f "$ODOO_CONF" ]]; then
        log_error "无法定位配置文件: $ODOO_CONF"
        log_info "尝试查找常见位置..."
        for conf in /etc/odoo/odoo.conf /etc/odoo.conf ~/.odoorc; do
            if [[ -f "$conf" ]]; then
                ODOO_CONF="$conf"
                log_info "找到配置文件: $ODOO_CONF"
                break
            fi
        done
        if [[ ! -f "$ODOO_CONF" ]]; then
            log_error "无法找到Odoo配置文件"
            return 1
        fi
    fi
    
    # 解析配置信息
    DB_NAME=$(grep -E "^db_name\s*=" "$ODOO_CONF" | head -1 | cut -d'=' -f2 | tr -d ' \r' || echo "")
    DATA_DIR=$(grep -E "^data_dir\s*=" "$ODOO_CONF" | head -1 | cut -d'=' -f2 | tr -d ' \r' || echo "")
    HTTP_PORT=$(grep -E "^http_port\s*=" "$ODOO_CONF" | head -1 | cut -d'=' -f2 | tr -d ' \r' || echo "8069")
    ADDONS_PATH=$(grep -E "^addons_path\s*=" "$ODOO_CONF" | head -1 | cut -d'=' -f2 | tr -d '\r' || echo "")
    
    # 获取Odoo版本和路径
    ODOO_BIN_PATH=$(ps -p "$ODOO_PID" -o cmd= | awk '{print $2}')
    if [[ -f "$ODOO_BIN_PATH" ]]; then
        ODOO_VERSION=$("$ODOO_BIN_PATH" --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+' || echo "未知")
        # ODOO_DIR应该是odoo-bin的父目录的父目录（如果是标准结构）
        # 例如: /opt/odoo/odoo/odoo-bin -> ODOO_DIR=/opt/odoo
        local bin_parent=$(dirname "$ODOO_BIN_PATH")
        if [[ "$(basename "$bin_parent")" == "odoo" ]]; then
            ODOO_DIR=$(dirname "$bin_parent")
        else
            ODOO_DIR="$bin_parent"
        fi
    else
        ODOO_VERSION="未知"
        ODOO_DIR=""
    fi
    
    PYTHON_VERSION=$(python3 --version 2>/dev/null | cut -d' ' -f2 || echo "未知")
    
    log_success "环境检测完成"
    log_info "  配置文件: $ODOO_CONF"
    log_info "  数据库: ${DB_NAME:-未设置}"
    log_info "  数据目录: ${DATA_DIR:-未设置}"
    log_info "  HTTP端口: $HTTP_PORT"
    log_info "  Odoo版本: $ODOO_VERSION"
    log_info "  Odoo目录: $ODOO_DIR"
    log_info "  Python版本: $PYTHON_VERSION"
    
    return 0
}
# 备份功能
backup_odoo() {
    echo "========================================"
    echo "    Odoo 智能备份"
    echo "========================================"
    
    check_system
    detect_odoo_environment || exit 1
    
    # 创建备份目录
    local backup_date=$(date +%Y%m%d_%H%M%S)
    local backup_dir="$TEMP_BASE/odoo_backup_$backup_date"
    mkdir -p "$backup_dir"/{database,filestore,source,config,metadata}
    
    log_info "创建备份目录: $backup_dir"
    
    # 记录完整环境元数据
    log_info "收集完整运行环境信息..."
    
    # 获取系统信息
    local ubuntu_version=$(lsb_release -r | cut -f2)
    local ubuntu_codename=$(lsb_release -c | cut -f2)
    local kernel_version=$(uname -r)
    local cpu_cores=$(nproc)
    local total_mem=$(free -h | awk '/^Mem:/ {print $2}')
    local disk_space=$(df -h / | awk 'NR==2 {print $2}')
    
    # 获取PostgreSQL详细信息
    local pg_version=$(psql --version 2>/dev/null | cut -d' ' -f3 || echo "未知")
    local pg_port=$(sudo -u postgres psql -tAc "SHOW port;" 2>/dev/null || echo "5432")
    local pg_max_conn=$(sudo -u postgres psql -tAc "SHOW max_connections;" 2>/dev/null || echo "未知")
    local pg_shared_buffers=$(sudo -u postgres psql -tAc "SHOW shared_buffers;" 2>/dev/null || echo "未知")
    
    # 获取Redis信息
    local redis_version=$(redis-server --version 2>/dev/null | grep -oP 'v=\K[0-9.]+' || echo "未知")
    local redis_port=$(grep "^port" /etc/redis/redis.conf 2>/dev/null | awk '{print $2}' || echo "6379")
    local redis_maxmem=$(grep "^maxmemory" /etc/redis/redis.conf 2>/dev/null | awk '{print $2}' || echo "未设置")
    
    # 获取Python包信息
    local pip_packages=""
    if [[ -n "$ODOO_DIR" && -d "$ODOO_DIR/venv" ]]; then
        pip_packages=$("$ODOO_DIR/venv/bin/pip" list --format=freeze 2>/dev/null || echo "")
    fi
    
    # 获取wkhtmltopdf版本
    local wkhtmltopdf_version=$(wkhtmltopdf --version 2>/dev/null | head -1 || echo "未安装")
    
    # 获取Node.js和npm版本
    local node_version=$(node --version 2>/dev/null || echo "未安装")
    local npm_version=$(npm --version 2>/dev/null || echo "未安装")
    
    # 记录完整环境信息
    cat > "$backup_dir/metadata/environment.txt" << EOF
# Odoo完整运行环境信息
# 备份时间: $(date '+%Y-%m-%d %H:%M:%S')
# 备份主机: $(hostname)

[系统信息]
UBUNTU_VERSION: $ubuntu_version
UBUNTU_CODENAME: $ubuntu_codename
KERNEL_VERSION: $kernel_version
CPU_CORES: $cpu_cores
TOTAL_MEMORY: $total_mem
DISK_SPACE: $disk_space
HOSTNAME: $(hostname)
TIMEZONE: $(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "未知")

[Odoo信息]
ODOO_VERSION: $ODOO_VERSION
ODOO_BIN_PATH: $ODOO_BIN_PATH
ODOO_DIR: $ODOO_DIR
ODOO_CONF: $ODOO_CONF
DB_NAME: ${DB_NAME:-未设置}
DATA_DIR: ${DATA_DIR:-未设置}
HTTP_PORT: $HTTP_PORT
ADDONS_PATH: ${ADDONS_PATH:-未设置}
ODOO_USER: $REAL_USER

[Python环境]
PYTHON_VERSION: $PYTHON_VERSION
PYTHON_PATH: $(which python3)
PYTHON_EXECUTABLE: $(readlink -f $(which python3))

[PostgreSQL信息]
POSTGRESQL_VERSION: $pg_version
POSTGRESQL_PORT: $pg_port
POSTGRESQL_MAX_CONNECTIONS: $pg_max_conn
POSTGRESQL_SHARED_BUFFERS: $pg_shared_buffers
POSTGRESQL_DATA_DIR: $(sudo -u postgres psql -tAc "SHOW data_directory;" 2>/dev/null || echo "未知")

[Redis信息]
REDIS_VERSION: $redis_version
REDIS_PORT: $redis_port
REDIS_MAXMEMORY: $redis_maxmem
REDIS_CONF: /etc/redis/redis.conf

[其他依赖]
WKHTMLTOPDF_VERSION: $wkhtmltopdf_version
WKHTMLTOPDF_PATH: $(which wkhtmltopdf 2>/dev/null || echo "未安装")
NODE_VERSION: $node_version
NPM_VERSION: $npm_version
LESS_VERSION: $(lessc --version 2>/dev/null || echo "未安装")

[系统服务]
ODOO_SERVICE: $(systemctl is-enabled odoo 2>/dev/null || echo "未配置")
POSTGRESQL_SERVICE: $(systemctl is-enabled postgresql 2>/dev/null || echo "未配置")
REDIS_SERVICE: $(systemctl is-enabled redis-server 2>/dev/null || echo "未配置")
NGINX_SERVICE: $(systemctl is-enabled nginx 2>/dev/null || echo "未配置")

[备份信息]
BACKUP_DATE: $backup_date
BACKUP_TYPE: 完整备份（源码+数据+配置+环境）
BACKUP_SCRIPT_VERSION: $SCRIPT_VERSION
EOF

    # 保存Python包列表
    if [[ -n "$pip_packages" ]]; then
        echo "$pip_packages" > "$backup_dir/metadata/python_packages.txt"
        log_info "  已保存Python包列表 ($(echo "$pip_packages" | wc -l) 个包)"
    else
        log_warning "  未找到Python虚拟环境或包列表"
        cat > "$backup_dir/metadata/python_packages.txt" << 'PYEOF'
# Python包列表未找到
# 可能原因: 虚拟环境不存在或路径不正确
# 恢复时将安装Odoo核心依赖包
PYEOF
    fi
    
    # 保存系统包信息
    log_info "收集系统包信息..."
    dpkg -l | grep -E "(python3|postgresql|redis|nginx|node|wkhtmltopdf)" > "$backup_dir/metadata/system_packages.txt" 2>/dev/null || true
    
    # 保存PostgreSQL配置
    local pg_conf_path=""
    for version in $(ls /etc/postgresql/ 2>/dev/null | sort -V -r); do
        if [[ -f "/etc/postgresql/$version/main/postgresql.conf" ]]; then
            pg_conf_path="/etc/postgresql/$version/main/postgresql.conf"
            break
        fi
    done
    if [[ -n "$pg_conf_path" && -f "$pg_conf_path" ]]; then
        cp "$pg_conf_path" "$backup_dir/config/postgresql.conf" 2>/dev/null || true
        # 同时保存pg_hba.conf
        local pg_hba_path=$(dirname "$pg_conf_path")/pg_hba.conf
        [[ -f "$pg_hba_path" ]] && cp "$pg_hba_path" "$backup_dir/config/pg_hba.conf" 2>/dev/null || true
        log_info "  已备份PostgreSQL配置"
    fi
    
    # 保存系统服务配置
    if [[ -f "/etc/systemd/system/odoo.service" ]]; then
        cp "/etc/systemd/system/odoo.service" "$backup_dir/config/odoo.service" 2>/dev/null || true
        log_info "  已备份Odoo服务配置"
    fi
    
    # 保存Redis配置
    if [[ -f "/etc/redis/redis.conf" ]]; then
        cp "/etc/redis/redis.conf" "$backup_dir/config/redis.conf" 2>/dev/null || true
        log_info "  已备份Redis配置"
    fi
    
    # 保存Nginx配置（如果存在）
    if [[ -d "/etc/nginx/sites-enabled" ]]; then
        mkdir -p "$backup_dir/config/nginx"
        cp /etc/nginx/sites-enabled/odoo* "$backup_dir/config/nginx/" 2>/dev/null || true
        cp /etc/nginx/nginx.conf "$backup_dir/config/nginx/nginx.conf" 2>/dev/null || true
        log_info "  已备份Nginx配置"
    fi
    
    # 保存环境变量
    if [[ -f "$HOME/.bashrc" ]]; then
        grep -E "(ODOO|PATH)" "$HOME/.bashrc" > "$backup_dir/config/bashrc_odoo.txt" 2>/dev/null || true
    fi
    
    log_success "环境信息收集完成"
    
    # 兼容旧版本，保留versions.txt
    cat > "$backup_dir/metadata/versions.txt" << EOF
ODOO_VERSION: $ODOO_VERSION
PYTHON_VERSION: $PYTHON_VERSION
POSTGRESQL_VERSION: $pg_version
ODOO_BIN_PATH: $ODOO_BIN_PATH
BACKUP_DATE: $backup_date
ORIGINAL_HOST: $(hostname)
EOF
    
    # 备份数据库
    log_info "备份PostgreSQL数据库..."
    local db_dump_file="$backup_dir/database/dump.sql"
    
    # 检查数据库是否存在
    if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "${DB_NAME:-odoo}"; then
        log_error "数据库 ${DB_NAME:-odoo} 不存在"
        exit 1
    fi
    
    # 执行备份
    if sudo -u postgres pg_dump "${DB_NAME:-odoo}" \
        --no-owner --no-acl --encoding=UTF-8 \
        --format=plain --verbose \
        > "$db_dump_file" 2>/dev/null; then
        
        local dump_size=$(du -h "$db_dump_file" | cut -f1)
        local dump_lines=$(wc -l < "$db_dump_file")
        log_success "数据库备份完成"
        log_info "  文件大小: $dump_size"
        log_info "  SQL行数: $dump_lines"
        
        # 添加版本注释
        sed -i "1i-- PostgreSQL Database Dump\\n-- Source Database: ${DB_NAME:-odoo}\\n-- Odoo Version: $ODOO_VERSION\\n-- Backup Time: $(date)\\n-- Backup Host: $(hostname)\\n" "$db_dump_file"
        
        # 创建数据库元数据
        cat > "$backup_dir/database/metadata.txt" << EOF
DATABASE_NAME: ${DB_NAME:-odoo}
DATABASE_SIZE: $(sudo -u postgres psql -tAc "SELECT pg_size_pretty(pg_database_size('${DB_NAME:-odoo}'));" 2>/dev/null || echo "未知")
TABLE_COUNT: $(sudo -u postgres psql -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" "${DB_NAME:-odoo}" 2>/dev/null || echo "未知")
BACKUP_TIME: $(date '+%Y-%m-%d %H:%M:%S')
POSTGRESQL_VERSION: $pg_version
EOF
    else
        log_error "数据库备份失败"
        log_info "请检查:"
        log_info "  1. PostgreSQL服务是否运行: sudo systemctl status postgresql"
        log_info "  2. 数据库是否存在: sudo -u postgres psql -l"
        log_info "  3. 权限是否正确: sudo -u postgres psql -c '\\du'"
        exit 1
    fi
    
    # 备份文件存储
    log_info "备份文件存储..."
    local filestore_paths=(
        "${DATA_DIR}/filestore/${DB_NAME:-odoo}"
        "/var/lib/odoo/filestore/${DB_NAME:-odoo}"
        "$HOME/.local/share/Odoo/filestore/${DB_NAME:-odoo}"
    )
    
    local filestore_found=false
    for path in "${filestore_paths[@]}"; do
        if [[ -d "$path" ]]; then
            log_info "  找到filestore: $path"
            
            # 使用rsync进行高效备份
            if command -v rsync &> /dev/null; then
                rsync -a --info=progress2 "$path/" "$backup_dir/filestore/$(basename "$path")/" 2>/dev/null || {
                    log_warning "  rsync失败，使用cp备份..."
                    cp -r "$path" "$backup_dir/filestore/" 2>/dev/null || true
                }
            else
                cp -r "$path" "$backup_dir/filestore/" 2>/dev/null || true
            fi
            
            local filestore_count=$(find "$path" -type f 2>/dev/null | wc -l)
            local filestore_size=$(du -sh "$path" 2>/dev/null | cut -f1)
            
            log_success "文件存储备份完成"
            log_info "  文件数量: $filestore_count"
            log_info "  存储大小: $filestore_size"
            
            # 保存filestore元数据
            cat > "$backup_dir/filestore/metadata.txt" << EOF
FILESTORE_PATH: $path
FILE_COUNT: $filestore_count
TOTAL_SIZE: $filestore_size
BACKUP_TIME: $(date '+%Y-%m-%d %H:%M:%S')
EOF
            
            filestore_found=true
            break
        fi
    done
    
    if [[ "$filestore_found" = false ]]; then
        log_warning "未找到filestore目录，可能是新安装或未使用文件存储"
        echo "FILESTORE_NOT_FOUND: true" > "$backup_dir/filestore/metadata.txt"
    fi
    
    # 备份完整Odoo源码（强制备份整个目录）
    if [[ -n "$ODOO_DIR" && -d "$ODOO_DIR" ]]; then
        log_info "备份完整Odoo源码目录..."
        
        # 强制备份整个Odoo源码目录，包含所有可能的修改
        local source_backup_dir="$backup_dir/source/odoo_complete"
        mkdir -p "$source_backup_dir"
        
        log_info "  正在复制完整源码目录（这可能需要几分钟）..."
        
        # 使用rsync进行高效备份，排除不必要的文件
        if command -v rsync &> /dev/null; then
            rsync -a --info=progress2 \
                  --exclude='*.pyc' \
                  --exclude='__pycache__' \
                  --exclude='*.log' \
                  --exclude='*.swp' \
                  --exclude='.git/objects' \
                  --exclude='filestore' \
                  --exclude='sessions' \
                  "$ODOO_DIR/" "$source_backup_dir/" 2>/dev/null || {
                log_warning "  rsync失败，使用cp备份..."
                cp -r "$ODOO_DIR/"* "$source_backup_dir/" 2>/dev/null || true
            }
        else
            cp -r "$ODOO_DIR/"* "$source_backup_dir/" 2>/dev/null || true
        fi
        
        # 清理不需要的文件
        log_info "  清理临时文件..."
        find "$source_backup_dir" -name "*.pyc" -delete 2>/dev/null || true
        find "$source_backup_dir" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
        find "$source_backup_dir" -name "*.log" -delete 2>/dev/null || true
        
        # 记录源码信息
        local source_size=$(du -sh "$source_backup_dir" | cut -f1)
        local py_files=$(find "$source_backup_dir" -name "*.py" | wc -l)
        
        log_success "完整源码备份完成"
        log_info "  目录大小: $source_size"
        log_info "  Python文件: $py_files"
        
        # 记录Git信息（如果存在）
        if [[ -d "$ODOO_DIR/.git" ]]; then
            log_info "  记录Git版本信息..."
            cd "$ODOO_DIR"
            
            # 保存Git提交历史
            git log --oneline -20 > "$backup_dir/metadata/git_commits.txt" 2>/dev/null || true
            
            # 保存未提交的修改
            git diff HEAD > "$backup_dir/metadata/git_modifications.txt" 2>/dev/null || true
            
            # 保存工作区状态
            git status --porcelain > "$backup_dir/metadata/git_status.txt" 2>/dev/null || true
            
            # 保存当前分支和远程信息
            cat > "$backup_dir/metadata/git_info.txt" << EOF
CURRENT_BRANCH: $(git branch --show-current 2>/dev/null || echo "未知")
CURRENT_COMMIT: $(git rev-parse HEAD 2>/dev/null || echo "未知")
REMOTE_URL: $(git remote get-url origin 2>/dev/null || echo "未配置")
LAST_COMMIT_DATE: $(git log -1 --format=%cd 2>/dev/null || echo "未知")
LAST_COMMIT_MESSAGE: $(git log -1 --format=%s 2>/dev/null || echo "未知")
EOF
            
            cd - > /dev/null
            log_info "  Git信息已保存"
        fi
        
        # 检查源码修改
        local modified_files=0
        if [[ -f "$ODOO_DIR/odoo-bin" ]]; then
            modified_files=$(find "$ODOO_DIR" -name "*.py" -newer "$ODOO_DIR/odoo-bin" 2>/dev/null | wc -l)
        fi
        
        if [[ "$modified_files" -gt 0 ]]; then
            log_warning "  检测到 $modified_files 个可能被修改的Python文件"
            echo "MODIFIED_SOURCE_FILES: $modified_files" >> "$backup_dir/metadata/versions.txt"
        fi
        
        # 保存源码结构信息
        cat > "$backup_dir/source/structure.txt" << EOF
ODOO_DIR: $ODOO_DIR
ODOO_BIN: $ODOO_BIN_PATH
SOURCE_SIZE: $source_size
PYTHON_FILES: $py_files
MODIFIED_FILES: $modified_files
BACKUP_TIME: $(date '+%Y-%m-%d %H:%M:%S')
EOF
        
        echo "SOURCE_BACKUP_COMPLETE: true" >> "$backup_dir/metadata/versions.txt"
    else
        log_error "无法找到Odoo源码目录，备份失败"
        exit 1
    fi
    
    # 备份自定义模块
    if [[ -n "$ADDONS_PATH" ]]; then
        IFS=',' read -ra paths <<< "$ADDONS_PATH"
        for path in "${paths[@]}"; do
            local clean_path=$(echo "$path" | tr -d ' \r')
            if [[ "$clean_path" != *"odoo/addons"* && -d "$clean_path" ]]; then
                local dir_name=$(basename "$clean_path")
                cp -r "$clean_path" "$backup_dir/source/custom_${dir_name}" 2>/dev/null || true
                log_success "备份自定义模块: $dir_name"
            fi
        done
    fi
    
    # 备份配置文件
    [[ -f "$ODOO_CONF" ]] && cp "$ODOO_CONF" "$backup_dir/config/"
    [[ -f "/etc/systemd/system/odoo.service" ]] && cp "/etc/systemd/system/odoo.service" "$backup_dir/config/" 2>/dev/null || true
    [[ -f "/etc/redis/redis.conf" ]] && cp "/etc/redis/redis.conf" "$backup_dir/config/" 2>/dev/null || true
    
    # 创建恢复说明
    cat > "$backup_dir/RESTORE_INSTRUCTIONS.md" << EOF
# Odoo 完整环境恢复说明

## 备份信息
- **备份时间**: $(date '+%Y-%m-%d %H:%M:%S')
- **备份主机**: $(hostname)
- **Odoo版本**: $ODOO_VERSION
- **Python版本**: $PYTHON_VERSION
- **Ubuntu版本**: $ubuntu_version
- **数据库**: ${DB_NAME:-odoo}
- **HTTP端口**: $HTTP_PORT

## 备份内容
✓ 完整Odoo源码（包含所有修改）
✓ PostgreSQL数据库完整备份
✓ 文件存储（filestore）
✓ 所有配置文件（Odoo、PostgreSQL、Redis、Nginx）
✓ Python包列表
✓ 系统环境信息

## 恢复步骤

### 1. 准备新服务器
- 推荐使用 Ubuntu 20.04 LTS 或更高版本
- 确保服务器有足够的磁盘空间和内存
- 确保网络连接正常

### 2. 上传备份文件
\`\`\`bash
# 将备份文件上传到新服务器
scp odoo_backup_*.zip user@new-server:/path/to/odoo-migrate/
\`\`\`

### 3. 执行恢复
\`\`\`bash
cd /path/to/odoo-migrate/
chmod +x odoo-migrate.sh
./odoo-migrate.sh restore
\`\`\`

恢复脚本将自动：
1. 检查系统兼容性
2. 安装所有必需的系统依赖
3. 恢复PostgreSQL和Redis配置
4. 恢复完整Odoo源码
5. 创建Python虚拟环境并安装依赖
6. 恢复数据库和文件存储
7. 配置并启动Odoo服务

### 4. 配置域名访问（可选）
\`\`\`bash
./odoo-migrate.sh nginx
\`\`\`

### 5. 验证恢复
\`\`\`bash
# 查看服务状态
./odoo-migrate.sh status

# 查看服务日志
sudo journalctl -u odoo -f
\`\`\`

## 注意事项
- 恢复过程需要sudo权限
- 恢复时间取决于数据量大小，通常需要10-30分钟
- 如果目标服务器Ubuntu版本不同，脚本会自动进行兼容性调整
- 恢复完成后，建议立即修改admin密码

## 故障排查
如果恢复失败，请检查：
1. 系统日志: \`sudo journalctl -u odoo -xe\`
2. Odoo日志: \`tail -f /var/log/odoo/odoo.log\`
3. 配置文件: \`cat /etc/odoo/odoo.conf\`
4. 数据库连接: \`sudo -u postgres psql -l\`

## 技术支持
- 项目地址: https://github.com/morhon-tech/odoo-migrate
- 问题反馈: https://github.com/morhon-tech/odoo-migrate/issues
EOF
    
    log_success "恢复说明文档已创建"
    
    # 打包备份文件
    local zip_file="$SCRIPT_DIR/odoo_backup_$backup_date.zip"
    log_info "创建备份压缩包..."
    
    # 确保备份目录所有文件权限正确
    log_info "设置备份文件权限..."
    chown -R "$REAL_UID:$REAL_GID" "$backup_dir"
    
    cd "$TEMP_BASE"
    if zip -rq "$zip_file" "$(basename "$backup_dir")" 2>/dev/null; then
        # 修改备份文件所有者为真实用户
        chown "$REAL_UID:$REAL_GID" "$zip_file"
        
        local backup_size=$(du -h "$zip_file" | cut -f1)
        
        # 验证备份完整性
        log_info "验证备份完整性..."
        if unzip -tq "$zip_file" &>/dev/null; then
            log_success "备份文件完整性验证通过"
        else
            log_warning "备份文件可能损坏，建议重新备份"
        fi
        
        # 生成备份校验和
        local checksum=$(sha256sum "$zip_file" | cut -d' ' -f1)
        echo "$checksum  $(basename "$zip_file")" > "$zip_file.sha256"
        chown "$REAL_UID:$REAL_GID" "$zip_file.sha256"
        
        echo "========================================"
        log_success "备份完成！"
        echo "========================================"
        log_info "备份信息:"
        log_info "  文件名: $(basename "$zip_file")"
        log_info "  文件大小: $backup_size"
        log_info "  校验和: ${checksum:0:16}..."
        log_info "  Odoo版本: $ODOO_VERSION"
        log_info "  数据库: ${DB_NAME:-odoo}"
        log_info "  文件所有者: $REAL_USER"
        echo ""
        log_info "备份内容:"
        echo "  ✓ 完整Odoo源码"
        echo "  ✓ PostgreSQL数据库"
        echo "  ✓ 文件存储（filestore）"
        echo "  ✓ 所有配置文件"
        echo "  ✓ Python包列表"
        echo "  ✓ 系统环境信息"
        echo ""
        log_info "下一步操作:"
        echo "  1. 验证备份: unzip -t $(basename "$zip_file")"
        echo "  2. 传输到新服务器: scp $(basename "$zip_file") user@server:/path/"
        echo "  3. 在新服务器上恢复: sudo ./odoo-migrate.sh restore"
        echo ""
        log_info "备份文件位置:"
        echo "  $zip_file"
        echo "  $zip_file.sha256"
        echo "========================================"
    else
        log_error "备份文件创建失败"
        log_info "可能原因:"
        echo "  - 磁盘空间不足"
        echo "  - 权限不足"
        echo "  - zip命令未安装"
        exit 1
    fi
}

# 安装系统依赖
install_system_dependencies() {
    log_info "安装系统依赖..."
    
    # 更新包列表
    sudo apt-get update -qq
    
    # 检测Ubuntu版本以安装合适的包
    local ubuntu_version=$(lsb_release -r | cut -f2)
    local version_major=$(echo "$ubuntu_version" | cut -d. -f1)
    
    # 基础依赖包
    local base_packages=(
        postgresql postgresql-contrib libpq-dev
        redis-server redis-tools
        build-essential libxml2-dev libxslt1-dev
        libldap2-dev libsasl2-dev libssl-dev
        zlib1g-dev libjpeg-dev libfreetype6-dev
        liblcms2-dev libtiff5-dev libwebp-dev
        python3-pip python3-venv python3-dev
        fonts-wqy-zenhei fontconfig curl wget git unzip rsync
        nginx certbot python3-certbot-nginx
    )
    
    # Ubuntu 20.04需要特殊处理node-less和nodejs
    if [[ "$version_major" -eq 20 ]]; then
        log_info "检测到Ubuntu 20.04，配置Node.js环境..."
        
        # 检查是否已安装nodejs
        if ! command -v node &> /dev/null; then
            # 使用NodeSource安装较新版本的Node.js
            log_info "安装Node.js 16.x LTS..."
            curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash -
            sudo apt-get install -y nodejs
        fi
        
        # 使用npm全局安装less和less-plugin-clean-css
        log_info "安装less编译器..."
        sudo npm install -g less less-plugin-clean-css
    else
        # Ubuntu 22.04及以上可以直接安装node-less
        base_packages+=(node-less)
    fi
    
    # 安装所有依赖
    log_info "安装系统包..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${base_packages[@]}"
    
    # 启动并启用Redis
    sudo systemctl start redis-server 2>/dev/null || true
    sudo systemctl enable redis-server 2>/dev/null || true
    
    # 启动并启用PostgreSQL
    sudo systemctl start postgresql 2>/dev/null || true
    sudo systemctl enable postgresql 2>/dev/null || true
    
    log_success "系统依赖安装完成"
}

# 安装wkhtmltopdf
install_wkhtmltopdf() {
    if ! command -v wkhtmltopdf &> /dev/null; then
        log_info "安装wkhtmltopdf..."
        
        # 获取Ubuntu版本和架构
        local ubuntu_codename=$(lsb_release -c -s)
        local ubuntu_version=$(lsb_release -r | cut -f2)
        local version_major=$(echo "$ubuntu_version" | cut -d. -f1)
        local arch=$(dpkg --print-architecture)
        
        # Ubuntu 20.04使用focal，22.04使用jammy，24.04使用noble
        local target_codename="$ubuntu_codename"
        case "$version_major" in
            20) target_codename="focal" ;;
            22) target_codename="jammy" ;;
            24) target_codename="noble" ;;
        esac
        
        # 尝试从apt安装
        if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y wkhtmltopdf 2>/dev/null; then
            log_success "wkhtmltopdf安装成功（apt）"
            return 0
        fi
        
        # apt安装失败，尝试下载deb包
        log_info "从GitHub下载wkhtmltopdf..."
        local deb_file="wkhtmltox_0.12.6.1-2.${target_codename}_${arch}.deb"
        local download_url="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/${deb_file}"
        
        # 如果特定版本不存在，使用focal版本（兼容性最好）
        if ! wget -q --spider "$download_url" 2>/dev/null; then
            log_warning "未找到${target_codename}版本，使用focal版本"
            deb_file="wkhtmltox_0.12.6.1-2.focal_${arch}.deb"
            download_url="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/${deb_file}"
        fi
        
        # 下载并安装
        if wget -q "$download_url" -O "/tmp/$deb_file" 2>/dev/null; then
            sudo dpkg -i "/tmp/$deb_file" 2>/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -f -y
            rm -f "/tmp/$deb_file"
            log_success "wkhtmltopdf安装成功（deb包）"
        else
            log_warning "wkhtmltopdf自动安装失败"
            log_info "可以稍后手动安装: sudo apt-get install wkhtmltopdf"
            log_info "或访问: https://wkhtmltopdf.org/downloads.html"
        fi
    else
        log_success "wkhtmltopdf已安装: $(wkhtmltopdf --version | head -1)"
    fi
}

# 优化Redis配置
optimize_redis() {
    log_info "优化Redis配置..."
    
    local redis_conf="/etc/redis/redis.conf"
    if [[ -f "$redis_conf" ]]; then
        # 备份原配置
        sudo cp "$redis_conf" "$redis_conf.backup.$(date +%Y%m%d)"
        
        # 获取系统内存
        local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        local total_mem_mb=$((total_mem_kb / 1024))
        local redis_mem=$((total_mem_mb / 8))  # Redis使用1/8内存
        
        # 应用Redis优化配置
        sudo bash -c "cat >> $redis_conf" << EOF

# Odoo Redis Optimizations - Added $(date)
maxmemory ${redis_mem}mb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
timeout 300
tcp-keepalive 300
databases 16
EOF
        
        sudo systemctl restart redis-server
        log_success "Redis优化完成，分配内存: ${redis_mem}MB"
    else
        log_warning "Redis配置文件不存在，跳过优化"
    fi
}
optimize_postgresql() {
    log_info "优化PostgreSQL配置..."
    
    local postgres_conf=""
    for version in $(ls /etc/postgresql/ 2>/dev/null | sort -V -r); do
        if [[ -f "/etc/postgresql/$version/main/postgresql.conf" ]]; then
            postgres_conf="/etc/postgresql/$version/main/postgresql.conf"
            break
        fi
    done
    
    if [[ -n "$postgres_conf" && -f "$postgres_conf" ]]; then
        sudo cp "$postgres_conf" "$postgres_conf.backup.$(date +%Y%m%d)"
        
        local total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        local total_mem_mb=$((total_mem_kb / 1024))
        local shared_buffers=$((total_mem_mb / 4))
        local effective_cache_size=$((total_mem_mb * 3 / 4))
        local work_mem=$((total_mem_mb / 64))
        local maintenance_work_mem=$((total_mem_mb / 16))
        
        sudo bash -c "cat >> $postgres_conf" << EOF

# Odoo Performance Optimizations - Added $(date)
shared_buffers = ${shared_buffers}MB
effective_cache_size = ${effective_cache_size}MB
work_mem = ${work_mem}MB
maintenance_work_mem = ${maintenance_work_mem}MB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
max_worker_processes = 8
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
EOF
        
        sudo systemctl restart postgresql
        log_success "PostgreSQL优化完成"
    fi
}

# 源码恢复功能
restore_source() {
    echo "========================================"
    echo "    Odoo 源码环境恢复"
    echo "========================================"
    
    check_system
    
    # 定位备份文件
    local backup_file
    backup_file=$(ls -1t "$SCRIPT_DIR"/odoo_backup_*.zip 2>/dev/null | head -1)
    if [[ -z "$backup_file" ]]; then
        log_error "当前目录未找到备份文件 (odoo_backup_*.zip)"
        exit 1
    fi
    log_info "找到备份文件: $(basename "$backup_file")"
    
    # 解压备份文件
    log_info "解压备份文件..."
    local restore_dir="$TEMP_BASE/restore"
    mkdir -p "$restore_dir"
    
    # 验证备份文件完整性
    if [[ -f "$backup_file.sha256" ]]; then
        log_info "验证备份文件完整性..."
        if cd "$(dirname "$backup_file")" && sha256sum -c "$(basename "$backup_file").sha256" &>/dev/null; then
            log_success "备份文件完整性验证通过"
        else
            log_warning "备份文件校验和不匹配，文件可能已损坏"
            read -p "是否继续恢复? [y/N]: " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
        cd - > /dev/null
    fi
    
    # 解压文件
    if unzip -q "$backup_file" -d "$restore_dir" 2>/dev/null; then
        log_success "备份文件解压完成"
    else
        log_error "备份文件解压失败"
        log_info "请检查:"
        echo "  1. 文件是否完整: ls -lh $backup_file"
        echo "  2. 磁盘空间是否充足: df -h"
        echo "  3. 解压测试: unzip -t $backup_file"
        exit 1
    fi
    
    local backup_root
    backup_root=$(find "$restore_dir" -type d -name "odoo_backup_*" | head -1)
    
    if [[ ! -d "$backup_root" ]]; then
        log_error "备份文件格式错误"
        exit 1
    fi
    
    # 读取完整环境信息
    local env_file="$backup_root/metadata/environment.txt"
    if [[ -f "$env_file" ]]; then
        log_info "读取原环境信息..."
        
        # 提取关键环境变量
        ODOO_VERSION=$(grep "^ODOO_VERSION:" "$env_file" | cut -d' ' -f2)
        PYTHON_VERSION=$(grep "^PYTHON_VERSION:" "$env_file" | cut -d' ' -f2)
        UBUNTU_VERSION=$(grep "^UBUNTU_VERSION:" "$env_file" | cut -d' ' -f2)
        PG_VERSION=$(grep "^POSTGRESQL_VERSION:" "$env_file" | cut -d' ' -f2)
        REDIS_VERSION=$(grep "^REDIS_VERSION:" "$env_file" | cut -d' ' -f2)
        
        log_info "原环境信息:"
        log_info "  Ubuntu: $UBUNTU_VERSION"
        log_info "  Odoo: $ODOO_VERSION"
        log_info "  Python: $PYTHON_VERSION"
        log_info "  PostgreSQL: $PG_VERSION"
        log_info "  Redis: $REDIS_VERSION"
        
        # 检查当前系统与原系统的兼容性
        local current_ubuntu=$(lsb_release -r | cut -f2)
        local current_python=$(python3 --version | cut -d' ' -f2)
        
        echo ""
        log_info "当前系统信息:"
        log_info "  Ubuntu: $current_ubuntu"
        log_info "  Python: $current_python"
        
        # 兼容性检查
        if [[ "$current_ubuntu" != "$UBUNTU_VERSION" ]]; then
            log_warning "Ubuntu版本不同 (原:$UBUNTU_VERSION 现:$current_ubuntu)"
            log_info "将进行兼容性恢复..."
        fi
        
        # Python版本检查
        local orig_py_major=$(echo "$PYTHON_VERSION" | cut -d. -f1-2)
        local curr_py_major=$(echo "$current_python" | cut -d. -f1-2)
        if [[ "$orig_py_major" != "$curr_py_major" ]]; then
            log_warning "Python主版本不同 (原:$orig_py_major 现:$curr_py_major)"
            log_info "可能需要重新编译某些Python包"
        fi
        
    elif [[ -f "$backup_root/metadata/versions.txt" ]]; then
        # 兼容旧版本备份
        log_warning "使用旧版本备份格式，环境信息可能不完整"
        ODOO_VERSION=$(grep "ODOO_VERSION:" "$backup_root/metadata/versions.txt" | cut -d' ' -f2)
        PYTHON_VERSION=$(grep "PYTHON_VERSION:" "$backup_root/metadata/versions.txt" | cut -d' ' -f2)
        log_info "原环境版本 - Odoo: $ODOO_VERSION, Python: $PYTHON_VERSION"
    else
        log_error "备份中缺少环境元数据"
        exit 1
    fi
    
    if [[ "$ODOO_VERSION" = "未知" || -z "$ODOO_VERSION" ]]; then
        log_error "备份中未记录Odoo版本，无法精确恢复"
        exit 1
    fi
    
    echo ""
    read -p "是否继续恢复? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "用户取消恢复"
        exit 0
    fi
    
    # 第一步：恢复运行环境
    log_info "========== 第一步：恢复运行环境 =========="
    
    # 安装系统依赖
    install_system_dependencies
    install_wkhtmltopdf
    
    # 恢复PostgreSQL配置（如果备份中有）
    if [[ -f "$backup_root/config/postgresql.conf" ]]; then
        log_info "恢复PostgreSQL配置..."
        local pg_conf_path=""
        for version in $(ls /etc/postgresql/ 2>/dev/null | sort -V -r); do
            if [[ -d "/etc/postgresql/$version/main" ]]; then
                pg_conf_path="/etc/postgresql/$version/main/postgresql.conf"
                break
            fi
        done
        
        if [[ -n "$pg_conf_path" ]]; then
            sudo cp "$pg_conf_path" "$pg_conf_path.backup.$(date +%Y%m%d_%H%M%S)"
            # 合并配置而不是完全覆盖
            log_info "  合并PostgreSQL优化配置..."
            sudo bash -c "echo '' >> '$pg_conf_path'"
            sudo bash -c "echo '# Restored from backup - $(date)' >> '$pg_conf_path'"
            sudo bash -c "cat '$backup_root/config/postgresql.conf' | grep -E '^[^#]' | grep -E '(shared_buffers|effective_cache_size|work_mem|maintenance_work_mem)' >> '$pg_conf_path'" 2>/dev/null || true
            sudo systemctl restart postgresql
            log_success "PostgreSQL配置已恢复"
        fi
    else
        # 如果没有备份配置，使用优化配置
        optimize_postgresql
    fi
    
    # 恢复Redis配置（如果备份中有）
    if [[ -f "$backup_root/config/redis.conf" ]]; then
        log_info "恢复Redis配置..."
        sudo cp /etc/redis/redis.conf /etc/redis/redis.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
        # 只恢复关键配置项
        log_info "  合并Redis优化配置..."
        sudo bash -c "grep -E '^(maxmemory|maxmemory-policy|save)' '$backup_root/config/redis.conf' >> /etc/redis/redis.conf" 2>/dev/null || true
        sudo systemctl restart redis-server
        log_success "Redis配置已恢复"
    else
        optimize_redis
    fi
    
    log_success "运行环境恢复完成"
    
    # 第二步：恢复Odoo源码
    log_info "========== 第二步：恢复Odoo源码 =========="
    
    # 创建Odoo目录
    local odoo_dir="/opt/odoo"
    mkdir -p "$odoo_dir"
    chown -R "$REAL_USER:$REAL_USER" "$odoo_dir"
    
    # 恢复完整Odoo源码（强制使用备份的源码）
    if [[ -d "$backup_root/source/odoo_complete" && -n "$(ls -A "$backup_root/source/odoo_complete" 2>/dev/null)" ]]; then
        log_info "恢复完整Odoo源码（使用备份的源码）..."
        
        # 检查是否有源码备份标记
        local source_complete=$(grep "SOURCE_BACKUP_COMPLETE:" "$backup_root/metadata/versions.txt" | cut -d' ' -f2 2>/dev/null || echo "false")
        if [[ "$source_complete" = "true" ]]; then
            log_success "检测到完整源码备份，开始恢复..."
            cp -r "$backup_root/source/odoo_complete/"* "$odoo_dir/"
            
            # 检查是否有源码修改记录
            local modified_count=$(grep "MODIFIED_SOURCE_FILES:" "$backup_root/metadata/versions.txt" | cut -d' ' -f2 2>/dev/null || echo "0")
            if [[ "$modified_count" -gt 0 ]]; then
                log_warning "恢复了包含 $modified_count 个修改文件的源码"
            fi
            
            # 恢复Git信息（如果存在）
            if [[ -f "$backup_root/metadata/git_commits.txt" ]]; then
                log_info "检测到Git历史记录"
                cp "$backup_root/metadata/git_"*.txt "$odoo_dir/" 2>/dev/null || true
            fi
        else
            log_error "备份中的源码不完整，无法恢复"
            exit 1
        fi
    elif [[ -d "$backup_root/source/odoo_core" && -n "$(ls -A "$backup_root/source/odoo_core" 2>/dev/null)" ]]; then
        # 兼容旧版本备份格式
        log_info "恢复Odoo源码（兼容模式）..."
        cp -r "$backup_root/source/odoo_core/"* "$odoo_dir/"
    else
        log_error "备份中未找到Odoo源码，无法恢复"
        log_error "请确保备份文件完整且包含源码目录"
        exit 1
    fi
    
    # 恢复自定义模块
    local custom_dir="$odoo_dir/custom_addons"
    mkdir -p "$custom_dir"
    for custom in "$backup_root/source"/custom_*; do
        if [[ -d "$custom" ]]; then
            cp -r "$custom" "$custom_dir/"
            log_success "恢复模块: $(basename "$custom")"
        fi
    done
    
    # 第三步：创建Python虚拟环境并安装依赖
    log_info "========== 第三步：配置Python环境 =========="
    
    local venv_path="$odoo_dir/venv"
    
    # 检查Python版本兼容性
    local current_python=$(python3 --version | cut -d' ' -f2)
    log_info "当前Python版本: $current_python"
    log_info "原环境Python版本: $PYTHON_VERSION"
    
    # 创建虚拟环境（使用真实用户）
    log_info "创建Python虚拟环境..."
    su - "$REAL_USER" -c "python3 -m venv '$venv_path'" || {
        log_warning "使用su创建失败，直接创建..."
        python3 -m venv "$venv_path"
        chown -R "$REAL_USER:$REAL_USER" "$venv_path"
    }
    
    # 激活虚拟环境
    source "$venv_path/bin/activate"
    
    # 升级pip和基础工具
    log_info "升级pip和基础工具..."
    pip install --upgrade pip setuptools wheel -q
    
    # 如果有备份的Python包列表，使用它
    if [[ -f "$backup_root/metadata/python_packages.txt" ]]; then
        log_info "从备份恢复Python包..."
        
        # 先尝试完整恢复
        if pip install -r "$backup_root/metadata/python_packages.txt" -q 2>/dev/null; then
            log_success "Python包完整恢复成功"
        else
            log_warning "部分包安装失败，安装核心依赖..."
            
            # 安装核心依赖
            pip install -q psycopg2-binary Babel Pillow lxml reportlab python-dateutil \
                pytz decorator docutils polib requests passlib werkzeug \
                python-ldap pyserial qrcode vobject xlrd xlwt xlsxwriter \
                2>/dev/null || log_warning "部分核心包安装失败"
        fi
    else
        log_info "安装Odoo核心Python依赖..."
        
        # 安装核心依赖包
        pip install -q psycopg2-binary Babel Pillow lxml reportlab python-dateutil \
            pytz decorator docutils polib requests passlib werkzeug \
            python-ldap pyserial qrcode vobject xlrd xlwt xlsxwriter \
            2>/dev/null || log_warning "部分核心包安装失败"
    fi
    
    # 安装Odoo requirements（如果存在）
    if [[ -f "$odoo_dir/requirements.txt" ]]; then
        log_info "安装Odoo requirements.txt..."
        pip install -r "$odoo_dir/requirements.txt" -q 2>/dev/null || log_warning "部分requirements安装失败"
    fi
    
    # 验证关键包
    log_info "验证关键Python包..."
    local missing_packages=()
    for pkg in psycopg2 lxml Pillow; do
        if ! python -c "import $pkg" 2>/dev/null; then
            missing_packages+=("$pkg")
        fi
    done
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_warning "缺少关键包: ${missing_packages[*]}"
        log_info "尝试重新安装..."
        pip install -q psycopg2-binary lxml Pillow 2>/dev/null || true
    fi
    
    deactivate
    
    # 确保虚拟环境所有者正确
    chown -R "$REAL_USER:$REAL_USER" "$venv_path"
    
    log_success "Python环境配置完成"
    
    # 第四步：恢复数据库
    log_info "========== 第四步：恢复数据库 =========="
    
    # 确保PostgreSQL运行
    sudo systemctl start postgresql 2>/dev/null || true
    sudo systemctl enable postgresql 2>/dev/null || true
    
    # 等待PostgreSQL完全启动
    log_info "等待PostgreSQL启动..."
    local pg_ready=false
    for i in {1..30}; do
        if sudo -u postgres psql -c "SELECT 1" &>/dev/null; then
            pg_ready=true
            break
        fi
        sleep 1
    done
    
    if [[ "$pg_ready" = false ]]; then
        log_error "PostgreSQL启动失败"
        exit 1
    fi
    
    log_success "PostgreSQL已就绪"
    
    # 从备份中获取原数据库名称
    local original_db_name="${DB_NAME:-odoo}"
    local db_name="odoo_restored_$(date +%Y%m%d_%H%M%S)"
    
    log_info "原数据库名: $original_db_name"
    log_info "新数据库名: $db_name"
    
    # 创建数据库用户（如果不存在）
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$REAL_USER'" | grep -q 1; then
        log_info "创建数据库用户: $REAL_USER"
        sudo -u postgres createuser --superuser "$REAL_USER" 2>/dev/null || true
    fi
    
    # 恢复数据库
    if [[ -f "$backup_root/database/dump.sql" ]]; then
        log_info "创建数据库: $db_name"
        sudo -u postgres createdb -O "$REAL_USER" "$db_name" 2>/dev/null || {
            log_warning "数据库已存在，删除后重建"
            sudo -u postgres dropdb "$db_name" 2>/dev/null || true
            sudo -u postgres createdb -O "$REAL_USER" "$db_name"
        }
        
        log_info "导入数据库备份（这可能需要几分钟）..."
        if sudo -u postgres psql "$db_name" < "$backup_root/database/dump.sql" 2>/dev/null; then
            log_success "数据库恢复完成"
            
            # 验证数据库
            local table_count=$(sudo -u postgres psql -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" "$db_name" 2>/dev/null || echo "0")
            log_info "数据库表数量: $table_count"
        else
            log_error "数据库导入失败"
            exit 1
        fi
    else
        log_error "未找到数据库备份文件"
        exit 1
    fi
    
    # 第五步：恢复文件存储
    log_info "========== 第五步：恢复文件存储 =========="
    
    # 确定文件存储目录
    local filestore_base="/var/lib/odoo/filestore"
    local filestore_dir="$filestore_base/$db_name"
    
    # 创建文件存储目录
    mkdir -p "$filestore_base"
    chown -R "$REAL_USER:$REAL_USER" "$filestore_base"
    
    if [[ -d "$backup_root/filestore" ]]; then
        # 查找备份中的filestore目录
        local backup_filestore=$(find "$backup_root/filestore" -mindepth 1 -maxdepth 1 -type d | head -1)
        
        if [[ -n "$backup_filestore" && -d "$backup_filestore" ]]; then
            log_info "恢复文件存储到: $filestore_dir"
            mkdir -p "$filestore_dir"
            cp -r "$backup_filestore/"* "$filestore_dir/" 2>/dev/null || true
            
            # 统计文件数量
            local file_count=$(find "$filestore_dir" -type f 2>/dev/null | wc -l)
            local dir_size=$(du -sh "$filestore_dir" 2>/dev/null | cut -f1)
            
            log_success "文件存储恢复完成"
            log_info "  文件数量: $file_count"
            log_info "  存储大小: $dir_size"
        else
            log_warning "备份中未找到filestore内容"
        fi
    else
        log_warning "备份中未找到filestore目录"
    fi
    
    # 确保权限正确
    chown -R "$REAL_USER:$REAL_USER" "$filestore_base"
    log_success "文件存储权限设置完成"
    
    # 第六步：创建配置文件和服务
    log_info "========== 第六步：配置Odoo服务 =========="
    
    # 获取原HTTP端口
    local http_port="8069"
    if [[ -f "$backup_root/metadata/environment.txt" ]]; then
        http_port=$(grep "^HTTP_PORT:" "$backup_root/metadata/environment.txt" | cut -d' ' -f2 || echo "8069")
    elif [[ -f "$backup_root/metadata/system_info.txt" ]]; then
        http_port=$(grep "HTTP端口:" "$backup_root/metadata/system_info.txt" | cut -d':' -f2 | tr -d ' ' || echo "8069")
    fi
    
    # 检查端口是否被占用
    if ss -tln | grep -q ":$http_port "; then
        log_warning "端口 $http_port 已被占用，使用 8069"
        http_port="8069"
    fi
    
    log_info "配置HTTP端口: $http_port"
    
    # 创建配置目录
    mkdir -p /etc/odoo
    
    # 创建配置文件
    local odoo_conf="/etc/odoo/odoo.conf"
    log_info "创建Odoo配置文件: $odoo_conf"
    
    cat > "$odoo_conf" << EOF
[options]
# 路径配置
addons_path = $odoo_dir/odoo/addons,$odoo_dir/addons,$custom_dir
data_dir = $filestore_base
admin_passwd = admin

# 数据库配置
db_host = localhost
db_port = 5432
db_user = $REAL_USER
db_name = $db_name
db_maxconn = 64
db_template = template0

# 网络配置
http_port = $http_port
xmlrpc_port = $http_port
longpolling_port = $((http_port + 3))
proxy_mode = True

# 会话配置（Redis）
session_store = redis
redis_host = localhost
redis_port = 6379
redis_db = 1
redis_pass = 

# 性能优化配置
workers = $(nproc)
max_cron_threads = 2
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = 0

# 安全配置
list_db = False
dbfilter = ^%d\$
server_wide_modules = base,web

# 日志配置
log_level = info
logfile = /var/log/odoo/odoo.log
logrotate = True

# 其他配置
without_demo = True
EOF
    
    # 创建日志目录
    mkdir -p /var/log/odoo
    chown -R "$REAL_USER:$REAL_USER" /var/log/odoo
    
    log_success "配置文件创建完成"
    
    # 创建或恢复systemd服务
    log_info "配置systemd服务..."
    
    if [[ -f "$backup_root/config/odoo.service" ]]; then
        log_info "使用备份的服务配置（更新路径）..."
        cp "$backup_root/config/odoo.service" /etc/systemd/system/odoo.service
        
        # 更新路径和用户
        sed -i "s|WorkingDirectory=.*|WorkingDirectory=$odoo_dir|g" /etc/systemd/system/odoo.service
        sed -i "s|Environment=\"PATH=.*|Environment=\"PATH=$venv_path/bin:/usr/local/bin:/usr/bin:/bin\"|g" /etc/systemd/system/odoo.service
        sed -i "s|ExecStart=.*|ExecStart=$venv_path/bin/python3 $odoo_dir/odoo-bin --config=$odoo_conf|g" /etc/systemd/system/odoo.service
        sed -i "s|User=.*|User=$REAL_USER|g" /etc/systemd/system/odoo.service
        sed -i "s|Group=.*|Group=$REAL_USER|g" /etc/systemd/system/odoo.service
    else
        log_info "创建新的服务配置..."
        cat > /etc/systemd/system/odoo.service << EOF
[Unit]
Description=Odoo Open Source ERP and CRM (Version $ODOO_VERSION)
Documentation=https://www.odoo.com
After=network.target postgresql.service redis-server.service
Requires=postgresql.service

[Service]
Type=simple
User=$REAL_USER
Group=$REAL_USER
WorkingDirectory=$odoo_dir
Environment="PATH=$venv_path/bin:/usr/local/bin:/usr/bin:/bin"
Environment="PYTHONPATH=$odoo_dir"
ExecStart=$venv_path/bin/python3 $odoo_dir/odoo-bin --config=$odoo_conf
StandardOutput=journal
StandardError=journal
Restart=always
RestartSec=5s
KillMode=mixed
TimeoutStopSec=120

# 安全加固
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/odoo /var/log/odoo /tmp

[Install]
WantedBy=multi-user.target
EOF
    fi
    
    log_success "systemd服务配置完成"
    
    # 重新加载systemd并启动服务
    log_info "启动Odoo服务..."
    systemctl daemon-reload
    systemctl enable odoo
    systemctl start odoo
    
    # 验证安装
    log_info "等待Odoo服务启动（最多60秒）..."
    local service_ready=false
    for i in {1..60}; do
        if systemctl is-active --quiet odoo; then
            # 检查端口是否监听
            if ss -tln | grep -q ":$http_port "; then
                service_ready=true
                break
            fi
        fi
        sleep 1
        [[ $((i % 10)) -eq 0 ]] && log_info "  等待中... ${i}秒"
    done
    
    if [[ "$service_ready" = true ]]; then
        # 执行恢复后验证
        log_info "执行恢复后验证..."
        
        local validation_passed=true
        local validation_warnings=()
        
        # 验证服务状态
        if ! systemctl is-active --quiet odoo; then
            validation_passed=false
            validation_warnings+=("Odoo服务未运行")
        fi
        
        # 验证端口监听
        if ! ss -tln | grep -q ":$http_port "; then
            validation_passed=false
            validation_warnings+=("端口 $http_port 未监听")
        fi
        
        # 验证数据库连接
        if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$db_name"; then
            validation_passed=false
            validation_warnings+=("数据库 $db_name 不存在")
        fi
        
        # 验证文件存储
        if [[ ! -d "$filestore_base/$db_name" ]]; then
            validation_warnings+=("文件存储目录不存在或为空")
        fi
        
        # 验证Python环境
        if [[ ! -f "$venv_path/bin/python3" ]]; then
            validation_passed=false
            validation_warnings+=("Python虚拟环境未正确创建")
        fi
        
        # 验证关键Python包
        local missing_py_packages=()
        for pkg in psycopg2 lxml Pillow; do
            if ! "$venv_path/bin/python3" -c "import $pkg" 2>/dev/null; then
                missing_py_packages+=("$pkg")
            fi
        done
        if [[ ${#missing_py_packages[@]} -gt 0 ]]; then
            validation_warnings+=("缺少Python包: ${missing_py_packages[*]}")
        fi
        
        # 显示验证结果
        echo ""
        if [[ "$validation_passed" = true && ${#validation_warnings[@]} -eq 0 ]]; then
            log_success "所有验证检查通过 ✓"
        else
            if [[ "$validation_passed" = false ]]; then
                log_error "关键验证失败:"
                for warning in "${validation_warnings[@]}"; do
                    echo "  ✗ $warning"
                done
            else
                log_warning "发现以下警告:"
                for warning in "${validation_warnings[@]}"; do
                    echo "  ⚠ $warning"
                done
            fi
        fi
        
        echo ""
        echo "========================================"
        log_success "Odoo $ODOO_VERSION 环境恢复成功！"
        echo "========================================"
        log_info "恢复摘要:"
        log_info "  原系统: Ubuntu $UBUNTU_VERSION"
        log_info "  当前系统: Ubuntu $(lsb_release -r | cut -f2)"
        log_info "  Odoo版本: $ODOO_VERSION"
        log_info "  数据库: $db_name"
        log_info "  HTTP端口: $http_port"
        log_info "  安装目录: $odoo_dir"
        log_info "  配置文件: $odoo_conf"
        echo ""
        
        # 获取访问地址
        local public_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || ip route get 1 2>/dev/null | awk '{print $7; exit}' || echo "localhost")
        
        log_info "访问地址:"
        echo "  本地: http://localhost:$http_port"
        if [[ "$public_ip" != "localhost" ]]; then
            echo "  外网: http://$public_ip:$http_port"
        fi
        echo ""
        log_info "管理命令:"
        echo "  查看状态: sudo systemctl status odoo"
        echo "  查看日志: sudo journalctl -u odoo -f"
        echo "  重启服务: sudo systemctl restart odoo"
        echo "  停止服务: sudo systemctl stop odoo"
        echo ""
        log_info "下一步操作:"
        echo "  1. 访问上述地址测试Odoo"
        echo "  2. 运行: ./odoo-migrate.sh nginx  # 配置域名访问"
        echo "  3. 运行: ./odoo-migrate.sh status # 查看系统状态"
        echo ""
        
        if [[ ${#validation_warnings[@]} -gt 0 ]]; then
            log_warning "建议检查上述警告项"
        fi
        
        echo "========================================"
        
        # 记录恢复信息（使用真实用户权限）
        echo "SOURCE" > "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt"
        echo "$http_port" > "$SCRIPT_DIR/ODOO_PORT.txt"
        echo "$db_name" > "$SCRIPT_DIR/ODOO_DATABASE.txt"
        echo "$odoo_dir" > "$SCRIPT_DIR/ODOO_DIR.txt"
        
        # 修改文件所有者
        chown "$REAL_UID:$REAL_GID" "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt"
        chown "$REAL_UID:$REAL_GID" "$SCRIPT_DIR/ODOO_PORT.txt"
        chown "$REAL_UID:$REAL_GID" "$SCRIPT_DIR/ODOO_DATABASE.txt"
        chown "$REAL_UID:$REAL_GID" "$SCRIPT_DIR/ODOO_DIR.txt"
        
        # 创建恢复报告
        cat > "$SCRIPT_DIR/RESTORE_REPORT.txt" << EOF
Odoo恢复报告
============================================
恢复时间: $(date '+%Y-%m-%d %H:%M:%S')
恢复主机: $(hostname)

原环境信息:
  Ubuntu: $UBUNTU_VERSION
  Odoo: $ODOO_VERSION
  Python: $PYTHON_VERSION

当前环境信息:
  Ubuntu: $(lsb_release -r | cut -f2)
  Odoo: $ODOO_VERSION
  Python: $(python3 --version | cut -d' ' -f2)

恢复结果:
  数据库: $db_name
  HTTP端口: $http_port
  安装目录: $odoo_dir
  服务状态: $(systemctl is-active odoo)
  
验证状态: $([ "$validation_passed" = true ] && echo "通过" || echo "有警告")
警告数量: ${#validation_warnings[@]}

访问地址:
  本地: http://localhost:$http_port
  外网: http://$public_ip:$http_port
============================================
EOF
        
        chown "$REAL_UID:$REAL_GID" "$SCRIPT_DIR/RESTORE_REPORT.txt"
        log_info "恢复报告已保存: $SCRIPT_DIR/RESTORE_REPORT.txt"
    else
        log_error "服务启动失败或超时"
        echo ""
        log_info "故障排查步骤:"
        echo "  1. 查看服务状态: sudo systemctl status odoo"
        echo "  2. 查看详细日志: sudo journalctl -u odoo -xe"
        echo "  3. 查看Odoo日志: tail -f /var/log/odoo/odoo.log"
        echo "  4. 检查配置文件: cat $odoo_conf"
        echo "  5. 测试Python环境: $venv_path/bin/python3 $odoo_dir/odoo-bin --version"
        echo "  6. 检查数据库连接: sudo -u postgres psql -l"
        echo ""
        log_info "常见问题:"
        echo "  - Python依赖缺失: $venv_path/bin/pip list"
        echo "  - 端口被占用: ss -tln | grep $http_port"
        echo "  - 数据库连接失败: sudo systemctl status postgresql"
        echo "  - 权限问题: ls -la $odoo_dir"
        exit 1
    fi
}
# 配置本地Nginx（无SSL）
configure_local_nginx() {
    local odoo_port="$1"
    
    log_info "配置本地Nginx反向代理..."
    
    # 创建本地Nginx配置
    local nginx_conf="/etc/nginx/sites-available/odoo_local"
    
    sudo bash -c "cat > $nginx_conf" << EOF
# Odoo本地反向代理配置 - 生成时间: $(date)
# 部署模式: 本地模式（企业内网）
# 访问方式: http://服务器IP:80

# 上游服务器配置
upstream odoo_backend {
    server 127.0.0.1:$odoo_port max_fails=3 fail_timeout=30s;
    keepalive 32;
    keepalive_requests 100;
    keepalive_timeout 60s;
}

# 限流配置
limit_req_zone \\\$binary_remote_addr zone=login:10m rate=10r/m;
limit_req_zone \\\$binary_remote_addr zone=api:10m rate=50r/m;
limit_req_zone \\\$binary_remote_addr zone=general:10m rate=20r/s;

# 缓存配置
proxy_cache_path /var/cache/nginx/odoo levels=1:2 keys_zone=odoo_cache:100m max_size=1g inactive=60m;
proxy_cache_path /var/cache/nginx/odoo_static levels=1:2 keys_zone=odoo_static:50m max_size=500m inactive=7d;

# 主服务器配置
server {
    listen 80 default_server;
    server_name _;
    
    # 基本设置
    client_max_body_size 200M;
    client_body_timeout 60s;
    keepalive_timeout 65s;
    
    # 安全头部（本地环境适用）
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    server_tokens off;
    
    # 禁止访问敏感文件
    location ~ /\\.(ht|git|svn) {
        deny all;
        return 404;
    }
    
    location ~ \\.(sql|conf|log|bak|backup)\$ {
        deny all;
        return 404;
    }
    
    # 登录限流（本地环境相对宽松）
    location ~* ^/web/login {
        limit_req zone=login burst=5 nodelay;
        proxy_pass http://odoo_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # API限流
    location ~* ^/(api|jsonrpc) {
        limit_req zone=api burst=20 nodelay;
        proxy_pass http://odoo_backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # 静态文件高性能缓存
    location ~* /web/(static|image)/ {
        proxy_pass http://odoo_backend;
        proxy_cache odoo_static;
        proxy_cache_key \$scheme\$proxy_host\$request_uri;
        proxy_cache_valid 200 7d;
        proxy_cache_valid 404 1m;
        expires 7d;
        add_header Cache-Control "public, immutable";
        add_header X-Cache-Status \$upstream_cache_status always;
        gzip on;
        gzip_vary on;
        gzip_types text/css application/javascript image/svg+xml;
    }
    
    # CSS/JS文件优化
    location ~* \\.(css|js)\$ {
        proxy_pass http://odoo_backend;
        proxy_cache odoo_static;
        proxy_cache_valid 200 1d;
        expires 1d;
        add_header Cache-Control "public";
        gzip on;
        gzip_types text/css application/javascript;
    }
    
    # 健康检查端点
    location /nginx-health {
        access_log off;
        return 200 "healthy\\n";
        add_header Content-Type text/plain;
    }
    
    # 主应用代理
    location / {
        limit_req zone=general burst=30 nodelay;
        
        proxy_pass http://odoo_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        
        # 代理头部
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        
        # 超时设置
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        
        # 缓冲设置
        proxy_buffering on;
        proxy_buffers 16 64k;
        proxy_buffer_size 128k;
    }
}
EOF
    
    # 启用配置
    sudo ln -sf "$nginx_conf" /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    
    # 创建缓存目录
    sudo mkdir -p /var/cache/nginx/odoo /var/cache/nginx/odoo_static
    sudo chown -R www-data:www-data /var/cache/nginx/
    
    # 测试并重启Nginx
    if sudo nginx -t; then
        sudo systemctl enable nginx
        sudo systemctl restart nginx
        log_success "本地Nginx配置完成"
        
        # 获取服务器IP
        local server_ip
        server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || ip route get 1 | awk '{print $7; exit}' || echo "localhost")
        
        echo "========================================"
        log_success "本地模式Nginx配置完成！"
        echo "========================================"
        log_info "部署模式: 本地模式（企业内网）"
        log_info "访问地址: http://$server_ip"
        if [[ "$server_ip" != "localhost" ]]; then
            log_info "内网访问: http://$server_ip"
        fi
        log_info "端口: 80 (HTTP)"
        echo ""
        log_info "适用场景: 企业内网环境，员工内部使用"
        log_info "优势: 访问速度快，安全性高，维护简单"
        echo "========================================"
    else
        log_error "Nginx配置测试失败"
        exit 1
    fi
}

# Nginx配置功能
configure_nginx() {
    echo "========================================"
    echo "    Odoo Nginx反向代理配置"
    echo "========================================"
    
    check_system
    
    # 检测部署方式和端口
    local deployment_type=""
    local odoo_port="8069"
    
    [[ -f "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt" ]] && deployment_type=$(cat "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt")
    [[ -f "$SCRIPT_DIR/ODOO_PORT.txt" ]] && odoo_port=$(cat "$SCRIPT_DIR/ODOO_PORT.txt")
    
    log_info "检测到部署类型: ${deployment_type:-未知}"
    log_info "Odoo服务端口: $odoo_port"
    
    # 验证端口是否在使用
    if ! ss -tln | grep -q ":$odoo_port "; then
        log_warning "端口 $odoo_port 未检测到服务"
        read -p "是否继续配置? [y/N]: " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    
    # 获取域名信息（智能域名处理）
    echo ""
    log_info "Nginx部署模式选择："
    echo "  根据Odoo用途选择合适的部署模式："
    echo ""
    echo "  📊 企业管理系统用途："
    echo "    1. 本地模式（推荐）- 直接回车，使用IP访问"
    echo "    2. 二级域名模式（推荐）- 如 erp.company.com, manage.company.com"
    echo ""
    echo "  🌐 网站建设用途："
    echo "    3. 主域名模式（推荐）- 如 company.com, www.company.com"
    echo ""
    
    read -p "请输入域名（直接回车使用本地IP模式）: " domain
    
    # 智能域名处理逻辑
    local deployment_mode=""
    local main_domain=""
    local www_domain=""
    local use_ssl=false
    local admin_email=""
    local is_website_mode=false
    
    if [[ -z "$domain" ]]; then
        # 本地模式（企业管理推荐）
        deployment_mode="local"
        log_success "选择本地模式 - 企业管理系统"
        log_info "访问方式: http://服务器IP"
        log_info "适用场景: 企业内网环境，管理系统使用"
        log_info "优势: 访问速度快，安全性高，维护简单"
        
        # 本地模式不需要SSL和域名配置
        configure_local_nginx "$odoo_port"
        return 0
        
    elif [[ "$domain" =~ ^[a-zA-Z0-9-]+\.[a-zA-Z0-9-]+\.[a-zA-Z]{2,}$ ]]; then
        # 二级域名模式（企业管理推荐）
        deployment_mode="subdomain"
        main_domain="$domain"
        log_success "选择二级域名模式 - 企业管理系统"
        log_info "访问方式: https://$domain"
        log_info "适用场景: 企业管理系统，远程办公"
        log_info "优势: 专业性强，便于管理，安全可控"
        
        # 推荐的二级域名示例提示
        case "$domain" in
            erp.*) log_info "✅ 优秀选择: ERP企业资源规划系统" ;;
            manage.*) log_info "✅ 优秀选择: 企业管理系统" ;;
            admin.*) log_info "✅ 优秀选择: 管理后台系统" ;;
            office.*) log_info "✅ 优秀选择: 办公系统" ;;
            *) log_info "✅ 二级域名适合企业管理系统" ;;
        esac
        
    else
        # 主域名模式（网站建设推荐）
        deployment_mode="maindomain"
        is_website_mode=true
        log_success "✅ 选择主域名模式 - 网站建设"
        log_info "访问方式: https://$domain"
        log_info "适用场景: 企业官网，电商网站，门户网站"
        log_info "优势: SEO友好，品牌展示，用户体验佳"
        
        # 处理主域名
        if [[ $domain == www.* ]]; then
            main_domain="${domain#www.}"
            www_domain="$domain"
        else
            main_domain="$domain"
            www_domain="www.$domain"
        fi
        
        log_info "主域名: $main_domain"
        log_info "WWW域名: $www_domain"
    fi
    
    # 安装Nginx和Certbot
    sudo apt-get update -qq
    sudo apt-get install -y nginx certbot python3-certbot-nginx
    
    # SSL证书申请（仅二级域名和主域名模式）
    if [[ "$deployment_mode" != "local" ]]; then
        read -p "请输入管理员邮箱: " admin_email
        
        log_info "申请SSL证书..."
        use_ssl=true
        
        if [[ "$deployment_mode" = "subdomain" ]]; then
            # 二级域名只申请单个证书
            if sudo certbot certonly --nginx --non-interactive --agree-tos \
                -m "$admin_email" -d "$main_domain" 2>/dev/null; then
                log_success "SSL证书获取完成"
            else
                log_warning "SSL证书获取失败，配置HTTP访问"
                use_ssl=false
            fi
        else
            # 主域名申请主域名和www域名证书
            if sudo certbot certonly --nginx --non-interactive --agree-tos \
                -m "$admin_email" -d "$main_domain" -d "$www_domain" 2>/dev/null; then
                log_success "SSL证书获取完成"
            else
                log_warning "SSL证书获取失败，配置HTTP访问"
                use_ssl=false
            fi
        fi
    fi
    # 创建Nginx配置
    local nginx_conf="/etc/nginx/sites-available/odoo_${main_domain//\./_}"
    
    if [[ "$is_website_mode" = true ]]; then
        # 网站模式配置 - 针对网站建设优化
        sudo bash -c "cat > $nginx_conf" << EOF
# Odoo网站反向代理配置 - 生成时间: $(date)
# 部署模式: 网站建设模式
# 优化重点: SEO、性能、用户体验

upstream odoo_backend {
    server 127.0.0.1:$odoo_port max_fails=3 fail_timeout=30s;
    keepalive 64;
    keepalive_requests 1000;
    keepalive_timeout 75s;
}

# 网站专用限流配置（相对宽松）
limit_req_zone \\\$binary_remote_addr zone=login:10m rate=10r/m;
limit_req_zone \\\$binary_remote_addr zone=api:10m rate=100r/m;
limit_req_zone \\\$binary_remote_addr zone=general:10m rate=50r/s;
limit_req_zone \\\$binary_remote_addr zone=website:10m rate=100r/s;

# 网站专用缓存配置
proxy_cache_path /var/cache/nginx/odoo_website levels=1:2 keys_zone=website_cache:200m max_size=2g inactive=24h;
proxy_cache_path /var/cache/nginx/odoo_static levels=1:2 keys_zone=static_cache:100m max_size=1g inactive=7d;
proxy_cache_path /var/cache/nginx/odoo_images levels=1:2 keys_zone=image_cache:100m max_size=1g inactive=30d;

EOF
    else
        # 管理系统模式配置
        sudo bash -c "cat > $nginx_conf" << EOF
# Odoo管理系统反向代理配置 - 生成时间: $(date)
# 部署模式: 企业管理系统
# 优化重点: 安全性、稳定性、管理效率

upstream odoo_backend {
    server 127.0.0.1:$odoo_port max_fails=3 fail_timeout=30s;
    keepalive 32;
    keepalive_requests 100;
    keepalive_timeout 60s;
}

# 管理系统限流配置（相对严格）
limit_req_zone \\\$binary_remote_addr zone=login:10m rate=5r/m;
limit_req_zone \\\$binary_remote_addr zone=api:10m rate=30r/m;
limit_req_zone \\\$binary_remote_addr zone=general:10m rate=10r/s;

# 管理系统缓存配置
proxy_cache_path /var/cache/nginx/odoo levels=1:2 keys_zone=odoo_cache:100m max_size=1g inactive=60m;
proxy_cache_path /var/cache/nginx/odoo_static levels=1:2 keys_zone=static_cache:50m max_size=500m inactive=7d;

EOF
    fi
    
    # HTTP重定向配置（如果启用SSL）
    if [[ "$use_ssl" = true ]]; then
        sudo bash -c "cat >> $nginx_conf" << EOF

# HTTP到HTTPS重定向
server {
    listen 80;
    server_name $main_domain $www_domain;
    
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    location / {
        return 301 https://\\\$server_name\\\$request_uri;
    }
}

# HTTPS主服务器
server {
    listen 443 ssl http2;
    server_name $main_domain;
    
    ssl_certificate /etc/letsencrypt/live/$main_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$main_domain/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozTLS:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
EOF
    else
        sudo bash -c "cat >> $nginx_conf" << EOF

# HTTP主服务器
server {
    listen 80;
    server_name $main_domain;
EOF
    fi
    
    # 根据模式添加不同的配置
    if [[ "$is_website_mode" = true ]]; then
        # 网站模式专用配置
        sudo bash -c "cat >> $nginx_conf" << 'EOF'
    
    client_max_body_size 500M;
    client_body_timeout 120s;
    keepalive_timeout 75s;
    
    # 网站SEO优化头部
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    server_tokens off;
    
    # 网站专用Gzip配置
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/xml+rss
        application/json
        image/svg+xml;
    
    # 禁止访问敏感文件
    location ~ /\.(ht|git|svn) {
        deny all;
        return 404;
    }
    
    location ~ \.(sql|conf|log|bak|backup)$ {
        deny all;
        return 404;
    }
    
    # 网站首页和页面缓存（SEO优化）
    location = / {
        limit_req zone=website burst=50 nodelay;
        proxy_pass http://odoo_backend;
        proxy_cache website_cache;
        proxy_cache_key $scheme$proxy_host$request_uri$is_args$args;
        proxy_cache_valid 200 10m;
        proxy_cache_valid 404 1m;
        add_header X-Cache-Status $upstream_cache_status always;
        
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # 网站页面缓存
    location ~* ^/(page|shop|blog|event|forum)/ {
        limit_req zone=website burst=100 nodelay;
        proxy_pass http://odoo_backend;
        proxy_cache website_cache;
        proxy_cache_key $scheme$proxy_host$request_uri$is_args$args;
        proxy_cache_valid 200 5m;
        proxy_cache_valid 404 1m;
        add_header X-Cache-Status $upstream_cache_status always;
        
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # 图片优化缓存（网站重要）
    location ~* \.(jpg|jpeg|png|gif|ico|svg|webp)$ {
        proxy_pass http://odoo_backend;
        proxy_cache image_cache;
        proxy_cache_key $scheme$proxy_host$request_uri;
        proxy_cache_valid 200 30d;
        proxy_cache_valid 404 1h;
        expires 30d;
        add_header Cache-Control "public, immutable";
        add_header X-Cache-Status $upstream_cache_status always;
        
        # 图片压缩
        gzip on;
        gzip_types image/svg+xml;
    }
    
    # 登录限流（网站用户较多）
    location ~* ^/web/login {
        limit_req zone=login burst=10 nodelay;
        proxy_pass http://odoo_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # API限流（网站API调用较多）
    location ~* ^/(api|jsonrpc) {
        limit_req zone=api burst=50 nodelay;
        proxy_pass http://odoo_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # 静态文件高性能缓存
    location ~* /web/(static|image)/ {
        proxy_pass http://odoo_backend;
        proxy_cache static_cache;
        proxy_cache_key $scheme$proxy_host$request_uri;
        proxy_cache_valid 200 7d;
        proxy_cache_valid 404 1m;
        expires 7d;
        add_header Cache-Control "public, immutable";
        add_header X-Cache-Status $upstream_cache_status always;
        gzip on;
        gzip_vary on;
        gzip_types text/css application/javascript image/svg+xml;
    }
    
    # CSS/JS文件优化
    location ~* \.(css|js)$ {
        proxy_pass http://odoo_backend;
        proxy_cache static_cache;
        proxy_cache_valid 200 1d;
        expires 1d;
        add_header Cache-Control "public";
        gzip on;
        gzip_types text/css application/javascript;
    }
    
    # 网站健康检查
    location /nginx-health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
    
    # 主应用代理（网站模式）
    location / {
        limit_req zone=website burst=100 nodelay;
        
        proxy_pass http://odoo_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        
        # 代理头部
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        
        # 网站优化超时设置
        proxy_connect_timeout 60s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
        
        # 缓冲设置
        proxy_buffering on;
        proxy_buffers 32 64k;
        proxy_buffer_size 128k;
    }
}
EOF
    else
        # 管理系统模式配置
        sudo bash -c "cat >> $nginx_conf" << 'EOF'
    
    client_max_body_size 200M;
    client_body_timeout 60s;
    keepalive_timeout 65s;
    
    # 管理系统安全头部
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    server_tokens off;
    
    # 禁止访问敏感文件
    location ~ /\.(ht|git|svn) {
        deny all;
        return 404;
    }
    
    location ~ \.(sql|conf|log|bak|backup)$ {
        deny all;
        return 404;
    }
    
    # 登录限流（管理系统较严格）
    location ~* ^/web/login {
        limit_req zone=login burst=3 nodelay;
        proxy_pass http://odoo_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # API限流
    location ~* ^/(api|jsonrpc) {
        limit_req zone=api burst=10 nodelay;
        proxy_pass http://odoo_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    
    # 静态文件缓存
    location ~* /web/(static|image)/ {
        proxy_pass http://odoo_backend;
        proxy_cache static_cache;
        proxy_cache_valid 200 7d;
        expires 7d;
        add_header Cache-Control "public, immutable";
        gzip on;
        gzip_types text/css application/javascript image/svg+xml;
    }
    
    # 主应用代理（管理系统）
    location / {
        limit_req zone=general burst=20 nodelay;
        proxy_pass http://odoo_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
}
EOF
    fi
    # WWW重定向配置
    if [[ "$use_ssl" = true ]]; then
        sudo bash -c "cat >> $nginx_conf" << EOF

# WWW重定向到非WWW
server {
    listen 443 ssl http2;
    server_name $www_domain;
    
    ssl_certificate /etc/letsencrypt/live/$main_domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$main_domain/privkey.pem;
    
    return 301 https://$main_domain\\\$request_uri;
}
EOF
    fi
    
    # 启用配置
    sudo ln -sf "$nginx_conf" /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    
    # 创建缓存目录
    if [[ "$is_website_mode" = true ]]; then
        sudo mkdir -p /var/cache/nginx/odoo_website /var/cache/nginx/odoo_static /var/cache/nginx/odoo_images
    else
        sudo mkdir -p /var/cache/nginx/odoo /var/cache/nginx/odoo_static
    fi
    sudo chown -R www-data:www-data /var/cache/nginx/
    
    # 测试并重启Nginx
    if sudo nginx -t; then
        sudo systemctl enable nginx
        sudo systemctl restart nginx
        log_success "Nginx配置完成"
        
        # 配置证书自动续期
        if [[ "$use_ssl" = true ]]; then
            sudo bash -c "cat > /etc/letsencrypt/renewal-hooks/deploy/restart-nginx.sh" << 'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
            sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-nginx.sh
        fi
        
        echo "========================================"
        log_success "Nginx配置完成！"
        echo "========================================"
        log_info "域名: $main_domain"
        if [[ "$is_website_mode" = true ]]; then
            log_info "部署模式: 网站建设模式"
            log_info "优化重点: SEO、性能、用户体验"
        else
            log_info "部署模式: 企业管理系统"
            log_info "优化重点: 安全性、稳定性、管理效率"
        fi
        log_info "SSL证书: $([ "$use_ssl" = true ] && echo "已启用" || echo "未启用")"
        echo ""
        log_info "访问地址:"
        if [[ "$use_ssl" = true ]]; then
            echo "  https://$main_domain"
            [[ -n "$www_domain" && "$is_website_mode" = true ]] && echo "  https://$www_domain (自动跳转)"
        else
            echo "  http://$main_domain"
        fi
        echo "========================================"
    else
        log_error "Nginx配置测试失败"
        exit 1
    fi
}
# 状态检查功能
check_status() {
    echo "========================================"
    echo "    Odoo 系统状态检查"
    echo "========================================"
    
    # 检查配置端口
    local odoo_port="8069"
    [[ -f "$SCRIPT_DIR/ODOO_PORT.txt" ]] && odoo_port=$(cat "$SCRIPT_DIR/ODOO_PORT.txt")
    
    log_info "部署类型: 源码部署"
    log_info "配置端口: $odoo_port"
    
    # 检查服务状态
    echo ""
    log_info "服务状态检查:"
    
    # 源码部署检查
    if systemctl is-active --quiet odoo 2>/dev/null; then
        log_success "  Odoo服务: 运行中"
    else
        log_warning "  Odoo服务: 未运行"
    fi
    
    if systemctl is-active --quiet postgresql 2>/dev/null; then
        log_success "  PostgreSQL: 运行中"
    else
        log_warning "  PostgreSQL: 未运行"
    fi
    
    # 检查端口监听
    if ss -tln | grep -q ":$odoo_port "; then
        log_success "  端口 $odoo_port: 监听中"
    else
        log_warning "  端口 $odoo_port: 未监听"
    fi
    
    # 检查Nginx
    if systemctl is-active --quiet nginx 2>/dev/null; then
        log_success "  Nginx: 运行中"
        
        local nginx_configs
        nginx_configs=$(ls /etc/nginx/sites-enabled/odoo_* 2>/dev/null | wc -l)
        if [[ "$nginx_configs" -gt 0 ]]; then
            log_success "  Nginx Odoo配置: 已启用"
        else
            log_warning "  Nginx Odoo配置: 未找到"
        fi
    else
        log_warning "  Nginx: 未运行"
    fi
    
    # 网络连接测试
    echo ""
    log_info "网络连接测试:"
    if curl -s --max-time 5 http://localhost:$odoo_port > /dev/null; then
        log_success "  本地访问: 正常"
    else
        log_warning "  本地访问: 失败"
    fi
    
    # 显示访问信息
    echo ""
    log_info "访问信息:"
    local public_ip
    public_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "获取失败")
    echo "  公网IP: $public_ip"
    echo "  本地访问: http://localhost:$odoo_port"
    if [[ "$public_ip" != "获取失败" ]]; then
        echo "  公网访问: http://$public_ip:$odoo_port"
    fi
    
    # 检查备份文件
    echo ""
    local backup_count
    backup_count=$(ls -1 "$SCRIPT_DIR"/odoo_backup_*.zip 2>/dev/null | wc -l)
    if [[ "$backup_count" -gt 0 ]]; then
        log_info "备份文件: 找到 $backup_count 个备份文件"
        local latest_backup
        latest_backup=$(ls -1t "$SCRIPT_DIR"/odoo_backup_*.zip 2>/dev/null | head -1)
        if [[ -n "$latest_backup" ]]; then
            local backup_size
            backup_size=$(du -h "$latest_backup" | cut -f1)
            echo "  最新备份: $(basename "$latest_backup") ($backup_size)"
        fi
    else
        log_warning "备份文件: 未找到备份文件"
    fi
    
    echo "========================================"
}
# 主函数
main() {
    case "${1:-help}" in
        backup)
            backup_odoo
            ;;
        restore)
            restore_source
            ;;
        nginx)
            configure_nginx
            ;;
        status)
            check_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            log_error "未知命令: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    main "$@"
fi