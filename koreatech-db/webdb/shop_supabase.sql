-- ============================================================
-- 내 쇼핑몰 DB 만들기 (Supabase · 접두어 shop_)
-- 경영데이터베이스및실습 · 웹 DB 실습 2
-- 사용법: Supabase → SQL Editor → New query → 이 파일 전체를 붙여 넣고 Run
--         두 번 실행해도 안전합니다(이미 있으면 건너뜁니다).
-- 만드는 것은 모두 이름이 shop_ 으로 시작합니다.
--   shop_profiles     회원 (이름 · 연락처 · 등급 · 포인트 · 역할)
--   shop_products     상품
--   shop_orders       주문
--   shop_order_items  주문 상세 (주문 한 건에 담긴 상품들)
-- ============================================================

-- 0. 실행 위치 확인 — 「내」 Supabase 프로젝트에서만 실행합니다.
--    다른 사이트가 함께 쓰는 DB(공용 회원 표가 있는 곳)에서는 스스로 멈춥니다.
DO $guard$
BEGIN
  IF to_regclass('public.www_profiles') IS NOT NULL
     OR to_regclass('public.user_profiles') IS NOT NULL THEN
    RAISE EXCEPTION '이 SQL 은 본인이 새로 만든 Supabase 프로젝트에서만 실행하세요. (여기는 다른 사이트가 쓰는 DB 입니다)';
  END IF;
END
$guard$;

