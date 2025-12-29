#!/bin/bash
# ====================================================
# configure_nginx.sh - 智能Nginx配置脚本
# 自动检测Odoo部署方式（源码/Docker）并配置相应端口
# ====================================================

set -e
echo "========================================"
echo "    Odoo Nginx智能反向代理配置"
echo "========================================"

# 1. 检测部署方式
echo "[阶段1] 检测Odoo部署方式..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEPLOYMENT_TYPE=""
ODOO_PORT=""

# 检查是否存在部署类型记录
if [ -f "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt" ]; then
    DEPLOYMENT_TYPE=$(cat "$SCRIPT_DIR/DEPLOYMENT_TYPE.txt")
    echo "[信息] 检测到部署类型记录: $DEPLOYMENT_TYPE"
fi

# 检查端口记录
if [ -f "$SCRIPT_DIR/ODOO_PORT.txt" ]; then
    ODOO_PORT=$(cat "$SCRIPT_DIR/ODOO_PORT.txt")
else
    # 自动检测端口
    if [ "$DEPLOYMENT_TYPE" = "DOCKER" ]; then
        ODOO_PORT="8069"  # Docker Compose固定端口
    else
        # 尝试检测源码部署的端口
        if [ -f "/etc/odoo/odoo.conf" ]; then
            ODOO_PORT=$(grep "^http_port" /etc/odoo/odoo.conf | cut -d'=' -f2 | tr -d ' ' || echo "8069")
        else
            ODOO_PORT="8069"
        fi
    fi
fi

# 验证端口是否在使用中
if ! ss -tln | grep -q ":$ODOO_PORT "; then
    echo "[警告] 端口 $ODOO_PORT 未检测到服务"
    echo "请确保Odoo服务正在运行"
    read -p "是否继续配置? [y/N]: " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

echo "[信息] Odoo服务端口: $ODOO_PORT"

# 2. 获取域名信息
echo "[阶段2] 配置域名..."
read -p "请输入您的域名 (例如: example.com 或 www.example.com): " DOMAIN

# 规范化域名处理
if [[ $DOMAIN == www.* ]]; then
    MAIN_DOMAIN="${DOMAIN#www.}"
    WWW_PRESENT=true
    echo "[信息] 检测到www域名，主域名为: $MAIN_DOMAIN"
else
    MAIN_DOMAIN="$DOMAIN"
    WWW_DOMAIN="www.$DOMAIN"
    WWW_PRESENT=false
    echo "[信息] 主域名为: $MAIN_DOMAIN, 将添加: $WWW_DOMAIN"
fi

# 3. 获取SSL证书
echo "[阶段3] 获取SSL证书..."
if ! command -v certbot &> /dev/null; then
    echo "[信息] 安装Certbot..."
    sudo apt-get update
    sudo apt-get install -y certbot python3-certbot-nginx
fi

# 询问邮箱
read -p "请输入管理员邮箱 (用于SSL证书通知): " ADMIN_EMAIL

echo "[信息] 申请SSL证书..."
CERT_DOMAINS="-d $MAIN_DOMAIN"
if [ "$WWW_PRESENT" = true ]; then
    CERT_DOMAINS="$CERT_DOMAINS -d $DOMAIN"
else
    CERT_DOMAINS="$CERT_DOMAINS -d $WWW_DOMAIN"
fi

# 尝试获取证书
USE_SSL=true
if sudo certbot certonly --nginx --non-interactive --agree-tos \
    -m "$ADMIN_EMAIL" $CERT_DOMAINS 2>/dev/null; then
    echo "[成功] SSL证书获取完成"
else
    echo "[警告] SSL证书获取失败，可能是DNS未解析"
    echo "当前服务器IP: $(curl -s ifconfig.me)"
    read -p "是否继续配置Nginx (无SSL)? [y/N]: " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    USE_SSL=false
fi

# 4. 创建Nginx配置文件
echo "[阶段4] 创建Nginx配置..."
NGINX_CONF="/etc/nginx/sites-available/odoo_$MAIN_DOMAIN"
UPSTREAM_NAME="odoo_backend"

# 确定证书路径
if [ "$USE_SSL" = true ] && [ -d "/etc/letsencrypt/live/$MAIN_DOMAIN" ]; then
    SSL_CERT="/etc/letsencrypt/live/$MAIN_DOMAIN/fullchain.pem"
    SSL_KEY="/etc/letsencrypt/live/$MAIN_DOMAIN/privkey.pem"
else
    USE_SSL=false
fi

# 创建配置文件
sudo bash -c "cat > $NGINX_CONF" << EOF
# Odoo智能反向代理配置
# 生成时间: $(date)
# 部署类型: ${DEPLOYMENT_TYPE:-未知}
# Odoo端口: $ODOO_PORT

upstream $UPSTREAM_NAME {
    server 127.0.0.1:$ODOO_PORT;
    keepalive 64;
}

# 缓存配置
proxy_cache_path /var/cache/nginx/odoo levels=1:2 keys_zone=odoo_cache:10m max_size=1g inactive=60m;
EOF

# HTTP重定向配置
if [ "$USE_SSL" = true ]; then
sudo bash -c "cat >> $NGINX_CONF" << EOF

server {
    listen 80;
    server_name $MAIN_DOMAIN $WWW_DOMAIN;
    return 301 https://\$server_name\$request_uri;
}
EOF
fi

