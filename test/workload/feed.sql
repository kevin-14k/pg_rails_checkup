\set uid random(1, 20000)
SELECT id, title, created_at FROM posts WHERE user_id = :uid ORDER BY created_at DESC LIMIT 20;
