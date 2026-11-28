-- Functional tests for supabase/milestone-25.sql (§1–§8).
-- Run against the scratch pm25_test database AFTER the chain + M25 x2.
-- Every test prints Tn PASS or Tn FAIL. Run with ON_ERROR_STOP off;
-- each test catches its own errors inside a DO block.
--
-- Stubs (Supabase-only objects, same as the M23/M24 validators):
--   auth schema + auth.users + auth.uid()/auth.jwt() reading
--   app.test_uid / app.test_email, storage schema + storage.buckets /
--   storage.objects (bootstrap in /tmp/pm25_run.py). No live data.
--
-- Test users (uuids):
--   ordA 66666666-6666-6666-6666-666666666666  ordinary, Ghana, seller
--   ordB 77777777-7777-7777-7777-777777777777  ordinary, Ghana, buyer
--   ordC 88888888-8888-8888-8888-888888888888  ordinary, Ghana, approve flow
--   ordD 99999999-9999-9999-9999-999999999999  ordinary, reject/resubmit/replace/guard flow
--   stuA 11111111-1111-1111-1111-111111111111  student buyer
--   stuB 22222222-2222-2222-2222-222222222222  student seller
--   stuC 12121212-1212-1212-1212-121212121212  student approve flow
--   stuD 13131313-1313-1313-1313-131313131313  student reject/resubmit flow
--   team 44444444-4444-4444-4444-444444444444  pulsemarketsupport@gmail.com
--   stranger 33333333-3333-3333-3333-333333333333

\echo '--- fixtures: users + storage objects ---'
select set_config('app.test_uid', '', false);
select set_config('app.test_email', '', false);
insert into auth.users (id, email) values
  ('66666666-6666-6666-6666-666666666666', 'orda@test.local'),
  ('77777777-7777-7777-7777-777777777777', 'ordb@test.local'),
  ('88888888-8888-8888-8888-888888888888', 'ordc@test.local'),
  ('99999999-9999-9999-9999-999999999999', 'ordd@test.local'),
  ('11111111-1111-1111-1111-111111111111', 'buyer@test.local'),
  ('22222222-2222-2222-2222-222222222222', 'seller@test.local'),
  ('12121212-1212-1212-1212-121212121212', 'stuc@test.local'),
  ('13131313-1313-1313-1313-131313131313', 'stud@test.local'),
  ('44444444-4444-4444-4444-444444444444', 'pulsemarketsupport@gmail.com'),
  ('33333333-3333-3333-3333-333333333333', 'stranger@test.local');
insert into storage.buckets (id, name, public) values ('verification-ids', 'verification-ids', false) on conflict (id) do nothing;
insert into storage.objects (bucket_id, name) values
  ('verification-ids', '66666666-6666-6666-6666-666666666666/selfie-1.jpg'),
  ('verification-ids', '77777777-7777-7777-7777-777777777777/selfie-1.jpg'),
  ('verification-ids', '88888888-8888-8888-8888-888888888888/selfie-1.jpg'),
  ('verification-ids', '99999999-9999-9999-9999-999999999999/selfie-1.jpg'),
  ('verification-ids', '99999999-9999-9999-9999-999999999999/selfie-2.jpg'),
  ('verification-ids', '99999999-9999-9999-9999-999999999999/selfie-3.jpg'),
  ('verification-ids', '99999999-9999-9999-9999-999999999999/front-1.jpg'),
  ('verification-ids', '99999999-9999-9999-9999-999999999999/front-2.jpg'),
  ('verification-ids', '12121212-1212-1212-1212-121212121212/id-front-1.jpg'),
  ('verification-ids', '12121212-1212-1212-1212-121212121212/id-back-1.jpg'),
  ('verification-ids', '13131313-1313-1313-1313-131313131313/id-front-1.jpg'),
  ('verification-ids', '13131313-1313-1313-1313-131313131313/id-back-1.jpg'),
  ('verification-ids', '13131313-1313-1313-1313-131313131313/id-front-2.jpg'),
  ('verification-ids', '13131313-1313-1313-1313-131313131313/id-back-2.jpg');

\echo '--- fixtures: approved student buyer + seller (auth null seeding) ---'
insert into public.verifications (user_id, university, student_id, student_email, invite_code, status, flagged) values
  ('11111111-1111-1111-1111-111111111111', 'University of Port Harcourt', 'U2026/001', 'buyer@uniport.edu.ng', 'PM-BUYER1', 'approved', false),
  ('22222222-2222-2222-2222-222222222222', 'University of Port Harcourt', 'U2026/002', 'seller@uniport.edu.ng', 'PM-SELLER1', 'approved', false);

\echo '--- fixtures: ordinary verifications via the real insert path (as each user) ---'
select set_config('app.test_uid', '66666666-6666-6666-6666-666666666666', false);
select set_config('app.test_email', 'orda@test.local', false);
insert into public.verifications (user_id, account_type, full_name, country, currency, face_photo_url, invite_code) values
  ('66666666-6666-6666-6666-666666666666', 'ordinary', 'Ama Mensah', 'Ghana', 'GHS', '66666666-6666-6666-6666-666666666666/selfie-1.jpg', 'PM-ORDA1');
select set_config('app.test_uid', '77777777-7777-7777-7777-777777777777', false);
select set_config('app.test_email', 'ordb@test.local', false);
insert into public.verifications (user_id, account_type, full_name, country, currency, face_photo_url, invite_code) values
  ('77777777-7777-7777-7777-777777777777', 'ordinary', 'Kwame Boateng', 'Ghana', 'GHS', '77777777-7777-7777-7777-777777777777/selfie-1.jpg', 'PM-ORDB1');
