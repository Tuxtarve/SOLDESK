-- ticketing 기준데이터(Seed) 입력 (원본 3 tier 기준 복구/최신화)
-- - MySQL 5.7 호환(CTE/WITH RECURSIVE/윈도우 함수 사용 안 함)
-- - 운영자 제공 기준데이터: movies/theaters/halls/hall_seats/schedules/concerts/concert_shows
-- - 트랜잭션 데이터(booking/booking_seats/payment/users 생성 등)는 넣지 않음
-- - 재실행 시 중복 에러를 피하도록 INSERT IGNORE / NOT EXISTS / ON DUPLICATE KEY UPDATE 사용

USE ticketing;

-- =====================================================================
-- 1) 영화(1~10) + 더미(11~40) 복구
-- =====================================================================

INSERT INTO movies (
  movie_id, title, genre, director, runtime_minutes,
  poster_url, main_poster_url, video_url, audience_count,
  release_date, synopsis, synopsis_line, status, hide,
  created_at, updated_at
)
VALUES
  (1, '왕과 사는 남자', '드라마', '장항준', 117, '/images/posters/king.jpg', '/images/posters/main_king.jpg', 'https://www.youtube.com/watch?v=9sxEZuJskvM', 15218700, '2026-03-28', '1457년 청령포, 역사가 지우려 했던 이야기', '“나는 이제 어디로 갑니까…”', 'ACTIVE', 'N', '2026-04-03 21:01:25', '2026-04-04 16:51:31'),
  (2, '프로젝트 헤일메리', 'SF', '필로드', 156, '/images/posters/hail.jpg', '/images/posters/main_hail.jpg', 'https://www.youtube.com/watch?v=GC2SR2MGdck', 1543200, '2026-03-15', '죽어가는 태양, 종말 위기에 놓인 지구', '인류의 운명을 건 단 하나의 미션', 'ACTIVE', 'N', '2026-04-03 21:01:25', '2026-04-04 16:50:55'),
  (3, '호퍼스', '애니메이션', '다니엘 총', 104, '/images/posters/ho.jpg', '/images/posters/main_ho.jpg', 'https://www.youtube.com/watch?v=qNIYD3yzG-U', 2875400, '2026-02-20', '디즈니·픽사의 가장 사랑스러운 애니멀 어드벤처가 온다!', '비버 모드 ON!', 'ACTIVE', 'N', '2026-04-03 21:01:25', '2026-04-04 16:50:23'),
  (4, '위 리브 인 타임', '멜로/로맨스', '존 크로울리', 108, '/images/posters/we.jpg', '/images/posters/main_we.jpg', 'https://www.youtube.com/watch?v=qqlfn-T-OFA', 980300, '2026-04-08', '우리의 사랑은 함께한 시간에 영원히 남는다.', '우리의 사랑은 함께한 시간에 영원히 남는다.', 'ACTIVE', 'N', '2026-04-03 21:01:25', '2026-04-05 19:54:08'),
  (5, '쉘터', '액션', '릭 로먼 워', 107, '/images/posters/shelter.jpg', '/images/posters/dummy.jpg', 'https://www.youtube.com/watch?v=7Q9P8jyKczU', 0, '2026-04-15', '등대에 홀로 숨어살던 한 남자.', '등대에 홀로 숨어살던 한 남자.', 'ACTIVE', 'N', '2026-04-03 21:01:25', '2026-04-05 19:47:17'),
  (6, '네가 마지막으로 남긴 노래', '멜로/로맨스', '미키 타카히로', 117, '/images/posters/last_song.jpg', '/images/posters/dummy.jpg', 'https://www.youtube.com/watch?v=IKjpAIHqBPI', 42251, '2026-04-01', '시를 쓰는 소년과 노래로 세상을 그리는 소녀가 음악으로 이어지는 청춘 로맨스', '“나에게 가사를 써줄래?”', 'ACTIVE', 'N', '2026-04-05 16:19:21', '2026-04-05 20:08:52'),
  (7, '살목지', '공포', '이상민', 95, '/images/posters/salmokji.jpg', '/images/posters/dummy.jpg', 'https://www.youtube.com/watch?v=jL2kpyq_ODk', 19156, '2026-04-08', '기이한 소문이 끊이지 않는 저수지에서 촬영팀이 정체불명의 존재와 마주하게 되는 공포 영화', '거긴, 절대 살아서는 못 나와', 'ACTIVE', 'N', '2026-04-05 16:19:21', '2026-04-05 20:08:52'),
  (8, '엔하이픈 - 이머전 인 시네마', '공연실황', '미상', 53, '/images/posters/enhypen_immersion.jpg', '/images/posters/dummy.jpg', 'https://www.youtube.com/watch?v=tb6xlBgBpug', 0, '2026-04-08', '엔하이픈의 몰입형 공연을 극장에서 만나는 스페셜 시네마', '오직 ENGENE를 위한 순간', 'ACTIVE', 'N', '2026-04-05 16:21:38', '2026-04-05 20:08:52'),
  (9, '올란도', '드라마', '샐리 포터', 94, '/images/posters/orlando.jpg', '/images/posters/dummy.jpg', 'https://www.youtube.com/watch?v=D3seA01zVhQ', 0, '2026-04-08', '400년의 시간을 지나며 자신의 정체성을 찾아가는 올란도의 여정을 그린 영화', '같은 사람이야, 변한 건 없어', 'ACTIVE', 'N', '2026-04-05 16:23:56', '2026-04-05 20:08:52'),
  (10, '내 이름은', '드라마', '정지영', 112, '/images/posters/my_name.jpg', '/images/posters/dummy.jpg', 'https://www.youtube.com/watch?v=P4Wv-zm-AJ0', 2057, '2026-04-15', '잃어버린 기억과 이름을 찾아가는 여정을 통해 제주 4·3의 상처를 그린 드라마', '가슴에 묻은 78년의 약속', 'ACTIVE', 'N', '2026-04-05 16:25:55', '2026-04-05 20:08:52')
