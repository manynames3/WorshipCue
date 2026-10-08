#!/usr/bin/env python3
"""Exercise real PostgreSQL RLS/RPCs in a new, isolated external-drive cluster.

This does not start Supabase Auth, Storage HTTP, Realtime, or modify a cloud project.
No existing database URL is accepted and no database is reset.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import uuid

REPO = Path(__file__).resolve().parents[1]
DEFAULT_ROOT = REPO.parent / "DeveloperTools" / "WorshipCue" / "BackendTests"
PG = Path(os.environ.get("WORSHIPCUE_POSTGRES_BIN", "/opt/homebrew/opt/postgresql@17/bin"))

SHIM = """
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
create table auth.users(id uuid primary key, is_anonymous boolean not null default false);
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb
$$;
grant usage on schema auth to anon,authenticated,service_role;
grant execute on function auth.uid(),auth.jwt() to anon,authenticated,service_role;
create schema storage;
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text references storage.buckets(id),name text,metadata jsonb,unique(bucket_id,name));
alter table storage.objects enable row level security;
grant usage on schema storage to anon,authenticated,service_role;
grant select,insert,update,delete on storage.objects to authenticated;
grant all on all tables in schema storage to service_role;
"""


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


class Database:
    def __init__(self, directory: Path, port: int):
        self.directory = directory
        self.port = port

    def execute(self, sql: str, actor: str | None = None, role: str = "postgres", expect: str | None = None):
        prefix = ""
        if role != "postgres":
            prefix += f"set role {role};\n"
        prefix += "set request.jwt.claim.sub=" + literal(actor or "") + ";\n"
        prefix += "set request.jwt.claims=" + literal(json.dumps({"sub": actor, "role": role})) + ";\n"
        result = subprocess.run([str(PG / "psql"), "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-h", "127.0.0.1", "-p", str(self.port), "-U", os.environ.get("USER", "aiden"), "-d", "worshipcue_test"],
                                input=prefix + sql, text=True, capture_output=True, timeout=40)
        if expect:
            assert result.returncode != 0 and expect in result.stderr, f"Expected {expect}, got database exit {result.returncode}: {result.stderr[:400]}"
            return None
        assert result.returncode == 0, f"Database exit {result.returncode}: {result.stderr[:700]}"
        lines = result.stdout.strip().splitlines()
        return lines[-1] if lines else ""

    def rpc(self, name: str, payload: dict, actor: str | None, role="authenticated", expect=None):
        result = self.execute(f"select public.{name}({literal(json.dumps(payload))}::jsonb);", actor, role, expect)
        return json.loads(result) if result else None

    def count(self, table: str, actor: str | None, where="true", role="authenticated") -> int:
        return int(self.execute(f"select count(*) from {table} where {where};", actor, role))


def run_checks(db: Database, completed: list[str]) -> list[str]:

    def checked(name: str):
        completed.append(name)
        print("PASS " + name, flush=True)

    users = {name: str(uuid.uuid4()) for name in ("admin", "member", "leader", "other", "guest", "unscoped", "revoked")}
    for name, actor in users.items():
        db.execute(f"insert into auth.users values('{actor}',{str(name in ('guest','unscoped')).lower()});")
    db.rpc("create_church_and_default_team", {"display_name": "Synthetic tenant A", "timezone": "America/New_York"}, users["guest"], expect="ACCESS_REVOKED")
    db.rpc("create_church_and_default_team", {"display_name": "Synthetic", "timezone": "UTC"}, None, expect="AUTH_REQUIRED")
    db.rpc("create_church_and_default_team", {"display_name": "Synthetic", "timezone": "UTC"}, None, role="anon", expect="permission denied")
    church = db.rpc("create_church_and_default_team", {"display_name": "Synthetic tenant A", "timezone": "America/New_York"}, users["admin"])
    other = db.rpc("create_church_and_default_team", {"display_name": "Synthetic tenant B", "timezone": "UTC"}, users["other"])
    c, t = church["church_id"], church["team_id"]
    for name in ("member", "leader", "revoked"):
        db.execute(f"insert into public.memberships(church_id,team_id,user_id,role,active) values('{c}','{t}','{users[name]}','{'leader' if name=='leader' else 'member'}',{str(name!='revoked').lower()});")
    assert db.count("public.churches", users["member"]) == 1
    assert db.count("public.churches", users["unscoped"]) == 0
    assert db.count("public.churches", users["revoked"]) == 0
    assert db.count("public.churches", users["other"]) == 1
    db.execute(f"update public.memberships set role='admin' where user_id='{users['member']}';", users["member"], "authenticated", expect="permission denied")
    checked("authentication, anonymous denial, scoped memberships, direct role escalation denial")

    def song(actor=users["admin"], church_id=c):
        return db.rpc("create_song", {"command_id": str(uuid.uuid4()), "church_id": church_id, "canonical_title": "Synthetic chart"}, actor)["song_id"]

    geometry = {"schema_version": 1, "crop_x": 12, "crop_y": 18, "crop_width": 600, "crop_height": 774, "rotation": 90}
    def asset(kind: str, actor=users["admin"], church_id=c, verified=True):
        data = f"synthetic-{kind}-{uuid.uuid4()}".encode()
        p = {"church_id": church_id, "type": kind, "sha256": hashlib.sha256(data).hexdigest(), "expected_bytes": len(data)}
        a = db.rpc("stage_asset", p, actor)
        db.execute(f"insert into storage.objects(bucket_id,name,metadata) values('worshipcue-private',{literal(a['storage_key'])},'{{\"size\":{len(data)}}}');", actor, "authenticated")
        if verified:
            validation = {"pdf": {"kind": "pdf", "page_count": 1, "pages": [geometry]}, "native": {"kind": "pencilkit-bounded"}, "preview": {"kind": "png-rgba", "width": 600, "height": 774}}[kind]
            a = db.rpc("finalize_asset", {"actor_id": actor, "asset_id": a["id"], "sha256": p["sha256"], "expected_bytes": len(data), "validation": validation}, None, "service_role")
        return a

    a = asset("pdf", verified=False)
    final_payload = {"actor_id": users["admin"], "asset_id": a["id"], "sha256": a["sha256"], "expected_bytes": a["bytes"], "validation": {"kind": "pdf", "page_count": 1, "pages": [geometry]}}
    db.rpc("finalize_asset", final_payload, users["admin"], expect="permission denied")
    db.rpc("finalize_asset", {k: v for k, v in final_payload.items() if k != "actor_id"}, None, "service_role", expect="ASSET_NOT_AUTHORIZED")
    db.rpc("finalize_asset", {**final_payload, "actor_id": users["other"]}, None, "service_role", expect="ASSET_NOT_AUTHORIZED")
    db.rpc("finalize_asset", {**final_payload, "sha256": "0" * 64}, None, "service_role", expect="HASH_MISMATCH")
    a = db.rpc("finalize_asset", final_payload, None, "service_role")
    db.execute(f"update storage.objects set metadata='{{}}' where name={literal(a['storage_key'])};", users["admin"], "authenticated")
    assert db.execute(f"select metadata->>'size' from storage.objects where name={literal(a['storage_key'])};", users["admin"], "authenticated") == str(a["bytes"])
    assert db.count("storage.objects", users["other"]) == 0
    db.execute(f"update public.assets set sha256='{'0'*64}' where id='{a['id']}';", expect="IMMUTABLE_RESOURCE")
    checked("server-only finalization, hash/size receipts, immutable storage, cross-tenant object denial")

    sid = song()
    p = {"command_id": str(uuid.uuid4()), "song_id": sid, "verified_pdf_asset_id": a["id"], "written_key": "G", "label": "Synthetic", "page_manifest": [geometry]}
    db.rpc("publish_chart_version", p, users["member"], expect="ACCESS_REVOKED")
    db.rpc("publish_chart_version", {**p, "page_manifest": [{**geometry, "crop_width": 999}]}, users["admin"], expect="INVALID_PAGE")
    db.rpc("publish_chart_version", {**p, "page_manifest": [{}]}, users["admin"], expect="INVALID_PAGE")
    v1 = db.rpc("publish_chart_version", p, users["admin"])
    assert db.rpc("publish_chart_version", p, users["admin"])["id"] == v1["id"]
    db.rpc("publish_chart_version", {**p, "label": "different"}, users["admin"], expect="IDEMPOTENCY_CONFLICT")
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(db.rpc, "publish_chart_version", {**p, "command_id": str(uuid.uuid4())}, users["admin"]) for _ in range(2)]
        assert sorted(f.result()["version_number"] for f in futures) == [2, 3]
    db.execute(f"delete from public.chart_versions where id='{v1['id']}';", expect="IMMUTABLE_RESOURCE")
    db.execute(f"update public.chart_versions set label='changed' where id='{v1['id']}';", users["admin"], "authenticated", expect="permission denied")
    v_other_song = db.rpc("publish_chart_version", {**p, "command_id": str(uuid.uuid4()), "song_id": song()}, users["admin"])
    checked("published geometry integrity, numbered concurrent versions, chart idempotency and immutability")

    s = db.rpc("create_setlist", {"command_id": str(uuid.uuid4()), "church_id": c, "team_id": t, "title": "Synthetic rehearsal", "timezone": "UTC"}, users["admin"])["id"]
    s2 = db.rpc("create_setlist", {"command_id": str(uuid.uuid4()), "church_id": c, "team_id": t, "title": "Unassigned rehearsal", "timezone": "UTC"}, users["admin"])["id"]
    occurrence = str(uuid.uuid4())
    items = [{"id": occurrence, "song_id": sid, "team_chart_version_id": v1["id"], "performance_key": "A", "position": 0, "kind": "planned"}]
    sp = {"setlist_id": s, "base_revision": 0, "command_id": str(uuid.uuid4()), "items": items}
    db.rpc("save_setlist", {k: v for k, v in sp.items() if k != "base_revision"}, users["leader"], expect="REVISION_CONFLICT")
    db.rpc("save_setlist", {**sp, "base_revision": None}, users["leader"], expect="REVISION_CONFLICT")
    db.rpc("save_setlist", {**sp, "base_revision": -1}, users["leader"], expect="REVISION_CONFLICT")
    assert db.execute(f"select revision from public.setlists where id='{s}';") == "0"
    assert db.rpc("save_setlist", sp, users["leader"])["revision"] == 1
    assert db.rpc("save_setlist", sp, users["leader"])["revision"] == 1
    db.rpc("save_setlist", {**sp, "command_id": str(uuid.uuid4())}, users["leader"], expect="REVISION_CONFLICT")
    db.rpc("save_setlist", {**sp, "base_revision": 1, "command_id": str(uuid.uuid4()), "items": [{**items[0], "team_chart_version_id": v_other_song["id"]}]}, users["leader"], expect="FILE_NOT_READY")
    assert db.count("public.performance_items", users["member"]) == 1
    checked("setlist CAS, idempotency, occurrence identity and failed-batch rollback")

    invite = db.rpc("create_invitation", {"church_id": c, "team_id": t, "setlist_id": s, "permitted_role": "guest", "expires_at": "2099-01-01T00:00:00Z", "max_uses": 1}, users["admin"], expect="INVALID_INPUT")
    invite = db.rpc("create_invitation", {"church_id": c, "team_id": t, "setlist_id": s, "permitted_role": "guest", "expires_at": db.execute("select (now()+interval '1 day')::text;"), "max_uses": 1}, users["admin"])
    redemption = {"actor_id": users["guest"], "token_hash": hashlib.sha256(invite["token"].encode()).hexdigest()}
    db.rpc("redeem_invitation", redemption, users["guest"], expect="permission denied")
    assert db.rpc("redeem_invitation", redemption, None, "service_role")["role"] == "guest"
    assert db.rpc("redeem_invitation", redemption, None, "service_role")["setlist_id"] == s
    db.rpc("redeem_invitation", {**redemption, "actor_id": users["unscoped"]}, None, "service_role", expect="ACCESS_REVOKED")
    assert db.count("public.setlists", users["guest"]) == 1
    assert db.count("public.chart_versions", users["guest"]) == 1
    assert db.count("public.songs", users["guest"]) == 1
    assert db.count("public.assets", users["guest"]) == 1
    db.rpc("stage_asset", {"church_id": c, "type": "native", "sha256": "0"*64, "expected_bytes": 10}, users["guest"], expect="ASSET_NOT_AUTHORIZED")
    for _ in range(10):
        assert db.rpc("consume_invitation_attempt", {"actor_id": users["unscoped"]}, None, "service_role")["allowed"]
    assert not db.rpc("consume_invitation_attempt", {"actor_id": users["unscoped"]}, None, "service_role")["allowed"]
    checked("one-use hashed invitations, scoped guests, redemption dedupe and durable failed-attempt throttling")

    device = str(uuid.uuid4())
    lease = db.rpc("acquire_editor", {"setlist_id": s, "device_id": device, "expected_epoch": 0, "explicit_takeover": False}, users["leader"])
    assert lease["epoch"] == 1 and lease["active"]
    db.rpc("acquire_editor", {"setlist_id": s, "device_id": str(uuid.uuid4()), "expected_epoch": 1, "explicit_takeover": False}, users["admin"], expect="STALE_CONTROLLER")
    db.rpc("renew_editor", {"setlist_id": s, "device_id": str(uuid.uuid4()), "epoch": 1}, users["leader"], expect="STALE_CONTROLLER")
    for field in ("device_id", "epoch"):
        renewal = {"setlist_id": s, "device_id": device, "epoch": 1}
        db.rpc("renew_editor", {k: v for k, v in renewal.items() if k != field}, users["leader"], expect="STALE_CONTROLLER")
        db.rpc("renew_editor", {**renewal, field: None}, users["leader"], expect="STALE_CONTROLLER")
    session = db.rpc("start_session", {"setlist_id": s, "device_id": device, "epoch": 1, "command_id": str(uuid.uuid4())}, users["leader"])
    call = {"session_id": session["id"], "command_id": str(uuid.uuid4()), "device_id": device, "expected_controller_epoch": 1, "expected_latest_sequence": 0,
            "performance_item_id": occurrence, "song_id": sid, "team_chart_version_id": v1["id"], "performance_key": "A"}
    for field, error in (("expected_controller_epoch", "STALE_CONTROLLER"), ("device_id", "STALE_CONTROLLER"), ("expected_latest_sequence", "STALE_CALL")):
        db.rpc("publish_call", {k: v for k, v in call.items() if k != field}, users["leader"], expect=error)
        db.rpc("publish_call", {**call, field: None}, users["leader"], expect=error)
    c1 = db.rpc("publish_call", call, users["leader"])
    c2 = db.rpc("publish_call", {**call, "command_id": str(uuid.uuid4()), "expected_latest_sequence": 1, "performance_key": "G"}, users["leader"])
    assert c2["latest_sequence"] == 2
    replay = db.rpc("publish_call", call, users["leader"])
    assert replay["call"]["id"] == c1["call"]["id"] and replay["latest_sequence"] == 2
    db.rpc("publish_call", {**call, "performance_key": "C"}, users["leader"], expect="IDEMPOTENCY_CONFLICT")
    db.rpc("publish_call", {**call, "command_id": str(uuid.uuid4())}, users["leader"], expect="STALE_CALL")
    assert "page" not in json.dumps(c2["call"])
    checked("device-fenced leases, immutable sequences, timeout replay without head regression and stale rejection")

    native = asset("native", users["member"])
    preview = asset("preview", users["member"])
    identity = {"church_id": c, "chart_version_id": v1["id"], "page_index": 0, "scope": "personal", "owner_user_id": users["member"], "performance_item_id": None}
    ap = {"layer_identity": identity, "command_id": str(uuid.uuid4()), "parent_revision": 0, "native_asset_id": native["id"], "preview_asset_id": preview["id"], "geometry": geometry, "device_id": str(uuid.uuid4())}
    db.rpc("save_annotation_revision", {k: v for k, v in ap.items() if k != "parent_revision"}, users["member"], expect="REVISION_CONFLICT")
    db.rpc("save_annotation_revision", {**ap, "parent_revision": None}, users["member"], expect="REVISION_CONFLICT")
    db.rpc("save_annotation_revision", {**ap, "geometry": None}, users["member"], expect="INVALID_PAGE")
    db.rpc("save_annotation_revision", {**ap, "layer_identity": {**identity, "owner_user_id": None}}, users["member"], expect="ACCESS_REVOKED")
    assert db.rpc("get_annotation_head", {"layer_identity": identity}, users["member"]) is None
    head = db.rpc("save_annotation_revision", ap, users["member"])
    assert head["revision_number"] == 1 and head["native_sha256"] == native["sha256"]
    assert db.rpc("save_annotation_revision", ap, users["member"])["revision_id"] == head["revision_id"]
    db.rpc("save_annotation_revision", {**ap, "parent_revision": 1}, users["member"], expect="IDEMPOTENCY_CONFLICT")
    db.rpc("save_annotation_revision", {**ap, "command_id": str(uuid.uuid4())}, users["member"], expect="REVISION_CONFLICT")
    db.rpc("get_annotation_head", {"layer_identity": identity}, users["admin"], expect="ACCESS_REVOKED")
    db.rpc("get_annotation_head", {"layer_id": head["layer_id"]}, users["leader"], expect="ACCESS_REVOKED")
    assert db.count("public.annotation_revisions", users["admin"]) == 0
    assert db.count("public.assets", users["admin"], f"id='{native['id']}'") == 0
    assert db.count("storage.objects", users["admin"], "name=" + literal(native["storage_key"])) == 0
    db.rpc("save_annotation_revision", {**ap, "command_id": str(uuid.uuid4()), "layer_identity": {**identity, "page_index": 1}}, users["member"], expect="INVALID_PAGE")
    db.rpc("save_annotation_revision", {**ap, "command_id": str(uuid.uuid4()), "geometry": {**geometry, "rotation": 0}}, users["member"], expect="INVALID_PAGE")
    checked("exact personal CAS, conflict preservation, private ink/asset/storage denial to leaders and admins")

    team_native, team_preview = asset("native", users["leader"]), asset("preview", users["leader"])
    team_identity = {**identity, "scope": "team", "owner_user_id": None, "performance_item_id": occurrence}
    team_ap = {**ap, "layer_identity": team_identity, "command_id": str(uuid.uuid4()), "native_asset_id": team_native["id"], "preview_asset_id": team_preview["id"], "device_id": device, "controller_epoch_if_team": 1}
    db.rpc("save_annotation_revision", team_ap, users["member"], expect="ACCESS_REVOKED")
    team_head = db.rpc("save_annotation_revision", team_ap, users["leader"])
    assert db.rpc("get_annotation_head", {"layer_identity": team_identity}, users["guest"])["revision_id"] == team_head["revision_id"]
    assert db.count("public.assets", users["guest"]) == 3
    new_device = str(uuid.uuid4())
    lease2 = db.rpc("acquire_editor", {"setlist_id": s, "device_id": new_device, "expected_epoch": 1, "explicit_takeover": True}, users["admin"])
    assert lease2["epoch"] == 2
    assert db.rpc("save_annotation_revision", team_ap, users["leader"])["revision_id"] == team_head["revision_id"]
    db.rpc("save_annotation_revision", {**team_ap, "command_id": str(uuid.uuid4()), "parent_revision": 1}, users["leader"], expect="STALE_CONTROLLER")
    db.rpc("publish_call", {**call, "command_id": str(uuid.uuid4()), "expected_latest_sequence": 2}, users["leader"], expect="STALE_CONTROLLER")
    assert db.rpc("publish_call", call, users["leader"])["latest_sequence"] == 2
    db.execute(f"update public.memberships set role='member' where user_id='{users['leader']}' and team_id='{t}';")
    assert db.rpc("publish_call", call, users["leader"])["latest_sequence"] == 2
    assert db.rpc("save_annotation_revision", team_ap, users["leader"])["revision_id"] == team_head["revision_id"]
    db.rpc("publish_call", {**call, "command_id": str(uuid.uuid4()), "expected_latest_sequence": 2}, users["leader"], expect="ACCESS_REVOKED")
    checked("team exact-context snapshots, guest read-only access, takeover fencing and safe old-command receipts")

    admin_call = {**call, "device_id": new_device, "expected_controller_epoch": 2}
    with ThreadPoolExecutor(max_workers=2) as pool:
        def race():
            try:
                return db.rpc("publish_call", {**admin_call, "command_id": str(uuid.uuid4()), "expected_latest_sequence": 2}, users["admin"])
            except AssertionError as error:
                assert "STALE_CALL" in str(error)
                return None
        results = list(pool.map(lambda _: race(), range(2)))
    assert sum(r is not None for r in results) == 1
    adhoc = str(uuid.uuid4())
    db.rpc("publish_call", {**admin_call, "command_id": str(uuid.uuid4()), "expected_latest_sequence": 3, "performance_item_id": adhoc}, users["admin"], expect="ACCESS_REVOKED")
    db.rpc("publish_call", {**admin_call, "command_id": str(uuid.uuid4()), "expected_latest_sequence": 3, "performance_item_id": adhoc, "ad_hoc_draft": {"id": adhoc}}, users["admin"])
    assert db.count("public.performance_items", users["guest"]) == 2
    assert db.execute(f"select position from public.performance_items where id='{occurrence}';", users["member"], "authenticated") == "0"
    ack = db.rpc("acknowledge_open", {"session_id": session["id"], "call_id": c1["call"]["id"], "device_id": str(uuid.uuid4()), "selected_chart_version_id": v1["id"]}, users["guest"])
    assert ack["opened"] and not ack["is_latest"] and ack["meaning"] == "rendered_not_ready"
    snap = db.rpc("get_session_snapshot", {"session_id": session["id"]}, users["guest"])
    assert snap["latest_sequence"] == 4 and len(snap["history"]) == 4 and len(snap["annotation_heads"]) == 1
    db.rpc("get_session_snapshot", {"session_id": session["id"]}, users["other"], expect="ACCESS_REVOKED")
    checked("simultaneous sequence race, atomic ad-hoc call, unchanged planned order and historical acknowledgement")

    clients = [str(uuid.uuid4()) for _ in range(50)]
    db.execute("insert into auth.users(id) values " + ",".join(f"('{u}')" for u in clients) + ";")
    db.execute("insert into public.memberships(church_id,team_id,user_id,role) values " + ",".join(f"('{c}','{t}','{u}','member')" for u in clients) + ";")
    with ThreadPoolExecutor(max_workers=8) as pool:
        snapshots = list(pool.map(lambda u: db.rpc("get_session_snapshot", {"session_id": session["id"]}, u), clients))
    assert all(x["latest_sequence"] == 4 and x["latest_call"]["performance_item_id"] == adhoc and len(x["annotation_heads"]) == 1 for x in snapshots)
    assert all(not x["access"]["can_control"] and x["access"]["can_write_personal"] for x in snapshots)
    checked("fifty independent authenticated durable snapshot readers agree without gaining controller access")

    version_two = db.execute(f"select id from public.chart_versions where song_id='{sid}' and version_number=2;")
    db.rpc("set_personal_preference", {"song_id": sid, "preferred_version_id": version_two}, users["member"])
    admin_native, admin_preview = asset("native"), asset("preview")
    admin_annotation = {**team_ap, "command_id": str(uuid.uuid4()), "device_id": new_device, "controller_epoch_if_team": 2,
                        "native_asset_id": admin_native["id"], "preview_asset_id": admin_preview["id"]}
    unassigned_version_head = db.rpc("save_annotation_revision", {**admin_annotation, "layer_identity": {**team_identity, "chart_version_id": version_two}}, users["admin"])
    adhoc_head = db.rpc("save_annotation_revision", {**admin_annotation, "command_id": str(uuid.uuid4()), "layer_identity": {**team_identity, "performance_item_id": adhoc}}, users["admin"])
    outside_occurrence = str(uuid.uuid4())
    outside_item = {**items[0], "id": outside_occurrence}
    db.rpc("save_setlist", {"setlist_id": s2, "base_revision": 0, "command_id": str(uuid.uuid4()), "items": [outside_item]}, users["admin"])
    outside_device = str(uuid.uuid4())
    db.rpc("acquire_editor", {"setlist_id": s2, "device_id": outside_device, "expected_epoch": 0, "explicit_takeover": False}, users["admin"])
    outside_head = db.rpc("save_annotation_revision", {**admin_annotation, "command_id": str(uuid.uuid4()), "device_id": outside_device,
                                                       "controller_epoch_if_team": 1, "layer_identity": {**team_identity, "performance_item_id": outside_occurrence}}, users["admin"])
    member_manifest = db.rpc("preflight_manifest", {"setlist_id": s}, users["member"])
    assert {v["id"] for v in member_manifest["charts"]} == {v1["id"], version_two}
    expected_heads = {team_head["revision_id"], adhoc_head["revision_id"]}
    assert {h["revision_id"] for h in member_manifest["annotation_heads"]} == expected_heads
    assert all(h["scope"] == "team" and h["owner_user_id"] is None and h["native_sha256"] and h["preview_storage_key"] for h in member_manifest["annotation_heads"])
    excluded_heads = {head["revision_id"], outside_head["revision_id"], unassigned_version_head["revision_id"]}
    assert not expected_heads.intersection(excluded_heads)
    guest_manifest = db.rpc("preflight_manifest", {"setlist_id": s}, users["guest"])
    assert {v["id"] for v in guest_manifest["charts"]} == {v1["id"]}
    assert {h["revision_id"] for h in guest_manifest["annotation_heads"]} == expected_heads
    db.rpc("preflight_manifest", {"setlist_id": s2}, users["guest"], expect="ACCESS_REVOKED")
    db.rpc("preflight_manifest", {"setlist_id": s}, users["other"], expect="ACCESS_REVOKED")
    before_preflight = db.rpc("get_session_snapshot", {"session_id": session["id"]}, users["member"])
    before_revisions = db.count("public.annotation_revisions", None, role="postgres")
    before_participants = db.count("public.participants", None, role="postgres")
    with ThreadPoolExecutor(max_workers=8) as pool:
        manifests = list(pool.map(lambda u: db.rpc("preflight_manifest", {"setlist_id": s}, u), clients))
    assert all({h["revision_id"] for h in m["annotation_heads"]} == expected_heads for m in manifests)
    assert db.rpc("get_session_snapshot", {"session_id": session["id"]}, users["member"]) == before_preflight
    assert db.count("public.annotation_revisions", None, role="postgres") == before_revisions
    assert db.count("public.participants", None, role="postgres") == before_participants
    checked("preflight full exact team heads exclude private/wrong-context notes and fifty readers leave state unchanged")

    for sequence in range(4, 13):
        db.rpc("publish_call", {**admin_call, "command_id": str(uuid.uuid4()), "expected_latest_sequence": sequence}, users["admin"])
    snap = db.rpc("get_session_snapshot", {"session_id": session["id"]}, users["guest"])
    assert len(snap["history"]) == 10 and snap["history"][0]["sequence"] == 13 and snap["history"][-1]["sequence"] == 4
    db.execute(f"update public.editor_leases set expires_at=clock_timestamp()+interval '0.15 seconds' where setlist_id='{s}';")
    renew_payload = {"setlist_id": s, "device_id": new_device, "epoch": 2}
    db.execute("begin; select pg_sleep(0.25); select public.renew_editor(" + literal(json.dumps(renew_payload)) + "::jsonb); commit;", users["admin"], "authenticated", expect="STALE_CONTROLLER")
    db.execute(f"update public.editor_leases set expires_at=now()-interval '1 second' where setlist_id='{s}';")
    db.rpc("renew_editor", {"setlist_id": s, "device_id": new_device, "epoch": 2}, users["admin"], expect="STALE_CONTROLLER")
    lease3 = db.rpc("acquire_editor", {"setlist_id": s, "device_id": new_device, "expected_epoch": 2, "explicit_takeover": False}, users["admin"])
    assert lease3["epoch"] == 3
    ended = db.rpc("end_session", {"session_id": session["id"], "command_id": str(uuid.uuid4()), "device_id": new_device, "epoch": 3}, users["admin"])
    assert ended["status"] == "ENDED" and ended["latest_sequence"] == 13
    db.rpc("publish_call", {**admin_call, "command_id": str(uuid.uuid4()), "expected_controller_epoch": 3, "expected_latest_sequence": 13}, users["admin"], expect="SESSION_ENDED")
    db.rpc("revoke_guest_grant", {"setlist_id": s, "user_id": users["guest"]}, users["admin"])
    assert db.count("public.chart_versions", users["guest"]) == 0
    assert db.count("public.assets", users["guest"]) == 0
    assert db.count("storage.objects", users["guest"]) == 0
    db.rpc("get_session_snapshot", {"session_id": session["id"]}, users["guest"], expect="ACCESS_REVOKED")
    db.rpc("preflight_manifest", {"setlist_id": s}, users["guest"], expect="ACCESS_REVOKED")
    checked("bounded ten-call history, server lease expiry, increasing reacquisition epoch, end and revoked guest access")
    assert db.execute("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','private') and p.prosecdef and not ('search_path=\"\"'=any(p.proconfig));") == "0"
    checked("all security-definer functions use fixed empty search paths")
    return completed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-root", type=Path, default=DEFAULT_ROOT)
    args = parser.parse_args()
    args.output_root.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="backend-", dir=args.output_root))
    data = directory / "data"
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    report = {"status": "failed", "postgres": None, "groups": [], "unverified": ["Managed Auth OTP/anonymous HTTP", "Storage HTTP", "Supabase Realtime", "50-client and physical multi-iPad network qualification"]}
    started = False
    try:
        report["postgres"] = subprocess.check_output([str(PG / "postgres"), "--version"], text=True).strip()
        subprocess.run([str(PG / "initdb"), "-D", str(data), "-A", "trust", "--no-locale", "-E", "UTF8"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        subprocess.run([str(PG / "pg_ctl"), "-D", str(data), "-l", str(directory / "postgres.log"), "-o", f"-h 127.0.0.1 -p {port} -c unix_socket_directories=''", "-w", "start"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        started = True
        subprocess.run([str(PG / "createdb"), "-h", "127.0.0.1", "-p", str(port), "worshipcue_test"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        db = Database(directory, port)
        db.execute(SHIM)
        for migration in sorted((REPO / "supabase" / "migrations").glob("*.sql")):
            db.execute("begin;\n" + migration.read_text() + "\ncommit;")
        run_checks(db, report["groups"])
        report["status"] = "passed"
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        if started:
            subprocess.run([str(PG / "pg_ctl"), "-D", str(data), "-m", "fast", "-w", "stop"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        (directory / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        print("Evidence: " + str(directory / "results.json"), flush=True)
    print(f"{len(report['groups'])} backend integration groups passed; isolated cluster stopped.")


if __name__ == "__main__":
    main()
