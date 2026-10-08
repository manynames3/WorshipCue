#!/usr/bin/env python3
"""Verify handoff artifacts/contract examples/local schema, NOT the unbuilt app."""
from __future__ import annotations
import copy
import hashlib
import json
import sqlite3
import sys
import unittest
from pathlib import Path

try:
    from jsonschema import Draft202012Validator, FormatChecker, ValidationError
except ImportError:
    raise SystemExit('Install verification dependency: python3 -m pip install -r scripts/requirements.txt')

ROOT = Path(__file__).resolve().parents[1]

def load(path: str):
    return json.loads((ROOT / path).read_text(encoding='utf-8'))

def validator(name: str):
    schema = load(f'contracts/{name}.schema.json')
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema, format_checker=FormatChecker())

def database() -> sqlite3.Connection:
    db = sqlite3.connect(':memory:')
    db.executescript((ROOT / 'db/local_cache_v1.sql').read_text())
    db.execute("INSERT INTO local_accounts VALUES ('acct','user1','church1')")
    for version, song, number in [('v1','songA',1),('v2','songA',2),('vB','songB',1)]:
        db.execute('INSERT INTO chart_versions VALUES (?,?,?,?,?,?,?)', ('acct',version,song,number,'G',2,'a'*64))
        for page in [0,1]:
            db.execute('INSERT INTO page_geometry VALUES (?,?,?,?,?,?,?,?,?)', ('acct',version,page,0,0,612,792,0,1))
    db.commit()
    return db

def ink(db, *, key='layer1', version='v1', page=0, scope='personal', owner='user1', item=None):
    db.execute('INSERT INTO ink_pages VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
               ('acct',key,version,page,scope,owner,item,1,0,b'native-shape-placeholder',1,'2026-10-07T09:00:00Z'))

class ContractTests(unittest.TestCase):
    def test_live_example(self): validator('live-call').validate(load('fixtures/sample-live-call.json'))
    def test_chart_example(self): validator('chart-version').validate(load('fixtures/sample-chart-version.json'))
    def test_team_annotation_example(self): validator('annotation-revision').validate(load('fixtures/sample-annotation-revision.json'))
    def test_personal_annotation_shape(self):
        x=load('fixtures/sample-annotation-revision.json');x.update(scope='personal',owner_user_id=x['church_id'],performance_item_id=None)
        validator('annotation-revision').validate(x)
    def test_live_payload_cannot_contain_page_command(self):
        x=load('fixtures/sample-live-call.json');x['page_index']=0
        with self.assertRaises(ValidationError): validator('live-call').validate(x)
    def test_live_payload_cannot_contain_autofollow(self):
        x=load('fixtures/sample-live-call.json');x['auto_follow']=True
        with self.assertRaises(ValidationError): validator('live-call').validate(x)
    def test_sequence_zero_rejected(self):
        x=load('fixtures/sample-live-call.json');x['sequence']=0
        with self.assertRaises(ValidationError): validator('live-call').validate(x)
    def test_invalid_key_rejected(self):
        x=load('fixtures/sample-live-call.json');x['performance_key']='H'
        with self.assertRaises(ValidationError): validator('live-call').validate(x)
    def test_team_owner_cannot_be_personal(self):
        x=load('fixtures/sample-annotation-revision.json');x['owner_user_id']=x['church_id']
        with self.assertRaises(ValidationError): validator('annotation-revision').validate(x)
    def test_personal_requires_owner(self):
        x=load('fixtures/sample-annotation-revision.json');x.update(scope='personal',owner_user_id=None,performance_item_id=None)
        with self.assertRaises(ValidationError): validator('annotation-revision').validate(x)
    def test_geometry_rejects_invalid_rotation(self):
        x=load('fixtures/sample-annotation-revision.json');x['geometry']['rotation']=45
        with self.assertRaises(ValidationError): validator('annotation-revision').validate(x)
    def test_localization_keys_exist(self):
        strings=load('contracts/ko-KR.json')
        for error in load('contracts/error-codes.json')['errors']: self.assertIn(error['message_key'],strings)
    def test_chart_page_count_matches_manifest(self):
        x=load('fixtures/sample-chart-version.json');self.assertEqual(x['page_count'],len(x['pages']))
    def test_required_documents_exist(self):
        paths=['README.md','AGENTS.md','PROJECT_STATE.md','CODEX_START_HERE.md']
        paths += [str(p.relative_to(ROOT)) for p in (ROOT/'docs').glob('*.md')]
        self.assertGreaterEqual(len(paths),20)
        for path in paths: self.assertGreater((ROOT/path).stat().st_size,100)
    def test_every_manifest_file_matches_hash_and_size(self):
        for item in load('fixtures/pdf-manifest.json')['files']:
            data=(ROOT/item['path']).read_bytes()
            self.assertEqual(len(data),item['bytes']);self.assertEqual(hashlib.sha256(data).hexdigest(),item['sha256'])
    def test_native_asset_example_is_documented_as_shape_only(self):
        self.assertIn('placeholder native/preview', (ROOT/'fixtures/README.md').read_text())

