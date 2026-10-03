"""One-shot operational scripts, run inside the backend container or venv:

    python -m app.cli create_admin --username admin --password '...'
    python -m app.cli load_seed data/components_seed.json
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

from sqlalchemy import select

from app.core.database import init_models, session_scope
from app.core.security import hash_password, validate_password
from app.models.entities import Component, User
from app.services import repository
from app.services.importer import derive_is_chinese, stable_component_id
from app.services.matching import normalize, normalize_manufacturer


async def create_admin(username: str, password: str, full_name: str) -> None:
    await init_models()
    async with session_scope() as session:
        existing = (await session.execute(
            select(User).where(User.username == username))).scalar_one_or_none()
        if existing:
            print(f"User '{username}' already exists (role={existing.role}). Nothing to do.")
            return
        validate_password(password)
        session.add(User(username=username, full_name=full_name, role="administrator",
                         password_hash=hash_password(password), must_change_password=True))
    print(f"Created administrator '{username}'. They must change the password on first login.")


async def load_seed(path: str) -> None:
    """Bulk-load data/components_seed.json - the fastest way to populate a fresh
    instance without going through the import wizard's UI round trip. Prefer
    the /api/v1/database/import endpoints for anything after first boot, since
    those give you the staged preview and rollback this script skips."""
    await init_models()
    rows = json.loads(Path(path).read_text())
    n = 0
    async with session_scope() as session:
        for row in rows:
            row = dict(row)
            row["is_chinese"] = derive_is_chinese(row.get("country_of_origin", ""),
                                                  row.get("remarks", ""),
                                                  row.get("is_chinese", ""))
            row["manufacturer"] = normalize_manufacturer(row.get("manufacturer", ""))
            row["search_key"] = normalize(row.get("chip_number") or row.get("part_number"))
            row["confidence_score"] = float(row.get("confidence_score") or 100)
            cid = row.get("component_id") or stable_component_id(row)
            if await repository.get_by_component_id(session, cid):
                continue
            payload = {k: v for k, v in row.items()
                       if k in Component.__table__.columns.keys()}
            payload["component_id"] = cid
            session.add(Component(**payload,
                                  pending_verification=(row["is_chinese"] == "UNKNOWN")))
            n += 1
        await session.flush()
        await repository.cache.rebuild(session)
    print(f"Loaded {n} new component(s) from {path}.")


async def reclassify_unknown() -> None:
    """Repair databases seeded/imported before the derive_is_chinese fix:
    records whose country of origin is an explicit 'Unknown' (or N/A, -, ...)
    but were stored as is_chinese='NO' are set back to UNKNOWN, so they show
    YELLOW (review) instead of GREEN. Prints every record it changes."""
    from app.services.importer import UNKNOWN_COUNTRY_VALUES
    await init_models()
    n = 0
    async with session_scope() as session:
        rows = (await session.execute(
            select(Component).where(Component.is_chinese == "NO"))).scalars().all()
        for c in rows:
            if (c.country_of_origin or "").strip().upper() in UNKNOWN_COUNTRY_VALUES | {""}:
                print(f"  {c.component_id}  {c.chip_number or c.part_number}: NO -> UNKNOWN")
                c.is_chinese = "UNKNOWN"
                c.pending_verification = True
                n += 1
        await session.flush()
        await repository.cache.rebuild(session)
    print(f"Reclassified {n} record(s).")


def main() -> int:
    p = argparse.ArgumentParser(prog="python -m app.cli")
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("create_admin")
    a.add_argument("--username", required=True)
    a.add_argument("--password", required=True)
    a.add_argument("--full-name", default="System Administrator")

    s = sub.add_parser("load_seed")
    s.add_argument("path")

    sub.add_parser("reclassify_unknown",
                   help="repair records stored as non-Chinese with an 'Unknown' country")

    args = p.parse_args()
    if args.cmd == "create_admin":
        asyncio.run(create_admin(args.username, args.password, args.full_name))
    elif args.cmd == "load_seed":
        asyncio.run(load_seed(args.path))
    elif args.cmd == "reclassify_unknown":
        asyncio.run(reclassify_unknown())
    return 0


if __name__ == "__main__":
    sys.exit(main())