select set_config('app.test_uid', '88888888-8888-8888-8888-888888888888', false);
select set_config('app.test_email', 'ordc@test.local', false);
insert into public.verifications (user_id, account_type, full_name, country, currency, face_photo_url, invite_code) values
  ('88888888-8888-8888-8888-888888888888', 'ordinary', 'Efua Asante', 'Ghana', 'GHS', '88888888-8888-8888-8888-888888888888/selfie-1.jpg', 'PM-ORDC1');
select set_config('app.test_uid', '99999999-9999-9999-9999-999999999999', false);
select set_config('app.test_email', 'ordd@test.local', false);
insert into public.verifications (user_id, account_type, full_name, country, currency, face_photo_url, invite_code) values
  ('99999999-9999-9999-9999-999999999999', 'ordinary', 'Yaw Owusu', 'Ghana', 'GHS', '99999999-9999-9999-9999-999999999999/selfie-1.jpg', 'PM-ORDD1');

\echo '--- fixtures: team approves ordA + ordB (ordC/ordD are approved/rejected inside the tests) ---'
select set_config('app.test_uid', '44444444-4444-4444-4444-444444444444', false);
select set_config('app.test_email', 'pulsemarketsupport@gmail.com', false);
select public.review_verification('66666666-6666-6666-6666-666666666666', 'approved');
select public.review_verification('77777777-7777-7777-7777-777777777777', 'approved');

\echo '--- T1: ordinary signup ordC is pending review ---'
do $$
declare v_st text; v_at text; v_c text; v_cur text;
begin
  select status, account_type, country, currency into v_st, v_at, v_c, v_cur
    from public.verifications where user_id = '88888888-8888-8888-8888-888888888888';
  if v_st = 'pending review' and v_at = 'ordinary' and v_c = 'Ghana' and v_cur = 'GHS' then
    raise notice 'T1 PASS: ordinary signup pending review (ordinary/Ghana/GHS)';
  else raise notice 'T1 FAIL: status=% type=% country=% currency=%', v_st, v_at, v_c, v_cur; end if;
exception when others then raise notice 'T1 FAIL: %', sqlerrm;
end $$;

\echo '--- T2: approve ordC via review_verification ---'
do $$
declare v_st text;
begin
  perform public.review_verification('88888888-8888-8888-8888-888888888888', 'approved');
  select status into v_st from public.verifications where user_id = '88888888-8888-8888-8888-888888888888';
  if v_st = 'approved' then raise notice 'T2 PASS: ordinary row approved';
  else raise notice 'T2 FAIL: status=%', v_st; end if;
exception when others then raise notice 'T2 FAIL: %', sqlerrm;
end $$;

\echo '--- T3: reject ordD with reason blurry selfie ---'
do $$
declare v_st text; v_r text;
begin
  perform public.review_verification('99999999-9999-9999-9999-999999999999', 'rejected', 'blurry selfie');
  select status, rejection_reason into v_st, v_r from public.verifications where user_id = '99999999-9999-9999-9999-999999999999';
  if v_st = 'rejected' and v_r = 'blurry selfie' then raise notice 'T3 PASS: ordinary row rejected, reason stored';
  else raise notice 'T3 FAIL: status=% reason=%', v_st, v_r; end if;
exception when others then raise notice 'T3 FAIL: %', sqlerrm;
end $$;

\echo '--- T4: resubmit rejected ordD via resubmit_face_verification ---'
select set_config('app.test_uid', '99999999-9999-9999-9999-999999999999', false);
select set_config('app.test_email', 'ordd@test.local', false);
do $$
declare v_st text; v_r text; v_face text;
begin
  perform public.resubmit_face_verification('99999999-9999-9999-9999-999999999999/selfie-2.jpg', null);
  select status, rejection_reason, face_photo_url into v_st, v_r, v_face
    from public.verifications where user_id = '99999999-9999-9999-9999-999999999999';
  if v_st = 'pending review' and v_r is null and v_face = '99999999-9999-9999-9999-999999999999/selfie-2.jpg' then
    raise notice 'T4 PASS: face resubmit back to pending review, reason cleared, new selfie stored';
  else raise notice 'T4 FAIL: status=% reason=% face=%', v_st, v_r, v_face; end if;
exception when others then raise notice 'T4 FAIL: %', sqlerrm;
end $$;

\echo '--- T5: second identical face resubmit refused ---'
do $$
begin
  perform public.resubmit_face_verification('99999999-9999-9999-9999-999999999999/selfie-2.jpg', null);
  raise notice 'T5 FAIL: second identical resubmit was accepted';
exception when others then
  if sqlerrm like '%Only a rejected verification can be resubmitted%' then raise notice 'T5 PASS: second resubmit refused';
  else raise notice 'T5 FAIL: wrong error: %', sqlerrm; end if;
end $$;

\echo '--- T6: replace photos while pending review ---'
do $$
declare v_face text; v_st text;
begin
  perform public.replace_face_verification_photos('99999999-9999-9999-9999-999999999999/selfie-3.jpg', null);
  select face_photo_url, status into v_face, v_st from public.verifications where user_id = '99999999-9999-9999-9999-999999999999';
  if v_face = '99999999-9999-9999-9999-999999999999/selfie-3.jpg' and v_st = 'pending review' then
    raise notice 'T6 PASS: face photos replaced while pending review';
  else raise notice 'T6 FAIL: face=% status=%', v_face, v_st; end if;
exception when others then raise notice 'T6 FAIL: %', sqlerrm;
end $$;

\echo '--- T7: ordinary row calling student resubmit_verification refused (guard) ---'
do $$
begin
  perform public.resubmit_verification('99999999-9999-9999-9999-999999999999/front-1.jpg', '99999999-9999-9999-9999-999999999999/front-2.jpg');
  raise notice 'T7 FAIL: student resubmit on an ordinary row was accepted';