-- 1. 회원 표 — 로그인 계정(auth.users) 한 명당 한 줄
CREATE TABLE IF NOT EXISTS public.shop_profiles (
  id         uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email      text,
  name       text,
  phone      text,
  grade      text NOT NULL DEFAULT 'WELCOME'
             CONSTRAINT shop_profiles_grade_check CHECK (grade IN ('WELCOME', 'SILVER', 'GOLD', 'VIP')),
  points     integer NOT NULL DEFAULT 3000
             CONSTRAINT shop_profiles_points_check CHECK (points >= 0),
  role       text NOT NULL DEFAULT 'member'
             CONSTRAINT shop_profiles_role_check CHECK (role IN ('member', 'admin')),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 2. 상품 표
CREATE TABLE IF NOT EXISTS public.shop_products (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name       text NOT NULL,
  category   text NOT NULL,
  price      integer NOT NULL CONSTRAINT shop_products_price_check CHECK (price >= 0),
  stock      integer NOT NULL DEFAULT 0 CONSTRAINT shop_products_stock_check CHECK (stock >= 0),
  image_url  text,
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- 3. 주문 표 · 주문 상세 표
CREATE TABLE IF NOT EXISTS public.shop_orders (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  total      integer NOT NULL CONSTRAINT shop_orders_total_check CHECK (total >= 0),
  status     text NOT NULL DEFAULT '결제완료'
             CONSTRAINT shop_orders_status_check CHECK (status IN ('결제완료', '배송중', '배송완료', '취소')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.shop_order_items (
  order_id   bigint  NOT NULL REFERENCES public.shop_orders(id) ON DELETE CASCADE,
  product_id bigint  NOT NULL REFERENCES public.shop_products(id),
  qty        integer NOT NULL CONSTRAINT shop_order_items_qty_check CHECK (qty > 0),
  unit_price integer NOT NULL CONSTRAINT shop_order_items_price_check CHECK (unit_price >= 0),
  PRIMARY KEY (order_id, product_id)
);

-- 4. 관리자인지 묻는 함수 — 아래 보안 규칙에서 씁니다
CREATE OR REPLACE FUNCTION public.shop_is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.shop_profiles
    WHERE id = auth.uid() AND role = 'admin'
  );
$fn$;

-- 5. 가입하면 회원 표에 한 줄이 자동으로 생기게 합니다
--    (가입 화면에서 보낸 이름 · 연락처를 함께 저장)
CREATE OR REPLACE FUNCTION public.shop_handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  BEGIN
    INSERT INTO public.shop_profiles (id, email, name, phone)
    VALUES (NEW.id, NEW.email,
            NEW.raw_user_meta_data ->> 'name',
            NEW.raw_user_meta_data ->> 'phone')
    ON CONFLICT (id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    -- 회원 표에 못 넣어도 가입 자체는 막지 않습니다
    RAISE WARNING 'shop_profiles 자동 생성 실패: %', SQLERRM;
  END;
  RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS shop_on_auth_user_created ON auth.users;
CREATE TRIGGER shop_on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.shop_handle_new_user();

-- 이 SQL 을 실행하기 전에 이미 가입한 계정이 있으면 회원 표에 채워 넣습니다
INSERT INTO public.shop_profiles (id, email, name, phone)
SELECT u.id, u.email, u.raw_user_meta_data ->> 'name', u.raw_user_meta_data ->> 'phone'
FROM auth.users u
ON CONFLICT (id) DO NOTHING;

-- 6. 관리자가 회원의 등급 · 포인트 · 역할을 바꾸는 함수
--    (회원 관리 페이지가 이 함수를 부릅니다. 관리자가 아니면 거절)
CREATE OR REPLACE FUNCTION public.shop_admin_update_member(
  p_user_id uuid, p_grade text, p_points integer, p_role text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT public.shop_is_admin() THEN
    RAISE EXCEPTION '관리자만 할 수 있습니다' USING ERRCODE = '42501';
  END IF;
  UPDATE public.shop_profiles
     SET grade = p_grade, points = p_points, role = p_role
   WHERE id = p_user_id;
END;
$fn$;

-- 7. 함수 권한 — 로그인하지 않은 방문자는 관리 함수를 부를 수 없게
REVOKE EXECUTE ON FUNCTION public.shop_handle_new_user() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.shop_admin_update_member(uuid, text, integer, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.shop_admin_update_member(uuid, text, integer, text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.shop_is_admin() TO anon, authenticated;

-- 8. 보안 규칙(RLS) — 「누가 어느 줄을 볼 수 있는가」
ALTER TABLE public.shop_profiles    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shop_products    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shop_orders      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shop_order_items ENABLE ROW LEVEL SECURITY;

-- 표 권한: 방문자(anon)는 상품만 읽고, 회원(authenticated)은 필요한 것만
REVOKE ALL ON public.shop_profiles, public.shop_products, public.shop_orders, public.shop_order_items FROM anon, authenticated;
GRANT SELECT ON public.shop_products TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.shop_products TO authenticated;
GRANT SELECT ON public.shop_profiles TO authenticated;
GRANT UPDATE (name, phone) ON public.shop_profiles TO authenticated;   -- 등급 · 포인트 · 역할은 본인이 못 바꿉니다
GRANT SELECT, INSERT ON public.shop_orders, public.shop_order_items TO authenticated;
GRANT UPDATE (status) ON public.shop_orders TO authenticated;

-- 회원: 내 정보만 보고 고친다 / 관리자: 모두 본다
DROP POLICY IF EXISTS shop_profiles_select ON public.shop_profiles;
CREATE POLICY shop_profiles_select ON public.shop_profiles
  FOR SELECT TO authenticated
  USING (id = auth.uid() OR public.shop_is_admin());

DROP POLICY IF EXISTS shop_profiles_update_own ON public.shop_profiles;
CREATE POLICY shop_profiles_update_own ON public.shop_profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- 상품: 누구나 판매 중인 상품을 본다 / 관리자만 넣고 고치고 지운다
DROP POLICY IF EXISTS shop_products_select ON public.shop_products;
CREATE POLICY shop_products_select ON public.shop_products
  FOR SELECT TO anon, authenticated
  USING (is_active OR public.shop_is_admin());

DROP POLICY IF EXISTS shop_products_admin_insert ON public.shop_products;
CREATE POLICY shop_products_admin_insert ON public.shop_products
  FOR INSERT TO authenticated WITH CHECK (public.shop_is_admin());

DROP POLICY IF EXISTS shop_products_admin_update ON public.shop_products;
CREATE POLICY shop_products_admin_update ON public.shop_products
  FOR UPDATE TO authenticated USING (public.shop_is_admin()) WITH CHECK (public.shop_is_admin());

DROP POLICY IF EXISTS shop_products_admin_delete ON public.shop_products;
CREATE POLICY shop_products_admin_delete ON public.shop_products
  FOR DELETE TO authenticated USING (public.shop_is_admin());

-- 주문: 내 주문만 넣고 본다 / 관리자는 모두 보고 상태를 바꾼다
DROP POLICY IF EXISTS shop_orders_select ON public.shop_orders;
CREATE POLICY shop_orders_select ON public.shop_orders
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.shop_is_admin());

DROP POLICY IF EXISTS shop_orders_insert_own ON public.shop_orders;
CREATE POLICY shop_orders_insert_own ON public.shop_orders
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS shop_orders_admin_update ON public.shop_orders;
CREATE POLICY shop_orders_admin_update ON public.shop_orders
  FOR UPDATE TO authenticated USING (public.shop_is_admin()) WITH CHECK (public.shop_is_admin());

DROP POLICY IF EXISTS shop_order_items_select ON public.shop_order_items;
CREATE POLICY shop_order_items_select ON public.shop_order_items
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.shop_orders o
                 WHERE o.id = order_id AND (o.user_id = auth.uid() OR public.shop_is_admin())));

DROP POLICY IF EXISTS shop_order_items_insert_own ON public.shop_order_items;
CREATE POLICY shop_order_items_insert_own ON public.shop_order_items
  FOR INSERT TO authenticated
  WITH CHECK (EXISTS (SELECT 1 FROM public.shop_orders o
                      WHERE o.id = order_id AND o.user_id = auth.uid()));

-- 9. 예시 상품 6개 — 상품 표가 비어 있을 때만 넣습니다 (내 쇼핑몰 상품으로 바꿔 쓰세요)
INSERT INTO public.shop_products (name, category, price, stock)
SELECT v.name, v.category, v.price, v.stock
FROM (VALUES
  ('예시 상품 A', '분류1', 12000, 30),
  ('예시 상품 B', '분류1', 18000, 20),
  ('예시 상품 C', '분류2', 25000, 15),
  ('예시 상품 D', '분류2', 32000, 10),
  ('예시 상품 E', '분류3',  9000, 50),
  ('예시 상품 F', '분류3', 45000,  5)
) AS v(name, category, price, stock)
WHERE NOT EXISTS (SELECT 1 FROM public.shop_products);

-- 끝. 확인: Table Editor 에 shop_ 으로 시작하는 표 4개가 보이면 성공입니다.
--
-- [관리자 지정] 쇼핑몰에서 내 계정으로 가입한 뒤, 아래 한 줄의 이메일을 내 것으로 바꿔 따로 실행합니다.
--   UPDATE public.shop_profiles SET role = 'admin' WHERE email = '내이메일@example.com';
