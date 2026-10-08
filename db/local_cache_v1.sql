-- Reference LOCAL SQLite schema, not a Supabase/Postgres deployment migration.
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
BEGIN;
CREATE TABLE local_accounts (
 account_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, church_id TEXT NOT NULL,
 UNIQUE(user_id, church_id)
);
CREATE TABLE chart_versions (
 account_id TEXT NOT NULL REFERENCES local_accounts(account_id),
 version_id TEXT NOT NULL, song_id TEXT NOT NULL, version_number INTEGER NOT NULL CHECK(version_number>0),
 written_key TEXT, page_count INTEGER NOT NULL CHECK(page_count>0), pdf_sha256 TEXT NOT NULL CHECK(length(pdf_sha256)=64),
 PRIMARY KEY(account_id,version_id), UNIQUE(account_id,song_id,version_number), UNIQUE(account_id,version_id,song_id)
);
CREATE TABLE page_geometry (
 account_id TEXT NOT NULL, version_id TEXT NOT NULL, page_index INTEGER NOT NULL CHECK(page_index>=0),
 crop_x REAL NOT NULL, crop_y REAL NOT NULL, crop_width REAL NOT NULL CHECK(crop_width>0), crop_height REAL NOT NULL CHECK(crop_height>0),
 rotation INTEGER NOT NULL CHECK(rotation IN(0,90,180,270)), geometry_schema INTEGER NOT NULL DEFAULT 1 CHECK(geometry_schema=1),
 PRIMARY KEY(account_id,version_id,page_index),
 FOREIGN KEY(account_id,version_id) REFERENCES chart_versions(account_id,version_id)
);
CREATE TRIGGER geometry_page_bounds BEFORE INSERT ON page_geometry
WHEN NEW.page_index >= (SELECT page_count FROM chart_versions WHERE account_id=NEW.account_id AND version_id=NEW.version_id)
BEGIN SELECT RAISE(ABORT,'page out of bounds'); END;
CREATE TABLE ink_pages (
 account_id TEXT NOT NULL, layer_key TEXT NOT NULL, version_id TEXT NOT NULL, page_index INTEGER NOT NULL,
 scope TEXT NOT NULL CHECK(scope IN('personal','team')),
 owner_user_id TEXT, performance_item_id TEXT,
 local_generation INTEGER NOT NULL DEFAULT 0 CHECK(local_generation>=0),
 server_revision INTEGER NOT NULL DEFAULT 0 CHECK(server_revision>=0),
 native_data BLOB NOT NULL, dirty INTEGER NOT NULL CHECK(dirty IN(0,1)), saved_at TEXT NOT NULL,
 PRIMARY KEY(account_id,layer_key),
 FOREIGN KEY(account_id,version_id,page_index) REFERENCES page_geometry(account_id,version_id,page_index),
 CHECK((scope='personal' AND owner_user_id IS NOT NULL AND performance_item_id IS NULL)
    OR (scope='team' AND owner_user_id IS NULL AND performance_item_id IS NOT NULL))
);
CREATE UNIQUE INDEX personal_layer_identity ON ink_pages(account_id,owner_user_id,version_id,page_index) WHERE scope='personal';
CREATE UNIQUE INDEX team_layer_identity ON ink_pages(account_id,performance_item_id,version_id,page_index) WHERE scope='team';
CREATE TABLE ink_history (
 account_id TEXT NOT NULL, layer_key TEXT NOT NULL, local_generation INTEGER NOT NULL,
 native_data BLOB NOT NULL, saved_at TEXT NOT NULL,
 PRIMARY KEY(account_id,layer_key,local_generation),
 FOREIGN KEY(account_id,layer_key) REFERENCES ink_pages(account_id,layer_key)
);
CREATE TABLE private_outbox (
 account_id TEXT NOT NULL REFERENCES local_accounts(account_id), command_id TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN('personal_ink','personal_preference')),
 layer_key TEXT, local_generation INTEGER, base_server_revision INTEGER NOT NULL CHECK(base_server_revision>=0),
 payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
 state TEXT NOT NULL CHECK(state IN('pending','retry','conflict','synced','blocked')),
 PRIMARY KEY(account_id,command_id),
 FOREIGN KEY(account_id,layer_key) REFERENCES ink_pages(account_id,layer_key),
 CHECK(kind!='personal_ink' OR (layer_key IS NOT NULL AND local_generation IS NOT NULL))
);
CREATE UNIQUE INDEX private_outbox_generation ON private_outbox(account_id,layer_key,local_generation) WHERE kind='personal_ink';
CREATE TABLE asset_cache (
 account_id TEXT NOT NULL REFERENCES local_accounts(account_id), asset_id TEXT NOT NULL,
 sha256 TEXT NOT NULL CHECK(length(sha256)=64), relative_path TEXT NOT NULL,
 expected_bytes INTEGER NOT NULL CHECK(expected_bytes>0), downloaded_bytes INTEGER NOT NULL CHECK(downloaded_bytes>=0),
 state TEXT NOT NULL CHECK(state IN('not_started','downloading','verifying','ready','failed')),
 verified_at TEXT, pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN(0,1)),
 PRIMARY KEY(account_id,asset_id),
 CHECK(state!='ready' OR (verified_at IS NOT NULL AND downloaded_bytes=expected_bytes))
);
CREATE TABLE download_manifests (
 account_id TEXT NOT NULL REFERENCES local_accounts(account_id), manifest_id TEXT NOT NULL,
 setlist_id TEXT NOT NULL, setlist_revision INTEGER NOT NULL, created_at TEXT NOT NULL,
 PRIMARY KEY(account_id,manifest_id)
);
CREATE TABLE manifest_items (
 account_id TEXT NOT NULL, manifest_id TEXT NOT NULL, asset_id TEXT NOT NULL,
 reason TEXT NOT NULL CHECK(reason IN('team_chart','preferred_chart','standby_chart','team_preview')),
 PRIMARY KEY(account_id,manifest_id,asset_id),
 FOREIGN KEY(account_id,manifest_id) REFERENCES download_manifests(account_id,manifest_id),
 FOREIGN KEY(account_id,asset_id) REFERENCES asset_cache(account_id,asset_id)
);
CREATE TABLE personal_preferences (
 account_id TEXT NOT NULL, song_id TEXT NOT NULL, preferred_version_id TEXT NOT NULL,
 PRIMARY KEY(account_id,song_id),
 FOREIGN KEY(account_id,preferred_version_id,song_id) REFERENCES chart_versions(account_id,version_id,song_id)
);
CREATE TABLE view_state (
 account_id TEXT NOT NULL REFERENCES local_accounts(account_id), context_id TEXT NOT NULL,
 version_id TEXT NOT NULL, page_index INTEGER NOT NULL CHECK(page_index>=0),
 last_acknowledged_call_id TEXT, performance_key TEXT,
 PRIMARY KEY(account_id,context_id),
 FOREIGN KEY(account_id,version_id,page_index) REFERENCES page_geometry(account_id,version_id,page_index)
);
PRAGMA user_version = 1;
COMMIT;