ON DUPLICATE KEY UPDATE
  title = VALUES(title),
  genre = VALUES(genre),
  director = VALUES(director),
  runtime_minutes = VALUES(runtime_minutes),
  poster_url = VALUES(poster_url),
  main_poster_url = VALUES(main_poster_url),
  video_url = VALUES(video_url),
  audience_count = VALUES(audience_count),
  release_date = VALUES(release_date),
  synopsis = VALUES(synopsis),
  synopsis_line = VALUES(synopsis_line),
  status = VALUES(status),
  hide = VALUES(hide),
  updated_at = VALUES(updated_at);

-- 더미데이터 11~40
-- - 영화목록(페이지네이션 확인용)에는 보여야 함: hide='N'
-- - 예매/상영중 목록에서만 제외: theaters_read.py 가 title/genre/director로 제외 처리
DROP PROCEDURE IF EXISTS seed_dummy_movies_11_40;
DELIMITER $$
CREATE PROCEDURE seed_dummy_movies_11_40()
BEGIN
  DECLARE i INT DEFAULT 11;
  WHILE i <= 40 DO
    INSERT INTO movies (
      movie_id, title, genre, director, runtime_minutes,
      poster_url, main_poster_url, video_url, audience_count,
      release_date, synopsis, synopsis_line, status, hide,
      created_at, updated_at
    )
    VALUES (
      i,
      CONCAT('더미데이터', i - 10),
      '더미',
      '더미',
      100,
      '/images/posters/dummy.jpg',
      '/images/posters/dummy.jpg',
      NULL,
      0,
      DATE_ADD('2026-04-05', INTERVAL (i - 11) DAY),
      CONCAT('더미데이터', i - 10),
      NULL,
      'ACTIVE',
      'N',
      NOW(),
      NOW()
    )
    ON DUPLICATE KEY UPDATE
      title = VALUES(title),
      genre = VALUES(genre),
      director = VALUES(director),
      runtime_minutes = VALUES(runtime_minutes),
      poster_url = VALUES(poster_url),
      main_poster_url = VALUES(main_poster_url),
      video_url = VALUES(video_url),
      audience_count = VALUES(audience_count),
      release_date = VALUES(release_date),
      synopsis = VALUES(synopsis),
      synopsis_line = VALUES(synopsis_line),
      status = VALUES(status),
      hide = VALUES(hide),
      updated_at = NOW();
    SET i = i + 1;
  END WHILE;
