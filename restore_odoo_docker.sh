#!/bin/bash
# ====================================================
# restore_odoo_docker.sh - Docker Compose恢复脚本
# 特性：所有数据集中管理，版本严格匹配，端口统一8069
# 目录结构: /opt/odoo_docker/{data,config,addons,backups}
# ====================================================

set -e
echo "========================================"
echo "    Odoo Docker Compose 恢复"
echo "========================================"

# 1. 定位备份文件
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
BACKUP_FILE=$(ls -1t odoo_backup_*.zip 2>/dev/null | head -1)
if [ -z "$BACKUP_FILE" ]; then
    echo "[错误] 当前目录未找到备份文件"
    exit 1
fi
echo "[信息] 找到备份文件: $BACKUP_FILE"

# 2. 读取版本信息
echo "[阶段1] 读取版本信息..."
RESTORE_DIR="/tmp/odoo_docker_restore_$(date +%s)"
mkdir -p "$RESTORE_DIR"
unzip -q "$BACKUP_FILE" -d "$RESTORE_DIR"
BACKUP_ROOT=$(find "$RESTORE_DIR" -type d -name "odoo_backup_*" | head -1)

if [ -f "$BACKUP_ROOT/metadata/versions.txt" ]; then
    ODOO_VERSION=$(grep "ODOO_VERSION:" "$BACKUP_ROOT/metadata/versions.txt" | cut -d' ' -f2)
    if [ "$ODOO_VERSION" = "未知" ]; then
        read -p "备份中未记录Odoo版本，请输入版本号 (如 17.0): " ODOO_VERSION
    fi
else
    read -p "请输入Odoo版本号 (如 17.0): " ODOO_VERSION
fi

# 验证版本格式
if [[ ! "$ODOO_VERSION" =~ ^[0-9]+\.0$ ]]; then
    echo "[错误] 版本格式错误，应为 '17.0' 或 '18.0' 格式"
    exit 1
fi

# 3. 安装Docker和Docker Compose
echo "[阶段2] 安装Docker环境..."
if ! command -v docker &> /dev/null; then
    echo "[信息] 安装Docker..."
    sudo apt-get update
    sudo apt-get install -y docker.io docker-compose
    sudo systemctl start docker
    sudo systemctl enable docker
    sudo usermod -aG docker $USER
    echo "[注意] 需要重新登录或执行: newgrp docker"
fi

# 4. 创建统一数据目录
echo "[阶段3] 创建统一数据目录..."
ODOO_DOCKER_DIR="/opt/odoo_docker"
sudo mkdir -p "$ODOO_DOCKER_DIR"/{postgres_data,odoo_data,addons,backups,config}
sudo chown -R $USER:$USER "$ODOO_DOCKER_DIR"
sudo chmod -R 755 "$ODOO_DOCKER_DIR"

echo "[信息] 数据目录结构:"
echo "  $ODOO_DOCKER_DIR/"
echo "  ├── postgres_data/    # PostgreSQL数据库数据"
echo "  ├── odoo_data/        # Odoo文件存储"
echo "  ├── addons/           # 自定义模块"
echo "  ├── backups/          # 备份文件"
echo "  └── config/           # 配置文件"

# 5. 恢复自定义模块
echo "[阶段4] 恢复自定义模块..."
if [ -d "$BACKUP_ROOT/source" ]; then
    for custom in "$BACKUP_ROOT/source"/custom_*; do
        if [ -d "$custom" ]; then
            cp -r "$custom" "$ODOO_DOCKER_DIR/addons/"
            echo "  恢复模块: $(basename "$custom")"
        fi
    done
fi

# 6. 恢复文件存储
echo "[阶段5] 恢复文件存储..."
if [ -d "$BACKUP_ROOT/filestore" ] && [ -n "$(ls -A $BACKUP_ROOT/filestore/ 2>/dev/null)" ]; then
    cp -r "$BACKUP_ROOT/filestore" "$ODOO_DOCKER_DIR/odoo_data/filestore" 2>/dev/null || true
fi

# 7. 复制备份文件到备份目录
cp "$BACKUP_FILE" "$ODOO_DOCKER_DIR/backups/"

# 8. 创建Docker Compose配置文件
echo "[阶段6] 创建Docker Compose配置..."
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
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U odoo"]
      interval: 10s
      timeout: 5s
      retries: 5

  odoo:
    image: odoo:$ODOO_VERSION
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "8069:8069"  # 固定端口映射，便于Nginx配置
    environment:
      HOST: postgres
      USER: odoo
      PASSWORD: odoo
    volumes:
      - ./odoo_data:/var/lib/odoo
      - ./addons:/mnt/extra-addons
    restart: unless-stopped
    command: >
      --dev xml
      --proxy-mode
      --db-filter=^%d\$

volumes:
  postgres_data:
  odoo_data:
EOF

# 9. 创建数据库恢复脚本
echo "[阶段7] 创建数据库恢复工具..."
cat > "$ODOO_DOCKER_DIR/restore_database.sh" << 'EOF'
#!/bin/bash
# 数据库恢复工具
set -e

echo "=== Odoo 数据库恢复工具 ==="
echo "请确保Docker Compose服务正在运行..."
echo ""

# 获取容器ID
POSTGRES_CONTAINER=$(docker-compose ps -q postgres)
if [ -z "$POSTGRES_CONTAINER" ]; then
    echo "[错误] PostgreSQL容器未运行"
    exit 1
