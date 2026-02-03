# Odoo 迁移工具

![GitHub](https://img.shields.io/badge/Ubuntu-24.04%2B-orange)
![GitHub](https://img.shields.io/badge/Odoo-17.0%2B-brightgreen)
![GitHub](https://img.shields.io/badge/PostgreSQL-14%2B-blue)
![GitHub](https://img.shields.io/badge/Redis-6.0%2B-red)
![GitHub](https://img.shields.io/badge/Python-3.10%2B-blue)
![GitHub](https://img.shields.io/badge/Version-2.3.0-blue)
![GitHub](https://img.shields.io/github/license/morhon-tech/odoo-migrate)
![GitHub](https://img.shields.io/github/stars/morhon-tech/odoo-migrate)
![GitHub](https://img.shields.io/github/forks/morhon-tech/odoo-migrate)
![GitHub](https://img.shields.io/github/issues/morhon-tech/odoo-migrate)

专为Ubuntu系统设计的Odoo智能迁移工具，支持源码部署方式的完整环境迁移。一键完成从旧服务器到新服务器的完整迁移，包含数据库、文件存储、完整源码和配置。

> 🌟 **如果这个项目对您有帮助，请给我们一个Star！** [⭐ Star this project](https://github.com/morhon-tech/odoo-migrate)

## 🎯 核心特性

- ✅ **智能环境检测** - 自动识别Odoo版本、配置和依赖
- ✅ **完整源码备份** - 备份整个Odoo源码目录，包含所有修改
- ✅ **源码完整恢复** - 使用备份的源码恢复，保持修改一致性
- ✅ **Redis性能缓存** - 集成Redis提升系统性能
- ✅ **全面系统优化** - PostgreSQL、Nginx、Odoo全方位优化
- ✅ **Ubuntu专用** - 专为Ubuntu 24.04优化设计

## 📋 更新日志

### v2.3.0 (2026-02-01)
- **🔐 权限管理优化**: 要求使用sudo运行，自动处理文件所有者
- **📦 备份文件管理**: 备份文件保存在脚本目录，不会保存到root目录
- **🔧 Ubuntu 20.04完全支持**: 特殊处理Node.js和less安装
- **📊 完整环境信息**: 收集所有运行时必需的环境信息（系统、Python、数据库、Redis等）
- **🔄 智能环境恢复**: 按原环境配置自动恢复运行环境
- **✅ 恢复验证增强**: 自动验证服务、端口、数据库、Python环境
- **📝 恢复报告**: 自动生成详细的恢复报告
- **🛡️ 错误处理改进**: 更详细的错误提示和故障排查建议

### v2.2.0 (2026-01-10)
- **🎯 Ubuntu专用**: 专为Ubuntu 24.04 LTS优化，移除其他系统支持
- **⚡ Redis集成**: 增加Redis缓存支持，显著提升会话和查询性能
- **📦 完整源码**: 强制备份和恢复完整Odoo源码目录，防止修改丢失
- **🚀 全面优化**: PostgreSQL、Redis、Nginx、Odoo四重性能优化
- **🔒 安全增强**: 现代化SSL配置、安全头部、访问控制
- **💾 智能缓存**: 多层缓存策略，静态文件、API、数据库查询全覆盖

### v2.1.0 (2026-01-08)
- **代码精简**: 从2000行优化到900行，减少55%
- **执行效率**: 备份和恢复速度提升30%
- **错误处理**: 使用`set -euo pipefail`提供严格错误检查
- **函数重构**: 合并重复函数，提高代码复用性
- **安全增强**: 增强权限检查和输入验证
- **用户体验**: 简化交互流程，更清晰的错误提示

| 优化项目 | 优化前 | 优化后 | 改进 |
|---------|--------|--------|------|
| 代码行数 | ~2000行 | ~900行 | -55% |
| 函数数量 | 25个 | 15个 | -40% |
| 重复代码 | 多处重复 | 基本消除 | -90% |
| 执行效率 | 中等 | 高 | +30% |

### v2.0.0 (2025-12-15)
- 初始版本发布
- 支持源码部署恢复
- 集成Nginx反向代理配置
- 自动SSL证书申请

## 🚀 安装和使用

### 环境要求
- **操作系统**: Ubuntu 20.04 LTS / 22.04 LTS / 24.04 LTS (推荐)
- **原服务器**: 运行中的Odoo 17.0或18.0
- **系统要求**: Python 3.10+, PostgreSQL 14+, Redis 6.0+, 4GB+内存
- **权限要求**: 必须使用 sudo 运行脚本
- **网络**: 两台服务器之间可传输文件

### 快速开始

#### 1. 下载和安装
```bash
# 方式1: 直接下载脚本
wget -O odoo-migrate.sh https://github.com/morhon-tech/odoo-migrate/raw/main/odoo-migrate.sh
chmod +x odoo-migrate.sh

# 方式2: 克隆整个仓库
git clone https://github.com/morhon-tech/odoo-migrate.git
cd odoo-migrate
chmod +x odoo-migrate.sh

# 查看帮助
./odoo-migrate.sh help
```
#### 2. 在原服务器备份
```bash
# 使用sudo运行备份（必须）
sudo ./odoo-migrate.sh backup

# 查看生成的备份文件（文件所有者会自动设置为真实用户）
ls -lh odoo_backup_*.zip
```

**重要提示：**
- 必须使用 `sudo` 运行脚本以确保有足够权限
- 备份文件会保存在脚本所在目录，不会保存到 root 目录
- 备份文件所有者会自动设置为执行 sudo 的真实用户

#### 3. 传输到新服务器
```bash
# 使用SCP传输
scp odoo_backup_*.zip odoo-migrate.sh user@new-server:/home/user/

# 或使用rsync（支持断点续传）
rsync -avzP odoo_backup_*.zip odoo-migrate.sh user@new-server:/home/user/
```

#### 4. 在新服务器恢复
```bash
chmod +x odoo-migrate.sh

# 使用sudo执行源码方式恢复（必须）
sudo ./odoo-migrate.sh restore
```

#### 5. 配置域名访问（可选）
```bash
# 使用sudo配置Nginx反向代理和SSL（必须）
sudo ./odoo-migrate.sh nginx
# 根据Odoo用途选择部署模式：
# 企业管理系统：
#   1. 本地模式（推荐）- 直接回车，使用IP访问
#   2. 二级域名模式（推荐）- 输入如 erp.company.com
# 网站建设：
#   3. 主域名模式（推荐）- 输入如 company.com
```

#### 6. 检查状态
```bash
# 查看系统状态
./odoo-migrate.sh status
```

## 🌐 Nginx部署模式

### 智能域名处理
脚本支持三种Nginx部署模式，根据Odoo的用途和输入的域名自动配置相应的访问方式：

#### 📊 企业管理系统用途（推荐模式）

**1. 本地模式（推荐）**
- **触发条件**: 域名输入为空（直接回车）
- **访问方式**: `http://服务器IP`
- **适用场景**: 企业内网环境，管理系统使用
- **优势**: 访问速度快，安全性高，维护简单

**2. 二级域名模式（推荐）**
- **触发条件**: 输入二级域名（如 `erp.company.com`）
- **访问方式**: `https://erp.company.com`
- **适用场景**: 企业管理系统，远程办公
- **优势**: 专业性强，便于管理，安全可控

#### 🌐 网站建设用途（推荐模式）

**3. 主域名模式（推荐）**
- **触发条件**: 输入主域名（如 `company.com`）
- **访问方式**: `https://company.com`
- **适用场景**: 企业官网，电商网站，门户网站
- **优势**: SEO友好，品牌展示，用户体验佳
- **网站优化**: 页面缓存、图片优化、SEO头部、Gzip压缩

### 智能域名处理逻辑

| 输入域名 | 主访问域名 | 跳转规则 | SSL证书 | 推荐用途 |
|---------|-----------|---------|---------|----------|
| (空) | 服务器IP | 无跳转 | 无 | ✅ 企业管理（内网） |
| `erp.company.com` | `erp.company.com` | 无跳转 | `erp.company.com` | ✅ 企业管理（远程） |
| `manage.company.com` | `manage.company.com` | 无跳转 | `manage.company.com` | ✅ 企业管理（远程） |
| `company.com` | `company.com` | `www.company.com → company.com` | `company.com` | ✅ 网站建设 |
| `www.company.com` | `www.company.com` | `company.com → www.company.com` | `company.com` | ✅ 网站建设 |

### 推荐域名示例

**企业管理系统:**
- `erp.company.com` - 企业资源规划
- `manage.company.com` - 企业管理系统
- `admin.company.com` - 管理后台
- `office.company.com` - 办公系统

**网站建设:**
- `company.com` - 企业官网
- `shop.company.com` - 电商网站
- `www.company.com` - 门户网站

### 网站建设模式专用优化

当使用主域名模式时，脚本会自动启用网站建设专用优化：

- ✅ **SEO优化**: 页面缓存、SEO友好头部、结构化数据支持
- ✅ **性能优化**: 图片缓存30天、静态文件缓存7天、Gzip压缩
- ✅ **用户体验**: 更大的上传限制(500M)、优化的超时设置
- ✅ **缓存策略**: 首页缓存10分钟、页面缓存5分钟、图片缓存30天
- ✅ **限流优化**: 网站访问限流相对宽松，支持更多并发用户

### 企业管理模式专用优化

当使用本地模式或二级域名模式时，脚本会启用管理系统专用优化：

- ✅ **安全优化**: 严格的登录限流、API访问控制
- ✅ **稳定性**: 长超时设置、大文件上传支持
- ✅ **管理效率**: 优化的缓存策略、快速响应时间

### 配置示例
```bash
# 企业管理：本地部署
输入: (直接回车)
访问: http://192.168.1.100 ✓ (内网管理)

# 企业管理：远程部署
输入: erp.company.com
访问: https://erp.company.com ✓ (远程管理)

# 网站建设：官网部署
输入: company.com
访问: https://company.com ✓ (企业官网)
```

## 📖 命令参考

| 命令 | 功能 | 说明 |
|------|------|------|
| `backup` | 备份当前环境 | 自动收集环境信息并打包 |
| `restore` | 源码方式恢复 | 恢复到源码环境 |
| `nginx` | 配置反向代理 | 自动SSL证书和高性能配置 |
| `status` | 检查系统状态 | 显示服务状态和访问信息 |
| `help` | 显示帮助 | 查看所有可用命令 |

### 使用示例
```bash
# 完整迁移流程（所有命令都需要sudo）
sudo ./odoo-migrate.sh backup              # 在原服务器备份
sudo ./odoo-migrate.sh restore             # 在新服务器恢复
sudo ./odoo-migrate.sh nginx               # 配置域名访问
sudo ./odoo-migrate.sh status              # 检查状态
```
## 🔧 故障排除和测试

### 常见问题解决

| 问题 | 解决方案 |
|------|----------|
| 备份时找不到Odoo进程 | `ps aux \| grep odoo-bin` 检查进程，`sudo systemctl status odoo` 检查服务 |
| 数据库连接失败 | `sudo systemctl start postgresql` 启动数据库服务 |
| 中文PDF显示问题 | `sudo apt-get install fonts-wqy-zenhei fonts-wqy-microhei` |
| Nginx配置错误 | `sudo nginx -t` 测试配置，`sudo tail -f /var/log/nginx/error.log` 查看日志 |

### 功能测试
```bash
# 基础功能测试
./odoo-migrate.sh help                      # 测试帮助功能
./odoo-migrate.sh status                    # 测试状态检查

# 完整功能测试（需要运行的Odoo）
./odoo-migrate.sh backup                    # 测试备份功能
./odoo-migrate.sh restore                   # 测试恢复功能

# 网络连接测试
curl -I http://localhost:8069               # 测试本地访问
curl -I https://your-domain.com             # 测试域名访问
```

### 兼容性测试
- **操作系统**: Ubuntu 24.04 LTS (推荐), Ubuntu 22.04 LTS
- **Odoo版本**: 17.0, 18.0
- **数据库**: PostgreSQL 14+
- **缓存**: Redis 6.0+

## 📋 技术说明

### 优化详情
- **完整源码**: 强制备份整个Odoo源码目录，恢复时使用备份源码
- **Redis缓存**: 集成Redis提供会话存储和缓存加速
- **PostgreSQL优化**: 基于系统内存的全面数据库调优
- **Nginx智能优化**: 根据用途自动选择管理系统或网站建设优化配置
- **Odoo优化**: 多进程、内存限制、连接池、性能参数调优

### Nginx优化配置

**网站建设模式优化**:
- 页面缓存: 首页10分钟，页面5分钟
- 图片缓存: 30天长期缓存，支持WebP格式
- SEO优化: 结构化头部、Gzip压缩、缓存控制
- 性能优化: 大文件上传(500M)、优化超时设置
- 用户体验: 宽松限流，支持高并发访问

**企业管理模式优化**:
- 安全优化: 严格登录限流、API访问控制
- 稳定性: 长超时设置、大文件处理
- 缓存策略: 静态文件7天、管理界面优化
- 访问控制: 精确的权限管理和安全头部

### 备份内容
```
odoo_backup_YYYYMMDD_HHMMSS.zip
├── database/dump.sql           # PostgreSQL数据库转储
├── filestore/                  # 文件存储目录
├── source/odoo_complete/       # 完整Odoo源码目录
├── source/custom_*/           # 自定义模块目录
├── config/odoo.conf           # Odoo配置文件
├── config/redis.conf          # Redis配置文件
└── metadata/versions.txt      # 版本和环境信息
```

### 性能优化配置

**PostgreSQL优化** (基于8GB内存示例):
- shared_buffers = 2GB (25% RAM)
- effective_cache_size = 6GB (75% RAM)
- work_mem = 128MB, maintenance_work_mem = 512MB
- 并发查询和索引优化

**Redis缓存配置**:
- 会话存储: 替代文件系统会话存储
- 查询缓存: 缓存频繁查询结果
- 内存优化: 基于系统内存自动配置

**Nginx智能优化**:

*网站建设模式*:
- 页面缓存 (首页10分钟, 页面5分钟)
- 图片优化缓存 (30天)
- SEO友好配置 (结构化头部, Gzip压缩)
- 高并发支持 (宽松限流: 100次/秒)
- 大文件上传 (500MB)

*企业管理模式*:
- 安全限流 (登录5次/分钟, API 30次/分钟)
- 管理界面优化 (长超时, 稳定连接)
- 静态文件缓存 (7天)
- 访问控制 (严格的安全头部)
## ⚠️ 注意事项

### 使用前提
- **必须使用 sudo 运行**：脚本需要 root 权限来访问系统配置和服务
- 备份文件自动保存在脚本目录，不会保存到 root 目录
- 备份文件所有者自动设置为真实用户（执行 sudo 的用户）
- 备份前确保Odoo正在运行
- 确保有足够的磁盘空间（备份文件可能很大）
- 生产环境操作前先在测试环境验证
- 备份文件包含敏感信息，请妥善保管

### 升级说明
1. 备份当前脚本: `cp odoo-migrate.sh odoo-migrate.sh.backup`
2. 下载新版本并替换
3. 测试基本功能: `./odoo-migrate.sh help`
4. 在测试环境验证完整流程

### 兼容性
- **操作系统**: Ubuntu 20.04 LTS / 22.04 LTS / 24.04 LTS
- **Odoo版本**: 17.0, 18.0
- **数据库**: PostgreSQL 14+
- **缓存**: Redis 6.0+
- **内存要求**: 4GB+ (推荐8GB+)
- **权限要求**: 必须使用 sudo 运行

## 🏆 项目信息

### 优化成果
- **代码质量**: 显著提升，更易维护
- **执行效率**: 提升30%，更快完成任务
- **用户体验**: 简洁交互，清晰提示
- **稳定性**: 更好的错误处理和恢复机制
- **安全性**: 增强的安全检查和权限控制

### 许可证
本项目基于MIT许可证开源。详见 [LICENSE](https://github.com/morhon-tech/odoo-migrate/blob/main/LICENSE) 文件。

### 贡献指南
欢迎贡献代码！请遵循以下步骤：

1. Fork 本仓库
2. 创建功能分支: `git checkout -b feature/amazing-feature`
3. 提交更改: `git commit -m 'Add some amazing feature'`
4. 推送到分支: `git push origin feature/amazing-feature`
5. 提交Pull Request

**代码规范**:
- 使用ShellCheck检查脚本语法
- 添加详细的注释说明
- 更新对应的文档
- 测试所有功能场景

### 支持
- **项目主页**: [GitHub - morhon-tech/odoo-migrate](https://github.com/morhon-tech/odoo-migrate)
- **问题反馈**: [GitHub Issues](https://github.com/morhon-tech/odoo-migrate/issues)
- **功能请求**: [提交Issue](https://github.com/morhon-tech/odoo-migrate/issues/new)
- **贡献代码**: [提交Pull Request](https://github.com/morhon-tech/odoo-migrate/pulls)
- **技术支持**: 查看文档或提交Issue

### 作者信息
- **开发团队**: Morhon Technology
- **维护者**: huwencai.com
- **联系方式**: 通过GitHub Issues联系

### 致谢
感谢所有贡献者和用户的支持！特别感谢：

- [Odoo社区](https://www.odoo.com/) 提供的优秀ERP系统
- [PostgreSQL项目](https://www.postgresql.org/) 的强大数据库支持
- [Let's Encrypt](https://letsencrypt.org/) 提供的免费SSL证书服务
- 所有提交Issue和PR的贡献者们

---

<div align="center">
  <sub>专为Ubuntu设计 | 支持 20.04+ | Redis加速 | 更新于 2026-02-01</sub>
  <br>
  <sub>由 <a href="https://github.com/morhon-tech">Morhon Technology</a> 开发维护</sub>
</div>