END$$
DELIMITER ;
CALL seed_dummy_movies_11_40();
DROP PROCEDURE IF EXISTS seed_dummy_movies_11_40;

-- =====================================================================
-- 2) 극장/상영관 + 좌석(3x10 전 상영관 보강)
-- =====================================================================

INSERT INTO theaters (theater_id, address, created_at, updated_at)
VALUES
  (1, '서울', NOW(), NOW()),
  (2, '경기', NOW(), NOW()),
  (3, '인천', NOW(), NOW()),
  (4, '대전', NOW(), NOW()),
  (5, '부산', NOW(), NOW())
ON DUPLICATE KEY UPDATE
  address = VALUES(address),
  updated_at = VALUES(updated_at);

INSERT INTO halls (theater_id, hall_name, total_seats, created_at, updated_at)
VALUES
  (1, 'A', 30, NOW(), NOW()),
  (1, 'B', 30, NOW(), NOW()),
  (2, 'A', 30, NOW(), NOW()),
  (2, 'B', 30, NOW(), NOW()),
  (3, 'A', 30, NOW(), NOW()),
  (3, 'B', 30, NOW(), NOW()),
  (4, 'A', 30, NOW(), NOW()),
  (4, 'B', 30, NOW(), NOW()),
  (5, 'A', 30, NOW(), NOW()),
  (5, 'B', 30, NOW(), NOW())
ON DUPLICATE KEY UPDATE
  total_seats = VALUES(total_seats),
  updated_at = VALUES(updated_at);

-- 전 상영관 3x10 좌석 채우기 (MySQL 5.7 호환)
INSERT IGNORE INTO hall_seats (hall_id, seat_row_no, seat_col_no, status, created_at)
SELECT
  h.hall_id,
  r.n AS seat_row_no,
  c.n AS seat_col_no,
  'ACTIVE' AS status,
  NOW() AS created_at
FROM halls h
CROSS JOIN (SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3) r
CROSS JOIN (
  SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5
  UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10
) c;

-- =====================================================================
-- 3) 스케줄: 2026-04-07 ~ 2026-05-30 "꽉 채움" (영화 1~10 골고루)
--    - MySQL 5.7 호환: 루프 기반
--    - 요구사항: hall_id(상영관) 기준으로 "상영시간이 안겹치게" 편성
--      -> 시작시간만 저장되므로, 러닝타임 + 정리시간(15분) 간격으로 회차 생성
-- =====================================================================

DROP PROCEDURE IF EXISTS seed_one_schedule;
DELIMITER $$
CREATE PROCEDURE seed_one_schedule(p_movie_id BIGINT, p_hall_id BIGINT, p_show_dt DATETIME)
BEGIN
  INSERT INTO schedules (
    movie_id, hall_id, show_date,
    total_count, remain_count, status,
    created_at, updated_at
  )
  SELECT
    p_movie_id,
    p_hall_id,
    p_show_dt,
    COALESCE(h.total_seats, 30),
    COALESCE(h.total_seats, 30),
    'OPEN',
    NOW(),
    NOW()
  FROM halls h
  WHERE h.hall_id = p_hall_id
  ON DUPLICATE KEY UPDATE
    movie_id = VALUES(movie_id),
    total_count = VALUES(total_count),
    remain_count = VALUES(remain_count),
    status = VALUES(status),
    updated_at = NOW();