fi

# 查找最新的备份文件
BACKUP_FILE=$(ls -1t backups/odoo_backup_*.zip | head -1)
if [ -z "$BACKUP_FILE" ]; then
    echo "[错误] 未找到备份文件"
    exit 1
fi

echo "找到备份文件: $(basename "$BACKUP_FILE")"

# 解压备份文件
TEMP_DIR="/tmp/db_restore_$(date +%s)"
mkdir -p "$TEMP_DIR"
unzip -q "$BACKUP_FILE" -d "$TEMP_DIR"
BACKUP_ROOT=$(find "$TEMP_DIR" -type d -name "odoo_backup_*" | head -1)

if [ ! -f "$BACKUP_ROOT/database/dump.sql" ]; then
    echo "[错误] 备份中未找到数据库文件"
    exit 1
fi

# 创建数据库
DB_NAME="odoo_restored_$(date +%Y%m%d)"
echo "创建数据库: $DB_NAME"
docker exec "$POSTGRES_CONTAINER" bash -c "createdb -U odoo $DB_NAME 2>/dev/null || true"

# 恢复数据库
echo "恢复数据库..."
docker exec -i "$POSTGRES_CONTAINER" psql -U odoo "$DB_NAME" < "$BACKUP_ROOT/database/dump.sql"

# 清理
rm -rf "$TEMP_DIR"

echo ""
echo "✅ 数据库恢复完成！"
echo "数据库名: $DB_NAME"
echo "访问信息:"
echo "  Host: localhost"
echo "  Port: 5432"
echo "  User: odoo"
echo "  Password: odoo"
echo "  Database: $DB_NAME"
EOF

chmod +x "$ODOO_DOCKER_DIR/restore_database.sh"

# 10. 创建管理脚本
echo "[阶段8] 创建管理脚本..."
cat > "$ODOO_DOCKER_DIR/manage.sh" << 'EOF'
#!/bin/bash
# Odoo Docker 管理脚本

case "$1" in
    start)
        echo "启动 Odoo 服务..."
        docker-compose up -d
        ;;
    stop)
        echo "停止 Odoo 服务..."
        docker-compose down
        ;;
    restart)
        echo "重启 Odoo 服务..."
        docker-compose restart
        ;;
    logs)
        docker-compose logs -f odoo
        ;;
    status)
        docker-compose ps
        ;;
    backup)
        echo "备份数据库..."
        DB_NAME=$(docker-compose exec postgres psql -U odoo -t -c "SELECT datname FROM pg_database WHERE datname LIKE 'odoo_%'" | head -1 | tr -d '[:space:]')
        if [ -n "$DB_NAME" ]; then
            BACKUP_FILE="backups/backup_$(date +%Y%m%d_%H%M%S).sql"
            docker-compose exec postgres pg_dump -U odoo "$DB_NAME" > "$BACKUP_FILE"
            echo "备份完成: $BACKUP_FILE"
        else
            echo "未找到Odoo数据库"
        fi
        ;;
    restore)
        ./restore_database.sh
        ;;
    *)
        echo "用法: $0 {start|stop|restart|logs|status|backup|restore}"
        exit 1
        ;;
esac
EOF

chmod +x "$ODOO_DOCKER_DIR/manage.sh"

# 11. 启动服务
echo "[阶段9] 启动Docker Compose服务..."
cd "$ODOO_DOCKER_DIR"
docker-compose down 2>/dev/null || true
docker-compose up -d

# 12. 等待服务启动
echo "[阶段10] 等待服务启动..."
sleep 15

# 13. 恢复数据库
echo "[阶段11] 恢复数据库..."
cd "$ODOO_DOCKER_DIR"
if [ -f "$BACKUP_ROOT/database/dump.sql" ]; then
    echo "准备恢复数据库..."
    ./restore_database.sh
else
    echo "[警告] 未找到数据库备份，将创建新数据库"
    echo "请稍后在Odoo界面创建数据库"
fi

# 14. 验证
if curl -s --max-time 5 http://localhost:8069 > /dev/null; then
    echo "========================================"
    echo "✅ Odoo Docker Compose 恢复成功！"
    echo "========================================"
    echo "部署详情:"
    echo "  Odoo版本:     $ODOO_VERSION"
    echo "  数据目录:     $ODOO_DOCKER_DIR"
    echo "  访问地址:     http://$(curl -s ifconfig.me):8069"
    echo ""
    echo "管理命令 (在 $ODOO_DOCKER_DIR 目录):"
    echo "  启动服务:     ./manage.sh start"
    echo "  停止服务:     ./manage.sh stop"
    echo "  查看日志:     ./manage.sh logs"
    echo "  备份数据库:   ./manage.sh backup"
    echo "  恢复数据库:   ./manage.sh restore"
    echo ""
    echo "接下来:"
    echo "1. 访问上述地址创建新数据库或恢复现有数据库"
    echo "2. 运行 ./configure_nginx.sh 配置域名访问"
    echo "========================================"
    
    # 记录部署信息
    echo "DOCKER" > "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt"
    echo "8069" > "$SCRIPT_DIR/ODOO_PORT.txt"
else
    echo "[警告] 服务可能正在启动中，请检查:"
    echo "  cd $ODOO_DOCKER_DIR && docker-compose logs -f odoo"
fi

# 清理
rm -rf "$RESTORE_DIR"