exception when others then
  if sqlerrm like '%This is for student verifications%' then raise notice 'T7 PASS: student resubmit refused for ordinary row';
  else raise notice 'T7 FAIL: wrong error: %', sqlerrm; end if;
end $$;

\echo '--- T8: ordinary row calling student replace_verification_photos refused (guard) ---'
do $$
begin
  perform public.replace_verification_photos('99999999-9999-9999-9999-999999999999/front-1.jpg', '99999999-9999-9999-9999-999999999999/front-2.jpg');
  raise notice 'T8 FAIL: student replace-photos on an ordinary row was accepted';
exception when others then
  if sqlerrm like '%This is for student verifications%' then raise notice 'T8 PASS: student replace-photos refused for ordinary row';
  else raise notice 'T8 FAIL: wrong error: %', sqlerrm; end if;
end $$;

\echo '--- fixtures: student verifications via the real insert path ---'
select set_config('app.test_uid', '12121212-1212-1212-1212-121212121212', false);
select set_config('app.test_email', 'stuc@test.local', false);
insert into public.verifications (user_id, university, student_id, student_email, invite_code, id_front_url, id_back_url) values
  ('12121212-1212-1212-1212-121212121212', 'University of Port Harcourt', 'U2026/012', 'stuc@uniport.edu.ng', 'PM-STUC1', '12121212-1212-1212-1212-121212121212/id-front-1.jpg', '12121212-1212-1212-1212-121212121212/id-back-1.jpg');
select set_config('app.test_uid', '13131313-1313-1313-1313-131313131313', false);
select set_config('app.test_email', 'stud@test.local', false);
insert into public.verifications (user_id, university, student_id, student_email, invite_code, id_front_url, id_back_url) values
  ('13131313-1313-1313-1313-131313131313', 'University of Port Harcourt', 'U2026/013', 'stud@uniport.edu.ng', 'PM-STUD1', '13131313-1313-1313-1313-131313131313/id-front-1.jpg', '13131313-1313-1313-1313-131313131313/id-back-1.jpg');

\echo '--- T9: student flow unchanged — approve stuC ---'
select set_config('app.test_uid', '44444444-4444-4444-4444-444444444444', false);
select set_config('app.test_email', 'pulsemarketsupport@gmail.com', false);
do $$
declare v_st text;
begin
  perform public.review_verification('12121212-1212-1212-1212-121212121212', 'approved');
  select status into v_st from public.verifications where user_id = '12121212-1212-1212-1212-121212121212';
  if v_st = 'approved' then raise notice 'T9 PASS: student row approved';
  else raise notice 'T9 FAIL: status=%', v_st; end if;
exception when others then raise notice 'T9 FAIL: %', sqlerrm;
end $$;

\echo '--- T10: student reject + student resubmit_verification still works ---'
do $$
declare v_st text; v_r text;
begin
  perform public.review_verification('13131313-1313-1313-1313-131313131313', 'rejected', 'blurry');
  select status, rejection_reason into v_st, v_r from public.verifications where user_id = '13131313-1313-1313-1313-131313131313';
  if not (v_st = 'rejected' and v_r = 'blurry') then raise notice 'T10 FAIL: reject step status=% reason=%', v_st, v_r; return; end if;
exception when others then raise notice 'T10 FAIL: reject raised: %', sqlerrm; return;
end $$;
select set_config('app.test_uid', '13131313-1313-1313-1313-131313131313', false);
select set_config('app.test_email', 'stud@test.local', false);
do $$
declare v_st text; v_r text; v_f text;
begin
  perform public.resubmit_verification('13131313-1313-1313-1313-131313131313/id-front-2.jpg', '13131313-1313-1313-1313-131313131313/id-back-2.jpg');
  select status, rejection_reason, id_front_url into v_st, v_r, v_f
    from public.verifications where user_id = '13131313-1313-1313-1313-131313131313';
  if v_st = 'pending review' and v_r is null and v_f = '13131313-1313-1313-1313-131313131313/id-front-2.jpg' then
    raise notice 'T10 PASS: student resubmit works, back to pending review, reason cleared';
  else raise notice 'T10 FAIL: status=% reason=% front=%', v_st, v_r, v_f; end if;
exception when others then raise notice 'T10 FAIL: resubmit raised: %', sqlerrm;
end $$;

\echo '--- T11: chat gate student/student approved pair true ---'
do $$
begin
  if public.pm_chat_verification_ok('12121212-1212-1212-1212-121212121212', '22222222-2222-2222-2222-222222222222') then
    raise notice 'T11 PASS: pm_chat_verification_ok(approved student, approved student) true';
  else raise notice 'T11 FAIL: returned false for approved pair'; end if;
exception when others then raise notice 'T11 FAIL: %', sqlerrm;
end $$;

\echo '--- T12: chat gate unapproved pair false ---'
do $$
begin
  if not public.pm_chat_verification_ok('13131313-1313-1313-1313-131313131313', '22222222-2222-2222-2222-222222222222') then
    raise notice 'T12 PASS: pm_chat_verification_ok(pending student, approved student) false';
  else raise notice 'T12 FAIL: returned true for unapproved pair'; end if;
exception when others then raise notice 'T12 FAIL: %', sqlerrm;
end $$;

\echo '--- T13: chat gate approved ordinary + approved student true ---'
do $$
begin
  if public.pm_chat_verification_ok('88888888-8888-8888-8888-888888888888', '22222222-2222-2222-2222-222222222222') then
    raise notice 'T13 PASS: pm_chat_verification_ok(approved ordinary, approved student) true';
  else raise notice 'T13 FAIL: returned false'; end if;