# 主服务器配置
if [ "$USE_SSL" = true ]; then
sudo bash -c "cat >> $NGINX_CONF" << EOF

server {
    listen 443 ssl http2;
    server_name $MAIN_DOMAIN;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
EOF
else
sudo bash -c "cat >> $NGINX_CONF" << EOF

server {
    listen 80;
    server_name $MAIN_DOMAIN;
EOF
fi

# 通用的代理配置
sudo bash -c "cat >> $NGINX_CONF" << EOF

    # 安全头部
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    # Odoo特定配置
    proxy_buffers 16 64k;
    proxy_buffer_size 128k;
    proxy_busy_buffers_size 128k;
    proxy_temp_file_write_size 1024m;
    proxy_connect_timeout 300s;
    proxy_send_timeout 300s;
    proxy_read_timeout 300s;
    proxy_redirect off;

    # 禁止访问隐藏文件
    location ~ /\. {
        deny all;
    }

    # 长期轮询 (如果使用)
    location /longpolling {
        proxy_pass http://$UPSTREAM_NAME;
    }

    # 静态文件缓存 - 显著提升性能
    location ~* /web/(static|image|image_placeholder)/ {
        proxy_pass http://$UPSTREAM_NAME;
        proxy_cache odoo_cache;
        proxy_cache_key \$scheme\$proxy_host\$request_uri;
        proxy_cache_valid 200 60m;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_500 http_502 http_503 http_504;
        proxy_cache_background_update on;
        proxy_cache_lock on;
        expires 365d;
        add_header Cache-Control "public, immutable";
        add_header X-Cache-Status \$upstream_cache_status;
    }

    # WebSocket支持
    location /websocket {
        proxy_pass http://$UPSTREAM_NAME;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # 健康检查端点
    location /web/health {
        proxy_pass http://$UPSTREAM_NAME;
        access_log off;
    }

    # 主应用代理
    location / {
        proxy_pass http://$UPSTREAM_NAME;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        
        # Odoo特定头部
        proxy_set_header Forwarded "\$proxy_add_forwarded;proto=\$scheme";
        
        # 安全增强
        proxy_hide_header X-Powered-By;
        proxy_hide_header Server;
    }

    # 禁止敏感路径访问
    location ~* ^/(web/database|manager|phpmyadmin) {
        deny all;
        return 403;
    }
}
EOF

# WWW重定向配置
if [ "$WWW_PRESENT" = false ] && [ "$USE_SSL" = true ]; then
sudo bash -c "cat >> $NGINX_CONF" << EOF

# www重定向到非www
server {
    listen 443 ssl http2;
    server_name $WWW_DOMAIN;

    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    return 301 https://$MAIN_DOMAIN\$request_uri;
}

server {
    listen 80;
    server_name $WWW_DOMAIN;
    return 301 https://$MAIN_DOMAIN\$request_uri;
}
EOF
fi

# 5. 启用配置
echo "[阶段5] 启用Nginx配置..."
sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# 6. 测试并重启Nginx
echo "[阶段6] 测试Nginx配置..."
if sudo nginx -t; then
    echo "[成功] 配置语法正确"
    sudo systemctl reload nginx || sudo systemctl restart nginx
    echo "[成功] Nginx服务已重启"
else
    echo "[错误] 配置语法错误，请检查"
    exit 1
fi

# 7. 配置证书自动续期
if [ "$USE_SSL" = true ]; then
    echo "[阶段7] 配置SSL证书自动续期..."
    sudo bash -c "cat > /etc/letsencrypt/renewal-hooks/deploy/restart-nginx.sh" << 'RENEW_HOOK'
#!/bin/bash
echo "SSL证书已更新，重启Nginx..." >> /var/log/nginx/cert_renew.log
systemctl reload nginx
RENEW_HOOK
    sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-nginx.sh
    
    # 测试续期
    if sudo certbot renew --dry-run; then
        echo "[成功] 证书自动续期配置完成"
    else
        echo "[警告] 证书续期测试失败，请手动检查"
    fi
fi

# 8. 验证
echo "[阶段8] 验证配置..."
sleep 3
echo "========================================"
echo "✅ Odoo Nginx配置完成！"
echo "========================================"
echo "配置摘要:"
echo "  域名: $MAIN_DOMAIN"
if [ "$WWW_PRESENT" = false ]; then
    echo "  WWW域名: $WWW_DOMAIN (重定向到主域名)"
fi
echo "  部署方式: ${DEPLOYMENT_TYPE:-自动检测}"
echo "  Odoo端口: $ODOO_PORT"
echo "  SSL证书: $([ "$USE_SSL" = true ] && echo "已启用" || echo "未启用")"
echo ""
echo "访问地址:"
if [ "$USE_SSL" = true ]; then
    echo "  https://$MAIN_DOMAIN"
    echo "  (https://$WWW_DOMAIN 将重定向到上述地址)"
else
    echo "  http://$MAIN_DOMAIN"
    echo "  [注意] 未启用HTTPS，建议配置DNS后重新运行此脚本"
fi
echo ""
echo "测试命令:"
echo "  curl -I http://$MAIN_DOMAIN"
echo "  nginx -t"
echo ""
echo "配置文件: $NGINX_CONF"
echo "Nginx状态: sudo systemctl status nginx"
echo "========================================"