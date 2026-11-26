create or replace function public.mbe_flash_review(issue text,track text,card text,rating integer) returns jsonb language plpgsql security invoker set search_path='' as $$
declare due timestamptz;begin
 if auth.uid() is null or track not in ('MBE','SQE1') or rating not between 1 and 4 or coalesce(card,'')='' or coalesce(issue,'')='' then raise exception 'Invalid flashcard review';end if;
 due:=now()+(case rating when 1 then interval '10 minutes' when 2 then interval '1 day' when 3 then interval '3 days' else interval '7 days' end);
 insert into mbe_private.flashcard_reviews(user_id,issue_id,track,card_id,rating,due_at) values(auth.uid(),issue,track,card,rating,due) on conflict on constraint flashcard_reviews_pkey do update set rating=excluded.rating,due_at=excluded.due_at,reviewed_at=now();
 return jsonb_build_object('due_at',due);end $$;