exception when others then raise notice 'T13 FAIL: %', sqlerrm;
end $$;

\echo '--- T14: chat gate approved ordinary + approved ordinary true ---'
do $$
begin
  if public.pm_chat_verification_ok('88888888-8888-8888-8888-888888888888', '66666666-6666-6666-6666-666666666666') then
    raise notice 'T14 PASS: pm_chat_verification_ok(approved ordinary, approved ordinary) true';
  else raise notice 'T14 FAIL: returned false'; end if;
exception when others then raise notice 'T14 FAIL: %', sqlerrm;
end $$;

\echo '--- T15: fee NGN 5000 held -> (250,175) total 5425 ---'
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(5000, 'held', 'NGN');
  if v_s = 250 and v_c = 175 then raise notice 'T15 PASS: NGN 5000 held (250,175) total 5425';
  else raise notice 'T15 FAIL: got (% , %)', v_s, v_c; end if;
exception when others then raise notice 'T15 FAIL: %', sqlerrm;
end $$;

\echo '--- T16: fee NGN 4000 held -> (150,160) total 4310 ---'
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(4000, 'held', 'NGN');
  if v_s = 150 and v_c = 160 then raise notice 'T16 PASS: NGN 4000 held (150,160) total 4310';
  else raise notice 'T16 FAIL: got (% , %)', v_s, v_c; end if;
exception when others then raise notice 'T16 FAIL: %', sqlerrm;
end $$;

\echo '--- T17: fee NGN 100 cash -> (0,0) ---'
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(100, 'cash', 'NGN');
  if v_s = 0 and v_c = 0 then raise notice 'T17 PASS: NGN 100 cash (0,0)';
  else raise notice 'T17 FAIL: got (% , %)', v_s, v_c; end if;
exception when others then raise notice 'T17 FAIL: %', sqlerrm;
end $$;

\echo '--- T18: fee USD 100 held -> (2,3) total 105 ---'
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(100, 'held', 'USD');
  if v_s = 2 and v_c = 3 then raise notice 'T18 PASS: USD 100 held (2,3) total 105';
  else raise notice 'T18 FAIL: got (% , %)', v_s, v_c; end if;
exception when others then raise notice 'T18 FAIL: %', sqlerrm;
end $$;

\echo '--- T19: fee USD 2 held -> (1,1) ---'
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(2, 'held', 'USD');
  if v_s = 1 and v_c = 1 then raise notice 'T19 PASS: USD 2 held (1,1)';
  else raise notice 'T19 FAIL: got (% , %)', v_s, v_c; end if;
exception when others then raise notice 'T19 FAIL: %', sqlerrm;
end $$;

\echo '--- T20: fee USD 100 cash -> (0,0) ---'
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(100, 'cash', 'USD');
  if v_s = 0 and v_c = 0 then raise notice 'T20 PASS: USD 100 cash (0,0)';
  else raise notice 'T20 FAIL: got (% , %)', v_s, v_c; end if;
exception when others then raise notice 'T20 FAIL: %', sqlerrm;
end $$;

\echo '--- T21: fee GBP 100 held -> (2,3) total 105 ---'
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(100, 'held', 'GBP');
  if v_s = 2 and v_c = 3 then raise notice 'T21 PASS: GBP 100 held (2,3) total 105';
  else raise notice 'T21 FAIL: got (% , %)', v_s, v_c; end if;
exception when others then raise notice 'T21 FAIL: %', sqlerrm;
end $$;

