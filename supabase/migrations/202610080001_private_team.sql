-- Additive pilot schema. Managed Auth owns identities; no role is accepted from user metadata.
create schema if not exists private;
revoke all on schema private from public;

create table public.churches (
  id uuid primary key default gen_random_uuid(), name text not null check (length(btrim(name)) between 1 and 120),
  timezone text not null, lifecycle text not null default 'active' check (lifecycle in ('active','archived')),
  created_by uuid not null references auth.users(id), created_at timestamptz not null default now()
);
create table public.teams (
  id uuid primary key default gen_random_uuid(), church_id uuid not null references public.churches(id),
  name text not null check (length(btrim(name)) between 1 and 120), unique(id,church_id)
);
create table public.memberships (
  church_id uuid not null references public.churches(id), team_id uuid not null,
  user_id uuid not null references auth.users(id), role text not null check (role in ('member','leader','admin')),
  active boolean not null default true, created_at timestamptz not null default now(),
  primary key(team_id,user_id), foreign key(team_id,church_id) references public.teams(id,church_id)
);
create index memberships_actor on public.memberships(user_id,church_id) where active;
create table public.songs (
  id uuid primary key default gen_random_uuid(), church_id uuid not null references public.churches(id),
  canonical_title text not null check (length(btrim(canonical_title)) between 1 and 160),
  normalized_title text not null, initials text not null default '', rights_note text not null default '',
  archived_at timestamptz, next_version bigint not null default 1 check(next_version between 1 and 9007199254740991),
  unique(id,church_id)
);
create table public.assets (
  id uuid primary key default gen_random_uuid(), church_id uuid not null references public.churches(id),
  owner_user_id uuid not null references auth.users(id), type text not null check(type in ('pdf','native','preview')),
  storage_key text not null unique, sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
  bytes bigint not null check(bytes > 0 and bytes <= 104857600),
  status text not null default 'staging' check(status in ('staging','verified','rejected')),
  validation jsonb, created_at timestamptz not null default now(), verified_at timestamptz,
  check(type = 'pdf' or bytes <= 2097152), unique(id,church_id)
);
create table public.chart_versions (
  id uuid primary key default gen_random_uuid(), church_id uuid not null, song_id uuid not null,
  version_number bigint not null check(version_number between 1 and 9007199254740991),
  label text not null check(length(label)<=120), written_key text check(written_key ~ '^[A-G](#|b)?m?$'),
  pdf_asset_id uuid not null, page_count integer not null check(page_count between 1 and 20), page_manifest jsonb not null,
  published_at timestamptz not null default now(), archived_at timestamptz,
  unique(song_id,version_number), unique(id,church_id), unique(id,song_id,church_id),
  foreign key(song_id,church_id) references public.songs(id,church_id),
  foreign key(pdf_asset_id,church_id) references public.assets(id,church_id),
  check(jsonb_typeof(page_manifest)='array' and jsonb_array_length(page_manifest)=page_count)
);
create table public.setlists (
  id uuid primary key default gen_random_uuid(), church_id uuid not null, team_id uuid not null,
  title text not null check(length(btrim(title)) between 1 and 160), service_time timestamptz,
  timezone text not null, revision bigint not null default 0 check(revision between 0 and 9007199254740991),
  state text not null default 'draft' check(state in ('draft','published','archived')),
  unique(id,church_id), foreign key(team_id,church_id) references public.teams(id,church_id)
);
create table public.performance_items (
  id uuid primary key, church_id uuid not null, setlist_id uuid not null, song_id uuid not null,
  team_chart_version_id uuid not null, performance_key text not null check(performance_key ~ '^[A-G](#|b)?m?$'),
  position integer, kind text not null check(kind in ('planned','standby','ad_hoc')), revision bigint not null default 1,
  active boolean not null default true, unique(id,church_id),
  foreign key(setlist_id,church_id) references public.setlists(id,church_id),
  foreign key(song_id,church_id) references public.songs(id,church_id),
  foreign key(team_chart_version_id,song_id,church_id) references public.chart_versions(id,song_id,church_id),
  check((kind='planned' and position>=0) or (kind<>'planned' and position is null))
);
create unique index performance_item_position on public.performance_items(setlist_id,position) where active and kind='planned';
create table public.personal_preferences (
  user_id uuid not null references auth.users(id), church_id uuid not null, song_id uuid not null,
  preferred_version_id uuid not null, revision bigint not null default 1,
  primary key(user_id,song_id), foreign key(preferred_version_id,song_id,church_id) references public.chart_versions(id,song_id,church_id)
);
create table public.editor_leases (
  setlist_id uuid primary key, church_id uuid not null, controller_user_id uuid references auth.users(id),
  device_id uuid, epoch bigint not null default 0 check(epoch between 0 and 9007199254740991),
  expires_at timestamptz not null default '-infinity',
  foreign key(setlist_id,church_id) references public.setlists(id,church_id)
);
create table public.live_sessions (
  id uuid primary key default gen_random_uuid(), church_id uuid not null, setlist_id uuid not null,
  status text not null default 'LIVE' check(status in ('LIVE','ENDED')),
  latest_sequence bigint not null default 0 check(latest_sequence between 0 and 9007199254740991), latest_call_id uuid,
  state_revision bigint not null default 1, created_at timestamptz not null default now(), ended_at timestamptz,
  unique(id,church_id), foreign key(setlist_id,church_id) references public.setlists(id,church_id)
);
create unique index one_live_session on public.live_sessions(setlist_id) where status='LIVE';
create table public.live_calls (
  id uuid primary key default gen_random_uuid(), church_id uuid not null, session_id uuid not null,
  sequence bigint not null check(sequence between 1 and 9007199254740991), command_id uuid not null,
  performance_item_id uuid not null, song_id uuid not null, team_chart_version_id uuid not null,
  performance_key text not null check(performance_key ~ '^[A-G](#|b)?m?$'), actor_user_id uuid not null references auth.users(id),
  controller_epoch bigint not null, payload_digest text not null, created_at timestamptz not null default now(),
  unique(session_id,sequence), unique(session_id,command_id), unique(id,session_id),
  foreign key(session_id,church_id) references public.live_sessions(id,church_id),
  foreign key(performance_item_id,church_id) references public.performance_items(id,church_id),
  foreign key(team_chart_version_id,song_id,church_id) references public.chart_versions(id,song_id,church_id)
);
alter table public.live_sessions add constraint latest_call_belongs_to_session
  foreign key(latest_call_id,id) references public.live_calls(id,session_id);
