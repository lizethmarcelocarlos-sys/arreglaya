alter table public.profiles add column if not exists avatar_path text;

insert into storage.buckets (id, name, public) values
  ('profile-avatars', 'profile-avatars', false),
  ('verification-documents', 'verification-documents', false)
on conflict (id) do nothing;

create table if not exists public.verification_documents (
  id bigint generated always as identity primary key,
  technician_id uuid not null references public.profiles(id) on delete cascade,
  document_type text not null check (document_type in ('carnet_anverso', 'carnet_reverso', 'certificado')),
  path text not null unique,
  created_at timestamptz not null default now(),
  unique (technician_id, document_type)
);

alter table public.verification_documents enable row level security;

create policy "Técnico y admin ven documentos" on public.verification_documents for select to authenticated
  using (technician_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role::text = 'admin'));
create policy "Técnico sube sus documentos" on public.verification_documents for insert to authenticated
  with check (technician_id = auth.uid());
create policy "Usuarios ven avatares" on storage.objects for select to authenticated
  using (bucket_id = 'profile-avatars');
create policy "Usuario sube su avatar" on storage.objects for insert to authenticated
  with check (bucket_id = 'profile-avatars' and owner_id = auth.uid()::text);
create policy "Técnico y admin ven documentos privados" on storage.objects for select to authenticated
  using (bucket_id = 'verification-documents' and (owner_id = auth.uid()::text or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role::text = 'admin')));
create policy "Técnico sube documentos privados" on storage.objects for insert to authenticated
  with check (bucket_id = 'verification-documents' and owner_id = auth.uid()::text);
