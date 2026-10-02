"""Web adapter for the unchanged desktop calculation and drawing engines."""
from __future__ import annotations

import io
import json
import math
import os
import re
import secrets
import shutil
import sys
import threading
import zipfile
from dataclasses import asdict
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from flask import Flask, abort, jsonify, request, send_file, session
from werkzeug.exceptions import HTTPException
from werkzeug.security import check_password_hash

BASE = Path(__file__).resolve().parent
sys.path.insert(0, str(BASE / "vendor"))
from cable_stat.pipeline import run
from cable_stat.project import scan_project, find_workbook, load_alias_rows, save_aliases
from cable_stat.params import PARAM_SPECS, load_params, save_params
from cable_stat.visual import write_visualization_files
from modules.terminal.service import TerminalService
from modules.terminal.duanzi_dxf_tool import EXAMPLE_TERMINALS, EXAMPLE_WIRING, EXAMPLE_CABINET

app = Flask(__name__, static_folder="static")
app.config.update(SECRET_KEY=os.environ.get("SECRET_KEY") or secrets.token_hex(32),
                  MAX_CONTENT_LENGTH=80 * 1024 * 1024,
                  SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Strict",
                  SESSION_COOKIE_SECURE=os.environ.get("COOKIE_SECURE", "1") == "1")
ROOT = Path(os.environ.get("DATA_DIR", str(BASE / "data"))).resolve()
ROOT.mkdir(parents=True, exist_ok=True)
lock = threading.RLock()


@app.before_request
def protect():
    if request.path.startswith("/api/") and request.path not in ("/api/session", "/api/login"):
        if not session.get("authenticated"):
            abort(401, "请先登录")
    if request.method not in ("GET", "HEAD", "OPTIONS") and request.path.startswith("/api/"):
        if not secrets.compare_digest(request.headers.get("X-CSRF-Token", ""), session.get("csrf", "invalid")):
            abort(403, "会话已过期，请刷新后重试")


@app.after_request
def headers(response):
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "SAMEORIGIN"
    response.headers["Referrer-Policy"] = "same-origin"
    return response


@app.errorhandler(Exception)
def error(exc):
    if isinstance(exc, HTTPException):
        return jsonify(error=exc.description), exc.code
    if isinstance(exc, (ValueError, FileNotFoundError, RuntimeError, zipfile.BadZipFile)):
        return jsonify(error=str(exc)), 400
    app.logger.exception("Request failed")
    return jsonify(error="操作失败，请检查输入或查看服务日志"), 500


@app.get("/")
def index():
    return app.send_static_file("index.html")


@app.get("/health")
def health():
    return {"ok": True, "service": "2ci-workbench"}


@app.get("/favicon.ico")
def favicon():
    return app.send_static_file("favicon.png")


@app.get("/api/session")
def current_session():
    session.setdefault("csrf", secrets.token_hex(24))
    return {"authenticated": bool(session.get("authenticated")), "csrf": session["csrf"]}


@app.post("/api/login")
def login():
    configured = os.environ.get("PASSWORD_HASH", "")
    if not configured or not check_password_hash(configured, request.json.get("password", "")):
        abort(401, "密码不正确")
    session.clear()
    session.update(authenticated=True, csrf=secrets.token_hex(24))
    return {"csrf": session["csrf"]}


@app.post("/api/logout")
def logout():
    session.clear()
    return {"ok": True}


def project(pid):
    if not re.fullmatch(r"[a-f0-9]{16}", pid):
        abort(404)
    path = ROOT / pid
    if not (path / "project.json").is_file():
        abort(404)
    return path


def file_path(path, relative):
    target = (path / relative).resolve()
    if not target.is_relative_to(path.resolve()) or target == path or target.is_symlink():
        abort(400, "文件路径无效")
    return target


def describe(path):
    info = json.loads((path / "project.json").read_text(encoding="utf-8"))
    status = scan_project(path)
    return {**info, "id": path.name, "workbook": status.workbook.name if status.workbook else None,
            "workbook_error": status.workbook_error, "files": [asdict(f) for f in status.files],
            "outdated": status.result_outdated, "missing": status.missing_required,
            "outputs": [{"name": p.relative_to(path).as_posix(), "size": p.stat().st_size}
                        for p in sorted((path / "outputs").rglob("*")) if p.is_file()],
            "result": json.loads((path / "result.json").read_text(encoding="utf-8")) if (path / "result.json").exists() else None}


@app.get("/api/projects")
def projects():
    with lock:
        return [describe(p) for p in sorted(ROOT.iterdir()) if p.is_dir() and (p / "project.json").is_file()]


@app.post("/api/projects")
def create():
    name = str(request.json.get("name", "")).strip()
    if not name or len(name) > 100:
        abort(400, "请输入工程名称（最多100字）")
    with lock:
        path = ROOT / secrets.token_hex(8)
        shutil.copytree(BASE / "vendor" / "项目模板" / "data", path / "data")
        (path / "project.json").write_text(json.dumps({"name": name}, ensure_ascii=False), encoding="utf-8")
        return describe(path), 201


@app.get("/api/projects/<pid>")
def detail(pid):
    with lock:
        return describe(project(pid))


