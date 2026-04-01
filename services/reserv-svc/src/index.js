'use strict';

const express   = require('express');
const mysql     = require('mysql2/promise');
const Redis     = require('ioredis');
const { SQSClient, SendMessageCommand } = require('@aws-sdk/client-sqs');
const prom      = require('prom-client');
const { v4: uuidv4 } = require('uuid');
const winston   = require('winston');

const app  = express();
const PORT = process.env.PORT || 3001;

const log = winston.createLogger({
  level: 'info',
  format: winston.format.combine(winston.format.timestamp(), winston.format.json()),
  transports: [new winston.transports.Console()],
});

// ── Prometheus 메트릭 ─────────────────────────────────────────────────────────
prom.collectDefaultMetrics();

const reservationTotal = new prom.Counter({
  name: 'reservation_requests_total',
  help: '예매 요청 총 수',
  labelNames: ['status'],
});

const reservationDuration = new prom.Histogram({
  name: 'reservation_duration_ms',
  help: '예매 처리 시간 (ms)',
  buckets: [10, 30, 50, 100, 300, 500],
});

const seatAvailable = new prom.Gauge({
  name: 'seat_available_count',
  help: '이벤트별 잔여 좌석',
  labelNames: ['event_id'],
});

// ── AWS SQS ───────────────────────────────────────────────────────────────────
const sqsClient = new SQSClient({ region: process.env.AWS_REGION || 'ap-northeast-2' });
const SQS_URL   = process.env.SQS_QUEUE_URL;

// ── Redis ─────────────────────────────────────────────────────────────────────
const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: parseInt(process.env.REDIS_PORT || '6379'),
  lazyConnect: true,
});

// ── DB ────────────────────────────────────────────────────────────────────────
const dbConfig = {
  user:            process.env.DB_USER,
  password:        process.env.DB_PASSWORD,
  database:        process.env.DB_NAME || 'ticketing',
  port:            parseInt(process.env.DB_PORT || '3306'),
  connectionLimit: 5,
  waitForConnections: true,
};

let writerPool, readerPool;

async function getPools() {
  if (!writerPool) {
    writerPool = await mysql.createPool({ host: process.env.DB_WRITER_HOST, ...dbConfig });
    readerPool = await mysql.createPool({ host: process.env.DB_READER_HOST, ...dbConfig });
  }
  return { writerPool, readerPool };
}

app.use(express.json());

// ── 헬스체크 ──────────────────────────────────────────────────────────────────
app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'reserv-svc' });
});

// ── 예매 생성 (핵심 로직) ─────────────────────────────────────────────────────
app.post('/api/reservations', async (req, res) => {
  const end = reservationDuration.startTimer();
  const { eventId, seatIds, userId } = req.body;
  const cognitoUserId = req.headers['x-amzn-oidc-identity'] || userId;

  if (!cognitoUserId || !eventId || !seatIds?.length) {
    reservationTotal.inc({ status: 'bad_request' });
    return res.status(400).json({ error: '필수 파라미터 누락' });
  }

  const lockKey  = `seat:lock:${eventId}:${seatIds.sort().join(',')}`;
  const availKey = `seat:available:${eventId}`;

  try {
    // Redis 분산 락 (NX = 없을 때만 SET)
    const locked = await redis.set(lockKey, cognitoUserId, 'EX', 600, 'NX');
    if (!locked) {
      reservationTotal.inc({ status: 'seat_locked' });
      end();
      return res.status(409).json({ error: '다른 사용자가 선택 중인 좌석입니다' });
    }

    // Redis 재고 차감
    const remaining = await redis.decrby(availKey, seatIds.length);
    if (remaining < 0) {
      await redis.incrby(availKey, seatIds.length);
      await redis.del(lockKey);
      reservationTotal.inc({ status: 'sold_out' });
      end();
      return res.status(409).json({ error: '잔여 좌석이 부족합니다' });
    }

    seatAvailable.set({ event_id: eventId }, remaining);

    const reservationId  = uuidv4();
    const idempotencyKey = `${cognitoUserId}:${eventId}:${seatIds.sort().join(',')}`;
    const expiresAt      = new Date(Date.now() + 10 * 60 * 1000).toISOString();

    // SQS FIFO 큐에 비동기 처리 위임
    await sqsClient.send(new SendMessageCommand({
      QueueUrl:               SQS_URL,
      MessageGroupId:         eventId,
      MessageDeduplicationId: idempotencyKey,
      MessageBody: JSON.stringify({ reservationId, userId: cognitoUserId, eventId, seatIds, expiresAt, lockKey }),
    }));

    reservationTotal.inc({ status: 'pending' });
    end();
    log.info('예매 큐 투입', { reservationId, eventId });

    res.status(202).json({
      status: 'PENDING', reservationId, expiresAt,
      message: '예매 접수 완료. 10분 내 결제를 완료해 주세요.',
    });

  } catch (err) {
    await redis.del(lockKey).catch(() => {});
    await redis.incrby(availKey, seatIds.length).catch(() => {});
    reservationTotal.inc({ status: 'error' });
    end();
    log.error('예매 처리 실패', { err: err.message });
    res.status(500).json({ error: '예매 처리 중 오류가 발생했습니다' });
  }
});