\echo '--- fixtures: listings for the order tests (as each seller) ---'
select set_config('app.test_uid', '22222222-2222-2222-2222-222222222222', false);
select set_config('app.test_email', 'seller@test.local', false);
insert into public.listings (id, seller_id, seller_label, title, description, price, condition, category, university, state, ships_to, status, photos, delivery_methods, meetup_spot, courier, currency, country) values
  ('d1111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'Seller', 'USD item', 'Test item in good condition', 100, 'Good', 'Phones & gadgets', 'University of Port Harcourt', 'Rivers', 'same_state', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/22222222-2222-2222-2222-222222222222/photo1.jpg'], ARRAY['meetup'], 'Police station', null, 'USD', 'Nigeria'),
  ('d2222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222', 'Seller', 'GBP item', 'Test item in good condition', 100, 'Good', 'Phones & gadgets', 'University of Port Harcourt', 'Rivers', 'same_state', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/22222222-2222-2222-2222-222222222222/photo1.jpg'], ARRAY['meetup'], 'Police station', null, 'GBP', 'Nigeria'),
  ('d3333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222', 'Seller', 'GBP bad-fee item', 'Test item in good condition', 100, 'Good', 'Phones & gadgets', 'University of Port Harcourt', 'Rivers', 'same_state', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/22222222-2222-2222-2222-222222222222/photo1.jpg'], ARRAY['meetup'], 'Police station', null, 'GBP', 'Nigeria'),
  ('d4444444-4444-4444-4444-444444444444', '22222222-2222-2222-2222-222222222222', 'Seller', 'Cross-state bus item', 'Test item in good condition', 5000, 'Good', 'Phones & gadgets', 'University of Port Harcourt', 'Rivers', 'nationwide', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/22222222-2222-2222-2222-222222222222/photo1.jpg'], ARRAY['shipping'], null, 'God is Good Motors', 'NGN', 'Nigeria'),
  ('d5555555-5555-5555-5555-555555555555', '22222222-2222-2222-2222-222222222222', 'Seller', 'Same-state flight item', 'Test item in good condition', 5000, 'Good', 'Phones & gadgets', 'University of Port Harcourt', 'Rivers', 'nationwide', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/22222222-2222-2222-2222-222222222222/photo1.jpg'], ARRAY['shipping'], null, 'Air Peace flight', 'NGN', 'Nigeria'),
  ('d6666666-6666-6666-6666-666666666666', '22222222-2222-2222-2222-222222222222', 'Seller', 'Police station meetup item', 'Test item in good condition', 3000, 'Good', 'Books & study', 'University of Port Harcourt', 'Rivers', 'same_state', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/22222222-2222-2222-2222-222222222222/photo1.jpg'], ARRAY['meetup'], 'Police station', null, 'NGN', 'Nigeria'),
  ('d7777777-7777-7777-7777-777777777777', '22222222-2222-2222-2222-222222222222', 'Seller', 'Campus meetup item', 'Test item in good condition', 3000, 'Good', 'Books & study', 'University of Port Harcourt', 'Rivers', 'same_state', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/22222222-2222-2222-2222-222222222222/photo1.jpg'], ARRAY['meetup'], 'University main gate', null, 'NGN', 'Nigeria');
select set_config('app.test_uid', '66666666-6666-6666-6666-666666666666', false);
select set_config('app.test_email', 'orda@test.local', false);
insert into public.listings (id, seller_id, seller_label, title, description, price, condition, category, university, state, ships_to, status, photos, delivery_methods, meetup_spot, courier, currency, country) values
  ('d8888888-8888-8888-8888-888888888888', '66666666-6666-6666-6666-666666666666', 'Seller', 'Ghana DHL item', 'Test item in good condition', 5000, 'Good', 'Phones & gadgets', null, 'Greater Accra', 'nationwide', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/66666666-6666-6666-6666-666666666666/photo1.jpg'], ARRAY['shipping'], null, 'DHL International', 'GHS', 'Ghana'),
  ('d9999999-9999-9999-9999-999999999999', '66666666-6666-6666-6666-666666666666', 'Seller', 'Ghana bus item', 'Test item in good condition', 5000, 'Good', 'Phones & gadgets', null, 'Greater Accra', 'nationwide', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/66666666-6666-6666-6666-666666666666/photo1.jpg'], ARRAY['shipping'], null, 'STC Coaches', 'GHS', 'Ghana');
-- (M25 shipping change) Extra shipping listings for the free-text
-- transport tests: db111111 for the no-transport-name refusals
-- (T28/T29 — refused inserts never create an order, so the listing
-- stays free), db222222 (price 25000, over the old ₦20,000 tier-1
-- threshold) for the no-tier-restriction test (T30).
select set_config('app.test_uid', '22222222-2222-2222-2222-222222222222', false);
select set_config('app.test_email', 'seller@test.local', false);
insert into public.listings (id, seller_id, seller_label, title, description, price, condition, category, university, state, ships_to, status, photos, delivery_methods, meetup_spot, courier, currency, country) values
  ('db111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 'Seller', 'Free-text bus item', 'Test item in good condition', 5000, 'Good', 'Phones & gadgets', 'University of Port Harcourt', 'Rivers', 'nationwide', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/22222222-2222-2222-2222-222222222222/photo1.jpg'], ARRAY['shipping'], null, 'God is Good Motors', 'NGN', 'Nigeria'),
  ('db222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222', 'Seller', 'High-value bus item', 'Test item in good condition', 25000, 'Good', 'Phones & gadgets', 'University of Port Harcourt', 'Rivers', 'nationwide', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/22222222-2222-2222-2222-222222222222/photo1.jpg'], ARRAY['shipping'], null, 'God is Good Motors', 'NGN', 'Nigeria');

\echo '--- T22: USD order accepted with helper fees ---'
select set_config('app.test_uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('app.test_email', 'buyer@test.local', false);
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(100, 'held', 'USD');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, meetup_spot, currency)
    values ('e1111111-1111-1111-1111-111111111111', 'PM-ORD-M25001', 'd1111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 100, v_s, v_c, 0, 100 + v_s + v_c, 'held', 'meetup', 'reserved', 'Police station', 'USD');
  raise notice 'T22 PASS: USD order accepted with helper fees (service %, secure %) total %', v_s, v_c, 100 + v_s + v_c;
exception when others then raise notice 'T22 FAIL: %', sqlerrm;
end $$;

\echo '--- T23: GBP order accepted with helper fees ---'
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(100, 'held', 'GBP');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, meetup_spot, currency)
    values ('e2222222-2222-2222-2222-222222222222', 'PM-ORD-M25002', 'd2222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 100, v_s, v_c, 0, 100 + v_s + v_c, 'held', 'meetup', 'reserved', 'Police station', 'GBP');
  raise notice 'T23 PASS: GBP order accepted with helper fees (service %, secure %) total %', v_s, v_c, 100 + v_s + v_c;
exception when others then raise notice 'T23 FAIL: %', sqlerrm;
end $$;

\echo '--- T24: GBP order with a wrong fee refused ---'
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(100, 'held', 'GBP');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, meetup_spot, currency)
    values ('e3333333-3333-3333-3333-333333333333', 'PM-ORD-M25003', 'd3333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 100, v_s + 1, v_c, 0, 100 + v_s + 1 + v_c, 'held', 'meetup', 'reserved', 'Police station', 'GBP');
  raise notice 'T24 FAIL: wrong-fee GBP order was accepted';
exception when others then
  if sqlerrm like '%fees on this order do not match%' then raise notice 'T24 PASS: wrong-fee GBP order refused';
  else raise notice 'T24 FAIL: wrong error: %', sqlerrm; end if;
end $$;

\echo '--- T25: DHL International cross-country order passes ---'
do $$
declare v_s integer; v_c integer; v_ship integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(5000, 'held', 'GHS');
  v_ship := public.pm_shipping_fee('Greater Accra', 'Lagos');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, ship_to_state, ship_to_country, courier, currency)
    values ('e4444444-4444-4444-4444-444444444444', 'PM-ORD-M25004', 'd8888888-8888-8888-8888-888888888888', '11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', 5000, v_s, v_c, v_ship, 5000 + v_s + v_c + v_ship, 'held', 'shipping', 'reserved', 'Lagos', 'Nigeria', 'DHL International', 'GHS');
  raise notice 'T25 PASS: DHL International Ghana->Nigeria order accepted (fees %, % ship %)', v_s, v_c, v_ship;
exception when others then raise notice 'T25 FAIL: %', sqlerrm;
end $$;

\echo '--- T26: free-text transport name accepted (God is Good Motors, cross-state) ---'
do $$
declare v_s integer; v_c integer; v_ship integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(5000, 'held', 'NGN');
  v_ship := public.pm_shipping_fee('Rivers', 'Lagos');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, ship_to_state, ship_to_country, courier, currency)
    values ('e5555555-5555-5555-5555-555555555555', 'PM-ORD-M25005', 'd4444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 5000, v_s, v_c, v_ship, 5000 + v_s + v_c + v_ship, 'held', 'shipping', 'reserved', 'Lagos', 'Nigeria', 'God is Good Motors', 'NGN');
  raise notice 'T26 PASS: free-text transport God is Good Motors accepted cross-state (ship %)', v_ship;
exception when others then raise notice 'T26 FAIL: %', sqlerrm;
end $$;

\echo '--- T27: plate/flight number stored (Air Peace flight, P47108) ---'
do $$
declare v_s integer; v_c integer; v_ship integer; v_co text; v_ref text;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(5000, 'held', 'NGN');
  v_ship := public.pm_shipping_fee('Rivers', 'Rivers');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, ship_to_state, ship_to_country, courier, transport_ref, currency)
    values ('e6666666-6666-6666-6666-666666666666', 'PM-ORD-M25006', 'd5555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 5000, v_s, v_c, v_ship, 5000 + v_s + v_c + v_ship, 'held', 'shipping', 'reserved', 'Rivers', 'Nigeria', 'Air Peace flight', 'P47108', 'NGN');
  select courier, transport_ref into v_co, v_ref from public.orders where id = 'e6666666-6666-6666-6666-666666666666';
  if v_co = 'Air Peace flight' and v_ref = 'P47108' then raise notice 'T27 PASS: stored row shows courier=Air Peace flight, transport_ref=P47108';
  else raise notice 'T27 FAIL: stored courier=% transport_ref=%', v_co, v_ref; end if;
exception when others then raise notice 'T27 FAIL: %', sqlerrm;
end $$;

\echo '--- T28: shipping order refused with no transport name (courier null AND courier blank) ---'
do $$
declare v_s integer; v_c integer; v_ship integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(5000, 'held', 'NGN');
  v_ship := public.pm_shipping_fee('Rivers', 'Rivers');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, ship_to_state, ship_to_country, courier, currency)
    values ('eaa00001-1111-1111-1111-111111111111', 'PM-ORD-M25028', 'db111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 5000, v_s, v_c, v_ship, 5000 + v_s + v_c + v_ship, 'held', 'shipping', 'reserved', 'Rivers', 'Nigeria', null, 'NGN');
  raise notice 'T28 FAIL: shipping order with courier null was accepted';
exception when others then
  if sqlerrm like '%Type the name of the transport for this shipment.%' then raise notice 'T28 PASS (part 1): courier null refused';
  else raise notice 'T28 FAIL: wrong error: %', sqlerrm; end if;
end $$;
do $$
declare v_s integer; v_c integer; v_ship integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(5000, 'held', 'NGN');
  v_ship := public.pm_shipping_fee('Rivers', 'Rivers');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, ship_to_state, ship_to_country, courier, currency)
    values ('eaa00002-1111-1111-1111-111111111111', 'PM-ORD-M25029', 'db111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 5000, v_s, v_c, v_ship, 5000 + v_s + v_c + v_ship, 'held', 'shipping', 'reserved', 'Rivers', 'Nigeria', '   ', 'NGN');
  raise notice 'T28 FAIL: shipping order with blank courier was accepted';
exception when others then
  if sqlerrm like '%Type the name of the transport for this shipment.%' then raise notice 'T28 PASS (part 2): blank courier refused';
  else raise notice 'T28 FAIL: wrong error: %', sqlerrm; end if;
end $$;

\echo '--- T29: shipping order refused with no transport name but transport_ref present ---'
do $$
declare v_s integer; v_c integer; v_ship integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(5000, 'held', 'NGN');
  v_ship := public.pm_shipping_fee('Rivers', 'Rivers');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, ship_to_state, ship_to_country, courier, transport_ref, currency)
    values ('eaa00003-1111-1111-1111-111111111111', 'PM-ORD-M25030', 'db111111-1111-1111-1111-111111111111', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 5000, v_s, v_c, v_ship, 5000 + v_s + v_c + v_ship, 'held', 'shipping', 'reserved', 'Rivers', 'Nigeria', null, 'ABC123', 'NGN');
  raise notice 'T29 FAIL: shipping order with transport_ref but no name was accepted';
exception when others then
  if sqlerrm like '%Type the name of the transport for this shipment.%' then raise notice 'T29 PASS: transport_ref alone is not enough, name still required';
  else raise notice 'T29 FAIL: wrong error: %', sqlerrm; end if;
end $$;

\echo '--- T30: high-value order (25000, over old 20000 tier-1 threshold) with free-text bus transport accepted ---'
do $$
declare v_s integer; v_c integer; v_ship integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(25000, 'held', 'NGN');
  v_ship := public.pm_shipping_fee('Rivers', 'Lagos');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, ship_to_state, ship_to_country, courier, currency)
    values ('eaa00004-1111-1111-1111-111111111111', 'PM-ORD-M25031', 'db222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 25000, v_s, v_c, v_ship, 25000 + v_s + v_c + v_ship, 'held', 'shipping', 'reserved', 'Lagos', 'Nigeria', 'God is Good Motors', 'NGN');
  raise notice 'T30 PASS: high-value order with free-text bus transport accepted, no tier restriction (fees %, % ship %)', v_s, v_c, v_ship;
exception when others then raise notice 'T30 FAIL: %', sqlerrm;
end $$;

\echo '--- T31: rider details — seller on same-city order accepted, on cross-state order refused ---'
-- Move both shipping orders to held with auth null (trigger bypass,
-- the established seeding pattern): T26 order e5555555 is
-- cross-state (Lagos vs Rivers), T27 order e6666666 is same-city
-- (Rivers vs Rivers). Both carry free-text transport names.
select set_config('app.test_uid', '', false);
select set_config('app.test_email', '', false);
update public.orders set status = 'held' where id in ('e5555555-5555-5555-5555-555555555555', 'e6666666-6666-6666-6666-666666666666');
select set_config('app.test_uid', '22222222-2222-2222-2222-222222222222', false);
select set_config('app.test_email', 'seller@test.local', false);
do $$
declare v_n text; v_p text;
begin
  update public.orders set rider_name = 'Chidi Rider', rider_phone = '+2348012345678' where id = 'e6666666-6666-6666-6666-666666666666';
  select rider_name, rider_phone into v_n, v_p from public.orders where id = 'e6666666-6666-6666-6666-666666666666';
  if v_n = 'Chidi Rider' and v_p = '+2348012345678' then raise notice 'T31 PASS (part 1): seller set rider details on same-city order with free-text transport';
  else raise notice 'T31 FAIL: rider_name=% rider_phone=%', v_n, v_p; end if;
exception when others then raise notice 'T31 FAIL: same-city rider update raised: %', sqlerrm;
end $$;
do $$
begin
  update public.orders set rider_name = 'Chidi Rider', rider_phone = '+2348012345678' where id = 'e5555555-5555-5555-5555-555555555555';
  raise notice 'T31 FAIL: seller set rider details on cross-state order';
exception when others then
  if sqlerrm like '%except the seller for a held or shipped same-city order%' then raise notice 'T31 PASS (part 2): seller rider update on cross-state order refused';
  else raise notice 'T31 FAIL: wrong error: %', sqlerrm; end if;
end $$;

\echo '--- T32: meetup at Police station passes ---'
select set_config('app.test_uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('app.test_email', 'buyer@test.local', false);
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(3000, 'held', 'NGN');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, meetup_spot, currency)
    values ('e8888888-8888-8888-8888-888888888888', 'PM-ORD-M25008', 'd6666666-6666-6666-6666-666666666666', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 3000, v_s, v_c, 0, 3000 + v_s + v_c, 'held', 'meetup', 'reserved', 'Police station', 'NGN');
  raise notice 'T32 PASS: meetup at Police station accepted';
exception when others then raise notice 'T32 FAIL: %', sqlerrm;
end $$;

\echo '--- T33: meetup at campus spot still passes ---'
do $$
declare v_s integer; v_c integer;
begin
  select service_fee, secure_fee into v_s, v_c from public.pm_fee_breakdown(3000, 'held', 'NGN');
  insert into public.orders (id, code, listing_id, buyer_id, seller_id, item_price, service_fee, secure_fee, shipping_fee, total, payment_method, delivery_method, status, meetup_spot, currency)
    values ('e9999999-9999-9999-9999-999999999999', 'PM-ORD-M25009', 'd7777777-7777-7777-7777-777777777777', '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', 3000, v_s, v_c, 0, 3000 + v_s + v_c, 'held', 'meetup', 'reserved', 'University main gate', 'NGN');
  raise notice 'T33 PASS: meetup at campus spot accepted';
exception when others then raise notice 'T33 FAIL: %', sqlerrm;
end $$;

\echo '--- T34: ordinary seller listing (Ghana/GHS, university NULL) accepted ---'
select set_config('app.test_uid', '66666666-6666-6666-6666-666666666666', false);
select set_config('app.test_email', 'orda@test.local', false);
do $$
declare v_c text; v_cur text; v_u text;
begin
  insert into public.listings (id, seller_id, seller_label, title, description, price, condition, category, university, state, ships_to, status, photos, delivery_methods, meetup_spot, courier, currency, country)
    values ('da111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666', 'Seller', 'Ghana ordinary item', 'Test item in good condition', 2000, 'Good', 'Fashion', null, 'Greater Accra', 'same_state', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/66666666-6666-6666-6666-666666666666/photo1.jpg'], ARRAY['meetup'], 'Shopping mall', null, 'GHS', 'Ghana');
  select country, currency, university into v_c, v_cur, v_u from public.listings where id = 'da111111-1111-1111-1111-111111111111';
  if v_c = 'Ghana' and v_cur = 'GHS' and v_u is null then raise notice 'T34 PASS: ordinary seller listing accepted (Ghana/GHS, university NULL)';
  else raise notice 'T34 FAIL: country=% currency=% university=%', v_c, v_cur, v_u; end if;
exception when others then raise notice 'T34 FAIL: %', sqlerrm;
end $$;

\echo '--- T35: student listing with university set accepted unchanged ---'
select set_config('app.test_uid', '22222222-2222-2222-2222-222222222222', false);
select set_config('app.test_email', 'seller@test.local', false);
do $$
declare v_u text;
begin
  insert into public.listings (id, seller_id, seller_label, title, description, price, condition, category, university, state, ships_to, status, photos, delivery_methods, meetup_spot, courier, currency, country)
    values ('da222222-2222-2222-2222-222222222222', '22222222-2222-2222-2222-222222222222', 'Seller', 'Student item', 'Test item in good condition', 2000, 'Good', 'Fashion', 'University of Port Harcourt', 'Rivers', 'same_state', 'active', ARRAY['https://x/storage/v1/object/public/listing-media/22222222-2222-2222-2222-222222222222/photo1.jpg'], ARRAY['meetup'], 'University main gate', null, 'NGN', 'Nigeria');
  select university into v_u from public.listings where id = 'da222222-2222-2222-2222-222222222222';
  if v_u = 'University of Port Harcourt' then raise notice 'T35 PASS: student listing with university accepted';
  else raise notice 'T35 FAIL: university=%', v_u; end if;
exception when others then raise notice 'T35 FAIL: %', sqlerrm;
end $$;

\echo '--- T36: pre-run check (a) — account_type outside student/ordinary ---'
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.verifications where account_type not in ('student', 'ordinary');
  if v_n = 0 then raise notice 'T36 PASS: check (a) 0 rows';
  else raise notice 'T36 FAIL: check (a) returned % rows', v_n; end if;
exception when others then raise notice 'T36 FAIL: %', sqlerrm;
end $$;

\echo '--- T37: pre-run check (b) — listings/orders/wallet rows missing currency ---'
do $$
declare v_n integer;
begin
  select (select count(*) from public.listings where currency is null or btrim(currency) = '')
       + (select count(*) from public.orders where currency is null or btrim(currency) = '')
       + (select count(*) from public.wallet_ledger where currency is null or btrim(currency) = '') into v_n;
  if v_n = 0 then raise notice 'T37 PASS: check (b) 0 rows';
  else raise notice 'T37 FAIL: check (b) returned % rows', v_n; end if;
exception when others then raise notice 'T37 FAIL: %', sqlerrm;
end $$;

\echo '--- T38: pre-run check (c) — ordinary rows missing name/country/selfie ---'
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.verifications
    where account_type = 'ordinary'
      and (nullif(btrim(coalesce(full_name, '')), '') is null
        or nullif(btrim(coalesce(country, '')), '') is null
        or nullif(btrim(coalesce(face_photo_url, '')), '') is null);
  if v_n = 0 then raise notice 'T38 PASS: check (c) 0 rows';
  else raise notice 'T38 FAIL: check (c) returned % rows', v_n; end if;
exception when others then raise notice 'T38 FAIL: %', sqlerrm;
end $$;
\echo '--- T39: pre-run check (d) — orders whose fees mismatch pm_fee_breakdown ---'
do $$
declare v_n integer;
begin
  select count(*) into v_n
    from public.orders o
    cross join lateral public.pm_fee_breakdown(
      o.item_price, o.payment_method,
      coalesce(o.currency, 'NGN')) f
    where o.service_fee <> f.service_fee
       or o.secure_fee <> f.secure_fee;
  if v_n = 0 then raise notice 'T39 PASS: check (d) 0 rows';
  else raise notice 'T39 FAIL: check (d) returned % rows', v_n; end if;
exception when others then raise notice 'T39 FAIL: %', sqlerrm;
end $$;

\echo '--- T40: UPDATE nulling a student listing university refused; ordinary update with university staying NULL passes ---'
select set_config('app.test_uid', '22222222-2222-2222-2222-222222222222', false);
select set_config('app.test_email', 'seller@test.local', false);
do $$
begin
  update public.listings set university = null where id = 'da222222-2222-2222-2222-222222222222';
  raise notice 'T40 FAIL: UPDATE nulling a student listing university was accepted';
-- T40 part 1 accepts EITHER error message: the M25 guard's own message
-- ('A student listing must keep its university.') OR the pre-existing M24
-- trigger's message ('A listing's seller, university, state and view count
-- cannot be changed.'). pm_validate_listing_update_trg (M24, §13) fires
-- before pm_validate_listing_values_update_trg (M25 guard) alphabetically,
-- so on a direct UPDATE the older message surfaces and the M25 guard's
-- message can never be seen that way. The M25 guard remains as
-- defense-in-depth. What matters is the behaviour — refusal + university
-- unchanged (parts 2 and 3) — not which message fires.
exception when others then
  if sqlerrm like '%A student listing must keep its university.%'
     or sqlerrm like '%A listing''s seller, university, state and view count cannot be changed.%' then raise notice 'T40 PASS (part 1): student listing university-nulling UPDATE refused';
  else raise notice 'T40 FAIL: wrong error: %', sqlerrm; end if;
end $$;
do $$
declare v_u text;
begin
  select university into v_u from public.listings where id = 'da222222-2222-2222-2222-222222222222';
  if v_u = 'University of Port Harcourt' then raise notice 'T40 PASS (part 2): student listing university unchanged after refused UPDATE';
  else raise notice 'T40 FAIL: student listing university is now %', v_u; end if;
exception when others then raise notice 'T40 FAIL: %', sqlerrm;
end $$;
select set_config('app.test_uid', '66666666-6666-6666-6666-666666666666', false);
select set_config('app.test_email', 'orda@test.local', false);
do $$
declare v_p integer; v_u text;
begin
  update public.listings set price = 2100 where id = 'da111111-1111-1111-1111-111111111111';
  select price, university into v_p, v_u from public.listings where id = 'da111111-1111-1111-1111-111111111111';
  if v_p = 2100 and v_u is null then raise notice 'T40 PASS (part 3): ordinary listing update with university staying NULL passes';
  else raise notice 'T40 FAIL: ordinary listing price=% university=%', v_p, v_u; end if;
exception when others then raise notice 'T40 FAIL: %', sqlerrm;
end $$;