create table public.participants (
  session_id uuid not null references public.live_sessions(id), user_id uuid not null references auth.users(id), device_id uuid not null,
  last_seen_at timestamptz not null default now(), latest_received_call_id uuid, last_opened_call_id uuid,
  selected_chart_version_id uuid references public.chart_versions(id), rendered_at timestamptz,
  primary key(session_id,user_id,device_id),
  foreign key(latest_received_call_id,session_id) references public.live_calls(id,session_id),
  foreign key(last_opened_call_id,session_id) references public.live_calls(id,session_id)
);
create table public.annotation_layers (
  id uuid primary key default gen_random_uuid(), church_id uuid not null, chart_version_id uuid not null,
  page_index integer not null check(page_index>=0), scope text not null check(scope in ('personal','team')),
  owner_user_id uuid references auth.users(id), performance_item_id uuid,
  check((scope='personal' and owner_user_id is not null and performance_item_id is null)
     or (scope='team' and owner_user_id is null and performance_item_id is not null)),
  foreign key(chart_version_id,church_id) references public.chart_versions(id,church_id),
  foreign key(performance_item_id,church_id) references public.performance_items(id,church_id)
);
create unique index one_personal_layer on public.annotation_layers(owner_user_id,chart_version_id,page_index) where scope='personal';
create unique index one_team_layer on public.annotation_layers(performance_item_id,chart_version_id,page_index) where scope='team';
create table public.annotation_revisions (
  id uuid primary key default gen_random_uuid(), layer_id uuid not null references public.annotation_layers(id),
  parent_revision bigint not null check(parent_revision>=0), server_revision bigint not null check(server_revision between 1 and 9007199254740991),
  command_id uuid not null, native_asset_id uuid not null references public.assets(id), preview_asset_id uuid not null references public.assets(id),
  geometry jsonb not null, editor_user_id uuid not null references auth.users(id), device_id uuid not null,
  payload_digest text not null, created_at timestamptz not null default now(),
  unique(layer_id,server_revision), unique(layer_id,command_id), unique(id,layer_id,server_revision)
);
create table public.annotation_heads (
  layer_id uuid primary key references public.annotation_layers(id), revision_id uuid not null, revision_number bigint not null,
  foreign key(revision_id,layer_id,revision_number) references public.annotation_revisions(id,layer_id,server_revision)
);
create table public.guest_grants (
  user_id uuid not null references auth.users(id), church_id uuid not null, setlist_id uuid not null,
  expires_at timestamptz not null, revoked_at timestamptz, primary key(user_id,setlist_id),
  foreign key(setlist_id,church_id) references public.setlists(id,church_id)
);
create table public.invitations (
  id uuid primary key default gen_random_uuid(), token_hash text not null unique check(token_hash ~ '^[0-9a-f]{64}$'),
  church_id uuid not null, team_id uuid not null, setlist_id uuid,
  permitted_role text not null check(permitted_role in ('member','leader','guest')),
  inviter uuid not null references auth.users(id), expires_at timestamptz not null,
  max_uses integer not null check(max_uses between 1 and 50), used_count integer not null default 0,
  revoked_at timestamptz, check((permitted_role='guest')=(setlist_id is not null)),
  foreign key(team_id,church_id) references public.teams(id,church_id),
  foreign key(setlist_id,church_id) references public.setlists(id,church_id)
);
create table private.invitation_redemptions (
  invitation_id uuid not null references public.invitations(id), user_id uuid not null references auth.users(id),
  primary key(invitation_id,user_id)
);
create table private.rate_limits (actor_id uuid not null, operation text not null, window_start timestamptz not null, uses integer not null, primary key(actor_id,operation));
create table private.command_receipts (actor_id uuid not null, operation text not null, command_id uuid not null, payload_digest text not null, receipt jsonb not null, primary key(actor_id,operation,command_id));
create table public.audit_events (
  id uuid primary key default gen_random_uuid(), actor_id uuid not null, church_id uuid not null, resource_id uuid not null,
  action text not null, created_at timestamptz not null default now()
);

create function private.fail(code text, details jsonb default '{}'::jsonb) returns void language plpgsql set search_path='' as $$
begin
  raise exception using errcode='P0001', message=code,
    detail=jsonb_build_object('code',code,'message_key',case code when 'REVISION_CONFLICT' then 'notes.conflict' when 'STALE_CONTROLLER' then 'notes.leaseLost'
      when 'STALE_CALL' then 'live.staleTap' when 'IDEMPOTENCY_CONFLICT' then 'live.staleTap' when 'FILE_NOT_READY' then 'download.missing'
      when 'HASH_MISMATCH' then 'download.failure' when 'INVALID_PAGE' then 'download.failure' when 'INVALID_KEY' then 'key.unknown'
      when 'SESSION_ENDED' then 'live.ended' when 'RATE_LIMITED' then 'download.retry' else 'permission.denied' end,
      'retryable',code in ('AUTH_REQUIRED','RATE_LIMITED','FILE_NOT_READY','HASH_MISMATCH'), 'correlation_id',gen_random_uuid(),'details',details)::text;
end $$;
create function private.actor() returns uuid language plpgsql stable security definer set search_path='' as $$
declare u uuid:=auth.uid(); begin if u is null then perform private.fail('AUTH_REQUIRED'); end if; return u; end $$;
create function private.is_guest() returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((select is_anonymous from auth.users where id=auth.uid()),true)
$$;
create function private.member_of(c uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.memberships where church_id=c and user_id=auth.uid() and active) and not private.is_guest()
$$;
create function private.leader_of(c uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.memberships where church_id=c and user_id=auth.uid() and active and role in ('leader','admin')) and not private.is_guest()
$$;
create function private.admin_of(c uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.memberships where church_id=c and user_id=auth.uid() and active and role='admin') and not private.is_guest()
$$;
create function private.read_setlist(s uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.setlists sl where sl.id=s and (
    exists(select 1 from public.memberships m where m.church_id=sl.church_id and m.user_id=auth.uid() and m.active and (m.team_id=sl.team_id or m.role='admin') and not private.is_guest())
    or exists(select 1 from public.guest_grants g where g.setlist_id=sl.id and g.user_id=auth.uid() and g.revoked_at is null and g.expires_at>clock_timestamp())))
$$;
create function private.edit_setlist(s uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.setlists sl join public.memberships m on m.church_id=sl.church_id
    where sl.id=s and m.user_id=auth.uid() and m.active and m.role in ('leader','admin') and (m.team_id=sl.team_id or m.role='admin')) and not private.is_guest()
$$;
create function private.read_chart(v uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.chart_versions cv where cv.id=v and (private.member_of(cv.church_id)
    or exists(select 1 from public.performance_items i where i.team_chart_version_id=cv.id and i.active and i.kind in ('planned','standby') and private.read_setlist(i.setlist_id))
    or exists(select 1 from public.live_calls lc join public.live_sessions ls on ls.id=lc.session_id where lc.team_chart_version_id=cv.id and private.read_setlist(ls.setlist_id))))
$$;
create function private.read_layer(l uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.annotation_layers al where al.id=l and
    ((al.scope='personal' and al.owner_user_id=auth.uid() and private.member_of(al.church_id))
    or (al.scope='team' and private.read_chart(al.chart_version_id) and exists(select 1 from public.performance_items pi where pi.id=al.performance_item_id and private.read_setlist(pi.setlist_id)))))
$$;
create function private.read_asset(a uuid) returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from public.assets x where x.id=a and (
    (x.owner_user_id=auth.uid() and private.member_of(x.church_id))
    or (x.status='verified' and x.type='pdf' and exists(select 1 from public.chart_versions cv where cv.pdf_asset_id=x.id and private.read_chart(cv.id)))
    or (x.status='verified' and x.type in ('native','preview') and exists(select 1 from public.annotation_revisions ar where (ar.native_asset_id=x.id or ar.preview_asset_id=x.id) and private.read_layer(ar.layer_id)))))
$$;
create function private.rate_limit(op text, max_uses integer, seconds integer) returns void language plpgsql security definer set search_path='' as $$
declare n integer; begin
  insert into private.rate_limits values(private.actor(),op,now(),1)
  on conflict(actor_id,operation) do update set
    uses=case when private.rate_limits.window_start<now()-make_interval(secs=>seconds) then 1 else private.rate_limits.uses+1 end,
    window_start=case when private.rate_limits.window_start<now()-make_interval(secs=>seconds) then now() else private.rate_limits.window_start end
  returning uses into n;
  if n>max_uses then perform private.fail('RATE_LIMITED'); end if;
