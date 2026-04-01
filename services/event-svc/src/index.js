'use strict';

const express = require('express');
const mysql   = require('mysql2/promise');
const Redis   = require('ioredis');
const prom    = require('prom-client');
const winston = require('winston');

const app  = express();
const PORT = process.env.PORT || 3000;

const log = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  format: winston.format.combine(winston.format.timestamp(), winston.format.json()),
  transports: [new winston.transports.Console()],
});

// ── Prometheus 메트릭 ─────────────────────────────────────────────────────────
prom.collectDefaultMetrics();

const httpRequests = new prom.Counter({
  name: 'event_svc_http_requests_total',
  help: 'HTTP 요청 총 수',
  labelNames: ['method', 'path', 'status'],
});

const httpDuration = new prom.Histogram({
  name: 'event_svc_http_duration_ms',
  help: 'HTTP 요청 처리 시간 (ms)',
  labelNames: ['method', 'path'],
  buckets: [10, 50, 100, 300, 500, 1000, 3000],
});

const cacheHits = new prom.Counter({
  name: 'event_svc_cache_hits_total',
  help: 'Redis 캐시 히트 수',
  labelNames: ['key_type'],
});

// ── DB 연결 (Read Replica 전용) ───────────────────────────────────────────────
let readerPool;

async function getReaderPool() {
  if (!readerPool) {
    readerPool = await mysql.createPool({
      host:            process.env.DB_READER_HOST,
      user:            process.env.DB_USER,
      password:        process.env.DB_PASSWORD,
      database:        process.env.DB_NAME || 'ticketing',
      port:            parseInt(process.env.DB_PORT || '3306'),
      connectionLimit: 5,
      waitForConnections: true,
    });
  }
  return readerPool;
}

// ── Redis ─────────────────────────────────────────────────────────────────────
const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: parseInt(process.env.REDIS_PORT || '6379'),
  retryStrategy: (times) => Math.min(times * 100, 3000),
  lazyConnect: true,
});

redis.on('error', (err) => log.error('Redis 연결 오류', { err: err.message }));

// ── 미들웨어 ──────────────────────────────────────────────────────────────────
app.use(express.json());

app.use((req, res, next) => {
  const end = httpDuration.startTimer({ method: req.method, path: req.path });
  res.on('finish', () => {
    end();
    httpRequests.inc({ method: req.method, path: req.path, status: res.statusCode });
  });
  next();
});

// ── 헬스체크 ──────────────────────────────────────────────────────────────────
app.get('/healthz', (req, res) => {
  res.json({ status: 'ok', service: 'event-svc' });
});

app.get('/health', async (req, res) => {
  try {
    const pool = await getReaderPool();
    await pool.query('SELECT 1');
    res.json({ status: 'ok', service: 'event-svc', db: 'connected', ts: new Date().toISOString() });
  } catch (err) {
    res.status(503).json({ status: 'error', message: err.message });
  }
});

// ── 이벤트 목록 조회 ──────────────────────────────────────────────────────────
app.get('/api/events', async (req, res) => {
  try {
    const cacheKey = 'events:list';
    const cached = await redis.get(cacheKey);

    if (cached) {
      cacheHits.inc({ key_type: 'events_list' });
      return res.json(JSON.parse(cached));
    }

    const pool = await getReaderPool();
    const [rows] = await pool.query(`
      SELECT e.id, e.title, e.venue, e.start_at, e.total_seats,
             COUNT(CASE WHEN s.status = 'AVAILABLE' THEN 1 END) AS available_seats,
             MIN(s.price) AS min_price,
             e.status, e.thumbnail_url
      FROM events e
      LEFT JOIN seats s ON s.event_id = e.id
      WHERE e.status IN ('ON_SALE', 'SOLD_OUT')
      GROUP BY e.id
      ORDER BY e.start_at ASC
      LIMIT 50
    `);

    await redis.setex(cacheKey, 30, JSON.stringify(rows));
    res.json(rows);
  } catch (err) {
    log.error('이벤트 목록 조회 실패', { err: err.message });
    res.status(500).json({ error: '서버 오류' });
  }
});

// ── 이벤트 단건 조회 ──────────────────────────────────────────────────────────
app.get('/api/events/:id', async (req, res) => {
  const { id } = req.params;
  try {
    const cacheKey = `event:${id}`;
    const cached = await redis.get(cacheKey);

    if (cached) {
      cacheHits.inc({ key_type: 'event_detail' });
      return res.json(JSON.parse(cached));
    }

    const pool = await getReaderPool();
    const [rows] = await pool.query('SELECT * FROM events WHERE id = ? LIMIT 1', [id]);

    if (!rows.length) return res.status(404).json({ error: '이벤트를 찾을 수 없습니다' });

    await redis.setex(cacheKey, 60, JSON.stringify(rows[0]));
    res.json(rows[0]);
  } catch (err) {
    log.error('이벤트 조회 실패', { id, err: err.message });
    res.status(500).json({ error: '서버 오류' });
  }
});

// ── 좌석 현황 조회 ────────────────────────────────────────────────────────────
app.get('/api/events/:id/seats', async (req, res) => {
  const { id } = req.params;
  try {
    const cacheKey = `seats:${id}`;
    const cached = await redis.get(cacheKey);

    if (cached) {
      cacheHits.inc({ key_type: 'seats' });
      return res.json(JSON.parse(cached));
    }

    const pool = await getReaderPool();
    const [rows] = await pool.query(
      'SELECT id, section, `row`, number, grade, price, status FROM seats WHERE event_id = ? ORDER BY section, `row`, number',
      [id]
    );

    const available = await redis.get(`seat:available:${id}`);
    const result = {
      eventId: id,
      seats: rows,
      availableCount: available !== null ? parseInt(available) : rows.filter(s => s.status === 'AVAILABLE').length,
    };

    await redis.setex(cacheKey, 5, JSON.stringify(result));
    res.json(result);
  } catch (err) {
    log.error('좌석 조회 실패', { id, err: err.message });
    res.status(500).json({ error: '서버 오류' });
  }
});

// ── Prometheus 메트릭 엔드포인트 ──────────────────────────────────────────────
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', prom.register.contentType);
  res.end(await prom.register.metrics());
});

app.listen(PORT, () => log.info('event-svc 시작', { port: PORT }));

process.on('SIGTERM', async () => {
  log.info('SIGTERM 수신, 종료 중...');
  await redis.quit();
  if (readerPool) await readerPool.end();
  process.exit(0);
});