END$$
DELIMITER ;

DROP PROCEDURE IF EXISTS seed_schedules_full_until_0530;
DELIMITER $$
CREATE PROCEDURE seed_schedules_full_until_0530()
BEGIN
  DECLARE d DATE DEFAULT '2026-04-07';
  DECLARE end_d DATE DEFAULT '2026-05-30';
  DECLARE done INT DEFAULT 0;
  DECLARE v_hall_id BIGINT;
  DECLARE slot_idx INT;
  DECLARE v_movie_id BIGINT DEFAULT 1;
  DECLARE v_runtime_min INT DEFAULT 117;
  DECLARE v_gap_min INT DEFAULT 15;
  DECLARE v_step_min INT DEFAULT 132;
  DECLARE v_show_dt DATETIME;

  DECLARE cur CURSOR FOR
    SELECT hall_id FROM halls ORDER BY hall_id ASC;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  -- 영화 1번(왕과 사는 남자) 러닝타임을 우선 사용 (없으면 기본 117분)
  SELECT COALESCE(runtime_minutes, 117) INTO v_runtime_min
  FROM movies
  WHERE movie_id = 1
  LIMIT 1;
  SET v_step_min = v_runtime_min + v_gap_min;

  WHILE d <= end_d DO
    SET done = 0;
    OPEN cur;

    read_loop: LOOP
      FETCH cur INTO v_hall_id;
      IF done = 1 THEN
        LEAVE read_loop;
      END IF;

      SET slot_idx = 0;
      WHILE slot_idx < 7 DO
        -- 09:00부터 (러닝타임+15분) 간격으로 7회차 생성
        -- 예: 117분 + 15분 = 132분 간격 -> 09:00, 11:12, 13:24, 15:36, 17:48, 20:00, 22:12
        SET v_show_dt = DATE_ADD(CONCAT(d, ' 09:00:00'), INTERVAL (slot_idx * v_step_min) MINUTE);

        -- 시연용으로 영화 1~10이 골고루 섞이게 편성 (일자/상영관/회차에 따라 라운드로빈)
        SET v_movie_id = 1 + MOD((slot_idx + CAST(v_hall_id AS SIGNED) + DATEDIFF(d, '2026-04-07')), 10);
        CALL seed_one_schedule(v_movie_id, v_hall_id, v_show_dt);

        SET slot_idx = slot_idx + 1;
      END WHILE;
    END LOOP;

    CLOSE cur;
    SET d = DATE_ADD(d, INTERVAL 1 DAY);
  END WHILE;
END$$
DELIMITER ;

CALL seed_schedules_full_until_0530();
DROP PROCEDURE IF EXISTS seed_schedules_full_until_0530;
DROP PROCEDURE IF EXISTS seed_one_schedule;

-- =====================================================================
-- 4) 콘서트/뮤지컬 시드(소규모) + 5만석 시드 복구
-- =====================================================================

INSERT INTO concerts (
  title, category, genre, venue_summary, poster_url, runtime_minutes,
  synopsis, synopsis_line, status, hide
)
SELECT
  '2026 봄 페스티벌 LIVE', 'CONCERT', '페스티벌', '올림픽공원 체조경기장', '/images/no-image.png', 150,
  '국내 인기 아티스트가 한자리에 모이는 야외 페스티벌입니다.', '야외 페스티벌, 단 하루.', 'ACTIVE', 'N'
WHERE NOT EXISTS (SELECT 1 FROM concerts WHERE title='2026 봄 페스티벌 LIVE' LIMIT 1);

INSERT INTO concerts (
  title, category, genre, venue_summary, poster_url, runtime_minutes,
  synopsis, synopsis_line, status, hide
)
SELECT
  '뮤지컬 <별이 빛나는 밤>', 'MUSICAL', '뮤지컬', '샤롯데씨어터', '/images/no-image.png', 140,
  '감동적인 스토리와 라이브 밴드가 어우러진 창작 뮤지컬.', '당신의 밤을 비추는 이야기.', 'ACTIVE', 'N'
