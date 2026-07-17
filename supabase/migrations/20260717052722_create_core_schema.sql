-- LifeManga 核心数据库 Schema
-- 图片保留在本地设备，云端只同步元数据与文件名

-- 启用 UUID 扩展
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- 1. 用户资料扩展（不要依赖 auth.users 做业务查询）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.profiles (
    id uuid PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
    display_name text,
    avatar_url text,
    purchased_credits integer NOT NULL DEFAULT 0,
    subscription_credits integer NOT NULL DEFAULT 0,
    subscription_tier text NOT NULL DEFAULT 'free' CHECK (subscription_tier IN ('free', 'pro', 'ultra')),
    total_generated integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.profiles IS '用户资料与 credits 余额';

-- 新用户注册时自动创建 profile，赠送 10 个免费 credits
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.profiles (id, purchased_credits)
    VALUES (NEW.id, 10)
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();

-- ============================================================
-- 2. 工程（Project）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.projects (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    name text NOT NULL,
    notes text,
    cover_item_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.projects IS '漫画工程，每个工程隔离一本漫画';

-- ============================================================
-- 3. 作品（MangaItem）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.items (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    project_id uuid NOT NULL REFERENCES public.projects ON DELETE CASCADE,
    style text NOT NULL,
    user_prompt text,
    story_script jsonb,
    is_favorite boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.items IS '一次生成的漫画作品元数据';

-- ============================================================
-- 4. 作品关联的本地图片文件名
-- ============================================================
CREATE TABLE IF NOT EXISTS public.item_images (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    item_id uuid NOT NULL REFERENCES public.items ON DELETE CASCADE,
    kind text NOT NULL CHECK (kind IN ('input', 'output')),
    filename text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.item_images IS '作品的本地图片文件名映射（图片实际存在用户设备）';

-- ============================================================
-- 5. 角色库
-- ============================================================
CREATE TABLE IF NOT EXISTS public.characters (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    name text NOT NULL,
    bio text,
    source_photo_filename text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.characters IS '角色元数据';

CREATE TABLE IF NOT EXISTS public.character_views (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    character_id uuid NOT NULL REFERENCES public.characters ON DELETE CASCADE,
    label text NOT NULL,
    filename text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.character_views IS '角色的多角度立绘文件名映射';

-- ============================================================
-- 6. Credits 消费记录（审计 + 防重复扣费）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.credit_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    amount integer NOT NULL,
    reason text NOT NULL,
    metadata jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.credit_transactions IS 'credits 变动审计日志';

-- ============================================================
-- 7. 生成任务
-- ============================================================
CREATE TABLE IF NOT EXISTS public.generation_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
    project_id uuid REFERENCES public.projects ON DELETE SET NULL,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'done', 'failed', 'timeout_unknown')),
    cost_credits integer NOT NULL,
    kind text NOT NULL CHECK (kind IN ('simple_image', 'story_script', 'story_render', 'character_sheet', 'pose_sheet')),
    style text,
    prompt text,
    result_urls jsonb,
    error_code text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.generation_jobs IS '图像生成任务记录，用于跨设备状态同步';

-- ============================================================
-- 8. RLS 策略
-- ============================================================
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.item_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.characters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.character_views ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.generation_jobs ENABLE ROW LEVEL SECURITY;

-- profiles: 用户只能读写自己的资料
CREATE POLICY "Users can select own profile"
    ON public.profiles FOR SELECT
    USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id);

CREATE POLICY "Users can insert own profile"
    ON public.profiles FOR INSERT
    WITH CHECK (auth.uid() = id);

-- projects: 用户只能访问自己的工程
CREATE POLICY "Users can manage own projects"
    ON public.projects FOR ALL
    USING (auth.uid() = user_id);

-- items: 用户只能访问自己的作品
CREATE POLICY "Users can manage own items"
    ON public.items FOR ALL
    USING (auth.uid() = user_id);

-- item_images: 通过 item 关联限制
CREATE POLICY "Users can manage own item_images"
    ON public.item_images FOR ALL
    USING (
        item_id IN (SELECT id FROM public.items WHERE user_id = auth.uid())
    );

-- characters
CREATE POLICY "Users can manage own characters"
    ON public.characters FOR ALL
    USING (auth.uid() = user_id);

-- character_views
CREATE POLICY "Users can manage own character_views"
    ON public.character_views FOR ALL
    USING (
        character_id IN (SELECT id FROM public.characters WHERE user_id = auth.uid())
    );

-- credit_transactions: 只读自己的审计记录
CREATE POLICY "Users can view own transactions"
    ON public.credit_transactions FOR SELECT
    USING (auth.uid() = user_id);

-- generation_jobs
CREATE POLICY "Users can manage own generation_jobs"
    ON public.generation_jobs FOR ALL
    USING (auth.uid() = user_id);

-- ============================================================
-- 9. 辅助函数
-- ============================================================

-- 原子扣费函数（由 Edge Functions 调用，使用 service_role）
CREATE OR REPLACE FUNCTION public.deduct_credits(
    p_user_id uuid,
    p_amount integer,
    p_reason text,
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_available integer;
BEGIN
    SELECT COALESCE(purchased_credits, 0) + COALESCE(subscription_credits, 0)
    INTO v_available
    FROM public.profiles
    WHERE id = p_user_id
    FOR UPDATE;

    IF v_available IS NULL OR v_available < p_amount THEN
        RETURN false;
    END IF;

    -- 优先扣除 subscription_credits，再扣 purchased_credits
    UPDATE public.profiles
    SET
        subscription_credits = GREATEST(0, subscription_credits - p_amount),
        purchased_credits = GREATEST(0, purchased_credits - GREATEST(0, p_amount - subscription_credits)),
        updated_at = now()
    WHERE id = p_user_id;

    INSERT INTO public.credit_transactions (user_id, amount, reason, metadata)
    VALUES (p_user_id, -p_amount, p_reason, p_metadata);

    RETURN true;
END;
$$;

-- 增加 credits（用于内购验证后充值）
CREATE OR REPLACE FUNCTION public.add_credits(
    p_user_id uuid,
    p_amount integer,
    p_reason text,
    p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.profiles
    SET purchased_credits = purchased_credits + p_amount,
        updated_at = now()
    WHERE id = p_user_id;

    INSERT INTO public.credit_transactions (user_id, amount, reason, metadata)
    VALUES (p_user_id, p_amount, p_reason, p_metadata);
END;
$$;

-- 增加 total_generated 计数
CREATE OR REPLACE FUNCTION public.increment_generated_count(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.profiles
    SET total_generated = total_generated + 1,
        updated_at = now()
    WHERE id = p_user_id;
END;
$$;

-- 获取用户 credits 余额
CREATE OR REPLACE FUNCTION public.get_credits(p_user_id uuid)
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
    SELECT COALESCE(purchased_credits, 0) + COALESCE(subscription_credits, 0)
    FROM public.profiles
    WHERE id = p_user_id;
$$;
