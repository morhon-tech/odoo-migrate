#!/bin/bash
# ====================================================
# odoo-migrate.sh - Odoo统一管理和迁移脚本
# 功能：备份、恢复（源码/Docker）、Nginx配置
# 使用：./odoo-migrate.sh [backup|restore|nginx|help]
# ====================================================

set -e

# 脚本信息
SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMP_BASE="/tmp/odoo_migrate_$$"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() { echo -e "${BLUE}[信息]${NC} $1"; }
log_success() { echo -e "${GREEN}[成功]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
log_error() { echo -e "${RED}[错误]${NC} $1"; }

# 清理函数
cleanup() {
    if [ -n "$TEMP_BASE" ] && [ -d "$TEMP_BASE" ]; then
        rm -rf "$TEMP_BASE"
    fi
}
trap cleanup EXIT

# 显示帮助信息
show_help() {
    cat << EOF
======================================
    Odoo 统一管理和迁移工具 v$SCRIPT_VERSION
======================================

使用方法:
  $0 backup              # 备份当前Odoo环境
  $0 restore [source]    # 恢复到源码环境（默认）
  $0 restore docker      # 恢复到Docker环境
  $0 nginx               # 配置Nginx反向代理
  $0 optimize            # 应用性能和安全优化
  $0 status              # 查看当前状态
  $0 help                # 显示此帮助信息

功能特性:
  ✓ 智能环境检测和版本记录
  ✓ 完整源码备份（包含修改）
  ✓ 双恢复模式（源码/Docker）
  ✓ 自动Nginx配置和SSL证书
  ✓ 性能和安全优化
  ✓ 中文PDF支持
  ✓ 依赖分析和自动安装

备份文件:
  - 自动检测当前目录下的 odoo_backup_*.zip 文件
  - 备份文件包含完整的环境信息和恢复说明

示例:
  ./odoo-migrate.sh backup           # 备份当前环境
  ./odoo-migrate.sh restore          # 源码方式恢复
  ./odoo-migrate.sh restore docker   # Docker方式恢复
  ./odoo-migrate.sh optimize         # 应用性能优化
  ./odoo-migrate.sh nginx            # 配置域名访问

EOF
}

# 检查系统要求
check_system() {
    log_info "检查系统环境..."
    
    # 检查操作系统
    if ! command -v lsb_release &> /dev/null; then
        log_error "不支持的操作系统，需要Ubuntu/Debian"
        exit 1
    fi
    
    # 检查权限
    if [ "$EUID" -eq 0 ]; then
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
    ODOO_PID=$(ps aux | grep "odoo-bin" | grep -v grep | head -1 | awk '{print $2}')
    if [ -z "$ODOO_PID" ]; then
        log_error "未找到运行的Odoo进程"
        log_info "请确保Odoo正在运行"
        return 1
    fi
    
    # 获取配置文件路径
    ODOO_CONF=$(ps -p $ODOO_PID -o cmd= | grep -o "\-c [^ ]*" | cut -d' ' -f2)
    if [ ! -f "$ODOO_CONF" ]; then
        log_error "无法定位配置文件: $ODOO_CONF"
        return 1
    fi
    
    # 解析配置信息
    DB_NAME=$(grep -E "^db_name\s*=" "$ODOO_CONF" | head -1 | cut -d'=' -f2 | tr -d ' \r')
    DATA_DIR=$(grep -E "^data_dir\s*=" "$ODOO_CONF" | head -1 | cut -d'=' -f2 | tr -d ' \r')
    HTTP_PORT=$(grep -E "^http_port\s*=" "$ODOO_CONF" | head -1 | cut -d'=' -f2 | tr -d ' \r' || echo "8069")
    ADDONS_PATH=$(grep -E "^addons_path\s*=" "$ODOO_CONF" | head -1 | cut -d'=' -f2 | tr -d '\r')
    
    # 获取Odoo版本和路径
    ODOO_BIN_PATH=$(ps -p $ODOO_PID -o cmd= | awk '{print $2}')
    if [ -f "$ODOO_BIN_PATH" ]; then
        ODOO_VERSION=$("$ODOO_BIN_PATH" --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+' || echo "未知")
        ODOO_DIR=$(dirname "$ODOO_BIN_PATH")
    else
        ODOO_VERSION="未知"
        ODOO_DIR=""
    fi
    
    # 获取Python版本
    PYTHON_VERSION=$(python3 --version 2>/dev/null | cut -d' ' -f2 || echo "未知")
    
    log_success "环境检测完成"
    log_info "  数据库: $DB_NAME"
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
    if ! detect_odoo_environment; then
        exit 1
    fi
    
    # 创建备份目录
    BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
    BACKUP_DIR="$TEMP_BASE/odoo_backup_$BACKUP_DATE"
    mkdir -p "$BACKUP_DIR"/{database,filestore,source,config,dependencies,fonts,metadata}
    
    log_info "创建备份目录: $BACKUP_DIR"
    
    # 记录版本元数据
    log_info "记录系统版本信息..."
    cat > "$BACKUP_DIR/metadata/versions.txt" << EOF
ODOO_VERSION: $ODOO_VERSION
PYTHON_VERSION: $PYTHON_VERSION
POSTGRESQL_VERSION: $(psql --version 2>/dev/null | cut -d' ' -f3 || echo "未知")
ODOO_BIN_PATH: $ODOO_BIN_PATH
BACKUP_DATE: $BACKUP_DATE
ORIGINAL_HOST: $(hostname)
EOF
    
    cat > "$BACKUP_DIR/metadata/system_info.txt" << EOF
# Odoo 环境备份元数据
备份时间: $(date)
原服务器: $(hostname)
系统: $(lsb_release -ds 2>/dev/null || uname -a)
数据库: $DB_NAME
数据目录: $DATA_DIR
HTTP端口: $HTTP_PORT
配置文件: $ODOO_CONF
EOF
    
    # 备份数据库
    log_info "备份PostgreSQL数据库..."
    DB_DUMP_FILE="$BACKUP_DIR/database/dump.sql"
    if sudo -u postgres pg_dump "$DB_NAME" --no-owner --no-acl --encoding=UTF-8 > "$DB_DUMP_FILE" 2>/dev/null; then
        DUMP_SIZE=$(du -h "$DB_DUMP_FILE" | cut -f1)
        log_success "数据库备份完成: $DUMP_SIZE"
        
        # 添加版本注释
        sed -i "1i-- PostgreSQL Dump\\n-- Source: $DB_NAME\\n-- Odoo Version: $ODOO_VERSION\\n-- Backup time: $(date)\\n" "$DB_DUMP_FILE"
        
        # 检查是否启用了网站功能
        log_info "检查网站配置..."
        WEBSITE_DOMAINS=""
        if sudo -u postgres psql -d "$DB_NAME" -tAc "SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='website')" 2>/dev/null | grep -q t; then
            WEBSITE_DOMAINS=$(sudo -u postgres psql -d "$DB_NAME" -tAc "SELECT domain FROM website WHERE domain IS NOT NULL AND domain != ''" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
            if [ -n "$WEBSITE_DOMAINS" ]; then
                log_warning "检测到网站功能已启用，绑定域名: $WEBSITE_DOMAINS"
                echo "WEBSITE_DOMAINS: $WEBSITE_DOMAINS" >> "$BACKUP_DIR/metadata/versions.txt"
                echo "WEBSITE_ENABLED: true" >> "$BACKUP_DIR/metadata/versions.txt"
            fi
        fi
    else
        log_error "数据库备份失败"
        exit 1
    fi
    
    # 备份文件存储
    log_info "备份文件存储..."
    if [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR/filestore/$DB_NAME" ]; then
        cp -r "$DATA_DIR/filestore/$DB_NAME" "$BACKUP_DIR/filestore/"
        FILESTORE_COUNT=$(find "$DATA_DIR/filestore/$DB_NAME" -type f | wc -l)
        log_success "文件存储备份完成，文件数: $FILESTORE_COUNT"
    else
        # 尝试常见路径
        for path in "/var/lib/odoo/filestore/$DB_NAME" "$HOME/.local/share/Odoo/filestore/$DB_NAME"; do
            if [ -d "$path" ]; then
                cp -r "$path" "$BACKUP_DIR/filestore/"
                log_success "从 $path 备份文件存储"
                break
            fi
        done
    fi
    
    # 备份完整Odoo源码（防止源码被修改）
    log_info "备份完整Odoo源码..."
    if [ -n "$ODOO_DIR" ] && [ -d "$ODOO_DIR" ]; then
        # 创建源码备份目录
        mkdir -p "$BACKUP_DIR/source/odoo_core"
        
        # 备份完整的Odoo核心目录，排除缓存和临时文件
        log_info "  备份Odoo核心源码..."
        rsync -av --exclude='*.pyc' --exclude='__pycache__' --exclude='*.log' \
              --exclude='.git' --exclude='filestore' --exclude='sessions' \
              "$ODOO_DIR/" "$BACKUP_DIR/source/odoo_core/" 2>/dev/null || {
            # 如果rsync失败，使用cp作为备选
            cp -r "$ODOO_DIR" "$BACKUP_DIR/source/odoo_core_backup" 2>/dev/null || true
            # 清理不需要的文件
            find "$BACKUP_DIR/source/odoo_core_backup" -name "*.pyc" -delete 2>/dev/null || true
            find "$BACKUP_DIR/source/odoo_core_backup" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
        }
        
        # 记录源码修改信息
        if [ -d "$ODOO_DIR/.git" ]; then
            cd "$ODOO_DIR"
            git log --oneline -10 > "$BACKUP_DIR/metadata/git_commits.txt" 2>/dev/null || true
            git diff HEAD > "$BACKUP_DIR/metadata/git_modifications.txt" 2>/dev/null || true
            git status --porcelain > "$BACKUP_DIR/metadata/git_status.txt" 2>/dev/null || true
            cd - > /dev/null
            log_info "  记录Git修改信息"
        fi
        
        # 检查是否有源码修改
        MODIFIED_FILES=$(find "$ODOO_DIR" -name "*.py" -newer "$ODOO_DIR/odoo-bin" 2>/dev/null | wc -l)
        if [ "$MODIFIED_FILES" -gt 0 ]; then
            log_warning "  检测到 $MODIFIED_FILES 个可能被修改的Python文件"
            echo "MODIFIED_SOURCE_FILES: $MODIFIED_FILES" >> "$BACKUP_DIR/metadata/versions.txt"
        fi
    fi
    
    # 备份自定义模块
    if [ -n "$ADDONS_PATH" ]; then
        IFS=',' read -ra ADDR <<< "$ADDONS_PATH"
        for path in "${ADDR[@]}"; do
            clean_path=$(echo "$path" | tr -d ' \r')
            if [[ "$clean_path" != *"odoo/addons"* ]] && [ -d "$clean_path" ]; then
                dir_name=$(basename "$clean_path")
                cp -r "$clean_path" "$BACKUP_DIR/source/custom_${dir_name}" 2>/dev/null || true
                log_success "备份自定义模块: $dir_name"
            fi
        done
    fi
    
    # 分析Python依赖
    log_info "分析Python依赖..."
    DEP_REPORT="$BACKUP_DIR/dependencies/requirements_analysis.txt"
    echo "# Odoo依赖分析报告 - Odoo版本: $ODOO_VERSION" > "$DEP_REPORT"
    echo "# 生成时间: $(date)" >> "$DEP_REPORT"
    pip3 freeze >> "$DEP_REPORT" 2>&1 || echo "# 无法获取pip列表" >> "$DEP_REPORT"
    
    # 收集中文字体
    log_info "收集中文字体..."
    FONT_PATHS=(
        "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc"
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc"
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    )
    for font_path in "${FONT_PATHS[@]}"; do
        if [ -f "$font_path" ]; then
            cp "$font_path" "$BACKUP_DIR/fonts/"
        fi
    done
    
    # 备份配置文件
    cp "$ODOO_CONF" "$BACKUP_DIR/config/"
    [ -f "/etc/systemd/system/odoo.service" ] && \
        cp "/etc/systemd/system/odoo.service" "$BACKUP_DIR/config/" 2>/dev/null || true
    
    # 创建恢复说明
    cat > "$BACKUP_DIR/RESTORE_INSTRUCTIONS.md" << EOF
# Odoo 恢复说明

## 备份信息
- Odoo版本: $ODOO_VERSION
- 数据库: $DB_NAME
- HTTP端口: $HTTP_PORT
- 备份时间: $(date)

## 恢复方式

### 源码恢复（推荐）
\`\`\`bash
./odoo-migrate.sh restore
\`\`\`

### Docker恢复
\`\`\`bash
./odoo-migrate.sh restore docker
\`\`\`

### 配置域名访问
\`\`\`bash
./odoo-migrate.sh nginx
\`\`\`
EOF
    
    # 打包备份文件
    ZIP_FILE="$SCRIPT_DIR/odoo_backup_$BACKUP_DATE.zip"
    log_info "创建备份包..."
    cd "$TEMP_BASE" && zip -rq "$ZIP_FILE" "$(basename "$BACKUP_DIR")"
    
    if [ -f "$ZIP_FILE" ]; then
        BACKUP_SIZE=$(du -h "$ZIP_FILE" | cut -f1)
        echo "========================================"
        log_success "备份完成！"
        echo "========================================"
        log_info "备份文件: $(basename "$ZIP_FILE")"
        log_info "文件大小: $BACKUP_SIZE"
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
# 恢复功能 - 源码方式
restore_source() {
    echo "========================================"
    echo "    Odoo 源码环境恢复"
    echo "========================================"
    
    check_system
    
    # 定位备份文件
    BACKUP_FILE=$(ls -1t "$SCRIPT_DIR"/odoo_backup_*.zip 2>/dev/null | head -1)
    if [ -z "$BACKUP_FILE" ]; then
        log_error "当前目录未找到备份文件 (odoo_backup_*.zip)"
        exit 1
    fi
    log_info "找到备份文件: $(basename "$BACKUP_FILE")"
    
    # 解压备份文件
    log_info "解压备份文件..."
    RESTORE_DIR="$TEMP_BASE/restore"
    mkdir -p "$RESTORE_DIR"
    unzip -q "$BACKUP_FILE" -d "$RESTORE_DIR"
    BACKUP_ROOT=$(find "$RESTORE_DIR" -type d -name "odoo_backup_*" | head -1)
    
    # 读取版本元数据
    if [ -f "$BACKUP_ROOT/metadata/versions.txt" ]; then
        ODOO_VERSION=$(grep "ODOO_VERSION:" "$BACKUP_ROOT/metadata/versions.txt" | cut -d' ' -f2)
        PYTHON_VERSION=$(grep "PYTHON_VERSION:" "$BACKUP_ROOT/metadata/versions.txt" | cut -d' ' -f2)
        WEBSITE_ENABLED=$(grep "WEBSITE_ENABLED:" "$BACKUP_ROOT/metadata/versions.txt" | cut -d' ' -f2 2>/dev/null)
        WEBSITE_DOMAINS=$(grep "WEBSITE_DOMAINS:" "$BACKUP_ROOT/metadata/versions.txt" | cut -d' ' -f2- 2>/dev/null)
        
        log_info "原环境版本 - Odoo: $ODOO_VERSION, Python: $PYTHON_VERSION"
        
        # 网站域名迁移提示
        if [ "$WEBSITE_ENABLED" = "true" ] && [ -n "$WEBSITE_DOMAINS" ]; then
            echo ""
            log_warning "⚠️  重要提示：检测到原系统启用了网站功能"
            log_warning "   绑定域名: $WEBSITE_DOMAINS"
            log_warning "   建议迁移后保持相同域名，避免网站功能异常"
            echo ""
            read -p "是否继续恢复? 如需更改域名请在恢复后手动更新数据库配置 [y/N]: " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "恢复已取消"
                exit 0
            fi
        fi
        
        if [ "$ODOO_VERSION" = "未知" ]; then
            log_error "备份中未记录Odoo版本，无法精确恢复"
            exit 1
        fi
    else
        log_error "备份中缺少版本元数据"
        exit 1
    fi
    
    # 安装系统依赖
    log_info "安装系统依赖..."
    sudo apt-get update
    sudo apt-get install -y \
        software-properties-common \
        postgresql postgresql-contrib libpq-dev \
        build-essential libxml2-dev libxslt1-dev \
        libldap2-dev libsasl2-dev libssl-dev \
        zlib1g-dev libjpeg-dev libfreetype6-dev \
        node-less node-clean-css python3-sass \
        fonts-wqy-zenhei fonts-wqy-microhei \
        fontconfig curl wget git unzip
    
    # 安装指定版本Python
    if ! command -v "python$PYTHON_VERSION" &> /dev/null; then
        log_info "安装 Python $PYTHON_VERSION..."
        sudo add-apt-repository -y ppa:deadsnakes/ppa
        sudo apt-get update
        sudo apt-get install -y \
            "python$PYTHON_VERSION" \
            "python$PYTHON_VERSION-dev" \
            "python$PYTHON_VERSION-venv" \
            "python$PYTHON_VERSION-distutils"
    fi
    
    # 安装wkhtmltopdf
    if ! command -v wkhtmltopdf &> /dev/null; then
        log_info "安装wkhtmltopdf..."
        sudo apt-get install -y wkhtmltopdf || {
            # 如果apt安装失败，尝试下载deb包
            wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.$(lsb_release -c -s)_amd64.deb" 2>/dev/null || \
            wget -q "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.focal_amd64.deb"
            sudo dpkg -i wkhtmltox_*.deb || sudo apt-get install -f -y
            rm -f wkhtmltox_*.deb
        }
    fi
    
    # 创建Odoo目录
    ODOO_DIR="/opt/odoo"
    sudo mkdir -p "$ODOO_DIR"
    sudo chown -R $USER:$USER "$ODOO_DIR"
    
    # 恢复或下载Odoo源码
    if [ -d "$BACKUP_ROOT/source/odoo_core" ] && [ -n "$(ls -A $BACKUP_ROOT/source/odoo_core 2>/dev/null)" ]; then
        log_info "恢复完整Odoo源码（包含可能的修改）..."
        cp -r "$BACKUP_ROOT/source/odoo_core/"* "$ODOO_DIR/"
        
        # 检查是否有源码修改记录
        if [ -f "$BACKUP_ROOT/metadata/versions.txt" ]; then
            MODIFIED_COUNT=$(grep "MODIFIED_SOURCE_FILES:" "$BACKUP_ROOT/metadata/versions.txt" | cut -d' ' -f2 2>/dev/null || echo "0")
            if [ "$MODIFIED_COUNT" -gt 0 ]; then
                log_warning "恢复了包含 $MODIFIED_COUNT 个修改文件的源码"
            fi
        fi
        
        # 恢复Git信息（如果存在）
        if [ -f "$BACKUP_ROOT/metadata/git_commits.txt" ]; then
            log_info "检测到Git历史记录，请手动检查源码修改"
            cp "$BACKUP_ROOT/metadata/git_"*.txt "$ODOO_DIR/" 2>/dev/null || true
        fi
    elif [ -d "$BACKUP_ROOT/source/odoo_core_backup" ]; then
        log_info "恢复备份的Odoo源码..."
        cp -r "$BACKUP_ROOT/source/odoo_core_backup/"* "$ODOO_DIR/"
    else
        log_info "下载Odoo $ODOO_VERSION 源码..."
        cd /tmp
        wget -q "https://github.com/odoo/odoo/archive/refs/tags/$ODOO_VERSION.zip" -O odoo_src.zip
        unzip -q odoo_src.zip
        cp -r "odoo-$ODOO_VERSION/"* "$ODOO_DIR/"
        rm -rf odoo_src.zip "odoo-$ODOO_VERSION"
    fi
    
    # 恢复自定义模块
    CUSTOM_DIR="$ODOO_DIR/custom_addons"
    mkdir -p "$CUSTOM_DIR"
    for custom in "$BACKUP_ROOT/source"/custom_*; do
        if [ -d "$custom" ]; then
            cp -r "$custom" "$CUSTOM_DIR/"
            log_success "恢复模块: $(basename "$custom")"
        fi
    done
    
    # 创建Python虚拟环境
    log_info "创建Python虚拟环境..."
    VENV_PATH="$ODOO_DIR/venv"
    "python$PYTHON_VERSION" -m venv "$VENV_PATH"
    source "$VENV_PATH/bin/activate"
    
    # 安装Python依赖
    pip install --upgrade pip setuptools wheel
    if [[ "$ODOO_VERSION" == 17.* ]] || [[ "$ODOO_VERSION" == 18.* ]]; then
        pip install odoo==$ODOO_VERSION
    else
        pip install psycopg2-binary Babel Pillow lxml reportlab python-dateutil
    fi
    deactivate
    
    # 启动PostgreSQL
    sudo systemctl start postgresql
    sudo systemctl enable postgresql
    
    # 创建数据库用户
    if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER'" | grep -q 1; then
        sudo -u postgres createuser --superuser "$USER" || true
    fi
    
    # 恢复数据库
    DB_NAME="odoo_restored_$(date +%Y%m%d)"
    if [ -f "$BACKUP_ROOT/database/dump.sql" ]; then
        log_info "恢复数据库: $DB_NAME"
        sudo -u postgres createdb "$DB_NAME" 2>/dev/null || true
        sudo -u postgres psql "$DB_NAME" < "$BACKUP_ROOT/database/dump.sql"
        log_success "数据库恢复完成"
    fi
    
    # 恢复文件存储
    FILESTORE_DIR="/var/lib/odoo/filestore"
    sudo mkdir -p "$FILESTORE_DIR"
    if [ -d "$BACKUP_ROOT/filestore" ]; then
        cp -r "$BACKUP_ROOT/filestore" "$FILESTORE_DIR/$DB_NAME" 2>/dev/null || true
    fi
    
    # 获取原HTTP端口
    HTTP_PORT="8069"
    if [ -f "$BACKUP_ROOT/metadata/system_info.txt" ]; then
        HTTP_PORT=$(grep "HTTP端口:" "$BACKUP_ROOT/metadata/system_info.txt" | cut -d':' -f2 | tr -d ' ')
    fi
    
    # 创建配置文件
    ODOO_CONF="/etc/odoo/odoo.conf"
    sudo mkdir -p /etc/odoo
    sudo bash -c "cat > $ODOO_CONF" << EOF
[options]
addons_path = $ODOO_DIR/odoo/addons,$ODOO_DIR/addons,$CUSTOM_DIR
data_dir = $FILESTORE_DIR
admin_passwd = admin
db_host = localhost
db_port = 5432
db_user = $USER
db_name = $DB_NAME
http_port = $HTTP_PORT
without_demo = True
proxy_mode = True
EOF
    
# 源码部署性能优化
optimize_source_performance() {
    log_info "应用源码部署性能优化..."
    
    # 1. PostgreSQL性能优化
    log_info "  优化PostgreSQL配置..."
    
    # 查找PostgreSQL配置文件
    POSTGRES_CONF=""
    for version in $(ls /etc/postgresql/ 2>/dev/null | sort -V -r); do
        if [ -f "/etc/postgresql/$version/main/postgresql.conf" ]; then
            POSTGRES_CONF="/etc/postgresql/$version/main/postgresql.conf"
            break
        fi
    done
    
    if [ -n "$POSTGRES_CONF" ] && [ -f "$POSTGRES_CONF" ]; then
        # 备份原配置
        sudo cp "$POSTGRES_CONF" "$POSTGRES_CONF.backup.$(date +%Y%m%d)"
        
        # 获取系统内存
        TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
        
        # 计算优化参数
        SHARED_BUFFERS=$((TOTAL_MEM_MB / 4))  # 25% of RAM
        EFFECTIVE_CACHE_SIZE=$((TOTAL_MEM_MB * 3 / 4))  # 75% of RAM
        WORK_MEM=$((TOTAL_MEM_MB / 64))  # RAM/64
        MAINTENANCE_WORK_MEM=$((TOTAL_MEM_MB / 16))  # RAM/16
        
        # 应用优化配置
        sudo bash -c "cat >> $POSTGRES_CONF" << EOF

# Odoo Performance Optimizations - Added $(date)
shared_buffers = ${SHARED_BUFFERS}MB
effective_cache_size = ${EFFECTIVE_CACHE_SIZE}MB
work_mem = ${WORK_MEM}MB
maintenance_work_mem = ${MAINTENANCE_WORK_MEM}MB
checkpoint_completion_target = 0.9
wal_buffers = 16MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200
max_worker_processes = 8
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
max_parallel_maintenance_workers = 4
EOF
        
        sudo systemctl restart postgresql
        log_success "  PostgreSQL性能优化完成"
    fi
    
    # 2. Odoo配置优化
    log_info "  优化Odoo配置..."
    if [ -f "$ODOO_CONF" ]; then
        # 备份原配置
        sudo cp "$ODOO_CONF" "$ODOO_CONF.backup.$(date +%Y%m%d)"
        
        # 添加性能优化配置
        sudo bash -c "cat >> $ODOO_CONF" << EOF

# Performance Optimizations - Added $(date)
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
EOF
        log_success "  Odoo性能配置完成"
    fi
    
    # 3. 系统级优化
    log_info "  应用系统级优化..."
    
    # 优化文件描述符限制
    sudo bash -c "cat >> /etc/security/limits.conf" << EOF
# Odoo optimizations
$USER soft nofile 65536
$USER hard nofile 65536
$USER soft nproc 32768
$USER hard nproc 32768
EOF
    
    # 优化内核参数
    sudo bash -c "cat >> /etc/sysctl.conf" << EOF
# Odoo performance optimizations
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 5000
EOF
    sudo sysctl -p
    
    log_success "  系统级优化完成"
}

# 源码部署安全优化
optimize_source_security() {
    log_info "应用源码部署安全优化..."
    
    # 1. 创建专用用户（如果不存在）
    if ! id "odoo" &>/dev/null; then
        sudo useradd -r -s /bin/false -d /opt/odoo -m odoo
        log_info "  创建odoo专用用户"
    fi
    
    # 2. 设置正确的文件权限
    log_info "  设置安全文件权限..."
    sudo chown -R odoo:odoo "$ODOO_DIR"
    sudo chmod -R 750 "$ODOO_DIR"
    sudo chmod +x "$ODOO_DIR/odoo-bin"
    
    # 设置配置文件权限
    sudo chown odoo:odoo "$ODOO_CONF"
    sudo chmod 640 "$ODOO_CONF"
    
    # 设置数据目录权限
    if [ -d "$FILESTORE_DIR" ]; then
        sudo chown -R odoo:odoo "$FILESTORE_DIR"
        sudo chmod -R 750 "$FILESTORE_DIR"
    fi
    
    # 3. 配置防火墙
    log_info "  配置防火墙规则..."
    if command -v ufw &> /dev/null; then
        sudo ufw --force enable
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        sudo ufw allow ssh
        sudo ufw allow 80/tcp
        sudo ufw allow 443/tcp
        # 只允许本地访问Odoo端口
        sudo ufw allow from 127.0.0.1 to any port $HTTP_PORT
        log_success "  防火墙配置完成"
    fi
    
    # 4. 增强Odoo配置安全性
    log_info "  增强Odoo安全配置..."
    sudo bash -c "cat >> $ODOO_CONF" << EOF

# Security Optimizations - Added $(date)
admin_passwd = $(openssl rand -base64 32)
list_db = False
dbfilter = ^%d\$
proxy_mode = True
server_wide_modules = base,web
EOF
    
    # 5. 设置日志轮转
    sudo bash -c "cat > /etc/logrotate.d/odoo" << EOF
/var/log/odoo/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 odoo odoo
    postrotate
        systemctl reload odoo
    endscript
}
EOF
    
    # 6. 创建日志目录
    sudo mkdir -p /var/log/odoo
    sudo chown odoo:odoo /var/log/odoo
    sudo chmod 750 /var/log/odoo
    
    # 更新服务文件使用odoo用户
    sudo bash -c "cat > /etc/systemd/system/odoo.service" << EOF
[Unit]
Description=Odoo Open Source ERP and CRM (Version $ODOO_VERSION)
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=odoo
Group=odoo
WorkingDirectory=$ODOO_DIR
Environment="PATH=$VENV_PATH/bin"
ExecStart=$VENV_PATH/bin/python3 $ODOO_DIR/odoo-bin --config=$ODOO_CONF --logfile=/var/log/odoo/odoo.log
Restart=always
RestartSec=5s
KillMode=mixed
TimeoutStopSec=120

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$ODOO_DIR $FILESTORE_DIR /var/log/odoo /tmp

[Install]
WantedBy=multi-user.target
EOF
    
    log_success "源码部署安全优化完成"
}
    
    # 启动服务
    sudo systemctl daemon-reload
    sudo systemctl enable odoo
    
    # 应用性能和安全优化
    optimize_source_performance
    optimize_source_security
    
    sudo systemctl start odoo
    
    # 验证安装
    sleep 10
    if systemctl is-active --quiet odoo; then
        echo "========================================"
        log_success "Odoo $ODOO_VERSION 源码恢复成功！"
        echo "========================================"
        log_info "访问地址: http://$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "localhost"):$HTTP_PORT"
        log_info "数据库: $DB_NAME"
        log_info "服务状态: sudo systemctl status odoo"
        echo ""
        log_info "接下来运行: ./odoo-migrate.sh nginx"
        echo "========================================"
        
        # 记录恢复信息
        echo "SOURCE" > "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt"
        echo "$HTTP_PORT" > "$SCRIPT_DIR/ODOO_PORT.txt"
    else
        log_error "服务启动失败，查看日志: sudo journalctl -u odoo"
        exit 1
    fi
}
# 恢复功能 - Docker方式
restore_docker() {
    echo "========================================"
    echo "    Odoo Docker Compose 恢复"
    echo "========================================"
    
    check_system
    
    # 定位备份文件
    BACKUP_FILE=$(ls -1t "$SCRIPT_DIR"/odoo_backup_*.zip 2>/dev/null | head -1)
    if [ -z "$BACKUP_FILE" ]; then
        log_error "当前目录未找到备份文件"
        exit 1
    fi
    
    # 解压并读取版本信息
    RESTORE_DIR="$TEMP_BASE/restore"
    mkdir -p "$RESTORE_DIR"
    unzip -q "$BACKUP_FILE" -d "$RESTORE_DIR"
    BACKUP_ROOT=$(find "$RESTORE_DIR" -type d -name "odoo_backup_*" | head -1)
    
    if [ -f "$BACKUP_ROOT/metadata/versions.txt" ]; then
        ODOO_VERSION=$(grep "ODOO_VERSION:" "$BACKUP_ROOT/metadata/versions.txt" | cut -d' ' -f2)
        WEBSITE_ENABLED=$(grep "WEBSITE_ENABLED:" "$BACKUP_ROOT/metadata/versions.txt" | cut -d' ' -f2 2>/dev/null)
        WEBSITE_DOMAINS=$(grep "WEBSITE_DOMAINS:" "$BACKUP_ROOT/metadata/versions.txt" | cut -d' ' -f2- 2>/dev/null)
        
        # 网站域名迁移提示
        if [ "$WEBSITE_ENABLED" = "true" ] && [ -n "$WEBSITE_DOMAINS" ]; then
            echo ""
            log_warning "⚠️  重要提示：检测到原系统启用了网站功能"
            log_warning "   绑定域名: $WEBSITE_DOMAINS"
            log_warning "   建议迁移后保持相同域名，避免网站功能异常"
            echo ""
            read -p "是否继续恢复? 如需更改域名请在恢复后手动更新数据库配置 [y/N]: " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "恢复已取消"
                exit 0
            fi
        fi
        
        if [ "$ODOO_VERSION" = "未知" ]; then
            read -p "请输入Odoo版本号 (如 17.0): " ODOO_VERSION
        fi
    else
        read -p "请输入Odoo版本号 (如 17.0): " ODOO_VERSION
    fi
    
    # 验证版本格式
    if [[ ! "$ODOO_VERSION" =~ ^[0-9]+\.0$ ]]; then
        log_error "版本格式错误，应为 '17.0' 或 '18.0' 格式"
        exit 1
    fi
    
    # 安装Docker
    if ! command -v docker &> /dev/null; then
        log_info "安装Docker..."
        sudo apt-get update
        sudo apt-get install -y docker.io docker-compose
        sudo systemctl start docker
        sudo systemctl enable docker
        sudo usermod -aG docker $USER
        log_warning "需要重新登录或执行: newgrp docker"
    fi
    
    # 创建统一数据目录
    ODOO_DOCKER_DIR="/opt/odoo_docker"
    sudo mkdir -p "$ODOO_DOCKER_DIR"/{postgres_data,odoo_data,addons,backups,config}
    sudo chown -R $USER:$USER "$ODOO_DOCKER_DIR"
    
    # 恢复自定义模块
    for custom in "$BACKUP_ROOT/source"/custom_*; do
        if [ -d "$custom" ]; then
            cp -r "$custom" "$ODOO_DOCKER_DIR/addons/"
            log_success "恢复模块: $(basename "$custom")"
        fi
    done
    
    # 恢复文件存储
    if [ -d "$BACKUP_ROOT/filestore" ]; then
        cp -r "$BACKUP_ROOT/filestore" "$ODOO_DOCKER_DIR/odoo_data/filestore" 2>/dev/null || true
    fi
    
    # 复制备份文件
    cp "$BACKUP_FILE" "$ODOO_DOCKER_DIR/backups/"
    
# Docker部署性能优化
optimize_docker_performance() {
    log_info "应用Docker部署性能优化..."
    
    # 1. 创建优化的Docker Compose配置
    cat > "$ODOO_DOCKER_DIR/docker-compose.yml" << EOF
version: '3.8'

services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: odoo
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ./postgres_data:/var/lib/postgresql/data/pgdata
      - ./postgres_config/postgresql.conf:/etc/postgresql/postgresql.conf
    command: postgres -c config_file=/etc/postgresql/postgresql.conf
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo"]
      interval: 10s
      timeout: 5s
      retries: 5
    # 性能优化
    shm_size: 256mb
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 1G

  odoo:
    image: odoo:$ODOO_VERSION
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "127.0.0.1:8069:8069"  # 只绑定本地接口，提高安全性
    environment:
      HOST: postgres
      USER: odoo
      PASSWORD: odoo
    volumes:
      - ./odoo_data:/var/lib/odoo
      - ./addons:/mnt/extra-addons
      - ./config/odoo.conf:/etc/odoo/odoo.conf:ro
      - ./logs:/var/log/odoo
    restart: unless-stopped
    command: >
      --config=/etc/odoo/odoo.conf
      --dev=xml
      --proxy-mode
      --db-filter=^%d$
      --logfile=/var/log/odoo/odoo.log
    # 性能和安全优化
    deploy:
      resources:
        limits:
          memory: 4G
        reservations:
          memory: 2G
    security_opt:
      - no-new-privileges:true
    read_only: false
    tmpfs:
      - /tmp:noexec,nosuid,size=100m

volumes:
  postgres_data:
  odoo_data:

networks:
  default:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
EOF
    
    # 2. 创建优化的PostgreSQL配置
    mkdir -p "$ODOO_DOCKER_DIR/postgres_config"
    
    # 获取系统内存
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
    
    # 计算Docker环境下的优化参数（更保守）
    SHARED_BUFFERS=$((TOTAL_MEM_MB / 8))  # 12.5% of RAM for Docker
    EFFECTIVE_CACHE_SIZE=$((TOTAL_MEM_MB / 2))  # 50% of RAM for Docker
    WORK_MEM=$((TOTAL_MEM_MB / 128))  # RAM/128 for Docker
    MAINTENANCE_WORK_MEM=$((TOTAL_MEM_MB / 32))  # RAM/32 for Docker
    
    cat > "$ODOO_DOCKER_DIR/postgres_config/postgresql.conf" << EOF
# PostgreSQL configuration for Odoo Docker deployment
# Generated on $(date)

# Connection settings
listen_addresses = '*'
port = 5432
max_connections = 100

# Memory settings
shared_buffers = ${SHARED_BUFFERS}MB
effective_cache_size = ${EFFECTIVE_CACHE_SIZE}MB
work_mem = ${WORK_MEM}MB
maintenance_work_mem = ${MAINTENANCE_WORK_MEM}MB

# Checkpoint settings
checkpoint_completion_target = 0.9
wal_buffers = 16MB

# Query planner settings
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200

# Parallel query settings
max_worker_processes = 8
max_parallel_workers_per_gather = 2
max_parallel_workers = 8
max_parallel_maintenance_workers = 2

# Logging settings
log_destination = 'stderr'
logging_collector = off
log_min_messages = warning
log_min_error_statement = error

# Locale settings
lc_messages = 'en_US.utf8'
lc_monetary = 'en_US.utf8'
lc_numeric = 'en_US.utf8'
lc_time = 'en_US.utf8'
default_text_search_config = 'pg_catalog.english'
EOF
    
    # 3. 创建优化的Odoo配置文件
    mkdir -p "$ODOO_DOCKER_DIR/config"
    cat > "$ODOO_DOCKER_DIR/config/odoo.conf" << EOF
[options]
# Database settings
db_host = postgres
db_port = 5432
db_user = odoo
db_password = odoo
db_maxconn = 64

# Server settings
http_port = 8069
proxy_mode = True

# Performance settings
workers = $(nproc)
max_cron_threads = 2
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = 0

# Security settings
admin_passwd = $(openssl rand -base64 32)
list_db = False
dbfilter = ^%d\$
server_wide_modules = base,web

# Logging settings
log_level = info
logfile = /var/log/odoo/odoo.log
log_db = False
log_handler = :INFO
syslog = False

# Session settings
session_dir = /tmp/sessions

# Addons settings
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons
EOF
    
    # 4. 创建日志目录
    mkdir -p "$ODOO_DOCKER_DIR/logs"
    chmod 755 "$ODOO_DOCKER_DIR/logs"
    
    log_success "Docker部署性能优化完成"
}

# Docker部署安全优化
optimize_docker_security() {
    log_info "应用Docker部署安全优化..."
    
    # 1. 创建Docker安全配置
    sudo mkdir -p /etc/docker
    sudo bash -c "cat > /etc/docker/daemon.json" << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true
}
EOF
    
    # 2. 配置防火墙规则
    if command -v ufw &> /dev/null; then
        sudo ufw --force enable
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        sudo ufw allow ssh
        sudo ufw allow 80/tcp
        sudo ufw allow 443/tcp
        # Docker网络规则
        sudo ufw allow from 172.20.0.0/16
        log_success "  防火墙配置完成"
    fi
    
    # 3. 创建安全的管理脚本
    cat > "$ODOO_DOCKER_DIR/manage.sh" << 'EOF'
#!/bin/bash
# Secure Odoo Docker management script

set -e

# 检查权限
check_permissions() {
    if [ "$EUID" -eq 0 ]; then
        echo "[错误] 不要以root用户运行此脚本"
        exit 1
    fi
}

# 安全检查
security_check() {
    # 检查文件权限
    if [ -f "docker-compose.yml" ]; then
        PERMS=$(stat -c "%a" docker-compose.yml)
        if [ "$PERMS" != "644" ]; then
            log_warn "docker-compose.yml权限不安全，正在修复..."
            chmod 644 docker-compose.yml
        fi
    fi
    
    # 检查配置文件权限
    if [ -f "config/odoo.conf" ]; then
        PERMS=$(stat -c "%a" config/odoo.conf)
        if [ "$PERMS" != "600" ]; then
            log_warn "odoo.conf权限不安全，正在修复..."
            chmod 600 config/odoo.conf
        fi
    fi
}

case "$1" in
    start)
        check_permissions
        security_check
        log_info "启动 Odoo 服务..."
        docker-compose up -d
        ;;
    stop)
        check_permissions
        log_info "停止 Odoo 服务..."
        docker-compose down
        ;;
    restart)
        check_permissions
        security_check
        log_info "重启 Odoo 服务..."
        docker-compose restart
        ;;
    logs)
        docker-compose logs -f --tail=100 odoo
        ;;
    status)
        docker-compose ps
        echo ""
        log_info "资源使用情况:"
        docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
        ;;
    backup)
        check_permissions
        log_info "备份数据库..."
        DB_NAME=$(docker-compose exec -T postgres psql -U odoo -t -c "SELECT datname FROM pg_database WHERE datname LIKE 'odoo_%'" | head -1 | tr -d '[:space:]')
        if [ -n "$DB_NAME" ]; then
            BACKUP_FILE="backups/backup_$(date +%Y%m%d_%H%M%S).sql"
            mkdir -p backups
            docker-compose exec -T postgres pg_dump -U odoo "$DB_NAME" > "$BACKUP_FILE"
            gzip "$BACKUP_FILE"
            echo "备份完成: ${BACKUP_FILE}.gz"
        else
            echo "未找到Odoo数据库"
        fi
        ;;
    restore)
        check_permissions
        ./restore_database.sh
        ;;
    update)
        check_permissions
        security_check
        log_info "更新容器镜像..."
        docker-compose pull
        docker-compose up -d
        ;;
    cleanup)
        check_permissions
        log_info "清理未使用的Docker资源..."
        docker system prune -f
        docker volume prune -f
        ;;
    security-scan)
        echo "执行安全扫描..."
        if command -v docker-bench-security &> /dev/null; then
            docker-bench-security
        else
            echo "docker-bench-security未安装，跳过安全扫描"
        fi
        security_check
        ;;
    *)
        echo "用法: $0 {start|stop|restart|logs|status|backup|restore|update|cleanup|security-scan}"
        echo ""
        echo "命令说明:"
        echo "  start         - 启动服务"
        echo "  stop          - 停止服务"
        echo "  restart       - 重启服务"
        echo "  logs          - 查看日志"
        echo "  status        - 查看状态和资源使用"
        echo "  backup        - 备份数据库"
        echo "  restore       - 恢复数据库"
        echo "  update        - 更新容器镜像"
        echo "  cleanup       - 清理Docker资源"
        echo "  security-scan - 安全扫描"
        exit 1
        ;;
esac
EOF
    chmod +x "$ODOO_DOCKER_DIR/manage.sh"
    
    # 4. 设置安全的文件权限
    chmod 600 "$ODOO_DOCKER_DIR/config/odoo.conf"
    chmod 644 "$ODOO_DOCKER_DIR/docker-compose.yml"
    chmod -R 755 "$ODOO_DOCKER_DIR"
    
    # 5. 创建日志轮转配置
    sudo bash -c "cat > /etc/logrotate.d/odoo-docker" << EOF
$ODOO_DOCKER_DIR/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 $(id -u):$(id -g)
    postrotate
        docker-compose -f $ODOO_DOCKER_DIR/docker-compose.yml restart odoo
    endscript
}
EOF
    
    log_success "Docker部署安全优化完成"
}
    
    # 创建管理脚本
    cat > "$ODOO_DOCKER_DIR/manage.sh" << 'EOF'
#!/bin/bash
case "$1" in
    start) docker-compose up -d ;;
    stop) docker-compose down ;;
    restart) docker-compose restart ;;
    logs) docker-compose logs -f odoo ;;
    status) docker-compose ps ;;
    backup)
        DB_NAME=$(docker-compose exec -T postgres psql -U odoo -t -c "SELECT datname FROM pg_database WHERE datname LIKE 'odoo_%'" | head -1 | tr -d '[:space:]')
        if [ -n "$DB_NAME" ]; then
            BACKUP_FILE="backups/backup_$(date +%Y%m%d_%H%M%S).sql"
            mkdir -p backups
            docker-compose exec -T postgres pg_dump -U odoo "$DB_NAME" > "$BACKUP_FILE"
            gzip "$BACKUP_FILE"
            echo "备份完成: ${BACKUP_FILE}.gz"
        else
            echo "未找到Odoo数据库"
        fi
        ;;
    restore) ./restore_database.sh ;;
    *) echo "用法: $0 {start|stop|restart|logs|status|backup|restore}" ;;
esac
EOF
    chmod +x "$ODOO_DOCKER_DIR/manage.sh"
    
    # 创建数据库恢复脚本
    cat > "$ODOO_DOCKER_DIR/restore_database.sh" << 'EOF'
#!/bin/bash
set -e
echo "=== 数据库恢复工具 ==="

POSTGRES_CONTAINER=$(docker-compose ps -q postgres)
if [ -z "$POSTGRES_CONTAINER" ]; then
    echo "[错误] PostgreSQL容器未运行"
    exit 1
fi

BACKUP_FILE=$(ls -1t backups/odoo_backup_*.zip | head -1)
if [ -z "$BACKUP_FILE" ]; then
    echo "[错误] 未找到备份文件"
    exit 1
fi

TEMP_DIR="/tmp/db_restore_$(date +%s)"
mkdir -p "$TEMP_DIR"
unzip -q "$BACKUP_FILE" -d "$TEMP_DIR"
BACKUP_ROOT=$(find "$TEMP_DIR" -type d -name "odoo_backup_*" | head -1)

if [ ! -f "$BACKUP_ROOT/database/dump.sql" ]; then
    echo "[错误] 备份中未找到数据库文件"
    exit 1
fi

DB_NAME="odoo_restored_$(date +%Y%m%d)"
echo "创建数据库: $DB_NAME"
docker exec "$POSTGRES_CONTAINER" bash -c "createdb -U odoo $DB_NAME 2>/dev/null || true"

echo "恢复数据库..."
docker exec -i "$POSTGRES_CONTAINER" psql -U odoo "$DB_NAME" < "$BACKUP_ROOT/database/dump.sql"

rm -rf "$TEMP_DIR"
echo "✅ 数据库恢复完成！数据库名: $DB_NAME"
EOF
    chmod +x "$ODOO_DOCKER_DIR/restore_database.sh"
    
    # 启动服务
    cd "$ODOO_DOCKER_DIR"
    docker-compose down 2>/dev/null || true
    
    # 应用性能和安全优化
    optimize_docker_performance
    optimize_docker_security
    
    docker-compose up -d
    
    # 等待并恢复数据库
    sleep 15
    if [ -f "$BACKUP_ROOT/database/dump.sql" ]; then
        ./restore_database.sh
    fi
    
    # 验证
    if curl -s --max-time 5 http://localhost:8069 > /dev/null; then
        echo "========================================"
        log_success "Odoo Docker Compose 恢复成功！"
        echo "========================================"
        log_info "访问地址: http://$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "localhost"):8069"
        log_info "数据目录: $ODOO_DOCKER_DIR"
        echo ""
        log_info "管理命令 (在 $ODOO_DOCKER_DIR 目录):"
        echo "  ./manage.sh start|stop|restart|logs|status"
        echo ""
        log_info "接下来运行: ./odoo-migrate.sh nginx"
        echo "========================================"
        
        # 记录部署信息
        echo "DOCKER" > "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt"
        echo "8069" > "$SCRIPT_DIR/ODOO_PORT.txt"
    else
        log_warning "服务可能正在启动中，请检查: cd $ODOO_DOCKER_DIR && docker-compose logs -f"
    fi
}
# Nginx配置功能
configure_nginx() {
    echo "========================================"
    echo "    Odoo Nginx智能反向代理配置"
    echo "========================================"
    
    check_system
    
    # 检测部署方式
    DEPLOYMENT_TYPE=""
    ODOO_PORT="8069"
    
    if [ -f "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt" ]; then
        DEPLOYMENT_TYPE=$(cat "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt")
        log_info "检测到部署类型: $DEPLOYMENT_TYPE"
    fi
    
    if [ -f "$SCRIPT_DIR/ODOO_PORT.txt" ]; then
        ODOO_PORT=$(cat "$SCRIPT_DIR/ODOO_PORT.txt")
    fi
    
    # 验证端口是否在使用
    if ! ss -tln | grep -q ":$ODOO_PORT "; then
        log_warning "端口 $ODOO_PORT 未检测到服务"
        read -p "是否继续配置? [y/N]: " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    
    log_info "Odoo服务端口: $ODOO_PORT"
    
    # 获取域名信息
    read -p "请输入您的域名 (例如: example.com): " DOMAIN
    
    # 处理域名
    if [[ $DOMAIN == www.* ]]; then
        MAIN_DOMAIN="${DOMAIN#www.}"
        WWW_DOMAIN="$DOMAIN"
    else
        MAIN_DOMAIN="$DOMAIN"
        WWW_DOMAIN="www.$DOMAIN"
    fi
    
    # 安装Certbot
    if ! command -v certbot &> /dev/null; then
        log_info "安装Certbot..."
        sudo apt-get update
        sudo apt-get install -y certbot python3-certbot-nginx
    fi
    
    # 获取SSL证书
    read -p "请输入管理员邮箱: " ADMIN_EMAIL
    
    log_info "申请SSL证书..."
    USE_SSL=true
    if sudo certbot certonly --nginx --non-interactive --agree-tos \
        -m "$ADMIN_EMAIL" -d "$MAIN_DOMAIN" -d "$WWW_DOMAIN" 2>/dev/null; then
        log_success "SSL证书获取完成"
    else
        log_warning "SSL证书获取失败，配置HTTP访问"
        USE_SSL=false
    fi
    
    # 创建高性能Nginx配置
    NGINX_CONF="/etc/nginx/sites-available/odoo_$MAIN_DOMAIN"
    
    # 检测部署类型以优化配置
    if [ "$DEPLOYMENT_TYPE" = "DOCKER" ]; then
        UPSTREAM_CONFIG="server 127.0.0.1:$ODOO_PORT max_fails=3 fail_timeout=30s;"
        CACHE_CONFIG="# Docker部署缓存配置"
    else
        UPSTREAM_CONFIG="server 127.0.0.1:$ODOO_PORT max_fails=3 fail_timeout=30s;"
        CACHE_CONFIG="# 源码部署缓存配置"
    fi
    
    sudo bash -c "cat > $NGINX_CONF" << EOF
# Odoo高性能反向代理配置
# 生成时间: $(date)
# 部署类型: ${DEPLOYMENT_TYPE:-未知}
# Odoo端口: $ODOO_PORT

# 上游服务器配置
upstream odoo_backend {
    $UPSTREAM_CONFIG
    keepalive 32;
    keepalive_requests 100;
    keepalive_timeout 60s;
}

upstream odoo_longpolling {
    server 127.0.0.1:8072 max_fails=3 fail_timeout=30s;
    keepalive 16;
}

# 缓存配置
proxy_cache_path /var/cache/nginx/odoo levels=1:2 keys_zone=odoo_cache:100m max_size=2g inactive=60m use_temp_path=off;
proxy_cache_path /var/cache/nginx/odoo_static levels=1:2 keys_zone=odoo_static:50m max_size=1g inactive=7d use_temp_path=off;

# 限流配置
limit_req_zone \$binary_remote_addr zone=login:10m rate=5r/m;
limit_req_zone \$binary_remote_addr zone=api:10m rate=30r/m;
limit_req_zone \$binary_remote_addr zone=general:10m rate=10r/s;

# 连接限制
limit_conn_zone \$binary_remote_addr zone=conn_limit_per_ip:10m;

# 地理位置阻止（可选）
geo \$blocked_country {
    default 0;
    # 根据需要添加要阻止的国家IP段
    # 例如: 1.2.3.0/24 1;
}

# 安全头部映射
map \$sent_http_content_type \$content_type_csp {
    ~^text/html "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:; img-src 'self' data: blob: https:; font-src 'self' data:; connect-src 'self' wss: ws:";
    default "";
}
EOF
    
    # HTTP重定向配置（如果启用SSL）
    if [ "$USE_SSL" = true ]; then
        sudo bash -c "cat >> $NGINX_CONF" << EOF

# HTTP到HTTPS重定向
server {
    listen 80;
    server_name $MAIN_DOMAIN $WWW_DOMAIN;
    
    # 安全头部
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    
    # Let's Encrypt验证
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    
    # 重定向到HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}
EOF
    fi
    
    # 主服务器配置
    if [ "$USE_SSL" = true ]; then
        sudo bash -c "cat >> $NGINX_CONF" << EOF

# HTTPS主服务器
server {
    listen 443 ssl http2;
    server_name $MAIN_DOMAIN;
    
    # SSL配置
    ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozTLS:10m;
    ssl_session_tickets off;
    
    # 现代SSL配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # HSTS
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
EOF
    else
        sudo bash -c "cat >> $NGINX_CONF" << EOF

# HTTP主服务器
server {
    listen 80;
    server_name $MAIN_DOMAIN;
EOF
    fi
    
    # 通用安全和性能配置
    sudo bash -c "cat >> $NGINX_CONF" << EOF
    
    # 基本设置
    client_max_body_size 200M;
    client_body_timeout 60s;
    client_header_timeout 60s;
    keepalive_timeout 65s;
    send_timeout 60s;
    
    # 连接限制
    limit_conn conn_limit_per_ip 20;
    
    # 安全头部
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy \$content_type_csp always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
    
    # 隐藏服务器信息
    server_tokens off;
    
    # 地理位置阻止
    if (\$blocked_country) {
        return 403;
    }
    
    # 禁止访问敏感文件
    location ~ /\.(ht|git|svn) {
        deny all;
        return 404;
    }
    
    location ~ \.(sql|conf|log|bak|backup)\$ {
        deny all;
        return 404;
    }
    
    # 禁止访问敏感路径
    location ~* ^/(web/database|database|manager|phpmyadmin|admin|xmlrpc) {
        deny all;
        return 403;
    }
    
    # 登录限流
    location ~* ^/web/login {
        limit_req zone=login burst=3 nodelay;
        proxy_pass http://odoo_backend;
        include /etc/nginx/proxy_params;
    }
    
    # API限流
    location ~* ^/(api|jsonrpc) {
        limit_req zone=api burst=10 nodelay;
        proxy_pass http://odoo_backend;
        include /etc/nginx/proxy_params;
    }
    
    # 长轮询支持
    location /longpolling {
        proxy_pass http://odoo_longpolling;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
    
    # WebSocket支持
    location /websocket {
        proxy_pass http://odoo_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
    
    # 静态文件高性能缓存
    location ~* /web/(static|image)/ {
        proxy_pass http://odoo_backend;
        proxy_cache odoo_static;
        proxy_cache_key \$scheme\$proxy_host\$request_uri;
        proxy_cache_valid 200 7d;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_lock on;
        proxy_cache_revalidate on;
        
        # 浏览器缓存
        expires 7d;
        add_header Cache-Control "public, immutable";
        add_header X-Cache-Status \$upstream_cache_status always;
        
        # Gzip压缩
        gzip on;
        gzip_vary on;
        gzip_types text/css application/javascript image/svg+xml;
        
        # 安全头部
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-Content-Type-Options "nosniff" always;
    }
    
    # CSS/JS文件优化
    location ~* \.(css|js)\$ {
        proxy_pass http://odoo_backend;
        proxy_cache odoo_static;
        proxy_cache_valid 200 1d;
        expires 1d;
        add_header Cache-Control "public";
        gzip on;
        gzip_types text/css application/javascript;
    }
    
    # 图片文件优化
    location ~* \.(jpg|jpeg|png|gif|ico|svg|webp)\$ {
        proxy_pass http://odoo_backend;
        proxy_cache odoo_static;
        proxy_cache_valid 200 30d;
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
    
    # 字体文件优化
    location ~* \.(woff|woff2|ttf|eot)\$ {
        proxy_pass http://odoo_backend;
        proxy_cache odoo_static;
        proxy_cache_valid 200 1y;
        expires 1y;
        add_header Cache-Control "public, immutable";
        add_header Access-Control-Allow-Origin "*";
    }
    
    # 健康检查端点
    location /nginx-health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
    
    # 主应用代理
    location / {
        limit_req zone=general burst=20 nodelay;
        
        proxy_pass http://odoo_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        
        # 代理头部
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        # 超时设置
        proxy_connect_timeout 300s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
        
        # 缓冲设置
        proxy_buffering on;
        proxy_buffers 16 64k;
        proxy_buffer_size 128k;
        proxy_busy_buffers_size 128k;
        proxy_temp_file_write_size 1024m;
        
        # 错误处理
        proxy_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
        proxy_next_upstream_tries 3;
        proxy_next_upstream_timeout 10s;
        
        # 隐藏后端头部
        proxy_hide_header X-Powered-By;
        proxy_hide_header Server;
    }
    
    # 错误页面
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
    
    location = /404.html {
        root /var/www/html;
        internal;
    }
    
    location = /50x.html {
        root /var/www/html;
        internal;
    }
}
EOF
    
    # WWW重定向配置
    if [ "$USE_SSL" = true ]; then
        sudo bash -c "cat >> $NGINX_CONF" << EOF

# WWW重定向到非WWW
server {
    listen 443 ssl http2;
    server_name $WWW_DOMAIN;
    
    ssl_certificate /etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem;
    
    return 301 https://$MAIN_DOMAIN\$request_uri;
}
EOF
    fi
    
    # 启用配置
    sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    
    # 创建缓存目录
    sudo mkdir -p /var/cache/nginx/odoo /var/cache/nginx/odoo_static
    sudo chown -R www-data:www-data /var/cache/nginx/
    
    # 创建错误页面
    sudo mkdir -p /var/www/html
    sudo bash -c "cat > /var/www/html/404.html" << 'EOF'
<!DOCTYPE html>
<html><head><title>页面未找到</title></head>
<body><h1>404 - 页面未找到</h1><p>请检查URL是否正确。</p></body></html>
EOF
    
    sudo bash -c "cat > /var/www/html/50x.html" << 'EOF'
<!DOCTYPE html>
<html><head><title>服务暂时不可用</title></head>
<body><h1>服务暂时不可用</h1><p>请稍后再试。</p></body></html>
EOF
    
    # 优化Nginx主配置
    sudo bash -c "cat > /etc/nginx/nginx.conf" << 'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    # 基本设置
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    
    # MIME类型
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # 日志格式
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    'rt=$request_time uct="$upstream_connect_time" '
                    'uht="$upstream_header_time" urt="$upstream_response_time"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;
    
    # Gzip压缩
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;
    
    # 缓冲区设置
    client_body_buffer_size 128k;
    client_header_buffer_size 1k;
    large_client_header_buffers 4 4k;
    output_buffers 1 32k;
    postpone_output 1460;
    
    # 超时设置
    client_header_timeout 3m;
    client_body_timeout 3m;
    send_timeout 3m;
    
    # 代理设置
    proxy_connect_timeout 300;
    proxy_send_timeout 300;
    proxy_read_timeout 300;
    proxy_buffer_size 4k;
    proxy_buffers 4 32k;
    proxy_busy_buffers_size 64k;
    proxy_temp_file_write_size 64k;
    proxy_intercept_errors on;
    
    # 包含站点配置
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF
    
    # 创建代理参数文件
    sudo bash -c "cat > /etc/nginx/proxy_params" << 'EOF'
proxy_set_header Host $http_host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Port $server_port;
proxy_redirect off;
EOF
    
    # 测试并重启Nginx
    if sudo nginx -t; then
        sudo systemctl reload nginx || sudo systemctl restart nginx
        log_success "Nginx配置完成"
        
        # 配置证书自动续期
        if [ "$USE_SSL" = true ]; then
            sudo bash -c "cat > /etc/letsencrypt/renewal-hooks/deploy/restart-nginx.sh" << 'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK
            sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-nginx.sh
        fi
        
        echo "========================================"
        log_success "Nginx配置完成！"
        echo "========================================"
        log_info "域名: $MAIN_DOMAIN"
        log_info "部署方式: ${DEPLOYMENT_TYPE:-自动检测}"
        log_info "Odoo端口: $ODOO_PORT"
        log_info "SSL证书: $([ "$USE_SSL" = true ] && echo "已启用" || echo "未启用")"
        echo ""
        log_info "访问地址:"
        if [ "$USE_SSL" = true ]; then
            echo "  https://$MAIN_DOMAIN"
        else
            echo "  http://$MAIN_DOMAIN"
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
    
    # 检查部署类型
    if [ -f "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt" ]; then
        DEPLOYMENT_TYPE=$(cat "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt")
        log_info "部署类型: $DEPLOYMENT_TYPE"
    else
        log_warning "未检测到部署类型记录"
        DEPLOYMENT_TYPE="未知"
    fi
    
    # 检查端口
    if [ -f "$SCRIPT_DIR/ODOO_PORT.txt" ]; then
        ODOO_PORT=$(cat "$SCRIPT_DIR/ODOO_PORT.txt")
        log_info "配置端口: $ODOO_PORT"
    else
        ODOO_PORT="8069"
    fi
    
    # 检查服务状态
    echo ""
    log_info "服务状态检查:"
    
    if [ "$DEPLOYMENT_TYPE" = "DOCKER" ]; then
        # Docker部署检查
        if [ -d "/opt/odoo_docker" ]; then
            cd /opt/odoo_docker
            if command -v docker-compose &> /dev/null; then
                echo "  Docker Compose状态:"
                docker-compose ps 2>/dev/null || echo "    未运行或配置错误"
            else
                log_warning "  Docker Compose未安装"
            fi
        else
            log_warning "  Docker数据目录不存在"
        fi
    else
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
    fi
    
    # 检查端口监听
    if ss -tln | grep -q ":$ODOO_PORT "; then
        log_success "  端口 $ODOO_PORT: 监听中"
    else
        log_warning "  端口 $ODOO_PORT: 未监听"
    fi
    
    # 检查Nginx
    if systemctl is-active --quiet nginx 2>/dev/null; then
        log_success "  Nginx: 运行中"
        
        # 检查Odoo配置文件
        NGINX_CONFIGS=$(ls /etc/nginx/sites-enabled/odoo_* 2>/dev/null | wc -l)
        if [ "$NGINX_CONFIGS" -gt 0 ]; then
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
    if curl -s --max-time 5 http://localhost:$ODOO_PORT > /dev/null; then
        log_success "  本地访问: 正常"
    else
        log_warning "  本地访问: 失败"
    fi
    
    # 显示访问信息
    echo ""
    log_info "访问信息:"
    PUBLIC_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "获取失败")
    echo "  公网IP: $PUBLIC_IP"
    echo "  本地访问: http://localhost:$ODOO_PORT"
    if [ "$PUBLIC_IP" != "获取失败" ]; then
        echo "  公网访问: http://$PUBLIC_IP:$ODOO_PORT"
    fi
    
    # 检查备份文件
    echo ""
    BACKUP_COUNT=$(ls -1 "$SCRIPT_DIR"/odoo_backup_*.zip 2>/dev/null | wc -l)
    if [ "$BACKUP_COUNT" -gt 0 ]; then
        log_info "备份文件: 找到 $BACKUP_COUNT 个备份文件"
        LATEST_BACKUP=$(ls -1t "$SCRIPT_DIR"/odoo_backup_*.zip 2>/dev/null | head -1)
        if [ -n "$LATEST_BACKUP" ]; then
            BACKUP_SIZE=$(du -h "$LATEST_BACKUP" | cut -f1)
            echo "  最新备份: $(basename "$LATEST_BACKUP") ($BACKUP_SIZE)"
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
            if [ "${2:-source}" = "docker" ]; then
                restore_docker
            else
                restore_source
            fi
            ;;
        nginx)
            configure_nginx
            ;;
        optimize)
            if [ -f "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt" ]; then
                DEPLOYMENT_TYPE=$(cat "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt")
                if [ "$DEPLOYMENT_TYPE" = "DOCKER" ]; then
                    log_info "应用Docker部署优化..."
                    cd /opt/odoo_docker 2>/dev/null || {
                        log_error "Docker部署目录不存在"
                        exit 1
                    }
                    optimize_docker_performance
                    optimize_docker_security
                    docker-compose restart
                else
                    log_info "应用源码部署优化..."
                    optimize_source_performance
                    optimize_source_security
                    sudo systemctl restart odoo
                fi
            else
                log_error "未检测到部署类型，请先运行恢复命令"
                exit 1
            fi
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
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi