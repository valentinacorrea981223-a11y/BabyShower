-- Lista de regalos Baby Maximiliano
-- Ejecuta este archivo en Supabase > SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.gifts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text not null default '',
  image_url text not null default '',
  quantity integer not null default 1 check (quantity > 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  gift_id uuid not null references public.gifts(id) on delete cascade,
  guest_name text not null check (length(trim(guest_name)) between 2 and 100),
  created_at timestamptz not null default now()
);

alter table public.gifts enable row level security;
alter table public.reservations enable row level security;

-- Los visitantes pueden ver únicamente los regalos activos y la cantidad reservada
-- a través de la relación. No se permite leer nombres de invitados desde el navegador.
alter table public.reservations add column if not exists guest_phone text not null default '';
alter table public.reservations add column if not exists guest_message text not null default '';

-- Administradores: crea tu usuario en Authentication > Users y luego ejecuta:
--   insert into public.admins(user_id) select id from auth.users where email = 'TU_CORREO';
create table if not exists public.admins (user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.admins enable row level security;
create or replace function public.is_admin() returns boolean language sql security definer set search_path = public stable
as $$ select exists(select 1 from public.admins where user_id = auth.uid()); $$;
grant execute on function public.is_admin() to anon, authenticated;
drop policy if exists "Admin manages gifts" on public.gifts;
create policy "Admin manages gifts" on public.gifts for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "Admin reads reservations" on public.reservations;
create policy "Admin reads reservations" on public.reservations for select to authenticated using (public.is_admin());
drop policy if exists "Admin deletes reservations" on public.reservations;
create policy "Admin deletes reservations" on public.reservations for delete to authenticated using (public.is_admin());

drop policy if exists "Public can read active gifts" on public.gifts;
create policy "Public can read active gifts" on public.gifts
for select to anon, authenticated using (active = true);

-- NOTA IMPORTANTE:
-- La interfaz de ejemplo consulta la tabla reservations para calcular disponibilidad.
-- No publiques nombres en políticas de lectura. Para producción se recomienda
-- sustituir esa consulta por una vista/RPC segura que solo entregue conteos, y
-- reservar mediante una función transaccional que impida exceder quantity.
-- El siguiente enfoque más seguro se implementa con funciones RPC:
create or replace function public.public_gift_list()
returns table (
  id uuid, name text, description text, image_url text,
  quantity integer, reserved_count bigint
)
language sql
security definer
set search_path = public
as $$
  select g.id, g.name, g.description, g.image_url, g.quantity,
         count(r.id) as reserved_count
  from public.gifts g
  left join public.reservations r on r.gift_id = g.id
  where g.active = true
  group by g.id
  order by g.created_at asc;
$$;

drop function if exists public.reserve_gift(uuid,text);
create or replace function public.reserve_gift(p_gift_id uuid, p_guest_name text, p_guest_phone text default null, p_guest_message text default null)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  gift_quantity integer;
  reserved_total integer;
begin
  if p_guest_name is null or length(trim(p_guest_name)) < 2 or length(trim(p_guest_name)) > 100 then
    raise exception 'Escribe tu nombre completo.';
  end if;

  select quantity into gift_quantity
  from public.gifts where id = p_gift_id and active = true
  for update;

  if gift_quantity is null then raise exception 'Este regalo ya no está disponible.'; end if;

  select count(*) into reserved_total
  from public.reservations where gift_id = p_gift_id;

  if reserved_total >= gift_quantity then raise exception 'Este regalo ya fue reservado.'; end if;

  insert into public.reservations(gift_id, guest_name, guest_phone, guest_message)
  values (p_gift_id, trim(p_guest_name), left(coalesce(trim(p_guest_phone),''),30), left(coalesce(trim(p_guest_message),''),300));

  return true;
end;
$$;

revoke all on function public.public_gift_list() from public;
grant execute on function public.public_gift_list() to anon, authenticated;
revoke all on function public.reserve_gift(uuid,text,text,text) from public;
grant execute on function public.reserve_gift(uuid,text,text,text) to anon, authenticated;

-- Cierre del panel: el rol anónimo (visitantes) no tiene acceso directo a las tablas.
-- Solo los usuarios autenticados que estén en public.admins pasan las políticas RLS.
revoke all on public.reservations from anon;
revoke all on public.admins from anon, authenticated;
revoke insert, update, delete on public.gifts from anon;

-- No se concede SELECT/INSERT directo sobre reservations a visitantes.
-- Añade regalos iniciales opcionales (puedes borrarlos o editarlos desde el panel SQL).
insert into public.gifts(name, description, quantity)
select v.name, v.description, v.quantity
from (values
 ('Pañales talla etapa 1','Un básico para los primeros meses.',2),
 ('Ropita de recién nacido','Bodies, pijamas o conjuntos suaves.',1),
 ('Cobija para bebé','Una cobija suave en tonos neutros.',1),
 ('Kit de aseo para bebé','Elementos esenciales para su cuidado diario.',1),
 ('Toallas y paños','Toallas suaves y paños de algodón.',1),
 ('Organizador de pañales','Para mantener sus cositas ordenadas.',1)
) as v(name,description,quantity)
where not exists (select 1 from public.gifts);

-- Administradora de este sitio (ejecuta DESPUÉS de crear el usuario en Authentication > Users):
insert into public.admins(user_id)
select id from auth.users where email = 'valentinacorrea.981223@gmail.com'
on conflict do nothing;


-- Almacenamiento de imágenes de regalos (máximo recomendado desde la web: 5 MB).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('gift-images', 'gift-images', true, 5242880, array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update set public = true, file_size_limit = 5242880,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif'];

drop policy if exists "Public can view gift images" on storage.objects;
create policy "Public can view gift images" on storage.objects
for select to anon, authenticated using (bucket_id = 'gift-images');

drop policy if exists "Admins upload gift images" on storage.objects;
create policy "Admins upload gift images" on storage.objects
for insert to authenticated with check (bucket_id = 'gift-images' and public.is_admin());

drop policy if exists "Admins update gift images" on storage.objects;
create policy "Admins update gift images" on storage.objects
for update to authenticated using (bucket_id = 'gift-images' and public.is_admin())
with check (bucket_id = 'gift-images' and public.is_admin());

drop policy if exists "Admins delete gift images" on storage.objects;
create policy "Admins delete gift images" on storage.objects
for delete to authenticated using (bucket_id = 'gift-images' and public.is_admin());
