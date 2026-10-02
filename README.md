# 电气二次设计工作台 · 网页版

[桌面版 cad-cable-stat](https://github.com/y1991427360s/cad-cable-stat) 的独立 Web 版本，部署目标为 9 号服务器与 https://2ci.sen666.com 。

支持工程创建及 ZIP 导入/备份、XLSX/CSV 上传、电缆长度计算、参数编辑、柜名映射、二维/三维路径复核、端子检查、逐排方向设置、完整与仅接线 DXF 下载、问题清单和 CAD 向导下载。原始清册不被覆盖。

`vendor/` 保存原版计算、绘图和工程存储核心，网页适配位于 `app.py`，界面位于 `static/`。工程保存在 `DATA_DIR` 指定目录，每个工程独立一个随机 ID 文件夹，沿用 `data/` 与 `outputs/` 格式。ZIP 导入只导入业务输入，不导入旧成果。网页端不直接操作本机 CAD；在 CAD 导出 CSV 后上传。

登录密码以 Werkzeug 哈希保存于未入库的 `.env`。会话使用 HttpOnly、Secure、SameSite cookie，写接口校验 CSRF。此版本为个人工作台，登录后可访问全部工程。端子切换页面/工程前自动保存；关闭浏览器前若有未保存输入会提示，建议主动点保存。

## 本地运行

```powershell
python -m pip install -r requirements.txt
# 设置 SECRET_KEY、PASSWORD_HASH、DATA_DIR；本机 HTTP 调试 COOKIE_SECURE=0
python -m flask --app app run --port 8029
```

Windows 可只安装 `Flask==3.1.3 openpyxl==3.1.5 ezdxf==1.4.3`；gunicorn 只用于 Linux 正式运行。

## 验证

```powershell
python -m unittest discover -s tests -v
cd vendor
python -m test_calculate_cable_lengths
python -m unittest test_duanzi_dxf_tool test_terminal_service
```

网页端集成验收覆盖登录/CSRF、输入上传、直线 10m + 7m 余量、源清册哈希不变、路径 HTML、两份 DXF 回读、端子保存、工程隔离、ZIP 备份、非法路径与参数拒绝。

## 服务器

源码 `/home/ubuntu/2ci-workbench`，数据 `/home/ubuntu/2ci-data`，服务 `2ci.service`，监听 `127.0.0.1:8029`。nginx 本机 TLS `9529`，443 SNI 对 `2ci.sen666.com` 转发至该端口，其他站点沿用原分流。Cloudflare 对该子域名单独设 SSL Strict，原 zone 模式保持不变。证书通过 DNS-01 申请。

部署配置见 `deploy/`，使用前按自己的服务器环境调整路径和域名。运维命令：`sudo systemctl status 2ci`、`sudo journalctl -u 2ci -n 100`；备份包含源码与 `.env`、`/home/ubuntu/2ci-data`，密钥与密码不能入库。


证书续期令牌仅存于 root 可读的 `/etc/letsencrypt/cloudflare-2ci.ini`。续期后通过 `deploy/renewal-hook.sh` 校验并 reload nginx。