class LocalSchemaTests(unittest.TestCase):
    def setUp(self): self.db=database()
    def tearDown(self): self.db.close()
    def test_schema_version(self): self.assertEqual(self.db.execute('PRAGMA user_version').fetchone()[0],1)
    def test_foreign_keys_enabled(self): self.assertEqual(self.db.execute('PRAGMA foreign_keys').fetchone()[0],1)
    def test_page_geometry_out_of_bounds_rejected(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('INSERT INTO page_geometry VALUES (?,?,?,?,?,?,?,?,?)',('acct','v1',2,0,0,612,792,0,1))
    def test_personal_notes_stay_separate_across_versions(self):
        ink(self.db);ink(self.db,key='layer2',version='v2')
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM ink_pages').fetchone()[0],2)
    def test_duplicate_layer_identity_rejected(self):
        ink(self.db)
        with self.assertRaises(sqlite3.IntegrityError): ink(self.db,key='layer2')
    def test_personal_layer_cannot_have_team_context(self):
        with self.assertRaises(sqlite3.IntegrityError): ink(self.db,item='item1')
    def test_team_requires_occurrence(self):
        with self.assertRaises(sqlite3.IntegrityError): ink(self.db,scope='team',owner=None)
    def test_team_layers_isolated_by_occurrence(self):
        ink(self.db,scope='team',owner=None,item='item1')
        ink(self.db,key='layer2',scope='team',owner=None,item='item2')
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM ink_pages').fetchone()[0],2)
    def test_ink_requires_exact_existing_page(self):
        with self.assertRaises(sqlite3.IntegrityError): ink(self.db,page=9)
    def test_no_live_call_kind_in_retry_outbox(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('INSERT INTO private_outbox VALUES (?,?,?,?,?,?,?,?)',('acct','cmd1','live_call',None,None,0,'{}','pending'))
    def test_saved_ink_and_outbox_commit_together(self):
        self.db.execute('BEGIN');ink(self.db)
        self.db.execute('INSERT INTO private_outbox VALUES (?,?,?,?,?,?,?,?)',('acct','cmd1','personal_ink','layer1',1,0,'{}','pending'))
        self.db.commit()
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM ink_pages').fetchone()[0],1)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM private_outbox').fetchone()[0],1)
    def test_failed_transaction_rolls_back_note(self):
        self.db.execute('BEGIN');ink(self.db)
        try:
            self.db.execute('INSERT INTO private_outbox VALUES (?,?,?,?,?,?,?,?)',('acct','cmd1','live_call','layer1',1,0,'{}','pending'))
        except sqlite3.IntegrityError: self.db.rollback()
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM ink_pages').fetchone()[0],0)
    def test_partial_file_cannot_be_ready(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('INSERT INTO asset_cache VALUES (?,?,?,?,?,?,?,?,?)',('acct','a1','b'*64,'a1.pdf',100,50,'ready','now',1))
    def test_ready_file_requires_verification_time(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('INSERT INTO asset_cache VALUES (?,?,?,?,?,?,?,?,?)',('acct','a1','b'*64,'a1.pdf',100,100,'ready',None,1))
    def test_complete_verified_file_can_be_ready(self):
        self.db.execute('INSERT INTO asset_cache VALUES (?,?,?,?,?,?,?,?,?)',('acct','a1','b'*64,'a1.pdf',100,100,'ready','now',1))
        self.assertEqual(self.db.execute('SELECT state FROM asset_cache').fetchone()[0],'ready')
    def test_preferred_version_must_belong_to_song(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute('INSERT INTO personal_preferences VALUES (?,?,?)',('acct','songA','vB'))

if __name__ == '__main__':
    unittest.main(verbosity=2)
