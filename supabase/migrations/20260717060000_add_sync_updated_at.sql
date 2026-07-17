-- 为云端同步增加 updated_at 字段
-- 仅同步元数据，图片仍保留在本地

ALTER TABLE public.items
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE public.character_views
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();
