\set uid random(1, 20000)
SELECT count(*) FROM comments WHERE user_id = :uid;
