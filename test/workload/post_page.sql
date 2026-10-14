\set pid random(1, 100000)
SELECT id, title, body FROM posts WHERE id = :pid;
SELECT id, user_id, body FROM comments WHERE post_id = :pid ORDER BY id LIMIT 50;
