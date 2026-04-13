-- 선택: concert_shows.remain_count · schedules.remain_count 를 ACTIVE 좌석 수와 맞춤 (1회).
-- 애플리케이션은 이 컬럼을 읽지 않고 잔여를 유도한다. 레거시 SQL·리포트용 동기화에만 사용.

UPDATE concert_shows cs
SET remain_count = GREATEST(0, cs.total_count - IFNULL((
  SELECT COUNT(*) FROM concert_booking_seats cbs
  WHERE cbs.show_id = cs.show_id AND UPPER(COALESCE(cbs.status, '')) = 'ACTIVE'
), 0));

UPDATE schedules s
SET remain_count = GREATEST(0, s.total_count - IFNULL((
  SELECT COUNT(*) FROM booking_seats bs
  WHERE bs.schedule_id = s.schedule_id AND UPPER(COALESCE(bs.status, '')) = 'ACTIVE'
), 0));
