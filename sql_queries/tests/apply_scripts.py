from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Iterable

import pymssql

GO_SPLIT_RE = re.compile(r"(?im)^\s*GO\s*$")
PROC_RE = re.compile(r"(?im)^\s*(CREATE|ALTER)\s+PROCEDURE\b")


def convert_sql_script_content(content: str, filename: str) -> str:
    normalized = content.replace("\r\n", "\n").replace("\r", "\n")
    if re.search(r"create_procedure|alter_procedure", filename, re.IGNORECASE):
        normalized = PROC_RE.sub("CREATE OR ALTER PROCEDURE", normalized)
    return normalized


def split_sql_batches(content: str) -> list[str]:
    return [part for part in GO_SPLIT_RE.split(content) if part.strip()]


def iter_sql_files(scripts_path: Path) -> Iterable[Path]:
    yield from sorted(scripts_path.glob("*.sql"), key=lambda p: p.name)


def apply_scripts(conn, scripts_path: Path) -> None:
    for path in iter_sql_files(scripts_path):
        content = convert_sql_script_content(path.read_text(encoding="utf-8-sig"), path.name)
        for index, batch in enumerate(split_sql_batches(content), start=1):
            cursor = conn.cursor()
            try:
                cursor.execute(batch)
                while cursor.nextset():
                    pass
            except Exception as exc:  # pragma: no cover - message is for harness diagnostics
                raise RuntimeError(f"Failed executing batch {index} from {path.name}: {exc}") from exc
            finally:
                cursor.close()
        conn.commit()


def _parse_server(server: str) -> tuple[str, int | None]:
    if ":" in server and not server.startswith("["):
        host, port = server.rsplit(":", 1)
        if port.isdigit():
            return host, int(port)
    return server, None


def connect(server: str, user: str, password: str, database: str, autocommit: bool = False):
    host, port = _parse_server(server)
    kwargs = {"server": host, "user": user, "password": password, "database": database, "autocommit": autocommit}
    if port is not None:
        kwargs["port"] = port
    return pymssql.connect(**kwargs)


def main() -> None:
    parser = argparse.ArgumentParser(description="Apply sql_queries/*.sql using Initialize-Database.ps1 semantics.")
    parser.add_argument("--server", required=True)
    parser.add_argument("--user", default="sa")
    parser.add_argument("--password", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--scripts-path", default=str(Path(__file__).resolve().parents[1]))
    args = parser.parse_args()
    with connect(args.server, args.user, args.password, args.database) as conn:
        apply_scripts(conn, Path(args.scripts_path))


if __name__ == "__main__":
    main()
