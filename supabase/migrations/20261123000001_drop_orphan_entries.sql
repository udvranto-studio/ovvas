-- Check-ins for a deleted habit are not stored. A phone that was offline
-- when the habit was deleted would otherwise upload them again, leaving
-- rows with no habit that every new phone downloads.
create or replace function public.ovvas_before_write() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.updated_at < old.updated_at then
    return null; -- an older edit arrived late: keep what is stored
  end if;
  if tg_table_name = 'entries' and exists (
    select 1 from public.habits h
    where h.user_id = new.user_id and h.id = new.habit_id and h.deleted
  ) then
    return null; -- the habit is deleted: drop the check-in
  end if;
  new.synced_at := clock_timestamp();
  return new;
end;
$$;

-- Remove the ones already stored.
delete from public.entries e
using public.habits h
where h.user_id = e.user_id and h.id = e.habit_id and h.deleted;
