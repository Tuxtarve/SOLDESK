-- ══════════════════════════════════════════════════════════════════════════════
-- Ticketing System DB Schema (MySQL 8.0)
-- ══════════════════════════════════════════════════════════════════════════════

CREATE DATABASE IF NOT EXISTS ticketing CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE ticketing;

-- 이벤트
CREATE TABLE IF NOT EXISTS events (
  id            CHAR(36)     NOT NULL DEFAULT (UUID()) PRIMARY KEY,
  title         VARCHAR(255) NOT NULL,
  venue         VARCHAR(255) NOT NULL,
  start_at      DATETIME     NOT NULL,
  end_at        DATETIME,
  total_seats   INT          NOT NULL DEFAULT 0,
  status        ENUM('UPCOMING','ON_SALE','SOLD_OUT','FINISHED','CANCELLED') NOT NULL DEFAULT 'UPCOMING',
  thumbnail_url TEXT,
  created_at    DATETIME     NOT NULL DEFAULT NOW(),
  updated_at    DATETIME     NOT NULL DEFAULT NOW() ON UPDATE NOW()
) ENGINE=InnoDB;

-- 좌석
CREATE TABLE IF NOT EXISTS seats (
  id        CHAR(36)      NOT NULL DEFAULT (UUID()) PRIMARY KEY,
  event_id  CHAR(36)      NOT NULL,
  section   VARCHAR(20)   NOT NULL,
  `row`     VARCHAR(10)   NOT NULL,
  number    INT           NOT NULL,
  grade     VARCHAR(20)   NOT NULL DEFAULT 'STANDARD',
  price     DECIMAL(10,2) NOT NULL DEFAULT 0,
  status    ENUM('AVAILABLE','RESERVED','SOLD','BLOCKED') NOT NULL DEFAULT 'AVAILABLE',
  UNIQUE KEY uq_seat (event_id, section, `row`, number),
  FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- 예매
CREATE TABLE IF NOT EXISTS reservations (
  id          CHAR(36)      NOT NULL PRIMARY KEY,
  user_id     VARCHAR(255)  NOT NULL,
  event_id    CHAR(36)      NOT NULL,
  status      ENUM('PENDING','CONFIRMED','CANCELLED','EXPIRED','REFUNDED') NOT NULL DEFAULT 'PENDING',
  total_price DECIMAL(10,2) NOT NULL DEFAULT 0,
  expires_at  DATETIME,
  created_at  DATETIME      NOT NULL DEFAULT NOW(),
  updated_at  DATETIME      NOT NULL DEFAULT NOW() ON UPDATE NOW(),
  FOREIGN KEY (event_id) REFERENCES events(id)
) ENGINE=InnoDB;

-- 예매-좌석 매핑 (M:M)
CREATE TABLE IF NOT EXISTS reservation_seats (
  reservation_id CHAR(36) NOT NULL,
  seat_id        CHAR(36) NOT NULL,
  PRIMARY KEY (reservation_id, seat_id),
  FOREIGN KEY (reservation_id) REFERENCES reservations(id) ON DELETE CASCADE,
  FOREIGN KEY (seat_id)        REFERENCES seats(id)
) ENGINE=InnoDB;

-- 결제
CREATE TABLE IF NOT EXISTS payments (
  id             CHAR(36)      NOT NULL DEFAULT (UUID()) PRIMARY KEY,
  reservation_id CHAR(36)      NOT NULL,
  amount         DECIMAL(10,2) NOT NULL,
  method         VARCHAR(20)   NOT NULL DEFAULT 'CARD',
  status         ENUM('PENDING','PAID','FAILED','REFUNDED') NOT NULL DEFAULT 'PENDING',
  paid_at        DATETIME,
  created_at     DATETIME      NOT NULL DEFAULT NOW(),
  FOREIGN KEY (reservation_id) REFERENCES reservations(id)
) ENGINE=InnoDB;

-- 인덱스
CREATE INDEX idx_seats_event    ON seats(event_id, status);
CREATE INDEX idx_reserv_user    ON reservations(user_id, status);
CREATE INDEX idx_reserv_event   ON reservations(event_id, status);
CREATE INDEX idx_reserv_expires ON reservations(expires_at, status);

-- ══ 샘플 데이터 ══════════════════════════════════════════════════════════════

INSERT IGNORE INTO events (id, title, venue, start_at, total_seats, status) VALUES
  ('a1b2c3d4-0001-0001-0001-000000000001', 'K-POP 월드 콘서트 2026', 'KSPO DOME, 서울',  DATE_ADD(NOW(), INTERVAL 30 DAY), 10000, 'ON_SALE'),
  ('a1b2c3d4-0001-0001-0001-000000000002', '클래식 갈라 나이트',      '예술의전당',        DATE_ADD(NOW(), INTERVAL 14 DAY), 2000,  'ON_SALE'),
  ('a1b2c3d4-0001-0001-0001-000000000003', '스탠드업 코미디 페스티벌', '홍대 롤링홀',       DATE_ADD(NOW(), INTERVAL  7 DAY), 500,   'ON_SALE');
