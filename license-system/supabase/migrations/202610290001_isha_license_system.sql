begin;

create table if not exists public.isha_licenses (
    id uuid primary key default gen_random_uuid(),
    key_hash text not null unique check (key_hash ~ '^[0-9a-f]{64}$'),
    key_prefix text not null,
    label text not null default '' check (char_length(label) <= 100),
    status text not null default 'active' check (status in ('active', 'revoked')),
    expires_at timestamptz,
    max_activations integer not null default 1 check (max_activations between 1 and 10),
    created_at timestamptz not null default now(),
    created_by uuid references auth.users(id) on delete set null,
    last_used_at timestamptz
);

create table if not exists public.isha_license_activations (
    id uuid primary key default gen_random_uuid(),
    license_id uuid not null references public.isha_licenses(id) on delete cascade,
    device_id text not null check (char_length(device_id) between 8 and 128),
    device_name text not null default 'iOS device' check (char_length(device_name) <= 80),
    created_at timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),
    unique (license_id, device_id)
);

create index if not exists isha_licenses_status_expiry_idx
    on public.isha_licenses (status, expires_at);
create index if not exists isha_license_activations_license_id_idx
    on public.isha_license_activations (license_id);

alter table public.isha_licenses enable row level security;
alter table public.isha_license_activations enable row level security;

revoke all on table public.isha_licenses from public, anon, authenticated;
revoke all on table public.isha_license_activations from public, anon, authenticated;
grant all on table public.isha_licenses to service_role;
grant all on table public.isha_license_activations to service_role;

create or replace function public.verify_isha_license(
    p_key_hash text,
    p_device_id text,
    p_device_name text
)
returns table (
    ok boolean,
    message text,
    expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_license public.isha_licenses%rowtype;
    v_activation public.isha_license_activations%rowtype;
    v_activation_count integer;
    v_device_name text;
begin
    if p_key_hash is null or p_key_hash !~ '^[0-9a-f]{64}$'
       or p_device_id is null or char_length(p_device_id) not between 8 and 128 then
        return query select false, 'Invalid license request.'::text, null::timestamptz;
        return;
    end if;

    v_device_name := left(coalesce(nullif(trim(p_device_name), ''), 'iOS device'), 80);

    -- Serialize first activations for a key, so parallel requests cannot exceed the device limit.
    select * into v_license
      from public.isha_licenses
     where key_hash = p_key_hash
     for update;

    if not found then
        return query select false, 'Invalid license key.'::text, null::timestamptz;
        return;
    end if;

    if v_license.status <> 'active' then
        return query select false, 'This license has been revoked.'::text, v_license.expires_at;
        return;
    end if;

    if v_license.expires_at is not null and v_license.expires_at <= now() then
        return query select false, 'This license has expired.'::text, v_license.expires_at;
        return;
    end if;

    select * into v_activation
      from public.isha_license_activations
     where license_id = v_license.id
       and device_id = p_device_id;

    if found then
        update public.isha_license_activations
           set device_name = v_device_name,
               last_seen_at = now()
         where id = v_activation.id;
    else
        select count(*)::integer into v_activation_count
          from public.isha_license_activations
         where license_id = v_license.id;

        if v_activation_count >= v_license.max_activations then
            return query select false, 'This license has reached its device activation limit.'::text, v_license.expires_at;
            return;
        end if;

        insert into public.isha_license_activations (license_id, device_id, device_name)
        values (v_license.id, p_device_id, v_device_name);
    end if;

    update public.isha_licenses
       set last_used_at = now()
     where id = v_license.id;

    return query select true, 'License active on this device.', v_license.expires_at;
end;
$function$;

revoke all on function public.verify_isha_license(text, text, text) from public, anon, authenticated;
grant execute on function public.verify_isha_license(text, text, text) to service_role;

commit;
