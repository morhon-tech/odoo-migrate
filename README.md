# Odoo 迁移工具

![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%2B-orange)
![Odoo](https://img.shields.io/badge/Odoo-17.0%2B-brightgreen)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-14%2B-blue)
![Python](https://img.shields.io/badge/Python-3.10%2B-blue)
![Version](https://img.shields.io/badge/Version-2.3.0-blue)
![License](https://img.shields.io/github/license/morhon-tech/odoo-migrate)

专为 Ubuntu 系统设计的 Odoo 源码部署迁移工具。一键完成从旧服务器到新服务器的完整迁移，包含数据库、文件存储、完整源码、pip 依赖和配置。

> 🌟 **如果这个项目对您有帮助，请给我们一个 Star！** [⭐ Star this project](https://github.com/morhon-tech/odoo-migrate)

## 🎯 核心特性

- ✅ **智能环境检测** - 自动识别 Odoo 版本、venv 路径、配置和依赖
- ✅ **完整源码备份** - 备份 Odoo 源码（排除 .git 历史，减少 80% 体积）
- ✅ **精确依赖还原** - 自动导出 `pip freeze`，恢复时精确安装相同版本
- ✅ **全面系统优化** - PostgreSQL、Nginx、Odoo 全方位性能优化
- ✅ **WebSocket 支持** - Nginx 配置包含 `/websocket` 和 `/longpolling` 路由
- ✅ **Ubuntu 专用** - 支持 Ubuntu 20.04+（备份），推荐 24.04（恢复）

## 📋 更新日志

### v2.3.0 (2026-04-13)
- **🔧 修复依赖安装**: 优先使用 `pip_freeze.txt` 精确还原依赖版本，回退到 `requirements.txt`
- **📦 排除 .git**: 备份排除 `.git`、`node_modules`、`.pot` 文件，体积从 ~5G 降到 ~700M
- **🌐 WebSocket 路由**: Nginx 配置添加 `/websocket` 和 `/longpolling`（Odoo 17 必需）
- **🗑️ 移除无效 Redis 配置**: Odoo 17 原生不支持 `session_store = redis`
- **⏱️ 修复 cron 超时**: `limit_time_real_cron` 从 0（无限制）改为 3600
- **� 版本检测优化**: 从 `release.py` 读取版本（比 `--version` 更可靠）
- **🐍 venv 自动检测**: 自动识别 `odoo_venv`、`venv` 等命名的虚拟环境
- **📋 支持 Ubuntu 20.04**: 备份支持 20.04+，恢复推荐 22.04+

### v2.2.0 (2026-01-10)
- Ubuntu 专用优化，移除其他系统支持
- 完整源码备份和恢复
- PostgreSQL、Nginx 性能优化
- 现代化 SSL 配置

## 🚀 快速开始

### 环境要求
- **备份**: Ubuntu 20.04+，运行中的 Odoo 17.0+（源码部署）
- **恢复**: Ubuntu 22.04+（推荐 24.04），4GB+ 内存，Python 3.10+

### 1. 在原服务器备份
```bash
wget -O odoo-migrate.sh https://github.com/morhon-tech/odoo-migrate/raw/main/odoo-migrate.sh
chmod +x odoo-migrate.sh
./odoo-migrate.sh backup
```

### 2. 传输到新服务器
```bash
scp odoo_backup_*.zip odoo-migrate.sh user@new-server:~/
```

### 3. 在新服务器恢复
```bash
chmod +x odoo-migrate.sh
./odoo-migrate.sh restore
```

### 4. 配置域名访问（可选）
```bash
./odoo-migrate.sh nginx
# 直接回车 → 本地 IP 模式（企业内网）
# 输入 erp.company.com → 二级域名模式（远程管理）
# 输入 company.com → 主域名模式（网站建设）
```

### 5. 检查状态
```bash
./odoo-migrate.sh status
```

## 📖 命令参考

| 命令 | 功能 | 说明 |
|------|------|------|
| `backup` | 备份当前环境 | 自动检测环境、导出依赖、打包源码和数据库 |
| `restore` | 源码方式恢复 | 创建 venv、安装精确依赖、恢复数据库和文件 |
| `nginx` | 配置反向代理 | 自动 SSL 证书，支持本地/二级域名/主域名三种模式 |
| `status` | 检查系统状态 | 显示服务状态和访问信息 |
| `help` | 显示帮助 | 查看所有可用命令 |

## 📦 备份内容

```
odoo_backup_YYYYMMDD_HHMMSS.zip
├── database/dump.sql              # PostgreSQL 数据库
├── filestore/                     # 文件存储（附件、图片等）
├── source/
│   ├── odoo_complete/             # 完整 Odoo 源码（排除 .git）
│   │   ├── pip_freeze.txt         # pip 依赖精确版本列表
│   │   └── requirements.txt       # Odoo 官方依赖
│   ├── custom_*/                  # 自定义模块目录
├── config/
│   ├── odoo.conf                  # Odoo 配置文件
│   └── odoo.service               # systemd 服务文件
└── metadata/
    ├── versions.txt               # 版本和环境信息
    └── git_commits.txt            # Git 提交记录（如有）
```

## 🌐 Nginx 部署模式

| 输入域名 | 模式 | 访问方式 | SSL | 推荐用途 |
|---------|------|---------|-----|---------|
| (空) | 本地模式 | `http://服务器IP` | 无 | 企业内网管理 |
| `erp.company.com` | 二级域名 | `https://erp.company.com` | 自动 | 远程管理系统 |
| `company.com` | 主域名 | `https://company.com` | 自动 | 企业官网/电商 |

所有模式均包含：
- `/websocket` 和 `/longpolling` 路由（Odoo 17 实时通信）
- 静态文件缓存（7 天）
- 登录和 API 限流
- 安全头部配置

## 🔧 故障排除

| 问题 | 解决方案 |
|------|----------|
| 备份时找不到 Odoo 进程 | `ps aux \| grep odoo-bin` 确认进程运行 |
| Ubuntu 版本过低 | 备份支持 20.04+，恢复需要 22.04+ |
| 恢复后依赖报错 | 检查 `pip_freeze.txt` 是否在备份中 |
| Nginx 502 错误 | `sudo systemctl status odoo` 检查 Odoo 是否启动 |
| WebSocket 断连 | 确认 Nginx 配置包含 `/websocket` 路由 |

## ⚠️ 注意事项

- 备份前确保 Odoo 正在运行
- 确保有足够的磁盘空间
- 生产环境操作前先在测试环境验证
- 备份文件包含数据库密码等敏感信息，请妥善保管

## 📋 技术说明

- **依赖管理**: 备份时自动从 venv 导出 `pip freeze`，恢复时精确安装相同版本
- **版本检测**: 从 `release.py` 读取版本号，比 `--version` 命令更可靠
- **venv 路径**: 自动检测 `odoo_venv`、`venv` 等命名的虚拟环境
- **PostgreSQL 优化**: 基于系统内存自动计算 `shared_buffers`、`effective_cache_size` 等参数
- **备份体积**: 排除 `.git` 后，典型备份约 500M-1G（取决于 enterprise addons 和 filestore）

## 🏆 项目信息

- **开发团队**: [Morhon Technology](https://github.com/morhon-tech)
- **许可证**: MIT License
- **问题反馈**: [GitHub Issues](https://github.com/morhon-tech/odoo-migrate/issues)

---

<div align="center">
  <sub>专为 Ubuntu 设计 | 支持 Odoo 17.0+ | 更新于 2026-04-13</sub>
</div>
