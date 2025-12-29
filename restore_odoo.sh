#!/bin/bash
# ====================================================
# restore_odoo.sh - Odoo源码恢复脚本（默认恢复方式）
# 严格按照备份的Python和Odoo版本恢复
# 使用方式：与备份ZIP文件放在同一目录运行
# ====================================================

set -e
echo "========================================"
echo "    Odoo 源码环境恢复（严格版本匹配）"
echo "========================================"

# 1. 环境检查
echo "[阶段1] 环境检查..."
if [ "$EUID" -eq 0 ]; then
    echo "[警告] 不建议以root用户运行"
    read -p "是否继续? [y/N]: " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# 2. 定位备份文件
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
BACKUP_FILE=$(ls -1t odoo_backup_*.zip 2>/dev/null | head -1)
if [ -z "$BACKUP_FILE" ]; then
    echo "[错误] 当前目录未找到备份文件 (odoo_backup_*.zip)"
    exit 1
fi
echo "[信息] 找到备份文件: $BACKUP_FILE"

# 3. 解压备份文件
echo "[阶段2] 解压备份文件..."
RESTORE_DIR="/tmp/odoo_restore_$(date +%s)"
mkdir -p "$RESTORE_DIR"
unzip -q "$BACKUP_FILE" -d "$RESTORE_DIR"
BACKUP_ROOT=$(find "$RESTORE_DIR" -type d -name "odoo_backup_*" | head -1)
if [ -z "$BACKUP_ROOT" ]; then
    echo "[错误] 备份包结构异常"
    exit 1
fi

# 4. 读取版本元数据（关键！）
echo "[阶段3] 读取版本元数据..."
if [ -f "$BACKUP_ROOT/metadata/versions.txt" ]; then
    ODOO_VERSION=$(grep "ODOO_VERSION:" "$BACKUP_ROOT/metadata/versions.txt" | cut -d' ' -f2)
    PYTHON_VERSION=$(grep "PYTHON_VERSION:" "$BACKUP_ROOT/metadata/versions.txt" | cut -d' ' -f2)
    echo "[信息] 原环境版本:"
    echo "  Odoo: $ODOO_VERSION"
    echo "  Python: $PYTHON_VERSION"
    
    if [ "$ODOO_VERSION" = "未知" ]; then
        echo "[错误] 备份中未记录Odoo版本，无法精确恢复"
        echo "请手动指定版本或使用Docker恢复"
        exit 1
    fi
else
    echo "[错误] 备份中缺少版本元数据"
    echo "请使用新版备份脚本重新备份"
    exit 1
fi

# 5. 安装指定版本的Python
echo "[阶段4] 安装Python $PYTHON_VERSION..."
if ! command -v "python$PYTHON_VERSION" &> /dev/null; then
    echo "[信息] 安装 Python $PYTHON_VERSION..."
    sudo apt-get update
    sudo apt-get install -y software-properties-common
    sudo add-apt-repository -y ppa:deadsnakes/ppa
    sudo apt-get update
    sudo apt-get install -y \
        "python$PYTHON_VERSION" \
        "python$PYTHON_VERSION-dev" \
        "python$PYTHON_VERSION-venv" \
        "python$PYTHON_VERSION-distutils"
else
    echo "[信息] Python $PYTHON_VERSION 已安装"
fi

# 6. 安装PostgreSQL（确保版本兼容）
echo "[阶段5] 安装PostgreSQL..."
sudo apt-get install -y \
    postgresql \
    postgresql-contrib \
    libpq-dev

# 检查PostgreSQL版本兼容性
PG_VERSION=$(psql --version 2>/dev/null | cut -d' ' -f3 | cut -d'.' -f1)
if [ -n "$PG_VERSION" ]; then
    echo "[信息] 新服务器PostgreSQL版本: $PG_VERSION"
    # 通常新版本兼容旧版本，这里只做提示
    echo "[提示] 确保PostgreSQL版本兼容性（新≥旧通常安全）"
fi

