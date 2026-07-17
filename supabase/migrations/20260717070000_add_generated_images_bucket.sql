-- 创建公开 bucket 用于存放 AI 生成的结果图
insert into storage.buckets (id, name, public, avif_autodetection)
values ('generated-images', 'generated-images', true, false)
on conflict (id) do nothing;
