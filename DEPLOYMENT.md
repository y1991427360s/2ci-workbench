# 部署说明

Linux 部署使用 `deploy/2ci.service` 与 `deploy/2ci.nginx.conf` 作为示例，按环境修改路径、用户和域名。

- 安装 requirements.txt，配置未入库的 `.env`：SECRET_KEY、PASSWORD_HASH、DATA_DIR、COOKIE_SECURE。
- PASSWORD_HASH 使用 Werkzeug generate_password_hash 生成，SECRET_KEY 使用随机值。
- 工程数据保存在 DATA_DIR，备份源码、凭据与工程数据时须分别保管，禁止公开凭据及业务数据。
- 正式环境使用 HTTPS 与 COOKIE_SECURE=1；证书续期后校验并 reload nginx。
- `deploy/configure_server.py` 为现有站点的部署脚本，执行前检查 nginx 的 SNI 分流及服务配置。
- 验证：`python -m unittest discover -s tests -v`。

个人工作台采用单用户密码保护；登录后可访问该实例全部工程。CAD 导出仍需在本机执行。
