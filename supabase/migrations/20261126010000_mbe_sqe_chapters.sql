alter table mbe_private.attempts drop constraint attempts_choice_check;
alter table mbe_private.attempts add constraint attempts_choice_check check(choice in ('A','B','C','D','E'));
create table mbe_private.chapters(user_id uuid not null references auth.users(id) on delete cascade,issue_id text not null,revision integer not null check(revision>0),content jsonb not null,updated_at timestamptz default now(),primary key(user_id,issue_id));
alter table mbe_private.chapters enable row level security;
create policy owner_only on mbe_private.chapters to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);
grant select,insert,update on mbe_private.chapters to authenticated;
create table mbe_private.chapter_versions(user_id uuid not null references auth.users(id) on delete cascade,issue_id text not null,revision integer not null,content jsonb not null,primary key(user_id,issue_id,revision));
alter table mbe_private.chapter_versions enable row level security;
create policy owner_only on mbe_private.chapter_versions to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);
grant select,insert on mbe_private.chapter_versions to authenticated;
CREATE OR REPLACE FUNCTION public.mbe_import(batch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare q jsonb; uid uuid:=auth.uid(); old mbe_private.questions%rowtype; ident text; rev integer; fp text; n integer:=0; u integer:=0; s integer:=0; errs jsonb:='[]'; report jsonb;
begin
 if uid is null then raise exception 'Authentication required'; end if;
 if jsonb_typeof(batch) is distinct from 'array' or jsonb_array_length(batch)>500 then raise exception 'Expected array of at most 500 questions'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(uid::text,0));
 for q in select value from pg_catalog.jsonb_array_elements(batch) loop
 begin
 ident:=q->>'id';rev:=(q->>'revision')::integer;
 if ident is null or length(ident) not between 1 and 200 or rev is null or rev<1 or coalesce(q->>'question_en','')='' or coalesce(q->>'subject','')='' or coalesce(q->>'topic','')='' or coalesce(q->>'generator','')='' or coalesce(q->>'source_type','') not in ('AI_ORIGINAL','AI_ADAPTED','OFFICIAL_RELEASED') or coalesce(q->>'correct_choice','') not in ('A','B','C','D','E') or jsonb_typeof(q->'explanation') is distinct from 'object' or jsonb_typeof(q->'choices') is distinct from 'array' then raise exception 'Invalid required fields'; end if;
 if coalesce(q->>'exam_track','MBE') not in ('MBE','SQE1') or (q->>'exam_track'='SQE1' and coalesce(q->>'issue_id','')='') or jsonb_array_length(q->'choices')<>(case when q->>'exam_track'='SQE1' then 5 else 4 end) or not exists(select 1 from jsonb_array_elements(q->'choices') v where v->>'id'=q->>'correct_choice') or exists(select 1 from pg_catalog.jsonb_array_elements(q->'choices') with ordinality as x(c,i) where coalesce(c->>'id','')<>substr('ABCDE',i::integer,1) or coalesce(c->>'en','')='') then raise exception 'Wrong choices for exam track'; end if;
 fp:=md5(coalesce(q->>'exam_track','MBE')||'|'||regexp_replace(lower(q->>'question_en'),'[^[:alnum:]]','','g')||'|'||(select string_agg(regexp_replace(lower(c->>'en'),'[^[:alnum:]]','','g'),'|' order by c->>'en') from pg_catalog.jsonb_array_elements(q->'choices') c));
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
end $function$
;
CREATE OR REPLACE FUNCTION public.mbe_grade(qid text, rev integer, pick text, elapsed integer, certainty integer, attempt uuid, allow_unreviewed boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare uid uuid:=auth.uid(); q mbe_private.questions%rowtype; a mbe_private.attempts%rowtype; right_answer boolean; days integer;
begin
 if uid is null then raise exception 'Authentication required';end if;
 select * into q from mbe_private.questions where user_id=uid and id=qid and revision=rev;
 if not found then raise exception 'Question unavailable or revised';end if;
 if q.status not in ('Sources verified','Human reviewed') and not allow_unreviewed then raise exception 'Unreviewed question';end if;
 if not exists(select 1 from jsonb_array_elements(q.content->'choices') v where v->>'id'=pick) or certainty not between 1 and 5 or elapsed not between 0 and 86400 then raise exception 'Invalid attempt';end if;
 right_answer:=pick=(q.content->>'correct_choice');
 days:=case when right_answer and certainty>=4 and elapsed<=108 then 3 else 1 end;
 insert into mbe_private.attempts(user_id,attempt_id,question_id,revision,choice,correct,seconds,confidence,due_at,practice_only)
 values(uid,attempt,qid,rev,pick,right_answer,elapsed,certainty,now()+days*interval '1 day',q.status not in ('Sources verified','Human reviewed')) on conflict do nothing;
 select * into a from mbe_private.attempts where user_id=uid and attempt_id=attempt;
 if a.question_id<>qid or a.revision<>rev or a.choice<>pick then raise exception 'Attempt ID conflict';end if;
 return jsonb_build_object('attempt',to_jsonb(a)-'user_id','correct_choice',q.content->'correct_choice','explanation',q.content->'explanation');
end $function$
;
create function public.mbe_chapters() returns jsonb language sql stable security invoker set search_path='' as $$ select coalesce(jsonb_agg(content order by content->>'subject',content->>'title'),'[]'::jsonb) from mbe_private.chapters where user_id=auth.uid() $$;
create function public.mbe_import_chapters(batch jsonb) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c jsonb; uid uuid:=auth.uid(); old mbe_private.chapters%rowtype; ident text; rev integer; n integer:=0;s integer:=0;errs jsonb:='[]';
begin
 if uid is null then raise exception 'Authentication required';end if;
 if jsonb_typeof(batch) is distinct from 'array' or jsonb_array_length(batch)>500 then raise exception 'Expected chapter array';end if;
 perform pg_advisory_xact_lock(hashtextextended(uid::text,0));
 for c in select value from jsonb_array_elements(batch) loop
 begin
 ident:=c->>'issue_id';rev:=(c->>'revision')::integer;
 if coalesce(ident,'')='' or rev is null or rev<1 or coalesce(c->>'subject','')='' or coalesce(c->>'title','')='' or coalesce(c->>'mapping','') not in ('direct','partial','us_only','uk_only') then raise exception 'Invalid chapter fields';end if;
 if (c->>'mapping') in ('direct','partial','us_only') and jsonb_typeof(c->'us') is distinct from 'object' then raise exception 'US section required';end if;
 if (c->>'mapping') in ('direct','partial','uk_only') and jsonb_typeof(c->'uk') is distinct from 'object' then raise exception 'UK section required';end if;
 select * into old from mbe_private.chapters where user_id=uid and issue_id=ident;
 if found and old.revision>=rev then s:=s+1;continue;end if;
 if old.issue_id is not null then insert into mbe_private.chapter_versions values(uid,ident,old.revision,old.content);end if;
 c:=c||jsonb_build_object('status','Unreviewed');
 insert into mbe_private.chapters(user_id,issue_id,revision,content) values(uid,ident,rev,c) on conflict(user_id,issue_id) do update set revision=excluded.revision,content=excluded.content,updated_at=now();
 n:=n+1;
 exception when others then errs:=errs||jsonb_build_array(jsonb_build_object('issue_id',ident,'error',sqlerrm));end;
 end loop;return jsonb_build_object('saved',n,'duplicates',s,'errors',errs);end $$;
create function public.mbe_cards(track text,issue text,include_unreviewed boolean default false) returns jsonb language sql stable security invoker set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_build_object('id',id,'revision',revision,'question_en',content->'question_en','question_ko',content->'question_ko','choices',(select jsonb_agg(jsonb_build_object('id',c->'id','en',c->'en','ko',c->'ko') order by c->>'id') from jsonb_array_elements(content->'choices') c),'status',status) order by imported_at,id),'[]'::jsonb)
 from mbe_private.questions where user_id=auth.uid() and coalesce(content->>'exam_track','MBE')=track and (issue='' or coalesce(content->>'issue_id','')=issue) and (include_unreviewed or status in ('Sources verified','Human reviewed')) $$;
revoke all on function public.mbe_chapters(),public.mbe_import_chapters(jsonb),public.mbe_cards(text,text,boolean) from public,anon;
grant execute on function public.mbe_chapters(),public.mbe_import_chapters(jsonb),public.mbe_cards(text,text,boolean) to authenticated;