end $$;
create function private.geometry(g jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare r jsonb; begin
  r:=jsonb_build_object('schema_version',coalesce(g->'schema_version',g->'schemaVersion'),
    'crop_x',coalesce(g->'crop_x',g->'cropX'),'crop_y',coalesce(g->'crop_y',g->'cropY'),
    'crop_width',coalesce(g->'crop_width',g->'cropWidth'),'crop_height',coalesce(g->'crop_height',g->'cropHeight'),'rotation',g->'rotation');
  if r->>'schema_version' is distinct from '1' or jsonb_typeof(r->'crop_x') is distinct from 'number' or jsonb_typeof(r->'crop_y') is distinct from 'number'
    or jsonb_typeof(r->'crop_width') is distinct from 'number' or jsonb_typeof(r->'crop_height') is distinct from 'number'
    or jsonb_typeof(r->'rotation') is distinct from 'number' then perform private.fail('INVALID_PAGE'); end if;
  if not (r->>'crop_width')::numeric>0 or not (r->>'crop_height')::numeric>0
    or (r->>'rotation')::numeric not in (0,90,180,270)
    or abs((r->>'crop_x')::numeric)>100000 or abs((r->>'crop_y')::numeric)>100000
    or (r->>'crop_width')::numeric>100000 or (r->>'crop_height')::numeric>100000 then perform private.fail('INVALID_PAGE'); end if;
  return r;
end $$;
create function private.manifest(pages jsonb) returns jsonb language plpgsql immutable set search_path='' as $$
declare result jsonb:='[]'; g jsonb; begin
  if jsonb_typeof(pages) is distinct from 'array' or jsonb_array_length(pages) not between 1 and 200 then perform private.fail('INVALID_PAGE'); end if;
  for g in select value from jsonb_array_elements(pages) loop result:=result||jsonb_build_array(private.geometry(g)); end loop; return result;
end $$;
create function private.digest(p jsonb) returns text language sql immutable set search_path='' as $$ select encode(sha256(convert_to(p::text,'UTF8')),'hex') $$;
create function private.receipt(op text, command uuid, payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare r private.command_receipts; begin
  select * into r from private.command_receipts where actor_id=private.actor() and operation=op and command_id=command;
  if found then if r.payload_digest<>private.digest(payload) then perform private.fail('IDEMPOTENCY_CONFLICT'); end if; return r.receipt; end if;
  return null;
end $$;
create function private.remember(op text, command uuid, payload jsonb, receipt jsonb) returns void language sql security definer set search_path='' as $$
  insert into private.command_receipts values(private.actor(),op,command,private.digest(payload),receipt)
$$;
create function private.asset_receipt(a uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('schema_version',1,'id',id,'asset_id',id,'church_id',church_id,'type',type,'storage_key',storage_key,
    'sha256',sha256,'bytes',bytes,'status',status,'page_count',validation->'page_count','page_manifest',validation->'pages') from public.assets where id=a
$$;
create function private.chart_receipt(v uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('schema_version',1,'id',cv.id,'chart_version_id',cv.id,'church_id',cv.church_id,'song_id',cv.song_id,
    'version_number',cv.version_number,'label',cv.label,'written_key',cv.written_key,'pdf_asset_id',a.id,'pdf_sha256',a.sha256,
    'pdf_bytes',a.bytes,'page_count',cv.page_count,'page_manifest',cv.page_manifest,'pages',cv.page_manifest)
  from public.chart_versions cv join public.assets a on a.id=cv.pdf_asset_id where cv.id=v
$$;
create function private.call_receipt(c uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('schema_version',1,'id',id,'call_id',id,'session_id',session_id,'sequence',sequence,'command_id',command_id,
    'performance_item_id',performance_item_id,'song_id',song_id,'team_chart_version_id',team_chart_version_id,
    'performance_key',performance_key,'controller_epoch',controller_epoch,'created_at',created_at) from public.live_calls where id=c
$$;
create function private.annotation_receipt(r uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('schema_version',1,'revision_id',ar.id,'layer_id',al.id,'church_id',al.church_id,
    'chart_version_id',al.chart_version_id,'page_index',al.page_index,'scope',al.scope,'owner_user_id',al.owner_user_id,'performance_item_id',al.performance_item_id,
    'revision_number',ar.server_revision,'parent_revision',ar.parent_revision,'command_id',ar.command_id,'native_format','pencilkit',
    'native_asset_id',n.id,'native_sha256',n.sha256,'native_bytes',n.bytes,'native_storage_key',n.storage_key,
    'preview_asset_id',p.id,'preview_sha256',p.sha256,'preview_bytes',p.bytes,'preview_storage_key',p.storage_key,'geometry',ar.geometry,'created_at',ar.created_at)
  from public.annotation_revisions ar join public.annotation_layers al on al.id=ar.layer_id join public.assets n on n.id=ar.native_asset_id
    join public.assets p on p.id=ar.preview_asset_id where ar.id=r
$$;

create function public.create_church_and_default_team(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c uuid; t uuid; u uuid:=private.actor(); begin
  if private.is_guest() then perform private.fail('ACCESS_REVOKED'); end if;
  if not exists(select 1 from pg_catalog.pg_timezone_names where name=p->>'timezone') then perform private.fail('INVALID_INPUT'); end if;
  perform private.rate_limit('create_church',3,86400);
  insert into public.churches(name,timezone,created_by) values(p->>'display_name',p->>'timezone',u) returning id into c;
  insert into public.teams(church_id,name) values(c,'Worship Team') returning id into t;
  insert into public.memberships values(c,t,u,'admin',true,now());
  return jsonb_build_object('schema_version',1,'church_id',c,'team_id',t,'role','admin');
end $$;
create function public.create_song(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c uuid:=(p->>'church_id')::uuid; command uuid:=(p->>'command_id')::uuid; v uuid; r jsonb; title text:=coalesce(p->>'canonical_title',p->>'title'); begin
  perform private.actor(); if not private.leader_of(c) then perform private.fail('ACCESS_REVOKED'); end if;
  perform pg_advisory_xact_lock(hashtextextended(private.actor()::text||'song'||command::text,0));
  r:=private.receipt('create_song',command,p); if r is not null then return r; end if;
  insert into public.songs(church_id,canonical_title,normalized_title,rights_note) values(c,title,lower(btrim(title)),coalesce(p->>'rights_note','')) returning id into v;
  r:=jsonb_build_object('schema_version',1,'id',v,'song_id',v,'church_id',c,'canonical_title',title);
  perform private.remember('create_song',command,p,r); return r;
end $$;
create function public.stage_asset(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c uuid:=(p->>'church_id')::uuid; u uuid:=private.actor(); a uuid:=gen_random_uuid(); kind text:=p->>'type'; suffix text; begin
  if not private.member_of(c) or (kind='pdf' and not private.leader_of(c)) then perform private.fail('ASSET_NOT_AUTHORIZED'); end if;
  perform private.rate_limit('stage_asset',100,60);
  suffix:=case kind when 'pdf' then 'pdf' when 'native' then 'drawing' when 'preview' then 'png' else null end;
  if suffix is null then perform private.fail('INVALID_INPUT'); end if;
  insert into public.assets(id,church_id,owner_user_id,type,storage_key,sha256,bytes)
    values(a,c,u,kind,c::text||'/'||u::text||'/'||a::text||'.'||suffix,p->>'sha256',(p->>'expected_bytes')::bigint);
  return private.asset_receipt(a);
end $$;
-- Only the Edge finalizer may submit server-derived geometry/content validation.
create function public.finalize_asset(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.assets; validated jsonb:=p->'validation'; begin
  select * into a from public.assets where id=(p->>'asset_id')::uuid for update;
  if not found or a.owner_user_id is distinct from (p->>'actor_id')::uuid
    or not exists(select 1 from public.memberships where user_id=a.owner_user_id and church_id=a.church_id and active)
    or not exists(select 1 from auth.users where id=a.owner_user_id and not is_anonymous)
    then perform private.fail('ASSET_NOT_AUTHORIZED'); end if;
  if a.sha256 is distinct from p->>'sha256' or a.bytes is distinct from (p->>'expected_bytes')::bigint then perform private.fail('HASH_MISMATCH'); end if;
  if a.status='verified' then return private.asset_receipt(a.id); end if;
  if a.status<>'staging' then perform private.fail('FILE_NOT_READY'); end if;
  if not exists(select 1 from storage.objects where bucket_id='worshipcue-private' and name=a.storage_key) then perform private.fail('FILE_NOT_READY'); end if;
  if a.type='pdf' then
    if validated->>'kind' is distinct from 'pdf' or coalesce((validated->>'page_count')::integer,0) not between 1 and 200
      or private.manifest(validated->'pages')<>validated->'pages'
      or jsonb_array_length(validated->'pages')<>(validated->>'page_count')::integer then perform private.fail('INVALID_PAGE'); end if;
  elsif a.type='native' then
    if validated->>'kind' is distinct from 'pencilkit-bounded' then perform private.fail('INVALID_INPUT'); end if;
  else
    if validated->>'kind' is distinct from 'png-rgba' or coalesce((validated->>'width')::integer,0) not between 1 and 8192
      or coalesce((validated->>'height')::integer,0) not between 1 and 8192
      or (validated->>'width')::bigint*(validated->>'height')::bigint>16777216 then perform private.fail('INVALID_INPUT'); end if;
  end if;
  update public.assets set status='verified',validation=validated,verified_at=now() where id=a.id;
  return private.asset_receipt(a.id);
end $$;
create function public.publish_chart_version(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.songs; a public.assets; v uuid; r jsonb; pages jsonb; command uuid:=(p->>'command_id')::uuid; begin
  perform private.actor(); select * into s from public.songs where id=(p->>'song_id')::uuid for update;
  if not found or not private.leader_of(s.church_id) then perform private.fail('ACCESS_REVOKED'); end if;
  r:=private.receipt('publish_chart_version',command,p); if r is not null then return r; end if;
  select * into a from public.assets where id=(p->>'verified_pdf_asset_id')::uuid;
  if not found or a.status<>'verified' or a.type<>'pdf' or a.church_id<>s.church_id then perform private.fail('FILE_NOT_READY'); end if;
  pages:=private.manifest(p->'page_manifest');
  if jsonb_array_length(pages)>20 or pages<>a.validation->'pages' then perform private.fail('INVALID_PAGE'); end if;
  if p->>'written_key' is not null and p->>'written_key' !~ '^[A-G](#|b)?m?$' then perform private.fail('INVALID_KEY'); end if;
  insert into public.chart_versions(church_id,song_id,version_number,label,written_key,pdf_asset_id,page_count,page_manifest)
    values(s.church_id,s.id,s.next_version,coalesce(p->>'label',''),p->>'written_key',a.id,jsonb_array_length(pages),pages) returning id into v;
  update public.songs set next_version=next_version+1 where id=s.id;
  r:=private.chart_receipt(v); perform private.remember('publish_chart_version',command,p,r);
  insert into public.audit_events(actor_id,church_id,resource_id,action) values(private.actor(),s.church_id,v,'chart_published'); return r;
end $$;
create function public.create_setlist(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c uuid:=(p->>'church_id')::uuid; t uuid:=(p->>'team_id')::uuid; s uuid; command uuid:=(p->>'command_id')::uuid; r jsonb; begin
  perform private.actor(); if not private.leader_of(c) or not exists(select 1 from public.memberships where church_id=c and user_id=auth.uid() and active and role in ('leader','admin') and (team_id=t or role='admin')) then perform private.fail('ACCESS_REVOKED'); end if;
  perform pg_advisory_xact_lock(hashtextextended(private.actor()::text||'setlist'||command::text,0));
  r:=private.receipt('create_setlist',command,p); if r is not null then return r; end if;
  if not exists(select 1 from pg_catalog.pg_timezone_names where name=p->>'timezone') then perform private.fail('INVALID_INPUT'); end if;
  insert into public.setlists(church_id,team_id,title,timezone,service_time) values(c,t,p->>'title',p->>'timezone',(p->>'service_time')::timestamptz) returning id into s;
  insert into public.editor_leases(setlist_id,church_id) values(s,c);
  r:=jsonb_build_object('schema_version',1,'id',s,'setlist_id',s,'church_id',c,'team_id',t,'revision',0,'title',p->>'title');
  perform private.remember('create_setlist',command,p,r); return r;
end $$;
create function public.save_setlist(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.setlists; command uuid:=(p->>'command_id')::uuid; r jsonb; item jsonb; old public.performance_items; kind text; pos integer; begin
  perform private.actor(); select * into s from public.setlists where id=(p->>'setlist_id')::uuid for update;
  if not found or not private.edit_setlist(s.id) then perform private.fail('ACCESS_REVOKED'); end if;
  r:=private.receipt('save_setlist',command,p); if r is not null then return r; end if;
  if jsonb_typeof(p->'base_revision') is distinct from 'number' or (p->>'base_revision')::numeric<0
    or s.revision is distinct from (p->>'base_revision')::bigint then perform private.fail('REVISION_CONFLICT',jsonb_build_object('revision',s.revision)); end if;
  if jsonb_typeof(p->'items') is distinct from 'array' or jsonb_array_length(p->'items')>200 then perform private.fail('INVALID_INPUT'); end if;
  if (select count(*) from jsonb_array_elements(p->'items'))<>(select count(distinct value->>'id') from jsonb_array_elements(p->'items')) then perform private.fail('INVALID_INPUT'); end if;
  update public.performance_items set active=false where setlist_id=s.id and public.performance_items.kind in ('planned','standby');
  for item in select value from jsonb_array_elements(p->'items') loop
    kind:=item->>'kind'; pos:=(item->>'position')::integer;
    if kind not in ('planned','standby') then perform private.fail('INVALID_INPUT'); end if;
    if item->>'performance_key' is null or item->>'performance_key' !~ '^[A-G](#|b)?m?$' then perform private.fail('INVALID_KEY'); end if;
    if not exists(select 1 from public.chart_versions cv join public.assets a on a.id=cv.pdf_asset_id where cv.id=(item->>'team_chart_version_id')::uuid
      and cv.song_id=(item->>'song_id')::uuid and cv.church_id=s.church_id and a.status='verified') then perform private.fail('FILE_NOT_READY'); end if;
    select * into old from public.performance_items where id=(item->>'id')::uuid;
    if found and (old.setlist_id<>s.id or old.song_id<>(item->>'song_id')::uuid or old.kind='ad_hoc') then perform private.fail('ACCESS_REVOKED'); end if;
    insert into public.performance_items(id,church_id,setlist_id,song_id,team_chart_version_id,performance_key,position,kind)
      values((item->>'id')::uuid,s.church_id,s.id,(item->>'song_id')::uuid,(item->>'team_chart_version_id')::uuid,item->>'performance_key',pos,kind)
    on conflict(id) do update set team_chart_version_id=excluded.team_chart_version_id,performance_key=excluded.performance_key,
      position=excluded.position,kind=excluded.kind,revision=public.performance_items.revision+1,active=true;
  end loop;
  update public.setlists set revision=revision+1,state='published',title=coalesce(p->>'title',title) where id=s.id returning revision into s.revision;
  r:=jsonb_build_object('schema_version',1,'id',s.id,'setlist_id',s.id,'revision',s.revision);
  perform private.remember('save_setlist',command,p,r); return r;
end $$;
create function public.set_personal_preference(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare v public.chart_versions; r bigint; begin
  perform private.actor(); select * into v from public.chart_versions where id=(p->>'preferred_version_id')::uuid;
  if not found or not private.member_of(v.church_id) or v.song_id<>(p->>'song_id')::uuid then perform private.fail('ACCESS_REVOKED'); end if;
  insert into public.personal_preferences values(private.actor(),v.church_id,v.song_id,v.id,1)
  on conflict(user_id,song_id) do update set preferred_version_id=excluded.preferred_version_id,revision=public.personal_preferences.revision+1 returning revision into r;
  return jsonb_build_object('schema_version',1,'song_id',v.song_id,'preferred_version_id',v.id,'revision',r);
end $$;
create function public.create_invitation(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c uuid:=(p->>'church_id')::uuid; t uuid:=(p->>'team_id')::uuid; s uuid:=(p->>'setlist_id')::uuid; token text:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
  expiry timestamptz:=(p->>'expires_at')::timestamptz; i uuid; role text:=p->>'permitted_role'; begin
  perform private.actor(); if not private.admin_of(c) then perform private.fail('ACCESS_REVOKED'); end if;
  if expiry<=now() or expiry>now()+interval '7 days' or role not in ('member','leader','guest')
    or (s is not null and not exists(select 1 from public.setlists where id=s and church_id=c and team_id=t)) then perform private.fail('INVALID_INPUT'); end if;
  perform private.rate_limit('create_invitation',20,3600);
  insert into public.invitations(token_hash,church_id,team_id,setlist_id,permitted_role,inviter,expires_at,max_uses)
    values(encode(sha256(convert_to(token,'UTF8')),'hex'),c,t,s,role,private.actor(),expiry,coalesce((p->>'max_uses')::integer,1)) returning id into i;
  return jsonb_build_object('schema_version',1,'invitation_id',i,'token',token,'expires_at',expiry,'permitted_role',role,'installation_required',true);
end $$;
create function public.revoke_invitation(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.invitations; begin
  perform private.actor(); select * into i from public.invitations where id=(p->>'invitation_id')::uuid for update;
  if not found or not private.admin_of(i.church_id) then perform private.fail('ACCESS_REVOKED'); end if;
  update public.invitations set revoked_at=now() where id=i.id;
  return jsonb_build_object('schema_version',1,'invitation_id',i.id,'revoked',true);
end $$;
create function public.revoke_guest_grant(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.setlists; begin
  perform private.actor(); select * into s from public.setlists where id=(p->>'setlist_id')::uuid;
  if not found or not private.admin_of(s.church_id) then perform private.fail('ACCESS_REVOKED'); end if;
  update public.guest_grants set revoked_at=now() where setlist_id=s.id and user_id=(p->>'user_id')::uuid;
  return jsonb_build_object('schema_version',1,'revoked',true);
end $$;
-- The Edge performs managed Auth validation, then consumes attempts in a separate transaction.
create function public.consume_invitation_attempt(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare n integer; actor uuid:=(p->>'actor_id')::uuid; begin
  if not exists(select 1 from auth.users where id=actor) then perform private.fail('AUTH_REQUIRED'); end if;
  insert into private.rate_limits values(actor,'redeem_invitation',now(),1)
  on conflict(actor_id,operation) do update set uses=case when private.rate_limits.window_start<now()-interval '1 minute' then 1 else private.rate_limits.uses+1 end,
    window_start=case when private.rate_limits.window_start<now()-interval '1 minute' then now() else private.rate_limits.window_start end returning uses into n;
  return jsonb_build_object('allowed',n<=10,'retry_after',60);
end $$;
create function public.redeem_invitation(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare i public.invitations; u uuid:=(p->>'actor_id')::uuid; anon boolean; begin
  select is_anonymous into anon from auth.users where id=u; if not found then perform private.fail('AUTH_REQUIRED'); end if;
  select * into i from public.invitations where token_hash=p->>'token_hash' for update;
  if not found or i.revoked_at is not null or i.expires_at<=clock_timestamp() then perform private.fail('ACCESS_REVOKED'); end if;
  if exists(select 1 from private.invitation_redemptions where invitation_id=i.id and user_id=u) then
    return jsonb_build_object('schema_version',1,'church_id',i.church_id,'team_id',i.team_id,'setlist_id',i.setlist_id,'role',i.permitted_role,'expires_at',i.expires_at);
  end if;
  if i.used_count>=i.max_uses or (anon and i.permitted_role<>'guest') then perform private.fail('ACCESS_REVOKED'); end if;
  if i.permitted_role='guest' then
    insert into public.guest_grants values(u,i.church_id,i.setlist_id,i.expires_at,null)
    on conflict(user_id,setlist_id) do update set expires_at=excluded.expires_at,revoked_at=null;
  else
    insert into public.memberships(church_id,team_id,user_id,role) values(i.church_id,i.team_id,u,i.permitted_role)
    on conflict(team_id,user_id) do update set active=true,role=case when public.memberships.role='admin' then 'admin' when public.memberships.role='leader' then 'leader' else excluded.role end;
  end if;
  insert into private.invitation_redemptions values(i.id,u);
  update public.invitations set used_count=used_count+1 where id=i.id;
  return jsonb_build_object('schema_version',1,'church_id',i.church_id,'team_id',i.team_id,'setlist_id',i.setlist_id,'role',i.permitted_role,'expires_at',i.expires_at);
end $$;

create function private.lease_receipt(s uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('schema_version',1,'setlist_id',setlist_id,'controller_user_id',controller_user_id,
    'device_id',device_id,'epoch',epoch,'expires_at',expires_at,'active',expires_at>clock_timestamp() and controller_user_id is not null)
  from public.editor_leases where setlist_id=s
$$;
create function private.assert_controller(s uuid, device uuid, expected bigint) returns void language plpgsql security definer set search_path='' as $$
declare l public.editor_leases; begin
  perform private.actor();
  select * into l from public.editor_leases where setlist_id=s for update;
  if not found or not private.edit_setlist(s) or l.controller_user_id is distinct from private.actor()
    or l.device_id is distinct from device or l.epoch is distinct from expected or l.expires_at<=clock_timestamp() then perform private.fail('STALE_CONTROLLER'); end if;
end $$;
create function public.acquire_editor(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s uuid:=(p->>'setlist_id')::uuid; l public.editor_leases; device uuid:=(p->>'device_id')::uuid; begin
  perform private.actor(); perform 1 from public.setlists where id=s for update;
  if not found or not private.edit_setlist(s) or device is null then perform private.fail('ACCESS_REVOKED'); end if;
  select * into l from public.editor_leases where setlist_id=s for update;
  if l.epoch is distinct from (p->>'expected_epoch')::bigint then perform private.fail('STALE_CONTROLLER',jsonb_build_object('epoch',l.epoch)); end if;
  if l.expires_at>clock_timestamp() and l.controller_user_id=private.actor() and l.device_id=device then
    update public.editor_leases set expires_at=clock_timestamp()+interval '60 seconds' where setlist_id=s; return private.lease_receipt(s);
  end if;
  if l.expires_at>clock_timestamp() and l.controller_user_id is not null and coalesce((p->>'explicit_takeover')::boolean,false)=false then perform private.fail('STALE_CONTROLLER'); end if;
  update public.editor_leases set controller_user_id=private.actor(),device_id=device,epoch=epoch+1,expires_at=clock_timestamp()+interval '60 seconds' where setlist_id=s;
  insert into public.audit_events(actor_id,church_id,resource_id,action) select private.actor(),church_id,s,'editor_acquired' from public.setlists where id=s;
  return private.lease_receipt(s);
end $$;
create function public.renew_editor(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s uuid:=(p->>'setlist_id')::uuid; begin
  perform 1 from public.setlists where id=s for update;
  perform private.assert_controller(s,(p->>'device_id')::uuid,(p->>'epoch')::bigint);
  update public.editor_leases set expires_at=clock_timestamp()+interval '60 seconds' where setlist_id=s; return private.lease_receipt(s);
end $$;
create function public.release_editor(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s uuid:=(p->>'setlist_id')::uuid; begin
  perform 1 from public.setlists where id=s for update;
  perform private.assert_controller(s,(p->>'device_id')::uuid,(p->>'epoch')::bigint);
  update public.editor_leases set controller_user_id=null,device_id=null,expires_at=clock_timestamp() where setlist_id=s;
  return private.lease_receipt(s);
end $$;
create function private.snapshot(s uuid) returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object('schema_version',1,'id',ls.id,'session_id',ls.id,'church_id',ls.church_id,'setlist_id',ls.setlist_id,
    'status',ls.status,'latest_sequence',ls.latest_sequence,'state_revision',ls.state_revision,'controller_epoch',el.epoch,
    'latest_call',private.call_receipt(ls.latest_call_id),
    'history',coalesce((select jsonb_agg(private.call_receipt(h.id) order by h.sequence desc) from
      (select id,sequence from public.live_calls where session_id=ls.id order by sequence desc limit 10) h),'[]'::jsonb),
    'annotation_heads',coalesce((select jsonb_agg(jsonb_build_object('layer_id',al.id,'performance_item_id',al.performance_item_id,
      'chart_version_id',al.chart_version_id,'page_index',al.page_index,'revision_id',ah.revision_id,'revision_number',ah.revision_number))
      from public.annotation_layers al join public.annotation_heads ah on ah.layer_id=al.id join public.performance_items pi on pi.id=al.performance_item_id
      where pi.setlist_id=ls.setlist_id and al.scope='team' and private.read_layer(al.id)),'[]'::jsonb),
    'access',jsonb_build_object('scope',case when private.member_of(ls.church_id) then 'member' else 'guest' end,
      'can_control',private.edit_setlist(ls.setlist_id),'can_write_personal',private.member_of(ls.church_id)))
  from public.live_sessions ls join public.editor_leases el on el.setlist_id=ls.setlist_id where ls.id=s
$$;
create function public.get_session_snapshot(p jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s public.live_sessions; begin
  perform private.actor(); select * into s from public.live_sessions where id=(p->>'session_id')::uuid;
  if not found or not private.read_setlist(s.setlist_id) then perform private.fail('ACCESS_REVOKED'); end if;
  return private.snapshot(s.id);
end $$;
create function public.start_session(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.setlists; new_session uuid; command uuid:=(p->>'command_id')::uuid; r jsonb; begin
  perform private.actor(); select * into s from public.setlists where id=(p->>'setlist_id')::uuid for update;
  if not found or not private.edit_setlist(s.id) then perform private.fail('ACCESS_REVOKED'); end if;
  r:=private.receipt('start_session',command,p); if r is not null then return private.snapshot((r->>'session_id')::uuid); end if;
  perform private.assert_controller(s.id,(p->>'device_id')::uuid,(p->>'epoch')::bigint);
  if exists(select 1 from public.live_sessions where setlist_id=s.id and status='LIVE') then perform private.fail('SESSION_ACTIVE'); end if;
  insert into public.live_sessions(church_id,setlist_id) values(s.church_id,s.id) returning public.live_sessions.id into new_session;
  r:=jsonb_build_object('session_id',new_session); perform private.remember('start_session',command,p,r); return private.snapshot(new_session);
end $$;
create function public.publish_call(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.live_sessions; existing public.live_calls; item public.performance_items; chart public.chart_versions;
  call uuid; command uuid:=(p->>'command_id')::uuid; digest text:=private.digest(p); begin
  perform private.actor(); select * into s from public.live_sessions where id=(p->>'session_id')::uuid;
  if not found or not private.read_setlist(s.setlist_id) then perform private.fail('ACCESS_REVOKED'); end if;
  perform 1 from public.setlists where id=s.setlist_id for update;
  perform 1 from public.editor_leases where setlist_id=s.setlist_id for update;
  select * into s from public.live_sessions where id=s.id for update;
  select * into existing from public.live_calls where session_id=s.id and command_id=command;
  if found then
    if existing.payload_digest<>digest then perform private.fail('IDEMPOTENCY_CONFLICT'); end if;
    return jsonb_build_object('schema_version',1,'call',private.call_receipt(existing.id),'latest_call',private.call_receipt(s.latest_call_id),'latest_sequence',s.latest_sequence,'snapshot',private.snapshot(s.id));
  end if;
  if not private.edit_setlist(s.setlist_id) then perform private.fail('ACCESS_REVOKED'); end if;
  if s.status<>'LIVE' then perform private.fail('SESSION_ENDED'); end if;
  perform private.assert_controller(s.setlist_id,(p->>'device_id')::uuid,(p->>'expected_controller_epoch')::bigint);
  if s.latest_sequence is distinct from (p->>'expected_latest_sequence')::bigint then perform private.fail('STALE_CALL',jsonb_build_object('latest_sequence',s.latest_sequence)); end if;
  if p->>'performance_key' is null or p->>'performance_key' !~ '^[A-G](#|b)?m?$' then perform private.fail('INVALID_KEY'); end if;
  select * into chart from public.chart_versions where id=(p->>'team_chart_version_id')::uuid and song_id=(p->>'song_id')::uuid and church_id=s.church_id;
  if not found or not exists(select 1 from public.assets where id=chart.pdf_asset_id and status='verified') then perform private.fail('FILE_NOT_READY'); end if;
  select * into item from public.performance_items where id=(p->>'performance_item_id')::uuid;
  if not found then
    if coalesce(p->'ad_hoc_draft',p->'ad_hoc_draft_optional') is null or (coalesce(p->'ad_hoc_draft',p->'ad_hoc_draft_optional')->>'id')::uuid is distinct from (p->>'performance_item_id')::uuid then perform private.fail('ACCESS_REVOKED'); end if;
    insert into public.performance_items(id,church_id,setlist_id,song_id,team_chart_version_id,performance_key,position,kind)
      values((p->>'performance_item_id')::uuid,s.church_id,s.setlist_id,chart.song_id,chart.id,p->>'performance_key',null,'ad_hoc') returning * into item;
  end if;
  if item.setlist_id<>s.setlist_id or item.song_id<>chart.song_id or not item.active then perform private.fail('ACCESS_REVOKED'); end if;
  insert into public.live_calls(church_id,session_id,sequence,command_id,performance_item_id,song_id,team_chart_version_id,performance_key,actor_user_id,controller_epoch,payload_digest)
    values(s.church_id,s.id,s.latest_sequence+1,command,item.id,chart.song_id,chart.id,p->>'performance_key',private.actor(),(p->>'expected_controller_epoch')::bigint,digest) returning id into call;
  update public.live_sessions set latest_sequence=latest_sequence+1,latest_call_id=call,state_revision=state_revision+1 where id=s.id returning * into s;
  insert into public.audit_events(actor_id,church_id,resource_id,action) values(private.actor(),s.church_id,call,'call_published');
  return jsonb_build_object('schema_version',1,'call',private.call_receipt(call),'latest_call',private.call_receipt(call),'latest_sequence',s.latest_sequence,'snapshot',private.snapshot(s.id));
end $$;
create function public.acknowledge_open(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.live_sessions; c public.live_calls; v public.chart_versions; device uuid:=(p->>'device_id')::uuid; begin
  perform private.actor(); select * into s from public.live_sessions where id=(p->>'session_id')::uuid;
  if not found or not private.read_setlist(s.setlist_id) then perform private.fail('ACCESS_REVOKED'); end if;
  select * into c from public.live_calls where id=(p->>'call_id')::uuid and session_id=s.id;
  if not found then perform private.fail('STALE_CALL'); end if;
  select * into v from public.chart_versions where id=(p->>'selected_chart_version_id')::uuid and song_id=c.song_id;
  if not found or not private.read_chart(v.id) then perform private.fail('ASSET_NOT_AUTHORIZED'); end if;
  insert into public.participants(session_id,user_id,device_id,latest_received_call_id,last_opened_call_id,selected_chart_version_id,rendered_at)
    values(s.id,private.actor(),device,s.latest_call_id,c.id,v.id,now())
  on conflict(session_id,user_id,device_id) do update set last_seen_at=now(),latest_received_call_id=excluded.latest_received_call_id,
    last_opened_call_id=excluded.last_opened_call_id,selected_chart_version_id=excluded.selected_chart_version_id,rendered_at=now();
  return jsonb_build_object('schema_version',1,'call_id',c.id,'selected_chart_version_id',v.id,'opened',true,'is_latest',s.latest_call_id=c.id,'meaning','rendered_not_ready');
end $$;
create function public.end_session(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare s public.live_sessions; r jsonb; command uuid:=(p->>'command_id')::uuid; begin
  perform private.actor(); select * into s from public.live_sessions where id=(p->>'session_id')::uuid;
  if not found or not private.edit_setlist(s.setlist_id) then perform private.fail('ACCESS_REVOKED'); end if;
  perform 1 from public.setlists where id=s.setlist_id for update;
  perform 1 from public.editor_leases where setlist_id=s.setlist_id for update;
  select * into s from public.live_sessions where id=s.id for update;
  r:=private.receipt('end_session',command,p); if r is not null then return private.snapshot(s.id); end if;
  if not (private.admin_of(s.church_id) and coalesce((p->>'explicit_admin_end')::boolean,false)) then
    perform private.assert_controller(s.setlist_id,(p->>'device_id')::uuid,(p->>'epoch')::bigint);
  end if;
  update public.live_sessions set status='ENDED',ended_at=now(),state_revision=state_revision+1 where id=s.id;
  insert into public.audit_events(actor_id,church_id,resource_id,action) values(private.actor(),s.church_id,s.id,'session_ended');
  perform private.remember('end_session',command,p,jsonb_build_object('session_id',s.id)); return private.snapshot(s.id);
end $$;

create function private.validate_identity(i jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v public.chart_versions; item public.performance_items; page integer:=(i->>'page_index')::integer; scope text:=i->>'scope'; begin
  perform private.actor(); select * into v from public.chart_versions where id=(i->>'chart_version_id')::uuid;
  if not found or v.church_id is distinct from (i->>'church_id')::uuid or not private.read_chart(v.id) then perform private.fail('ASSET_NOT_AUTHORIZED'); end if;
  if page is null or page<0 or page>=v.page_count then perform private.fail('INVALID_PAGE'); end if;
  if scope='personal' then
    if (i->>'owner_user_id')::uuid is distinct from private.actor() or i->>'performance_item_id' is not null or not private.member_of(v.church_id) then perform private.fail('ACCESS_REVOKED'); end if;
  elsif scope='team' then
    select * into item from public.performance_items where id=(i->>'performance_item_id')::uuid;
    if not found or item.church_id<>v.church_id or item.song_id<>v.song_id or not private.read_setlist(item.setlist_id) or i->>'owner_user_id' is not null then perform private.fail('ACCESS_REVOKED'); end if;
  else perform private.fail('INVALID_INPUT'); end if;
  return jsonb_build_object('church_id',v.church_id,'chart_version_id',v.id,'page_index',page,'scope',scope,
    'owner_user_id',i->'owner_user_id','performance_item_id',i->'performance_item_id');
end $$;
create function private.find_layer(i jsonb) returns uuid language sql stable security definer set search_path='' as $$
  select id from public.annotation_layers where church_id=(i->>'church_id')::uuid and chart_version_id=(i->>'chart_version_id')::uuid
    and page_index=(i->>'page_index')::integer and scope=i->>'scope'
    and owner_user_id is not distinct from (i->>'owner_user_id')::uuid and performance_item_id is not distinct from (i->>'performance_item_id')::uuid
$$;
create function public.get_annotation_head(p jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare layer uuid; r uuid; begin
  perform private.actor();
  if p->>'layer_id' is not null then
    layer:=(p->>'layer_id')::uuid; if not private.read_layer(layer) then perform private.fail('ACCESS_REVOKED'); end if;
  else layer:=private.find_layer(private.validate_identity(p->'layer_identity')); end if;
  if layer is null then return null; end if;
  select revision_id into r from public.annotation_heads where layer_id=layer;
  return private.annotation_receipt(r);
end $$;
create function public.save_annotation_revision(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare i jsonb:=private.validate_identity(p->'layer_identity'); l uuid; head public.annotation_heads; existing public.annotation_revisions;
  item public.performance_items; native public.assets; preview public.assets; geometry jsonb:=private.geometry(p->'geometry');
  revision uuid; command uuid:=(p->>'command_id')::uuid; digest text:=private.digest(p); parent bigint:=(p->>'parent_revision')::bigint; begin
  if i->>'scope'='team' then
    select * into item from public.performance_items where id=(i->>'performance_item_id')::uuid;
    perform 1 from public.setlists where id=item.setlist_id for update;
    perform 1 from public.editor_leases where setlist_id=item.setlist_id for update;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(i::text,0));
  l:=private.find_layer(i);
  if l is not null then
    perform 1 from public.annotation_layers where id=l for update;
    select * into existing from public.annotation_revisions where layer_id=l and command_id=command;
    if found then
      if existing.payload_digest<>digest then perform private.fail('IDEMPOTENCY_CONFLICT'); end if;
      return private.annotation_receipt(existing.id);
    end if;
  end if;
  if i->>'scope'='team' then
    if not private.edit_setlist(item.setlist_id) then perform private.fail('ACCESS_REVOKED'); end if;
    perform private.assert_controller(item.setlist_id,(p->>'device_id')::uuid,(p->>'controller_epoch_if_team')::bigint);
  end if;
  select * into native from public.assets where id=(p->>'native_asset_id')::uuid;
  select * into preview from public.assets where id=(p->>'preview_asset_id')::uuid;
  if native.id is null or preview.id is null or native.type<>'native' or preview.type<>'preview' or native.status<>'verified' or preview.status<>'verified'
    or native.owner_user_id<>private.actor() or preview.owner_user_id<>private.actor()
    or native.church_id<>(i->>'church_id')::uuid or preview.church_id<>(i->>'church_id')::uuid then perform private.fail('FILE_NOT_READY'); end if;
  if not exists(select 1 from public.chart_versions where id=(i->>'chart_version_id')::uuid and page_manifest->(i->>'page_index')::integer=geometry) then perform private.fail('INVALID_PAGE'); end if;
  if parent is null or parent<0 then perform private.fail('REVISION_CONFLICT'); end if;
  if l is null then
    if parent<>0 then perform private.fail('REVISION_CONFLICT',jsonb_build_object('head',null)); end if;
    insert into public.annotation_layers(church_id,chart_version_id,page_index,scope,owner_user_id,performance_item_id)
      values((i->>'church_id')::uuid,(i->>'chart_version_id')::uuid,(i->>'page_index')::integer,i->>'scope',(i->>'owner_user_id')::uuid,(i->>'performance_item_id')::uuid) returning id into l;
  end if;
  select * into head from public.annotation_heads where layer_id=l for update;
  if coalesce(head.revision_number,0)<>parent then perform private.fail('REVISION_CONFLICT',jsonb_build_object('head',private.annotation_receipt(head.revision_id))); end if;
  insert into public.annotation_revisions(layer_id,parent_revision,server_revision,command_id,native_asset_id,preview_asset_id,geometry,editor_user_id,device_id,payload_digest)
    values(l,parent,parent+1,command,native.id,preview.id,geometry,private.actor(),(p->>'device_id')::uuid,digest) returning id into revision;
  insert into public.annotation_heads values(l,revision,parent+1) on conflict(layer_id) do update set revision_id=excluded.revision_id,revision_number=excluded.revision_number;
  return private.annotation_receipt(revision);
end $$;
create function public.preflight_manifest(p jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare s public.setlists; begin
  perform private.actor(); select * into s from public.setlists where id=(p->>'setlist_id')::uuid;
  if not found or not private.read_setlist(s.id) then perform private.fail('ACCESS_REVOKED'); end if;
  return jsonb_build_object('schema_version',1,'setlist_id',s.id,'setlist_revision',s.revision,
    'charts',coalesce((select jsonb_agg(private.chart_receipt(v)) from (
      select team_chart_version_id v from public.performance_items where setlist_id=s.id and active and kind in ('planned','standby')
      union select pp.preferred_version_id from public.personal_preferences pp join public.performance_items pi on pi.song_id=pp.song_id
        where pp.user_id=private.actor() and pi.setlist_id=s.id and pi.active and private.member_of(s.church_id)
      union select lc.team_chart_version_id from public.live_calls lc join public.live_sessions ls on ls.id=lc.session_id where ls.setlist_id=s.id
    ) exact where private.read_chart(v)),'[]'::jsonb),
    'annotation_heads',coalesce((select jsonb_agg(private.annotation_receipt(ah.revision_id) order by al.performance_item_id,al.chart_version_id,al.page_index)
      from public.annotation_layers al join public.annotation_heads ah on ah.layer_id=al.id
      where al.scope='team' and private.read_layer(al.id) and exists(
        select 1 from (
          select id performance_item_id,team_chart_version_id chart_version_id from public.performance_items
            where setlist_id=s.id and active and kind in ('planned','standby')
          union select lc.performance_item_id,lc.team_chart_version_id from public.live_calls lc
            join public.live_sessions ls on ls.id=lc.session_id where ls.setlist_id=s.id
        ) eligible where eligible.performance_item_id=al.performance_item_id and eligible.chart_version_id=al.chart_version_id
      )),'[]'::jsonb));
end $$;
create function public.set_membership_active(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare c uuid:=(p->>'church_id')::uuid; u uuid:=(p->>'user_id')::uuid; t uuid:=(p->>'team_id')::uuid; begin
  perform private.actor(); if not private.admin_of(c) or u=private.actor() then perform private.fail('ACCESS_REVOKED'); end if;
  update public.memberships set active=(p->>'active')::boolean where church_id=c and team_id=t and user_id=u;
  return jsonb_build_object('schema_version',1,'user_id',u,'active',(p->>'active')::boolean);
end $$;

-- Immutable history and receipts remain intact even for application administrators.
create function private.immutable_row() returns trigger language plpgsql set search_path='' as $$ begin perform private.fail('IMMUTABLE_RESOURCE'); return null; end $$;
create trigger immutable_chart before update or delete on public.chart_versions for each row execute function private.immutable_row();
create trigger immutable_call before update or delete on public.live_calls for each row execute function private.immutable_row();
create trigger immutable_revision before update or delete on public.annotation_revisions for each row execute function private.immutable_row();
create function private.immutable_verified_asset() returns trigger language plpgsql set search_path='' as $$
begin if old.status='verified' then perform private.fail('IMMUTABLE_RESOURCE'); end if; return new; end $$;
create trigger immutable_verified_asset before update or delete on public.assets for each row execute function private.immutable_verified_asset();

alter table public.churches enable row level security;
alter table public.teams enable row level security;
alter table public.memberships enable row level security;
alter table public.songs enable row level security;
alter table public.assets enable row level security;
alter table public.chart_versions enable row level security;
alter table public.setlists enable row level security;
alter table public.performance_items enable row level security;
alter table public.personal_preferences enable row level security;
alter table public.editor_leases enable row level security;
alter table public.live_sessions enable row level security;
alter table public.live_calls enable row level security;
alter table public.participants enable row level security;
alter table public.annotation_layers enable row level security;
alter table public.annotation_revisions enable row level security;
alter table public.annotation_heads enable row level security;
alter table public.guest_grants enable row level security;
alter table public.invitations enable row level security;
alter table public.audit_events enable row level security;
create policy churches_read on public.churches for select to authenticated using(private.member_of(id) or exists(select 1 from public.guest_grants where church_id=churches.id and user_id=auth.uid() and revoked_at is null and expires_at>clock_timestamp()));
create policy teams_read on public.teams for select to authenticated using(private.member_of(church_id) or exists(select 1 from public.guest_grants g join public.setlists s on s.id=g.setlist_id where s.team_id=teams.id and g.user_id=auth.uid() and g.revoked_at is null and g.expires_at>clock_timestamp()));
create policy memberships_read on public.memberships for select to authenticated using(user_id=auth.uid() or private.admin_of(church_id));
create policy songs_read on public.songs for select to authenticated using(private.member_of(church_id) or exists(select 1 from public.chart_versions cv where cv.song_id=songs.id and private.read_chart(cv.id)));
create policy assets_read on public.assets for select to authenticated using(private.read_asset(id));
create policy charts_read on public.chart_versions for select to authenticated using(private.read_chart(id));
create policy setlists_read on public.setlists for select to authenticated using(private.read_setlist(id));
create policy items_read on public.performance_items for select to authenticated using(private.read_setlist(setlist_id) and ((active and kind in ('planned','standby')) or private.member_of(church_id)
  or exists(select 1 from public.live_calls where performance_item_id=performance_items.id)));
create policy preferences_read on public.personal_preferences for select to authenticated using(user_id=auth.uid() and private.member_of(church_id));
create policy leases_read on public.editor_leases for select to authenticated using(private.read_setlist(setlist_id));
create policy sessions_read on public.live_sessions for select to authenticated using(private.read_setlist(setlist_id));
create policy calls_read on public.live_calls for select to authenticated using(exists(select 1 from public.live_sessions where id=live_calls.session_id and private.read_setlist(setlist_id)));
create policy participants_read on public.participants for select to authenticated using(user_id=auth.uid() or exists(select 1 from public.live_sessions where id=participants.session_id and private.edit_setlist(setlist_id)));
create policy layers_read on public.annotation_layers for select to authenticated using(private.read_layer(id));
create policy revisions_read on public.annotation_revisions for select to authenticated using(private.read_layer(layer_id));
create policy heads_read on public.annotation_heads for select to authenticated using(private.read_layer(layer_id));
create policy guest_grants_read on public.guest_grants for select to authenticated using(user_id=auth.uid() or private.admin_of(church_id));
create policy invitations_read on public.invitations for select to authenticated using(private.admin_of(church_id));
create policy audit_read on public.audit_events for select to authenticated using(private.admin_of(church_id));

revoke all on all tables in schema public from anon,authenticated;
grant select on public.churches,public.teams,public.memberships,public.songs,public.assets,public.chart_versions,public.setlists,
  public.performance_items,public.personal_preferences,public.editor_leases,public.live_sessions,public.live_calls,public.participants,
  public.annotation_layers,public.annotation_revisions,public.annotation_heads,public.guest_grants,public.invitations,public.audit_events to authenticated;
revoke all on all functions in schema private from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.member_of(uuid),private.admin_of(uuid),private.read_setlist(uuid),private.edit_setlist(uuid),private.read_chart(uuid),private.read_layer(uuid),private.read_asset(uuid) to authenticated;
revoke all on function public.create_church_and_default_team(jsonb),public.create_song(jsonb),public.stage_asset(jsonb),public.finalize_asset(jsonb),
  public.publish_chart_version(jsonb),public.create_setlist(jsonb),public.save_setlist(jsonb),public.set_personal_preference(jsonb),
  public.create_invitation(jsonb),public.revoke_invitation(jsonb),public.revoke_guest_grant(jsonb),public.consume_invitation_attempt(jsonb),public.redeem_invitation(jsonb),
  public.acquire_editor(jsonb),public.renew_editor(jsonb),public.release_editor(jsonb),public.start_session(jsonb),public.publish_call(jsonb),
  public.get_session_snapshot(jsonb),public.acknowledge_open(jsonb),public.end_session(jsonb),public.get_annotation_head(jsonb),
  public.save_annotation_revision(jsonb),public.preflight_manifest(jsonb),public.set_membership_active(jsonb) from public,anon,authenticated;
grant execute on function public.create_church_and_default_team(jsonb),public.create_song(jsonb),public.stage_asset(jsonb),
  public.publish_chart_version(jsonb),public.create_setlist(jsonb),public.save_setlist(jsonb),public.set_personal_preference(jsonb),
  public.create_invitation(jsonb),public.revoke_invitation(jsonb),public.revoke_guest_grant(jsonb),public.acquire_editor(jsonb),public.renew_editor(jsonb),
  public.release_editor(jsonb),public.start_session(jsonb),public.publish_call(jsonb),public.get_session_snapshot(jsonb),public.acknowledge_open(jsonb),
  public.end_session(jsonb),public.get_annotation_head(jsonb),public.save_annotation_revision(jsonb),public.preflight_manifest(jsonb),public.set_membership_active(jsonb) to authenticated;
grant execute on function public.finalize_asset(jsonb),public.consume_invitation_attempt(jsonb),public.redeem_invitation(jsonb) to service_role;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('worshipcue-private','worshipcue-private',false,104857600,
  array['application/pdf','application/octet-stream','image/png']);
create policy worshipcue_object_read on storage.objects for select to authenticated using(bucket_id='worshipcue-private'
  and exists(select 1 from public.assets a where a.storage_key=objects.name and private.read_asset(a.id)));
create policy worshipcue_object_insert on storage.objects for insert to authenticated with check(bucket_id='worshipcue-private'
  and exists(select 1 from public.assets a where a.storage_key=objects.name and a.owner_user_id=auth.uid() and a.status='staging'
    and private.member_of(a.church_id) and coalesce((metadata->>'size')::bigint,a.bytes)=a.bytes));
-- No client UPDATE/DELETE policy: upsert and overwriting verified originals are denied.
do $$ begin
  if exists(select 1 from pg_catalog.pg_publication where pubname='supabase_realtime') then
    alter publication supabase_realtime add table public.live_sessions,public.annotation_heads;
  end if;
end $$;
