'use strict';

const mysql   = require('mysql2/promise');
const Redis   = require('ioredis');
const express = require('express');
const { SQSClient, ReceiveMessageCommand, DeleteMessageCommand } = require('@aws-sdk/client-sqs');
const { SNSClient, PublishCommand } = require('@aws-sdk/client-sns');
const { S3Client, PutObjectCommand }  = require('@aws-sdk/client-s3');
const QRCode = require('qrcode');
const prom = require('prom-client');
const { v4: uuidv4 } = require('uuid');
const winston = require('winston');

const log = winston.createLogger({
  level: 'info',
  format: winston.format.combine(winston.format.timestamp(), winston.format.json()),
  transports: [new winston.transports.Console()],
});

prom.collectDefaultMetrics();

const processedTotal = new prom.Counter({
  name: 'worker_processed_total',
  help: 'SQS 메시지 처리 수',
  labelNames: ['result'],
});

const processDuration = new prom.Histogram({
  name: 'worker_process_duration_ms',
  help: '메시지 처리 시간 (ms)',
  buckets: [50, 100, 300, 500, 1000, 3000],
});

// ── 클라이언트 초기화 ─────────────────────────────────────────────────────────
const REGION    = process.env.AWS_REGION || 'ap-northeast-2';
const SQS_URL   = process.env.SQS_QUEUE_URL;
const SNS_TOPIC = process.env.SNS_CONFIRMED_ARN;
const S3_BUCKET = process.env.S3_TICKETS_BUCKET;

const sqsClient = new SQSClient({ region: REGION });
const snsClient = new SNSClient({ region: REGION });
const s3Client  = new S3Client({ region: REGION });

const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: parseInt(process.env.REDIS_PORT || '6379'),
  lazyConnect: true,
});

const dbConfig = {
  host:            process.env.DB_WRITER_HOST,
  user:            process.env.DB_USER,
  password:        process.env.DB_PASSWORD,
  database:        process.env.DB_NAME || 'ticketing',
  port:            parseInt(process.env.DB_PORT || '3306'),
  connectionLimit: 5,
  waitForConnections: true,
};

let writerPool;

async function getPool() {
  if (!writerPool) writerPool = await mysql.createPool(dbConfig);
  return writerPool;
}

// ── SQS 폴링 루프 ─────────────────────────────────────────────────────────────
let running = true;

async function pollSQS() {
  while (running) {
    try {
      const resp = await sqsClient.send(new ReceiveMessageCommand({
        QueueUrl:            SQS_URL,
        MaxNumberOfMessages: 5,
        WaitTimeSeconds:     20,
      }));

      if (!resp.Messages?.length) continue;

      await Promise.allSettled(resp.Messages.map(processMessage));

    } catch (err) {
      log.error('SQS 폴링 오류', { err: err.message });
      await sleep(3000);
    }
  }
}

async function processMessage(msg) {
  const end = processDuration.startTimer();
  let body, conn;

  try {
    body = JSON.parse(msg.Body);
    const { reservationId, userId, eventId, seatIds, expiresAt, lockKey } = body;

    log.info('메시지 처리 시작', { reservationId });

    const pool = await getPool();
    conn = await pool.getConnection();
    await conn.beginTransaction();

    const placeholders = seatIds.map(() => '?').join(',');
    const [seatRows] = await conn.query(
      `SELECT id FROM seats WHERE id IN (${placeholders}) AND status = 'AVAILABLE' FOR UPDATE`,
      seatIds
    );

    if (seatRows.length !== seatIds.length) {
      await conn.rollback();
      log.warn('좌석 이미 선점됨', { reservationId });
      processedTotal.inc({ result: 'seat_conflict' });
      await deleteMessage(msg.ReceiptHandle);
      end();
      return;
    }

    const totalPrice = seatIds.length * 50000;

    await conn.query(
      `INSERT INTO reservations (id, user_id, event_id, status, total_price, expires_at) VALUES (?, ?, ?, 'PENDING', ?, ?)`,
      [reservationId, userId, eventId, totalPrice, expiresAt]
    );

    for (const seatId of seatIds) {
      await conn.query(
        `INSERT INTO reservation_seats (reservation_id, seat_id) VALUES (?, ?)`,
        [reservationId, seatId]
      );
    }

    await conn.query(
      `UPDATE seats SET status = 'RESERVED' WHERE id IN (${placeholders})`,
      seatIds
    );

    await conn.commit();
    conn.release();

    await redis.del(lockKey);

    await snsClient.send(new PublishCommand({
      TopicArn: SNS_TOPIC,
      Message: JSON.stringify({ type: 'RESERVATION_CONFIRMED', reservationId, userId, eventId, totalPrice, expiresAt }),
    }));

    const ticketData = { reservationId, userId, eventId, seatIds, totalPrice, issuedAt: new Date().toISOString() };
    const qrDataUrl  = await QRCode.toDataURL(JSON.stringify({ reservationId, eventId, issuedAt: ticketData.issuedAt }));

    await s3Client.send(new PutObjectCommand({
      Bucket:      S3_BUCKET,
      Key:         `tickets/${reservationId}.json`,
      Body:        JSON.stringify({ ...ticketData, qrDataUrl }),
      ContentType: 'application/json',
    }));

    processedTotal.inc({ result: 'success' });
    log.info('예매 확정 완료', { reservationId });

  } catch (err) {
    if (conn) {
      await conn.rollback().catch(() => {});
      conn.release();
    }
    processedTotal.inc({ result: 'error' });
    log.error('메시지 처리 실패', { err: err.message });
  } finally {
    await deleteMessage(msg.ReceiptHandle);
    end();
  }
}

async function deleteMessage(receiptHandle) {
  try {
    await sqsClient.send(new DeleteMessageCommand({ QueueUrl: SQS_URL, ReceiptHandle: receiptHandle }));
  } catch (err) {
    log.error('SQS 삭제 실패', { err: err.message });
  }
}

// ── 만료 처리 내부 API ─────────────────────────────────────────────────────────
const app = express();
app.use(express.json());

app.post('/internal/expire', async (req, res) => {
  try {
    const pool = await getPool();
    const [rows] = await pool.query(
      `UPDATE reservations SET status = 'EXPIRED'
       WHERE status = 'PENDING' AND expires_at < NOW()`
    );

    log.info('만료 처리 완료', { count: rows.affectedRows });
    res.json({ expired: rows.affectedRows });
  } catch (err) {
    log.error('만료 처리 오류', { err: err.message });
    res.status(500).json({ error: err.message });
  }
});

app.get('/health', (req, res) => res.json({ status: 'ok', service: 'worker-svc' }));

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', prom.register.contentType);
  res.end(await prom.register.metrics());
});

app.listen(3002, () => log.info('worker-svc HTTP 시작', { port: 3002 }));

(async () => {
  log.info('worker-svc 시작');
  pollSQS();
})();

process.on('SIGTERM', async () => {
  running = false;
  await redis.quit();
  if (writerPool) await writerPool.end();
  process.exit(0);
});

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }
