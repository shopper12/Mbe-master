create schema if not exists mbe_private;
revoke all on schema mbe_private from public,anon;
grant usage on schema mbe_private to authenticated;
create table mbe_private.questions(
 user_id uuid not null references auth.users(id) on delete cascade,
 id text not null, revision integer not null check(revision>0),
 content jsonb not null, fingerprint text not null,
 status text not null default 'Unreviewed' check(status in ('Unreviewed','AI cross-checked','Sources verified','Disputed','Revision required','Human reviewed')),
 imported_at timestamptz not null default now(),
 primary key(user_id,id), unique(user_id,fingerprint)
);
create table mbe_private.question_versions(
 user_id uuid not null references auth.users(id) on delete cascade,id text not null,revision integer not null,content jsonb not null,status text not null, archived_at timestamptz default now(),primary key(user_id,id,revision)
);
create table mbe_private.attempts(
 user_id uuid not null references auth.users(id) on delete cascade, attempt_id uuid not null,question_id text not null,revision integer not null,choice text not null check(choice in ('A','B','C','D')),correct boolean not null,seconds integer not null check(seconds between 0 and 86400),confidence integer not null check(confidence between 1 and 5),reason text not null default '',created_at timestamptz not null default now(),due_at timestamptz not null,practice_only boolean not null,primary key(user_id,attempt_id)
);
create table mbe_private.bookmarks(user_id uuid not null references auth.users(id) on delete cascade,question_id text not null,primary key(user_id,question_id));
create table mbe_private.personal_notes(user_id uuid not null references auth.users(id) on delete cascade,question_id text not null,note text not null,primary key(user_id,question_id));
create table mbe_private.import_batches(user_id uuid not null references auth.users(id) on delete cascade,batch_id uuid default gen_random_uuid(),created_at timestamptz default now(),summary jsonb not null,primary key(user_id,batch_id));
create table mbe_private.review_results(user_id uuid not null references auth.users(id) on delete cascade,question_id text not null,revision integer not null,review_id uuid default gen_random_uuid(),status text not null,notes text not null,created_at timestamptz default now(),primary key(user_id,review_id));
do $$ declare t text; begin foreach t in array array['questions','question_versions','attempts','bookmarks','personal_notes','import_batches','review_results'] loop
 execute format('alter table mbe_private.%I enable row level security',t);
 execute format('create policy owner_only on mbe_private.%I to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id)',t);
 execute format('grant select, insert, update, delete on mbe_private.%I to authenticated',t);
 end loop; end $$;
create function public.mbe_import(batch jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare q jsonb; uid uuid:=auth.uid(); old mbe_private.questions%rowtype; ident text; rev integer; fp text; n integer:=0; u integer:=0; s integer:=0; errs jsonb:='[]'; report jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if jsonb_typeof(batch) is distinct from 'array' or jsonb_array_length(batch)>500 then raise exception 'Expected array of at most 500 questions'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(uid::text,0));
 for q in select value from pg_catalog.jsonb_array_elements(batch) loop
 begin
 ident:=q->>'id';rev:=(q->>'revision')::integer;
 if ident is null or length(ident) not between 1 and 200 or rev is null or rev<1 or coalesce(q->>'question_en','')='' or coalesce(q->>'subject','')='' or coalesce(q->>'topic','')='' or coalesce(q->>'generator','')='' or coalesce(q->>'source_type','') not in ('AI_ORIGINAL','AI_ADAPTED','OFFICIAL_RELEASED') or coalesce(q->>'correct_choice','') not in ('A','B','C','D') or jsonb_typeof(q->'explanation') is distinct from 'object' or jsonb_typeof(q->'choices') is distinct from 'array' then raise exception 'Invalid required fields'; end if;
 if jsonb_array_length(q->'choices')<>4 or exists(select 1 from pg_catalog.jsonb_array_elements(q->'choices') with ordinality as x(c,i) where coalesce(c->>'id','')<>substr('ABCD',i::integer,1) or coalesce(c->>'en','')='') then raise exception 'Expected four ordered choices A-D'; end if;
 fp:=md5(regexp_replace(lower(q->>'question_en'),'[^[:alnum:]]','','g')||'|'||(select string_agg(regexp_replace(lower(c->>'en'),'[^[:alnum:]]','','g'),'|' order by c->>'en') from pg_catalog.jsonb_array_elements(q->'choices') c));
 select * into old from mbe_private.questions where user_id=uid and id=ident;
 if found and rev<=old.revision then s:=s+1;continue;end if;
 if exists(select 1 from mbe_private.questions where user_id=uid and fingerprint=fp and id<>ident) then s:=s+1;continue;end if;
 q:=q||jsonb_build_object('qa',jsonb_build_object('status','Unreviewed'));
 if old.id is not null then
 insert into mbe_private.question_versions(user_id,id,revision,content,status) values(uid,old.id,old.revision,old.content,old.status);
 update mbe_private.questions set revision=rev,content=q,fingerprint=fp,status='Unreviewed',imported_at=now() where user_id=uid and id=ident;u:=u+1;
 else insert into mbe_private.questions(user_id,id,revision,content,fingerprint) values(uid,ident,rev,q,fp);n:=n+1;end if;
 exception when others then errs:=errs||jsonb_build_array(jsonb_build_object('id',ident,'error',sqlerrm));end;
 end loop;
 report:=jsonb_build_object('added',n,'updated',u,'duplicates',s,'errors',errs);
 insert into mbe_private.import_batches(user_id,summary) values(uid,report);return report;
