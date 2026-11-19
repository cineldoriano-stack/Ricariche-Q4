-- Ricariche Q4. Migrazione additiva da applicare una volta.
begin;

create table public.ricariche_pubbliche_q4 (
  id uuid primary key,
  data date not null,
  km_auto integer not null check (km_auto >= 0),
  nome text not null check (length(trim(nome)) between 1 and 300),
  localita text not null check (length(trim(localita)) between 1 and 500),
  totale_kwh numeric(12,3) not null check (totale_kwh > 0 and totale_kwh <> 'NaN'),
  totale_euro numeric(12,2) not null check (totale_euro >= 0 and totale_euro <> 'NaN'),
  prezzo_kwh numeric generated always as (round(totale_euro / nullif(totale_kwh,0),6)) stored,
  created_at timestamptz not null default now()
);

create table public.rimborsi_q4 (
  id uuid primary key,
  data date not null,
  importo numeric(12,2) not null check (importo > 0 and importo <> 'NaN'),
  created_at timestamptz not null default now()
);

alter table public.ricariche_pubbliche_q4 enable row level security;
alter table public.rimborsi_q4 enable row level security;
revoke all on public.ricariche_pubbliche_q4, public.rimborsi_q4 from public, anon, authenticated;
grant select, insert, delete on public.ricariche_pubbliche_q4 to authenticated;
grant select on public.rimborsi_q4 to authenticated;

create policy q4_colonnine_autorizzati on public.ricariche_pubbliche_q4
  for all to authenticated
  using (exists (select 1 from public.utenti_q4 where user_id = (select auth.uid())))
  with check (exists (select 1 from public.utenti_q4 where user_id = (select auth.uid())));
create policy q4_rimborsi_lettura on public.rimborsi_q4
  for select to authenticated
  using (exists (select 1 from public.utenti_q4 where user_id = (select auth.uid())));

-- L'importo e il saldo visualizzato viaggiano insieme. Due telefoni non possono
-- registrare due pagamenti sullo stesso saldo con una conferma ormai scaduta.
create function public.registra_rimborso_q4(p_id uuid, p_data date, p_importo numeric, p_saldo numeric)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  precedente public.rimborsi_q4%rowtype;
  saldo numeric;
begin
  if not exists (select 1 from public.utenti_q4 where user_id = (select auth.uid())) then
    raise exception 'Account non autorizzato' using errcode='42501';
  end if;
  if p_id is null or p_data is null or p_importo is null or p_saldo is null
     or p_importo not between 0.01 and 9999999999.99 or p_importo <> round(p_importo,2) then
    raise exception 'Data o importo del rimborso non validi';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(5134, 20261119);
  select * into precedente from public.rimborsi_q4 where id = p_id;
  if found then
    if precedente.importo = p_importo and precedente.data = p_data then return p_id; end if;
    raise exception 'Richiesta già utilizzata per un pagamento diverso';
  end if;
  lock table public.ricariche_q4 in share mode;
  select (select coalesce(sum(totale_euro),0) from public.ricariche_q4)
       - (select coalesce(sum(importo),0) from public.rimborsi_q4) into saldo;
  if p_saldo <> saldo then raise exception 'Il saldo è cambiato. Controlla il nuovo saldo e conferma di nuovo.'; end if;
  if p_importo > saldo then raise exception 'Il rimborso supera il saldo disponibile.'; end if;
  insert into public.rimborsi_q4(id,data,importo) values(p_id,p_data,p_importo);
  return p_id;
end;
$$;
revoke all on function public.registra_rimborso_q4(uuid,date,numeric,numeric) from public, anon, authenticated;
grant execute on function public.registra_rimborso_q4(uuid,date,numeric,numeric) to authenticated;

create view public.q4_movimenti with (security_invoker=true) as
  select 'casa'::text tipo,id,data,km_auto,contatore_prima,contatore_dopo,
         totale_kwh,prezzo_kwh,totale_euro,null::text nome,null::text localita,created_at
    from public.ricariche_q4
  union all
  select 'colonnina',id,data,km_auto,null,null,totale_kwh,prezzo_kwh,totale_euro,nome,localita,created_at
    from public.ricariche_pubbliche_q4
  union all
  select 'rimborso',id,data,null,null,null,null,null,importo,null,null,created_at
    from public.rimborsi_q4;
revoke all on public.q4_movimenti from public, anon, authenticated;
grant select on public.q4_movimenti to authenticated;
notify pgrst, 'reload schema';
commit;