// ── 예매 조회 ─────────────────────────────────────────────────────────────────
app.get('/api/reservations/:id', async (req, res) => {
  const { id } = req.params;
  const userId = req.headers['x-amzn-oidc-identity'];

  try {
    const { readerPool } = await getPools();
    const [rows] = await readerPool.query(
      `SELECT r.*, GROUP_CONCAT(rs.seat_id) AS seat_ids
       FROM reservations r
       LEFT JOIN reservation_seats rs ON r.id = rs.reservation_id
       WHERE r.id = ? AND r.user_id = ?
       GROUP BY r.id`,
      [id, userId]
    );
    if (!rows.length) return res.status(404).json({ error: '예매를 찾을 수 없습니다' });
    res.json(rows[0]);
  } catch (err) {
    res.status(500).json({ error: '서버 오류' });
  }
});

// ── 내 예매 목록 ──────────────────────────────────────────────────────────────
app.get('/api/reservations', async (req, res) => {
  const userId = req.headers['x-amzn-oidc-identity'];
  if (!userId) return res.status(401).json({ error: '인증 필요' });

  try {
    const { readerPool } = await getPools();
    const [rows] = await readerPool.query(
      `SELECT r.id, r.status, r.total_price, r.created_at, r.expires_at, e.title AS event_title, e.start_at
       FROM reservations r
       JOIN events e ON r.event_id = e.id
       WHERE r.user_id = ? AND r.status != 'EXPIRED'
       ORDER BY r.created_at DESC
       LIMIT 20`,
      [userId]
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: '서버 오류' });
  }
});

// ── 결제 처리 (Y/N 모의 결제) ─────────────────────────────────────────────────
app.post('/api/payments', async (req, res) => {
  const { reservationId, approved } = req.body;
  const userId = req.headers['x-amzn-oidc-identity'] || req.body.userId;

  if (!reservationId) return res.status(400).json({ error: '예매 ID 필요' });

  try {
    const { writerPool } = await getPools();
    const [rows] = await writerPool.query(
      'SELECT * FROM reservations WHERE id = ? LIMIT 1', [reservationId]
    );
    if (!rows.length) return res.status(404).json({ error: '예매를 찾을 수 없습니다' });

    const reservation = rows[0];

    if (approved) {
      await writerPool.query(
        `INSERT INTO payments (id, reservation_id, amount, method, status, paid_at)
         VALUES (UUID(), ?, ?, 'CARD', 'PAID', NOW())`,
        [reservationId, reservation.total_price]
      );
      await writerPool.query(
        `UPDATE reservations SET status = 'CONFIRMED' WHERE id = ?`, [reservationId]
      );
      log.info('결제 승인', { reservationId });
      res.json({ status: 'CONFIRMED', reservationId, amount: reservation.total_price });
    } else {
      await writerPool.query(
        `INSERT INTO payments (id, reservation_id, amount, method, status)
         VALUES (UUID(), ?, ?, 'CARD', 'FAILED')`,
        [reservationId, reservation.total_price]
      );
      await writerPool.query(
        `UPDATE reservations SET status = 'CANCELLED' WHERE id = ?`, [reservationId]
      );
      await writerPool.query(
        `UPDATE seats s
         JOIN reservation_seats rs ON s.id = rs.seat_id
         SET s.status = 'AVAILABLE'
         WHERE rs.reservation_id = ?`, [reservationId]
      );
      log.info('결제 거절 — 취소, 기록 보존', { reservationId });
      res.json({ status: 'CANCELLED', reservationId });
    }
  } catch (err) {
    log.error('결제 처리 실패', { err: err.message });
    res.status(500).json({ error: '결제 처리 중 오류' });
  }
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', prom.register.contentType);
  res.end(await prom.register.metrics());
});

app.listen(PORT, () => log.info('reserv-svc 시작', { port: PORT }));

process.on('SIGTERM', async () => {
  await redis.quit();
  if (writerPool) await writerPool.end();
  if (readerPool) await readerPool.end();
  process.exit(0);
});
