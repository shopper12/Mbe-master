create table mbe_private.flashcard_reviews(user_id uuid not null references auth.users(id) on delete cascade,issue_id text not null,track text not null check(track in ('MBE','SQE1')),card_id text not null,reviewed_at timestamptz not null default now(),rating integer not null check(rating between 1 and 4),due_at timestamptz not null,primary key(user_id,issue_id,track,card_id));
create table mbe_private.essay_attempts(user_id uuid not null references auth.users(id) on delete cascade,attempt_id uuid not null,issue_id text not null,prompt_id text not null,draft text not null default '',phase text not null check(phase in ('draft','submitted','self_assessed')),rubric jsonb not null default '{}',seconds integer not null default 0 check(seconds>=0),updated_at timestamptz not null default now(),primary key(user_id,attempt_id));
alter table mbe_private.flashcard_reviews enable row level security;
alter table mbe_private.essay_attempts enable row level security;
create policy owner_only on mbe_private.flashcard_reviews to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);
create policy owner_only on mbe_private.essay_attempts to authenticated using ((select auth.uid())=user_id) with check ((select auth.uid())=user_id);
grant select,insert,update on mbe_private.flashcard_reviews,mbe_private.essay_attempts to authenticated;
create function public.mbe_flash_review(issue text,track text,card text,rating integer) returns jsonb language plpgsql security invoker set search_path='' as $$
declare due timestamptz;begin
 if auth.uid() is null or track not in ('MBE','SQE1') or rating not between 1 and 4 or coalesce(card,'')='' or coalesce(issue,'')='' then raise exception 'Invalid flashcard review';end if;
 due:=now()+(case rating when 1 then interval '10 minutes' when 2 then interval '1 day' when 3 then interval '3 days' else interval '7 days' end);
 insert into mbe_private.flashcard_reviews(user_id,issue_id,track,card_id,rating,due_at) values(auth.uid(),issue,track,card,rating,due) on conflict(user_id,issue_id,track,card_id) do update set rating=excluded.rating,due_at=excluded.due_at,reviewed_at=now();
 return jsonb_build_object('due_at',due);end $$;
create function public.mbe_essay_save(attempt uuid,issue text,prompt text,body text,stage text,assessment jsonb,elapsed integer) returns void language plpgsql security invoker set search_path='' as $$
begin
 if auth.uid() is null or coalesce(issue,'')='' or coalesce(prompt,'')='' or stage not in ('draft','submitted','self_assessed') or length(coalesce(body,''))>100000 or elapsed not between 0 and 86400 then raise exception 'Invalid essay attempt';end if;
 insert into mbe_private.essay_attempts(user_id,attempt_id,issue_id,prompt_id,draft,phase,rubric,seconds) values(auth.uid(),attempt,issue,prompt,coalesce(body,''),stage,coalesce(assessment,'{}'),elapsed)
 on conflict(user_id,attempt_id) do update set draft=excluded.draft,phase=excluded.phase,rubric=excluded.rubric,seconds=excluded.seconds,updated_at=now()
 where mbe_private.essay_attempts.issue_id=excluded.issue_id and mbe_private.essay_attempts.prompt_id=excluded.prompt_id;end $$;
create function public.mbe_written_progress() returns jsonb language sql stable security invoker set search_path='' as $$ select jsonb_build_object('flashcards',coalesce((select jsonb_agg(to_jsonb(f)-'user_id') from mbe_private.flashcard_reviews f where user_id=auth.uid()),'[]'::jsonb),'essays',coalesce((select jsonb_agg(to_jsonb(e)-'user_id' order by updated_at desc) from mbe_private.essay_attempts e where user_id=auth.uid()),'[]'::jsonb)) $$;
revoke all on function public.mbe_flash_review(text,text,text,integer),public.mbe_essay_save(uuid,text,text,text,text,jsonb,integer),public.mbe_written_progress() from public,anon;
grant execute on function public.mbe_flash_review(text,text,text,integer),public.mbe_essay_save(uuid,text,text,text,text,jsonb,integer),public.mbe_written_progress() to authenticated;