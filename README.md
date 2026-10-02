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

## 二次设计项目一致性检查 V2

进入“项目检查”，点击“运行项目检查”。统一规则位于 `validation/engine.py`，文件适配及报告服务位于 `validation/service.py`；Flask 仅负责权限、工程定位和调用，前端仅展示及筛选。支持 ERROR / WARNING / INFO、规则、电缆号和柜名组合筛选；每条问题包含工程、对象位置、原始数据证据及处理建议。

报告保存在每个工程的 `outputs/reports/validation.json` 和 `validation.md`，成组原子替换，保留输入。GET `/api/projects/<id>/validation` 读取最近报告，POST 执行检查。输入内容或路径计算结果变化后，最近报告标记为过期；旧报告仍保留直到成功生成新报告。

清册支持唯一 XLSX（表头至少“电缆编号、起点、终点”，型号规格列可选），或上传 UTF-8 BOM / GBK / UTF-16 的 `电缆清册.csv`（“电缆编号,起点,终点,规格”）。CSV 清册目前用于一致性检查，长度计算仍沿用 XLSX。多份候选清册视为歧义，不静默选取其中一份。

原 `端子排.txt`、`接线.txt` 和 `settings.json` 继续使用。TXT 采用已有出图解析器，按默认前缀自动生成电缆号，不能推断原工程真实电缆编号，也只包含一个柜侧；报告明确显示这一覆盖限制。解析失败和不存在端子引用列入 D002，不静默忽略。

需要真实电缆号及两侧检查时，在工程总览上传 `端子数据.csv`，必需表头如下，每行是一个物理端子声明：

```csv
terminal_strip,terminal_number,cable_number,source_cabinet,target_cabinet,circuit_number,external
X,1,C1,1#保护柜,35kV开关柜,K1,true
X,1,C1,35kV开关柜,1#保护柜,K1,true
X,2,,1#保护柜,,,false
```

`source_cabinet` 始终表示端子所在柜，`target_cabinet` 表示接线对侧；允许清册与对侧端子记录方向相反。可选字段：`circuit_number`、`left_circuit`、`right_circuit`、`external`、`valid_connection`。存在电缆号或目标柜时按外部接线处理；备用端子无连接时会提示孤立端子 WARNING。CSV 存在时，项目检查优先使用 CSV，TXT 仍用于原出图流程，两者不会自动同步。柜名经现有空白/全角规范化及显式别名映射后比较，英文大小写不产生冲突；原值保留在 evidence。

规则及模型边界见 [validation-v2.md](docs/validation-v2.md)。可重复执行真实 API 验收：

```powershell
.\.venv\Scripts\python.exe scripts/accept_validation.py
```

验收会创建正常、故障两个隔离工程，上传 XLSX 和端子 CSV，确认正常工程 0 ERROR，以及重复电缆、起终点冲突、孤立端子、不存在电缆引用全部检出。工程与报告保留在 `outputs/acceptance/`，不写入生产 `DATA_DIR`。

## 服务器

源码 `/home/ubuntu/2ci-workbench`，数据 `/home/ubuntu/2ci-data`，服务 `2ci.service`，监听 `127.0.0.1:8029`。nginx 本机 TLS `9529`，443 SNI 对 `2ci.sen666.com` 转发至该端口，其他站点沿用原分流。Cloudflare 对该子域名单独设 SSL Strict，原 zone 模式保持不变。证书通过 DNS-01 申请。

部署配置见 `deploy/`，使用前按自己的服务器环境调整路径和域名。运维命令：`sudo systemctl status 2ci`、`sudo journalctl -u 2ci -n 100`；备份包含源码与 `.env`、`/home/ubuntu/2ci-data`，密钥与密码不能入库。


证书续期令牌仅存于 root 可读的 `/etc/letsencrypt/cloudflare-2ci.ini`。续期后通过 `deploy/renewal-hook.sh` 校验并 reload nginx。