WHERE NOT EXISTS (SELECT 1 FROM concerts WHERE title='뮤지컬 <별이 빛나는 밤>' LIMIT 1);

SET @cid1 := (SELECT concert_id FROM concerts WHERE title='2026 봄 페스티벌 LIVE' ORDER BY concert_id ASC LIMIT 1);
SET @cid2 := (SELECT concert_id FROM concerts WHERE title='뮤지컬 <별이 빛나는 밤>' ORDER BY concert_id ASC LIMIT 1);

INSERT INTO concert_shows (
  concert_id, show_date, venue_name, venue_address, hall_name,
  seat_rows, seat_cols, total_count, remain_count, price, status,
  created_at, updated_at
)
SELECT * FROM (
  SELECT @cid1 AS concert_id, '2026-05-10 18:00:00' AS show_date, '올림픽공원 체조경기장' AS venue_name, '서울 송파구 올림픽로 424' AS venue_address, '스탠딩 A' AS hall_name,
         5 AS seat_rows, 10 AS seat_cols, 50 AS total_count, 50 AS remain_count, 150000 AS price, 'OPEN' AS status, NOW() AS created_at, NOW() AS updated_at
  UNION ALL
  SELECT @cid1, '2026-05-11 15:00:00', '올림픽공원 체조경기장', '서울 송파구 올림픽로 424', '스탠딩 B',
         5, 10, 50, 50, 150000, 'OPEN', NOW(), NOW()
  UNION ALL
  SELECT @cid2, '2026-06-01 19:30:00', '샤롯데씨어터', '서울 송파구 올림픽로 240', '1층',
         5, 10, 50, 50, 99000, 'OPEN', NOW(), NOW()
  UNION ALL
  SELECT @cid2, '2026-06-02 14:00:00', '샤롯데씨어터', '서울 송파구 올림픽로 240', '1층',
         5, 10, 50, 50, 99000, 'OPEN', NOW(), NOW()
) AS v
WHERE v.concert_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1
    FROM concert_shows cs
    WHERE cs.concert_id = v.concert_id
      AND cs.show_date = v.show_date
      AND cs.hall_name = v.hall_name
  );

-- 5만석(200 x 250) 콘서트/회차 복구 (원본 seed_concert_large_50000.sql 기반)
INSERT INTO concerts
  (title, category, genre, venue_summary, poster_url, runtime_minutes, synopsis, synopsis_line, status, hide)
SELECT
  '2026 봄 페스티벌 LIVE - 5만석', 'CONCERT', '페스티벌', '올림픽공원 체조경기장 · 스탠딩 A', 'concert1.jpg', 140,
  '봄 페스티벌 라이브 공연입니다.', '봄 페스티벌 라이브 공연입니다.', 'ACTIVE', 'N'
WHERE NOT EXISTS (SELECT 1 FROM concerts WHERE title='2026 봄 페스티벌 LIVE - 5만석' LIMIT 1);

SET @cid_big := (SELECT concert_id FROM concerts WHERE title='2026 봄 페스티벌 LIVE - 5만석' ORDER BY concert_id ASC LIMIT 1);

INSERT INTO concert_shows
  (concert_id, show_date, venue_name, venue_address, hall_name, seat_rows, seat_cols, total_count, remain_count, price, status, created_at, updated_at)
SELECT
  @cid_big,
  '2026-05-10 18:00:00',
  '올림픽공원 체조경기장',
  '서울 송파구 올림픽로 424',
  '스탠딩 A',
  200,
  250,
  50000,
  50000,
  120000,
  'OPEN',
  NOW(),
  NOW()
WHERE @cid_big IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM concert_shows cs
    WHERE cs.concert_id = @cid_big
      AND cs.show_date = '2026-05-10 18:00:00'
      AND cs.hall_name = '스탠딩 A'
  );
