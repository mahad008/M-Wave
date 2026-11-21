-- M-WAVE  |  05_seed.sql
-- STEP 5: sample data for testing and the class demo (fictional).

insert into profiles(user_id, role, full_name, phone) values
 ('00000000-0000-0000-0000-000000000001','household','Ali Raza',      '0300-0000001'),
 ('00000000-0000-0000-0000-000000000002','household','Sara Khan',     '0300-0000002'),
 ('00000000-0000-0000-0000-000000000003','household','Hamza Sheikh',  '0300-0000003'),
 ('00000000-0000-0000-0000-000000000004','household','Ayesha Malik',  '0300-0000004'),
 ('00000000-0000-0000-0000-000000000005','household','Bilal Traders', '0300-0000005'),
 ('00000000-0000-0000-0000-000000000011','driver',   'Kamran Driver', '0311-0000011'),
 ('00000000-0000-0000-0000-000000000012','driver',   'Imran Driver',  '0311-0000012'),
 ('00000000-0000-0000-0000-000000000013','driver',   'Faisal Driver', '0311-0000013'),
 ('00000000-0000-0000-0000-000000000021','operator', 'Station Op 1',  '0322-0000021'),
 ('00000000-0000-0000-0000-000000000022','operator', 'Station Op 2',  '0322-0000022'),
 ('00000000-0000-0000-0000-000000000031','regulator','Regulator',     '0333-0000031');

insert into areas(name, zone) values ('Gulshan','East'), ('Korangi','South'), ('Saddar','Central');

insert into property_categories(name, monthly_quota_liters) values
 ('Small house', 10000), ('Apartment', 6000), ('Commercial', 30000);

-- official price caps (sample numbers, per 1000 L)
insert into price_rates(category_id, max_price_per_1000l) values (1, 900), (2, 900), (3, 1500);

insert into households(user_id, area_id, category_id, address) values
 ('00000000-0000-0000-0000-000000000001', 1, 1, 'House 12, Gulshan'),
 ('00000000-0000-0000-0000-000000000002', 1, 1, 'House 40, Gulshan'),
 ('00000000-0000-0000-0000-000000000003', 2, 2, 'Flat 5, Korangi'),
 ('00000000-0000-0000-0000-000000000004', 2, 2, 'Flat 9, Korangi'),
 ('00000000-0000-0000-0000-000000000005', 3, 3, 'Shop 3, Saddar');

insert into stations(name, area_id, operator_id) values
 ('Gulshan Hydrant', 1, '00000000-0000-0000-0000-000000000021'),
 ('Korangi Hydrant', 2, '00000000-0000-0000-0000-000000000022');

-- tanker 3 charges 1000 per 1000 L: above the residential cap (900), so only commercial can use it
insert into tankers(plate_no, capacity_liters, price_per_1000l) values
 ('KHI-1001', 6000, 800), ('KHI-1002', 8000, 850), ('KHI-1003', 12000, 1000);

insert into drivers(user_id, license_no, tanker_id) values
 ('00000000-0000-0000-0000-000000000011','LIC-001', 1),
 ('00000000-0000-0000-0000-000000000012','LIC-002', 2),
 ('00000000-0000-0000-0000-000000000013','LIC-003', 3);
