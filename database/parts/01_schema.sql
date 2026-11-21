-- M-WAVE  |  01_schema.sql
-- STEP 1: extensions, enum types, 14 tables, constraints.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;   -- used for OTP hashing

-- ---------- enum types (no invalid value can ever be stored) ----------
create type user_role     as enum ('household','driver','operator','regulator');
create type order_status  as enum ('WAITING','BOOKED','FILLED','DISPATCHED','DELIVERED','VERIFIED','CANCELLED');
create type tanker_status as enum ('AVAILABLE','BUSY','BLOCKED');
create type flag_type     as enum ('OVERFILL','SHORT_DELIVERY','OTP_ABUSE');

-- ---------- setup and people ----------
create table profiles (
  user_id    uuid primary key,          -- on Supabase this is the same id as auth.users.id
  role       user_role not null,
  full_name  text      not null,
  phone      text
);

create table areas (
  area_id bigint generated always as identity primary key,
  name    text not null unique,
  zone    text
);

create table property_categories (
  category_id          bigint generated always as identity primary key,
  name                 text not null unique,
  monthly_quota_liters int  not null check (monthly_quota_liters > 0)
);

create table households (
  household_id bigint generated always as identity primary key,
  user_id      uuid   not null unique references profiles(user_id) on update cascade,
  area_id      bigint not null references areas(area_id),
  category_id  bigint not null references property_categories(category_id),
  address      text   not null,
  is_active    boolean not null default true
);

create table stations (
  station_id  bigint generated always as identity primary key,
  name        text   not null unique,
  area_id     bigint not null references areas(area_id),
  operator_id uuid   references profiles(user_id) on update cascade
);

create table tankers (
  tanker_id       bigint generated always as identity primary key,
  plate_no        text not null unique,
  capacity_liters int  not null check (capacity_liters > 0),
  price_per_1000l numeric(10,2) not null check (price_per_1000l >= 0),
  status          tanker_status not null default 'AVAILABLE'
);

create table drivers (
  driver_id      bigint generated always as identity primary key,
  user_id        uuid   not null unique references profiles(user_id) on update cascade,
  license_no     text   not null unique,
  tanker_id      bigint unique references tankers(tanker_id),   -- one driver per tanker
  penalty_points int    not null default 0 check (penalty_points >= 0),
  is_blocked     boolean not null default false
);

-- official price cap per property category (newest row that has started wins)
create table price_rates (
  rate_id             bigint generated always as identity primary key,
  category_id         bigint not null references property_categories(category_id),
  max_price_per_1000l numeric(10,2) not null check (max_price_per_1000l > 0),
  effective_from      timestamptz not null default now(),
  unique (category_id, effective_from)
);

-- ---------- orders and tracking ----------
create table orders (
  order_id         bigint generated always as identity primary key,
  household_id     bigint not null references households(household_id),
  tanker_id        bigint references tankers(tanker_id),
  driver_id        bigint references drivers(driver_id),
  station_id       bigint references stations(station_id),
  volume_liters    int    not null check (volume_liters > 0),
  price            numeric(12,2) check (price is null or price >= 0),
  status           order_status not null default 'WAITING',
  otp_hash         text,
  otp_attempts     int not null default 0 check (otp_attempts >= 0),
  otp_expires_at   timestamptz,
  otp_verified     boolean not null default false,
  delivered_liters int check (delivered_liters is null or delivered_liters >= 0),
  household_rating smallint check (household_rating between 1 and 5),
  booked_at        timestamptz not null default now(),   -- time the order was placed
  filled_at        timestamptz,
  dispatched_at    timestamptz,
  delivered_at     timestamptz,
  verified_at      timestamptz,
  -- once an order is past WAITING it must have a tanker, driver and price
  constraint orders_assigned_chk check (
    status in ('WAITING','CANCELLED')
    or (tanker_id is not null and driver_id is not null and price is not null)
  )
);

-- one row per household per month (first day of the month); the quota check reads this
create table monthly_usage (
  household_id bigint not null references households(household_id),
  month        date   not null check (extract(day from month) = 1),
  liters_used  int    not null default 0 check (liters_used >= 0),
  primary key (household_id, month)
);

-- READ-ONLY (protected by triggers in step 2)
create table order_status_history (
  history_id bigint generated always as identity primary key,
  order_id   bigint not null references orders(order_id),
  old_status order_status,
  new_status order_status not null,
  changed_by uuid,
  changed_at timestamptz not null default now()
);

-- ---------- audit and control ----------
-- READ-ONLY (protected by triggers in step 2): one row per tanker filling
create table filling_audit (
  audit_id        bigint generated always as identity primary key,
  order_id        bigint not null unique references orders(order_id),
  station_id      bigint not null references stations(station_id),
  tanker_id       bigint not null references tankers(tanker_id),
  meter_liters    int    not null check (meter_liters > 0),
  tanker_capacity int    not null check (tanker_capacity > 0),
  recorded_at     timestamptz not null default now()
);

create table fraud_flags (
  flag_id    bigint generated always as identity primary key,
  order_id   bigint not null references orders(order_id),
  tanker_id  bigint references tankers(tanker_id),
  flag_type  flag_type not null,
  details    text,
  created_at timestamptz not null default now(),
  resolved   boolean not null default false
);

create table driver_penalties (
  penalty_id bigint generated always as identity primary key,
  driver_id  bigint not null references drivers(driver_id),
  order_id   bigint references orders(order_id),
  reason     text   not null,
  points     int    not null check (points > 0),
  created_at timestamptz not null default now()
);
