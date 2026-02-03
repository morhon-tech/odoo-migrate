# Odoo迁移脚本检查清单

## ✅ 已完成的检查和修复

### 1. 权限管理 ✓
- [x] 脚本要求使用 sudo 运行
- [x] 自动识别真实用户（SUDO_USER）
- [x] 备份文件保存在脚本目录，不保存到 root 目录
- [x] 备份文件所有者自动设置为真实用户
- [x] 所有生成的文件权限正确（DEPLOYMENT_TYPE.txt, RESTORE_REPORT.txt等）
- [x] Python虚拟环境所有者设置为真实用户
- [x] Odoo目录所有者设置为真实用户
- [x] 文件存储目录所有者设置为真实用户

### 2. 环境信息收集 ✓
- [x] 系统信息（Ubuntu版本、内核、CPU、内存、磁盘）
- [x] Odoo信息（版本、路径、配置文件、数据库、端口、用户）
- [x] Python环境（版本、路径、可执行文件、包列表）
- [x] PostgreSQL信息（版本、端口、连接数、共享缓冲区、数据目录）
- [x] Redis信息（版本、端口、最大内存、配置文件）
- [x] 其他依赖（wkhtmltopdf、Node.js、npm、less）
- [x] 系统服务状态（Odoo、PostgreSQL、Redis、Nginx）
- [x] 系统包列表（包含wkhtmltopdf）
- [x] PostgreSQL配置文件（postgresql.conf、pg_hba.conf）
- [x] Redis配置文件
- [x] Nginx配置文件
- [x] Odoo服务配置文件
- [x] Git信息（如果存在）

### 3. 备份功能 ✓
- [x] 完整源码备份（包含所有修改）
- [x] 数据库备份带元数据
- [x] 文件存储备份带统计信息
- [x] 配置文件完整备份
- [x] 生成SHA256校验和
- [x] 备份完整性验证
- [x] 详细的恢复说明文档
- [x] 备份文件权限正确设置
- [x] Python包列表处理（即使不存在也有说明）

### 4. Ubuntu 20.04+ 兼容性 ✓
- [x] 检测Ubuntu版本（20.04/22.04/24.04）
- [x] Ubuntu 20.04特殊处理Node.js安装（使用NodeSource）
- [x] Ubuntu 20.04使用npm全局安装less
- [x] Ubuntu 22.04/24.04直接使用apt安装node-less
- [x] wkhtmltopdf根据版本选择合适的包
- [x] 系统包安装使用DEBIAN_FRONTEND=noninteractive避免交互

### 5. 恢复功能 ✓
- [x] 备份文件完整性验证（SHA256）
- [x] 系统兼容性检查
- [x] 自动安装所有系统依赖
- [x] 恢复PostgreSQL配置（合并而非覆盖）
- [x] 恢复Redis配置
- [x] 恢复完整Odoo源码
- [x] 创建Python虚拟环境（使用真实用户）
- [x] 安装Python依赖（优先使用备份的包列表）
- [x] 验证关键Python包
- [x] 恢复数据库（带超时和错误处理）
- [x] 恢复文件存储
- [x] 配置systemd服务（使用真实用户）
- [x] 服务启动验证（60秒超时）

### 6. 恢复后验证 ✓
- [x] 服务状态检查
- [x] 端口监听检查
- [x] 数据库连接检查
- [x] 文件存储检查
- [x] Python环境检查
- [x] 关键包验证
- [x] 生成恢复报告

### 7. 错误处理 ✓
- [x] 详细的错误提示
- [x] 故障排查建议
- [x] PostgreSQL启动超时处理
- [x] 服务启动超时处理（60秒）
- [x] 备份文件验证
- [x] 兼容性警告
- [x] Python包安装失败处理
- [x] 数据库恢复失败处理

### 8. Odoo环境检测改进 ✓
- [x] 更详细的错误提示
- [x] 配置文件查找（多个常见位置）
- [x] ODOO_DIR计算修正（处理标准目录结构）
- [x] 显示更多调试信息

## 🔍 关键检查点

### 备份时必须收集的信息
1. ✅ Odoo源码完整目录
2. ✅ Python虚拟环境包列表
3. ✅ PostgreSQL配置和版本
4. ✅ Redis配置和版本
5. ✅ 系统服务配置
6. ✅ 数据库和文件存储
7. ✅ Odoo配置文件
8. ✅ 运行用户信息

### 恢复时必须执行的步骤
1. ✅ 验证备份文件完整性
2. ✅ 检查系统兼容性
3. ✅ 安装系统依赖（根据Ubuntu版本）
4. ✅ 恢复配置文件
5. ✅ 恢复源码
6. ✅ 创建Python环境（使用真实用户）
7. ✅ 恢复数据库
8. ✅ 恢复文件存储
9. ✅ 配置服务（使用真实用户）
10. ✅ 验证恢复结果

### 权限相关检查
1. ✅ 脚本必须用sudo运行
2. ✅ 备份文件所有者是真实用户
3. ✅ Odoo目录所有者是真实用户
4. ✅ Python虚拟环境所有者是真实用户
5. ✅ 文件存储目录所有者是真实用户
6. ✅ 日志目录所有者是真实用户
7. ✅ systemd服务使用真实用户运行

## 📝 测试建议

### 备份测试
```bash
# 1. 在运行的Odoo服务器上测试备份
sudo ./odoo-migrate.sh backup

# 2. 验证备份文件
ls -lh odoo_backup_*.zip
unzip -t odoo_backup_*.zip

# 3. 检查备份内容
unzip -l odoo_backup_*.zip | grep -E "(environment.txt|python_packages.txt|dump.sql)"

# 4. 验证文件所有者
ls -l odoo_backup_*.zip  # 应该是真实用户，不是root
```

### 恢复测试
```bash
# 1. 在新服务器上测试恢复
sudo ./odoo-migrate.sh restore

# 2. 检查服务状态
sudo systemctl status odoo
sudo systemctl status postgresql
sudo systemctl status redis-server

# 3. 验证端口监听
ss -tln | grep 8069

# 4. 测试访问
curl http://localhost:8069

# 5. 检查文件权限
ls -la /opt/odoo
ls -la /var/lib/odoo
ls -la /var/log/odoo
```

### Ubuntu版本测试
```bash
# 在不同Ubuntu版本上测试
# - Ubuntu 20.04 LTS
# - Ubuntu 22.04 LTS
# - Ubuntu 24.04 LTS

# 检查Node.js和less安装
node --version
npm --version
lessc --version
```

## ⚠️ 已知限制

1. 脚本仅支持Ubuntu系统（20.04/22.04/24.04）
2. 必须使用sudo运行
3. 需要运行中的Odoo实例才能备份
4. PostgreSQL必须使用postgres用户访问
5. 跨大版本恢复可能需要手动调整

## 🎯 质量保证

- ✅ 语法检查通过（bash -n）
- ✅ 所有函数都有错误处理
- ✅ 所有关键操作都有日志输出
- ✅ 所有文件操作都检查权限
- ✅ 所有服务操作都有超时处理
- ✅ 所有路径都使用变量，避免硬编码
- ✅ 所有用户相关操作都使用REAL_USER

## 📊 代码统计

- 总行数: ~2450行
- 函数数量: 18个
- 支持的命令: 5个（backup, restore, nginx, status, help）
- 支持的Ubuntu版本: 3个（20.04, 22.04, 24.04）
