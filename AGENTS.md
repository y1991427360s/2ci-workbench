# Repository Guidelines

## Project Structure & Module Organization

- `app.py`: Flask routes, authentication, uploads, project storage, and adapters to the calculation engines.
- `static/`: browser interface (`index.html`, `app.js`, `style.css`), icon, and downloadable CAD LISP.
- `vendor/`: desktop calculation, terminal drawing, storage modules, regression tests, and `项目模板/data/`. Read `vendor/ORIGIN.md` before changing these engines.
- `tests/test_web.py`: Web integration tests.
- `deploy/`: systemd/nginx configuration, deployment helpers, and certificate renewal hook.
- `README.md` and `DEPLOYMENT.md`: usage, architecture, and deployment evidence. Runtime engineering data lives outside version control.

## Build, Test, and Development Commands

```powershell
python -m pip install -r requirements.txt
python -m flask --app app run --port 8029
python -m unittest discover -s tests -v
node --check static/app.js
```

These install dependencies, start development, run integration tests, and check JavaScript syntax. No frontend build is required; gunicorn is Linux-only.

For engine regressions, run from `vendor/`:

```powershell
python -m test_calculate_cable_lengths
python -m unittest test_duanzi_dxf_tool test_terminal_service
```

Configure environment variables before starting: `SECRET_KEY`, `PASSWORD_HASH`, `DATA_DIR`, and `COOKIE_SECURE=0` for local HTTP. Use a separate local data directory.

## Coding Style & Naming Conventions

Use four-space indentation, `snake_case`, and `pathlib.Path` in Python. Keep HTTP/UI adapters separate from engine logic. Follow existing JavaScript conventions; no formatter or linter is configured.

Preserve Chinese business field names and established file layouts. Follow `.gitattributes`: source files use LF; LISP remains GBK with CRLF; Chinese CSV retains UTF-8 BOM. Preserve the root-only `/data/` ignore pattern so template data stays tracked.

## Testing Guidelines

Use `unittest` and name tests `test_<behavior>`. Cover changed behavior and failure cases. There is no numeric coverage threshold. Preserve source-workbook bytes, project isolation, CSRF checks, upload path validation, and DXF readability. Engine changes require both regression commands; calculation changes also require checking workbook and visualization outputs. For UI changes, verify desktop/mobile layouts and affected browser workflows.

## Commit & Pull Request Guidelines

Existing commits use concise imperative summaries, occasionally with a `chore:` prefix. Keep changes focused. PRs should explain behavior, validation commands/results, and deployment impact; link related issues when available and include screenshots for interface changes.

## Security & Deployment

Never commit passwords, `.env`, API tokens, SSH keys, or real engineering data. Preserve authentication, CSRF protection, and original inputs. Production uses `2ci.service` behind nginx on server 5 (`/opt/2ci-workbench`). Preserve existing SNI routing and the hostname-specific Cloudflare SSL override. Read `deploy/` and deployment documentation before changing infrastructure, and update documentation with verified facts.