end $$;
create function public.mbe_library() returns jsonb language sql stable security invoker set search_path='' as $$
 select coalesce(jsonb_agg(content||jsonb_build_object('qa',jsonb_build_object('status',status)) order by imported_at,id),'[]'::jsonb) from mbe_private.questions where user_id=auth.uid()
$$;
create function public.mbe_practice(include_unreviewed boolean default false) returns jsonb language sql stable security invoker set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'revision',revision,'question_en',content->'question_en','question_ko',content->'question_ko','choices',(select jsonb_agg(jsonb_build_object('id',c->'id','en',c->'en','ko',c->'ko') order by c->>'id') from jsonb_array_elements(content->'choices') c),'status',status) order by imported_at,id),'[]'::jsonb)
 from mbe_private.questions where user_id=auth.uid() and (include_unreviewed or status in ('Sources verified','Human reviewed'))
$$;
create function public.mbe_grade(qid text,rev integer,pick text,elapsed integer,certainty integer,attempt uuid,allow_unreviewed boolean default false) returns jsonb language plpgsql security invoker set search_path='' as $$
declare uid uuid:=auth.uid(); q mbe_private.questions%rowtype; a mbe_private.attempts%rowtype; right_answer boolean; days integer;
begin
 if uid is null then raise exception 'Authentication required';end if;
 select * into q from mbe_private.questions where user_id=uid and id=qid and revision=rev;
 if not found then raise exception 'Question unavailable or revised';end if;
 if q.status not in ('Sources verified','Human reviewed') and not allow_unreviewed then raise exception 'Unreviewed question';end if;
 if pick not in ('A','B','C','D') or certainty not between 1 and 5 or elapsed not between 0 and 86400 then raise exception 'Invalid attempt';end if;
 right_answer:=pick=(q.content->>'correct_choice');
 days:=case when right_answer and certainty>=4 and elapsed<=108 then 3 else 1 end;
 insert into mbe_private.attempts(user_id,attempt_id,question_id,revision,choice,correct,seconds,confidence,due_at,practice_only)
 values(uid,attempt,qid,rev,pick,right_answer,elapsed,certainty,now()+days*interval '1 day',q.status not in ('Sources verified','Human reviewed')) on conflict do nothing;
 select * into a from mbe_private.attempts where user_id=uid and attempt_id=attempt;
 if a.question_id<>qid or a.revision<>rev or a.choice<>pick then raise exception 'Attempt ID conflict';end if;
 return jsonb_build_object('attempt',to_jsonb(a)-'user_id','correct_choice',q.content->'correct_choice','explanation',q.content->'explanation');
end $$;
create function public.mbe_progress() returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('attempts',coalesce((select jsonb_agg(to_jsonb(a)-'user_id' order by a.created_at) from mbe_private.attempts a where a.user_id=auth.uid()),'[]'::jsonb),'bookmarks',coalesce((select jsonb_agg(question_id) from mbe_private.bookmarks where user_id=auth.uid()),'[]'::jsonb),'notes',coalesce((select jsonb_object_agg(question_id,note) from mbe_private.personal_notes where user_id=auth.uid()),'{}'::jsonb))
$$;
create function public.mbe_note(qid text,body text) returns void language sql security invoker set search_path='' as $$ insert into mbe_private.personal_notes(user_id,question_id,note) values(auth.uid(),qid,body) on conflict(user_id,question_id) do update set note=excluded.note $$;
create function public.mbe_bookmark(qid text,marked boolean) returns void language plpgsql security invoker set search_path='' as $$ begin if marked then insert into mbe_private.bookmarks values(auth.uid(),qid) on conflict do nothing;else delete from mbe_private.bookmarks where user_id=auth.uid() and question_id=qid;end if;end $$;
create function public.mbe_review(qid text,rev integer,decision text,body text) returns void language plpgsql security invoker set search_path='' as $$ begin
 if decision not in ('Unreviewed','Human reviewed','Disputed','Revision required') then raise exception 'Unsupported manual review status';end if;
 if coalesce(length(trim(body)),0)<10 then raise exception 'Review evidence or rationale required';end if;
 update mbe_private.questions set status=decision where user_id=auth.uid() and id=qid and revision=rev;
 if not found then raise exception 'Question unavailable';end if;
 insert into mbe_private.review_results(user_id,question_id,revision,status,notes) values(auth.uid(),qid,rev,decision,body);end $$;
create function public.mbe_backup() returns jsonb language sql stable security invoker set search_path='' as $$ select jsonb_build_object('schema_version','1.0','questions',public.mbe_library(),'progress',public.mbe_progress(),'versions',coalesce((select jsonb_agg(to_jsonb(v)-'user_id') from mbe_private.question_versions v where user_id=auth.uid()),'[]'::jsonb),'reviews',coalesce((select jsonb_agg(to_jsonb(r)-'user_id') from mbe_private.review_results r where user_id=auth.uid()),'[]'::jsonb)) $$;
do $$ declare f record; begin for f in select oid::regprocedure as sig from pg_proc where pronamespace='public'::regnamespace and proname like 'mbe_%' loop execute format('revoke all on function %s from public,anon',f.sig);execute format('grant execute on function %s to authenticated',f.sig);end loop;end $$;