# 7. 安装系统依赖
echo "[阶段6] 安装系统依赖..."
sudo apt-get install -y \
    build-essential \
    libxml2-dev \
    libxslt1-dev \
    libldap2-dev \
    libsasl2-dev \
    libssl-dev \
    zlib1g-dev \
    libjpeg-dev \
    libfreetype6-dev \
    node-less \
    node-clean-css \
    python3-sass \
    fonts-wqy-zenhei \
    fonts-wqy-microhei \
    fontconfig \
    curl \
    wget \
    git \
    unzip

# 8. 安装wkhtmltopdf
echo "[阶段7] 安装wkhtmltopdf..."
if ! command -v wkhtmltopdf &> /dev/null; then
    wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/wkhtmltox_0.12.6-1.$(lsb_release -c -s)_amd64.deb
    sudo dpkg -i wkhtmltox_*.deb
    sudo apt-get install -f
fi

# 9. 恢复Odoo源码
echo "[阶段8] 恢复Odoo源码..."
ODOO_DIR="/opt/odoo"
sudo mkdir -p "$ODOO_DIR"
sudo chown -R $USER:$USER "$ODOO_DIR"

# 检查是否有源码文件
if [ "$(ls -A $BACKUP_ROOT/source/*.py 2>/dev/null | head -1)" ]; then
    echo "[信息] 恢复Odoo核心文件..."
    cp $BACKUP_ROOT/source/*.py "$ODOO_DIR/" 2>/dev/null || true
    cp $BACKUP_ROOT/source/odoo-bin "$ODOO_DIR/" 2>/dev/null || true
else
    echo "[信息] 未找到源码文件，将从GitHub下载Odoo $ODOO_VERSION..."
    cd /tmp
    wget "https://github.com/odoo/odoo/archive/refs/tags/$ODOO_VERSION.zip" -O odoo_src.zip
    unzip -q odoo_src.zip
    cp -r "odoo-$ODOO_VERSION/"* "$ODOO_DIR/"
    rm -rf odoo_src.zip "odoo-$ODOO_VERSION"
fi

# 10. 恢复自定义模块
echo "[阶段9] 恢复自定义模块..."
CUSTOM_DIR="$ODOO_DIR/custom_addons"
mkdir -p "$CUSTOM_DIR"
for custom in "$BACKUP_ROOT/source"/custom_*; do
    if [ -d "$custom" ]; then
        cp -r "$custom" "$CUSTOM_DIR/"
        echo "  恢复模块: $(basename "$custom")"
    fi
done

# 11. 创建Python虚拟环境
echo "[阶段10] 创建Python虚拟环境..."
VENV_PATH="$ODOO_DIR/venv"
"python$PYTHON_VERSION" -m venv "$VENV_PATH"
source "$VENV_PATH/bin/activate"

# 12. 安装Python依赖
echo "[阶段11] 安装Python依赖..."
pip install --upgrade pip setuptools wheel

# 安装Odoo核心依赖（根据版本）
echo "[信息] 安装Odoo $ODOO_VERSION 依赖..."
if [[ "$ODOO_VERSION" == 17.* ]]; then
    pip install odoo==$ODOO_VERSION
elif [[ "$ODOO_VERSION" == 18.* ]]; then
    pip install odoo==$ODOO_VERSION
else
    echo "[警告] 未知Odoo版本，尝试安装通用依赖"
    pip install \
        psycopg2-binary \
        Babel \
        Pillow \
        lxml \
        reportlab \
        python-dateutil \
        polib \
        passlib \
        beautifulsoup4 \
        pypdf2 \
        phonenumbers \
        pyopenssl \
        pyserial \
        jinja2 \
        docutils \
        gevent
fi

# 从依赖报告安装额外包
if [ -f "$BACKUP_ROOT/dependencies/requirements_analysis.txt" ]; then
    echo "[信息] 安装额外依赖..."
    # 安装常见的业务依赖
    for dep in pandas numpy openpyxl xlrd xlwt; do
        if grep -iq "$dep" "$BACKUP_ROOT/dependencies/requirements_analysis.txt"; then
            pip install "$dep"
        fi
    done
fi
deactivate

# 13. 恢复数据库
echo "[阶段12] 恢复数据库..."
sudo systemctl start postgresql
sudo systemctl enable postgresql

# 创建数据库用户
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$USER'" | grep -q 1; then
    sudo -u postgres createuser --superuser "$USER" || true
fi

# 恢复数据库
DB_NAME="odoo_restored_$(date +%Y%m%d)"
if [ -f "$BACKUP_ROOT/database/dump.sql" ]; then
    echo "[信息] 恢复数据库: $DB_NAME"
    sudo -u postgres createdb "$DB_NAME" 2>/dev/null || true
    sudo -u postgres psql "$DB_NAME" < "$BACKUP_ROOT/database/dump.sql" && \
        echo "[成功] 数据库恢复完成" || \
        echo "[警告] 数据库恢复可能存在错误"
else
    echo "[错误] 未找到数据库转储文件"
    exit 1
fi

# 14. 恢复文件存储
FILESTORE_DIR="/var/lib/odoo/filestore"
sudo mkdir -p "$FILESTORE_DIR"
sudo chown -R $USER:$USER "$FILESTORE_DIR"
if [ -d "$BACKUP_ROOT/filestore" ] && [ -n "$(ls -A $BACKUP_ROOT/filestore/ 2>/dev/null)" ]; then
    cp -r "$BACKUP_ROOT/filestore" "$FILESTORE_DIR/$DB_NAME" 2>/dev/null || true
    echo "[信息] 文件存储恢复完成"
fi

# 15. 创建配置文件
echo "[阶段13] 创建Odoo配置文件..."
ODOO_CONF="/etc/odoo/odoo.conf"
sudo mkdir -p /etc/odoo

# 获取原HTTP端口
HTTP_PORT="8069"
if [ -f "$BACKUP_ROOT/metadata/system_info.txt" ]; then
    PORT_LINE=$(grep "原HTTP端口" "$BACKUP_ROOT/metadata/system_info.txt" | head -1)
    if [[ $PORT_LINE =~ :\ ([0-9]+) ]]; then
        HTTP_PORT="${BASH_REMATCH[1]}"
    fi
fi

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

# 16. 创建系统服务
echo "[阶段14] 创建系统服务..."
sudo bash -c "cat > /etc/systemd/system/odoo.service" << EOF
[Unit]
Description=Odoo Open Source ERP and CRM (Version $ODOO_VERSION)
After=postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$ODOO_DIR
Environment="PATH=$VENV_PATH/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PYTHONPATH=$ODOO_DIR"
ExecStart=$VENV_PATH/bin/python3 $ODOO_DIR/odoo-bin --config=$ODOO_CONF
Restart=always
RestartSec=5s
KillMode=mixed
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

# 17. 启动服务
echo "[阶段15] 启动Odoo $ODOO_VERSION 服务..."
sudo systemctl daemon-reload
sudo systemctl enable odoo
sudo systemctl start odoo

# 18. 验证
echo "[阶段16] 验证安装..."
sleep 10
if systemctl is-active --quiet odoo; then
    echo "========================================"
    echo "✅ Odoo $ODOO_VERSION 源码恢复成功！"
    echo "========================================"
    echo "部署详情:"
    echo "  Odoo版本:     $ODOO_VERSION"
    echo "  Python版本:   $PYTHON_VERSION"
    echo "  虚拟环境:     $VENV_PATH"
    echo "  源码目录:     $ODOO_DIR"
    echo "  数据库:       $DB_NAME"
    echo "  HTTP端口:     $HTTP_PORT"
    echo ""
    echo "访问地址: http://$(curl -s ifconfig.me):$HTTP_PORT"
    echo "服务状态: sudo systemctl status odoo"
    echo ""
    echo "接下来:"
    echo "1. 访问上述地址登录（默认密码: admin）"
    echo "2. 运行 ./configure_nginx.sh 配置域名访问"
    echo "========================================"
    
    # 记录恢复信息
    echo "$ODOO_VERSION" > "$SCRIPT_DIR/RESTORED_VERSION.txt"
    echo "$HTTP_PORT" > "$SCRIPT_DIR/ODOO_PORT.txt"
else
    echo "[错误] 服务启动失败，查看日志: sudo journalctl -u odoo --no-pager -l"
    exit 1
fi

# 清理
rm -rf "$RESTORE_DIR"