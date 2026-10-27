-- Phase 1: private storage buckets for progress photos and documents.
-- Files live under "<user_id>/<filename>". Buckets are PRIVATE: the app reads them through signed URLs only.

insert into storage.buckets (id, name, public)
values ('photos', 'photos', false), ('documents', 'documents', false)
on conflict (id) do update set public = false;

-- A user can only touch files inside their own folder.
create policy "own files: read" on storage.objects for select to authenticated
  using (bucket_id in ('photos', 'documents') and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "own files: upload" on storage.objects for insert to authenticated
  with check (bucket_id in ('photos', 'documents') and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "own files: update" on storage.objects for update to authenticated
  using (bucket_id in ('photos', 'documents') and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id in ('photos', 'documents') and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "own files: delete" on storage.objects for delete to authenticated
  using (bucket_id in ('photos', 'documents') and (storage.foldername(name))[1] = (select auth.uid())::text);
