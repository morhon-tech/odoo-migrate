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
SCRIPT_VERSION="2.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    
    # 检查是否为Ubuntu系统
    if ! command -v lsb_release &> /dev/null || ! lsb_release -i | grep -q "Ubuntu"; then
        log_error "此脚本仅支持Ubuntu系统"
        log_info "推荐使用Ubuntu 24.04 LTS"
        exit 1
    fi
    
    # 检查Ubuntu版本
    local ubuntu_version
    ubuntu_version=$(lsb_release -r | cut -f2)
    if [[ "$ubuntu_version" < "22.04" ]]; then
        log_error "Ubuntu版本过低，需要22.04或更高版本"
        log_info "推荐使用Ubuntu 24.04 LTS"
        exit 1
    fi
    
    log_success "检测到Ubuntu $ubuntu_version"
    if [[ "$ubuntu_version" == "24.04" ]]; then
        log_success "使用推荐的Ubuntu 24.04 LTS"
    fi
    
    # 检查权限
    if [[ $EUID -eq 0 ]]; then
        log_warning "不建议以root用户运行此脚本"
        read -p "是否继续? [y/N]: " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    
    log_success "系统检查通过"
}

# 智能检测Odoo环境
detect_odoo_environment() {
    log_info "检测Odoo运行环境..."
    
    # 检测运行中的Odoo进程
    if ! ODOO_PID=$(pgrep -f "odoo-bin" | head -1); then
        log_error "未找到运行的Odoo进程，请确保Odoo正在运行"
        return 1
    fi
    
    # 获取配置文件路径
    ODOO_CONF=$(ps -p "$ODOO_PID" -o cmd= | grep -o "\-c [^ ]*" | cut -d' ' -f2 || echo "")
    if [[ ! -f "$ODOO_CONF" ]]; then
        log_error "无法定位配置文件: $ODOO_CONF"
        return 1
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
        ODOO_DIR=$(dirname "$ODOO_BIN_PATH")
    else
        ODOO_VERSION="未知"
        ODOO_DIR=""
    fi
    
    PYTHON_VERSION=$(python3 --version 2>/dev/null | cut -d' ' -f2 || echo "未知")
    
    log_success "环境检测完成"
    log_info "  数据库: ${DB_NAME:-未设置}"
    log_info "  数据目录: ${DATA_DIR:-未设置}"
    log_info "  HTTP端口: $HTTP_PORT"
    log_info "  Odoo版本: $ODOO_VERSION"
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
    
    # 记录版本元数据
    log_info "记录系统版本信息..."
    cat > "$backup_dir/metadata/versions.txt" << EOF
ODOO_VERSION: $ODOO_VERSION
PYTHON_VERSION: $PYTHON_VERSION
POSTGRESQL_VERSION: $(psql --version 2>/dev/null | cut -d' ' -f3 || echo "未知")
ODOO_BIN_PATH: $ODOO_BIN_PATH
BACKUP_DATE: $backup_date
ORIGINAL_HOST: $(hostname)
EOF
    
    # 备份数据库
    log_info "备份PostgreSQL数据库..."
    local db_dump_file="$backup_dir/database/dump.sql"
    if sudo -u postgres pg_dump "${DB_NAME:-odoo}" --no-owner --no-acl --encoding=UTF-8 > "$db_dump_file" 2>/dev/null; then
        local dump_size=$(du -h "$db_dump_file" | cut -f1)
        log_success "数据库备份完成: $dump_size"
        
        # 添加版本注释
        sed -i "1i-- PostgreSQL Dump\\n-- Source: ${DB_NAME:-odoo}\\n-- Odoo Version: $ODOO_VERSION\\n-- Backup time: $(date)\\n" "$db_dump_file"
    else
        log_error "数据库备份失败"
        exit 1
    fi
    
    # 备份文件存储
    log_info "备份文件存储..."
    local filestore_paths=(
        "${DATA_DIR}/filestore/${DB_NAME:-odoo}"
        "/var/lib/odoo/filestore/${DB_NAME:-odoo}"
        "$HOME/.local/share/Odoo/filestore/${DB_NAME:-odoo}"
    )
    
    for path in "${filestore_paths[@]}"; do
        if [[ -d "$path" ]]; then
            cp -r "$path" "$backup_dir/filestore/"
            local filestore_count=$(find "$path" -type f | wc -l)
            log_success "文件存储备份完成，文件数: $filestore_count"
            break
        fi
    done
    
    # 备份完整Odoo源码（强制备份整个目录）
    if [[ -n "$ODOO_DIR" && -d "$ODOO_DIR" ]]; then
        log_info "备份完整Odoo源码目录..."
        
        # 强制备份整个Odoo源码目录，包含所有可能的修改
        local source_backup_dir="$backup_dir/source/odoo_complete"
        mkdir -p "$source_backup_dir"
        
        log_info "  正在复制完整源码目录..."
        rsync -av --exclude='*.pyc' --exclude='__pycache__' --exclude='*.log' \
              --exclude='filestore' --exclude='sessions' \
              "$ODOO_DIR/" "$source_backup_dir/" 2>/dev/null || {
            log_warning "  rsync失败，使用cp备份..."
            cp -r "$ODOO_DIR/"* "$source_backup_dir/" 2>/dev/null || true
            # 清理不需要的文件
            find "$source_backup_dir" -name "*.pyc" -delete 2>/dev/null || true
            find "$source_backup_dir" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
        }
        
        # 记录源码信息
        local source_size=$(du -sh "$source_backup_dir" | cut -f1)
        log_success "完整源码备份完成，大小: $source_size"
        
        # 记录Git信息（如果存在）
        if [[ -d "$ODOO_DIR/.git" ]]; then
            cd "$ODOO_DIR"
            git log --oneline -10 > "$backup_dir/metadata/git_commits.txt" 2>/dev/null || true
            git diff HEAD > "$backup_dir/metadata/git_modifications.txt" 2>/dev/null || true
            git status --porcelain > "$backup_dir/metadata/git_status.txt" 2>/dev/null || true
            cd - > /dev/null
            log_info "  记录Git修改信息"
        fi
        
        # 检查源码修改
        local modified_files=$(find "$ODOO_DIR" -name "*.py" -newer "$ODOO_DIR/odoo-bin" 2>/dev/null | wc -l)
        if [[ "$modified_files" -gt 0 ]]; then
            log_warning "  检测到 $modified_files 个可能被修改的Python文件"
            echo "MODIFIED_SOURCE_FILES: $modified_files" >> "$backup_dir/metadata/versions.txt"
        fi
        
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
# Odoo 恢复说明

## 备份信息
- Odoo版本: $ODOO_VERSION
- 数据库: ${DB_NAME:-odoo}
- HTTP端口: $HTTP_PORT
- 备份时间: $(date)

## 恢复方式

### 源码恢复
\`\`\`bash
./odoo-migrate.sh restore
\`\`\`

### 配置域名访问
\`\`\`bash
./odoo-migrate.sh nginx
\`\`\`
EOF
    
    # 打包备份文件
    local zip_file="$SCRIPT_DIR/odoo_backup_$backup_date.zip"
    log_info "创建备份包..."
    cd "$TEMP_BASE" && zip -rq "$zip_file" "$(basename "$backup_dir")"
    
    if [[ -f "$zip_file" ]]; then
        local backup_size=$(du -h "$zip_file" | cut -f1)
        echo "========================================"
        log_success "备份完成！"
        echo "========================================"
        log_info "备份文件: $(basename "$zip_file")"
        log_info "文件大小: $backup_size"
        log_info "Odoo版本: $ODOO_VERSION"
        echo ""
        log_info "下一步操作:"
        echo "  1. 将备份文件复制到新服务器"
        echo "  2. 运行: ./odoo-migrate.sh restore"
        echo "========================================"
    else
        log_error "备份文件创建失败"
        exit 1
    fi
}

# 安装系统依赖
install_system_dependencies() {
    log_info "安装系统依赖..."
    sudo apt-get update -qq
    sudo apt-get install -y \
        postgresql postgresql-contrib libpq-dev \
        redis-server redis-tools \
        build-essential libxml2-dev libxslt1-dev \
        libldap2-dev libsasl2-dev libssl-dev \
        zlib1g-dev libjpeg-dev libfreetype6-dev \
        node-less python3-pip python3-venv \
        fonts-wqy-zenhei fontconfig curl wget git unzip \
        nginx certbot python3-certbot-nginx
    
    # 启动并启用Redis
    sudo systemctl start redis-server
    sudo systemctl enable redis-server
    
    log_success "系统依赖安装完成"
}

# 安装wkhtmltopdf
install_wkhtmltopdf() {
    if ! command -v wkhtmltopdf &> /dev/null; then
        log_info "安装wkhtmltopdf..."
        sudo apt-get install -y wkhtmltopdf || {
            local deb_file="wkhtmltox_0.12.6-1.$(lsb_release -c -s)_amd64.deb"
            wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/$deb_file" 2>/dev/null || \
            wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb" -O "$deb_file"
            sudo dpkg -i "$deb_file" || sudo apt-get install -f -y
            rm -f "$deb_file"
        }
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
    unzip -q "$backup_file" -d "$restore_dir"
    local backup_root
    backup_root=$(find "$restore_dir" -type d -name "odoo_backup_*" | head -1)
    
    # 读取版本元数据
    if [[ -f "$backup_root/metadata/versions.txt" ]]; then
        ODOO_VERSION=$(grep "ODOO_VERSION:" "$backup_root/metadata/versions.txt" | cut -d' ' -f2)
        PYTHON_VERSION=$(grep "PYTHON_VERSION:" "$backup_root/metadata/versions.txt" | cut -d' ' -f2)
        log_info "原环境版本 - Odoo: $ODOO_VERSION, Python: $PYTHON_VERSION"
        
        if [[ "$ODOO_VERSION" = "未知" ]]; then
            log_error "备份中未记录Odoo版本，无法精确恢复"
            exit 1
        fi
    else
        log_error "备份中缺少版本元数据"
        exit 1
    fi
    
    # 安装依赖
    install_system_dependencies
    install_wkhtmltopdf
    
    # 创建Odoo目录
    local odoo_dir="/opt/odoo"
    sudo mkdir -p "$odoo_dir"
    sudo chown -R "$USER:$USER" "$odoo_dir"
    
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
    
    # 创建Python虚拟环境
    log_info "创建Python虚拟环境..."
    local venv_path="$odoo_dir/venv"
    python3 -m venv "$venv_path"
    source "$venv_path/bin/activate"
    
    pip install --upgrade pip setuptools wheel
    pip install psycopg2-binary Babel Pillow lxml reportlab python-dateutil
    deactivate
    
    # 启动PostgreSQL并优化
    sudo systemctl start postgresql
    sudo systemctl enable postgresql
    optimize_postgresql
    optimize_redis
    
    # 创建数据库用户
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER'" | grep -q 1; then
        sudo -u postgres createuser --superuser "$USER" || true
    fi
    
    # 恢复数据库
    local db_name="odoo_restored_$(date +%Y%m%d)"
    if [[ -f "$backup_root/database/dump.sql" ]]; then
        log_info "恢复数据库: $db_name"
        sudo -u postgres createdb "$db_name" 2>/dev/null || true
        sudo -u postgres psql "$db_name" < "$backup_root/database/dump.sql"
        log_success "数据库恢复完成"
    fi
    
    # 恢复文件存储
    local filestore_dir="/var/lib/odoo/filestore"
    sudo mkdir -p "$filestore_dir"
    if [[ -d "$backup_root/filestore" ]]; then
        sudo cp -r "$backup_root/filestore"/* "$filestore_dir/$db_name/" 2>/dev/null || true
    fi
    
    # 获取原HTTP端口
    local http_port="8069"
    if [[ -f "$backup_root/metadata/system_info.txt" ]]; then
        http_port=$(grep "HTTP端口:" "$backup_root/metadata/system_info.txt" | cut -d':' -f2 | tr -d ' ' || echo "8069")
    fi
    
    # 创建配置文件
    local odoo_conf="/etc/odoo/odoo.conf"
    sudo mkdir -p /etc/odoo
    sudo bash -c "cat > $odoo_conf" << EOF
[options]
addons_path = $odoo_dir/odoo/addons,$odoo_dir/addons,$custom_dir
data_dir = $filestore_dir
admin_passwd = admin
db_host = localhost
db_port = 5432
db_user = $USER
db_name = $db_name
http_port = $http_port
without_demo = True
proxy_mode = True

# Redis会话存储配置
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
db_maxconn = 64
list_db = False

# 安全配置
dbfilter = ^%d\$
server_wide_modules = base,web

# 日志配置
log_level = info
logrotate = True
EOF
    
    # 创建systemd服务
    sudo bash -c "cat > /etc/systemd/system/odoo.service" << EOF
[Unit]
Description=Odoo Open Source ERP and CRM (Version $ODOO_VERSION)
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$odoo_dir
Environment="PATH=$venv_path/bin"
ExecStart=$venv_path/bin/python3 $odoo_dir/odoo-bin --config=$odoo_conf
Restart=always
RestartSec=5s
KillMode=mixed
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF
    
    # 启动服务
    sudo systemctl daemon-reload
    sudo systemctl enable odoo
    sudo systemctl start odoo
    
    # 验证安装
    sleep 10
    if systemctl is-active --quiet odoo; then
        echo "========================================"
        log_success "Odoo $ODOO_VERSION 源码恢复成功！"
        echo "========================================"
        log_info "访问地址: http://$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "localhost"):$http_port"
        log_info "数据库: $db_name"
        log_info "服务状态: sudo systemctl status odoo"
        echo ""
        log_info "接下来运行: ./odoo-migrate.sh nginx"
        echo "========================================"
        
        # 记录恢复信息
        echo "SOURCE" > "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt"
        echo "$http_port" > "$SCRIPT_DIR/ODOO_PORT.txt"
    else
        log_error "服务启动失败，查看日志: sudo journalctl -u odoo"
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