@app.post("/api/projects/<pid>/upload")
def upload(pid):
    with lock:
        path = project(pid)
        staged = {}
        for upload in request.files.getlist("files"):
            name = Path(upload.filename.replace("\\", "/")).name
            if name.startswith("~$"):
                continue
            blob = upload.read()
            if name.lower().endswith(".zip"):
                with zipfile.ZipFile(io.BytesIO(blob)) as archive:
                    total = 0
                    for item in archive.infolist():
                        total += item.file_size
                        if total > 150 * 1024 * 1024:
                            abort(400, "工程解压后不能超过150MB")
                        if item.is_dir():
                            continue
                        parts = item.filename.replace("\\", "/").split("/")
                        if ".." in parts or parts[0] == "":
                            abort(400, "压缩包包含非法路径")
                        if "outputs" in parts:
                            continue
                        target = input_target(path, parts[-1])
                        if target:
                            if target in staged:
                                abort(400, "压缩包包含多个同名输入，请每次导入一个工程")
                            staged[target] = archive.read(item)
            else:
                target = input_target(path, name)
                if not target:
                    abort(400, "不支持的输入文件：" + name)
                staged[target] = blob
        if not staged:
            abort(400, "没有找到可导入的工程输入文件")
        # Stage every file before replacing, keeping a backup for rollback.
        originals = {p: p.read_bytes() if p.exists() else None for p in staged}
        try:
            for p, blob in staged.items():
                p.parent.mkdir(parents=True, exist_ok=True)
                temp = p.with_suffix(p.suffix + ".tmp")
                temp.write_bytes(blob)
                os.replace(temp, p)
        except Exception:
            for p, blob in originals.items():
                if blob is None:
                    p.unlink(missing_ok=True)
                else:
                    p.write_bytes(blob)
            raise
        return describe(path)


def input_target(path, name):
    if name.lower().endswith(".xlsx") and not name.startswith("~$"):
        return path / name
    aliases = {"cabinets.csv": "柜子坐标.csv", "route_segments.csv": "路径线段.csv", "shafts.csv": "竖井.csv"}
    name = aliases.get(name, name)
    if name in {"参数.csv", "柜子坐标.csv", "路径线段.csv", "竖井.csv", "房间范围.csv", "柜名别名.csv", "强制规则.csv"}:
        return path / "data" / name
    if name in {"端子排.txt", "接线.txt", "settings.json"}:
        return path / "data" / "terminal" / name


@app.route("/api/projects/<pid>/params", methods=["GET", "PUT"])
def params(pid):
    with lock:
        path = project(pid) / "data"
        if request.method == "PUT":
            values = {}
            for spec in PARAM_SPECS:
                value = float(request.json[spec.name])
                if not math.isfinite(value) or spec.check(value):
                    abort(400, spec.name + "：" + (spec.check(value) or "必须是有限数字"))
                values[spec.name] = value
            save_params(path, values)
        return {"values": load_params(path), "specs": [asdict(s) for s in PARAM_SPECS]}


@app.route("/api/projects/<pid>/aliases", methods=["GET", "PUT"])
def aliases(pid):
    with lock:
        path = project(pid)
        if request.method == "PUT":
            save_aliases(path / "data", request.json)
        from cable_stat.loaders import load_cabinets, load_workbook_rows
        cad, _ = load_cabinets(path / "data")
        required = []
        try:
            wb, _, _, _, required = load_workbook_rows(find_workbook(path))
            wb.close()
        except (FileNotFoundError, RuntimeError):
            pass
        return {"rows": load_alias_rows(path / "data"), "cad": sorted(cad), "required": required}


@app.post("/api/projects/<pid>/calculate")
def calculate(pid):
    with lock:
        path = project(pid)
        status = scan_project(path)
        if status.missing_required:
            abort(400, "请上传：" + "、".join(status.missing_required))
        result = run(find_workbook(path), path / "data", path / "outputs" / "自动统计_计算结果.xlsx")
        visual = json.loads(result.json_path.read_text(encoding="utf-8"))
        info = json.loads((path / "project.json").read_text(encoding="utf-8"))
        visual.update(title="电缆路径可视化 · " + info["name"],
                      generated_at=datetime.now(ZoneInfo("Asia/Shanghai")).isoformat(timespec="seconds"),
                      source_workbook=result.workbook.name,
                      output_workbook="outputs/" + result.output_workbook.name)
        write_visualization_files(path / "outputs", visual)
        summary = {"total": result.total, "ok": result.ok, "failed": result.failed,
                   "summary": result.summary, "issues": result.issues, "elapsed": result.elapsed,
                   "cabinet_check_rows": result.cabinet_check_rows, "notes": result.notes}
        (path / "result.json").write_text(json.dumps(summary, ensure_ascii=False), encoding="utf-8")
        return describe(path)


@app.route("/api/projects/<pid>/terminal", methods=["GET", "PUT"])
def terminal(pid):
    with lock:
        service = TerminalService(project(pid))
        if request.method == "PUT":
            service.save_state(request.json)
        return service.load_state()


@app.post("/api/projects/<pid>/terminal/<action>")
def drawing(pid, action):
    with lock:
        service = TerminalService(project(pid))
        if action == "inspect":
            return service.inspect(request.json)
        if action == "generate":
            result = service.generate(request.json)
            result.pop("traceback", None)
            return result
        abort(404)


@app.get("/api/examples")
def examples():
    return {"terminals": EXAMPLE_TERMINALS, "wiring": EXAMPLE_WIRING, "cabinet": EXAMPLE_CABINET}


@app.get("/api/projects/<pid>/file/<path:relative>")
def download(pid, relative):
    path = project(pid)
    target = file_path(path, relative)
    if not target.is_file() or target.name in {"project.json", "result.json"}:
        abort(404)
    inline = target.suffix.lower() == ".html" and relative.startswith("outputs/")
    return send_file(target, as_attachment=not inline)


@app.get("/api/projects/<pid>/export")
def export(pid):
    with lock:
        path = project(pid)
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w", zipfile.ZIP_DEFLATED) as archive:
            for item in path.rglob("*"):
                if item.is_file() and item.suffix not in {".tmp", ".bak"}:
                    archive.write(item, item.relative_to(path))
        stream.seek(0)
        return send_file(stream, as_attachment=True, download_name="工程备份.zip")
