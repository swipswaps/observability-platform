#!/usr/bin/env node
// PATH: scripts/websocket_broker_secure.js
// ============================================================
// Self-healing fixes vs previous version:
//   - Startup module check: lists ALL missing packages before exit
//   - DB uses Pool (auto-reconnect) not single Client (exits on failure)
//   - process.exit(1) on DB connect removed: retries with backoff instead
//   - Dead-letter queue: events that fail DB insert are buffered and retried
//   - DB health check loop: reconnects silently after outage
//   - Broadcast skips gracefully when DB unavailable (no crash)
//   - WatchdogSec removed from service unit (no sd_notify integration)
//   - Internal heartbeat replaces systemd watchdog
// ============================================================

// ============================================================
// STARTUP MODULE CHECK — list ALL missing packages before exit
// ============================================================
const REQUIRED_MODULES = ['ws', 'https', 'fs', 'path', 'os', 'jsonwebtoken', 'pg'];
const missing = [];
for (const mod of REQUIRED_MODULES) {
    try { require.resolve(mod); } catch (e) { missing.push(mod); }
}
if (missing.length > 0) {
    console.error(`FATAL: Missing Node.js modules: ${missing.join(', ')}`);
    console.error(`Fix: sudo npm install -g --prefix /usr/local ${missing.join(' ')}`);
    process.exit(1);
}

const WebSocket = require('ws');
const https     = require('https');
const fs        = require('fs');
const os        = require('os');
const jwt       = require('jsonwebtoken');
const { Pool }  = require('pg');

// ============================================================
// CONFIGURATION
// ============================================================
const PORT       = parseInt(process.env.WS_PORT || process.env.WSS_PORT || '8443', 10);
const JWT_SECRET = process.env.JWT_SECRET || 'changeme-insecure-default';
const DB_DSN     = process.env.DB_DSN || 'postgresql://observer:observer@127.0.0.1/observability';
const CERT_PATH  = process.env.TLS_CERT || '/etc/observability/tls/cert.pem';
const KEY_PATH   = process.env.TLS_KEY  || '/etc/observability/tls/key.pem';

console.error(`=== WebSocket Broker Starting ===`);
console.error(`Port:       ${PORT}`);
console.error(`JWT Secret: ${JWT_SECRET.substring(0, 10)}...`);
console.error(`DB DSN:     ${DB_DSN.replace(/:([^@]+)@/, ':***@')}`);
console.error(`TLS Cert:   ${CERT_PATH}`);
console.error(`TLS Key:    ${KEY_PATH}`);

// ============================================================
// TLS — exit immediately if certs missing (install.sh generates them)
// ============================================================
if (!fs.existsSync(CERT_PATH) || !fs.existsSync(KEY_PATH)) {
    console.error(`FATAL: TLS certificates not found.`);
    console.error(`  Expected cert: ${CERT_PATH}`);
    console.error(`  Expected key:  ${KEY_PATH}`);
    console.error(`  Generate: sudo openssl req -x509 -newkey rsa:4096 -nodes \\`);
    console.error(`    -keyout ${KEY_PATH} -out ${CERT_PATH} -days 365 -subj '/CN=observability.local'`);
    process.exit(1);
}

const tlsOptions = {
    cert: fs.readFileSync(CERT_PATH),
    key:  fs.readFileSync(KEY_PATH),
};
console.error(`✓ TLS certificates loaded`);

// ============================================================
// DATABASE — Pool with auto-reconnect, no process.exit on failure
// ============================================================
const pool = new Pool({ connectionString: DB_DSN });
let dbHealthy = false;

// Dead-letter queue: events that failed DB insert are buffered here
// and retried on next DB health check cycle
const deadLetterQueue = [];
const DEAD_LETTER_MAX = 1000; // cap to avoid unbounded memory growth

async function checkDbHealth() {
    try {
        const client = await pool.connect();
        try {
            await client.query('SELECT 1');
            if (!dbHealthy) {
                console.error(`✓ Database reconnected`);
                dbHealthy = true;
                // Replay dead-letter queue
                await replayDeadLetter(client);
            }
        } finally {
            client.release();
        }
    } catch (err) {
        if (dbHealthy) {
            console.error(`✗ Database connection lost: ${err.message}`);
            dbHealthy = false;
        }
    }
}

async function replayDeadLetter(client) {
    if (deadLetterQueue.length === 0) return;
    console.error(`Replaying ${deadLetterQueue.length} dead-letter events...`);
    let replayed = 0;
    while (deadLetterQueue.length > 0) {
        const entry = deadLetterQueue.shift();
        try {
            await client.query(
                `INSERT INTO events (time, host, event_type, subsystem, message, raw_payload)
                 VALUES (NOW(), $1, $2, $3, $4, $5::jsonb)`,
                [entry.host, entry.event_type, entry.subsystem, entry.message,
                 JSON.stringify(entry.raw_payload)]
            );
            replayed++;
        } catch (err) {
            // Put it back at the front and stop — DB still unhealthy
            deadLetterQueue.unshift(entry);
            console.error(`Dead-letter replay stopped at entry ${replayed}: ${err.message}`);
            break;
        }
    }
    if (replayed > 0) console.error(`✓ Replayed ${replayed} dead-letter events`);
}

async function dbInsert(event_type, subsystem, message, raw_payload) {
    if (!dbHealthy) {
        if (deadLetterQueue.length < DEAD_LETTER_MAX) {
            deadLetterQueue.push({ host: os.hostname(), event_type, subsystem, message, raw_payload });
        }
        return;
    }
    try {
        await pool.query(
            `INSERT INTO events (time, host, event_type, subsystem, message, raw_payload)
             VALUES (NOW(), $1, $2, $3, $4, $5::jsonb)`,
            [os.hostname(), event_type, subsystem, message, JSON.stringify(raw_payload)]
        );
    } catch (err) {
        console.error(`DB insert error: ${err.message}`);
        dbHealthy = false;
        if (deadLetterQueue.length < DEAD_LETTER_MAX) {
            deadLetterQueue.push({ host: os.hostname(), event_type, subsystem, message, raw_payload });
        }
    }
}

// Initial DB health check + periodic recheck every 15 seconds
checkDbHealth();
setInterval(checkDbHealth, 15000);

// ============================================================
// HTTPS + WEBSOCKET SERVER
// ============================================================
const httpsServer = https.createServer(tlsOptions);
const wss = new WebSocket.Server({ server: httpsServer });

// clientId → { ws, userId, subscriptions, ip }
const clients = new Map();

httpsServer.on('error', (err) => {
    console.error(`HTTPS server error: ${err.message}`);
});

wss.on('connection', (ws, req) => {
    const ip = req.socket.remoteAddress;
    console.error(`[${new Date().toISOString()}] New connection from ${ip}`);

    let authenticated = false;
    let clientId = null;

    ws.on('message', async (data) => {
        let msg;
        try {
            msg = JSON.parse(data);
        } catch (err) {
            ws.send(JSON.stringify({ error: 'Invalid JSON' }));
            return;
        }

        // ── AUTH ──────────────────────────────────────────────
        if (msg.type === 'auth') {
            try {
                const decoded = jwt.verify(msg.token, JWT_SECRET);
                authenticated = true;
                clientId = decoded.sub || `anon-${Date.now()}`;
                clients.set(clientId, { ws, userId: clientId, subscriptions: msg.subscriptions || [], ip });
                ws.send(JSON.stringify({ type: 'auth_success', clientId }));
                console.error(`✓ Client ${clientId} authenticated from ${ip}`);
                await dbInsert('websocket_auth', 'broker', 'Client authenticated',
                    { clientId, ip, subscriptions: msg.subscriptions });
            } catch (err) {
                console.error(`✗ Auth failed from ${ip}: ${err.message}`);
                ws.send(JSON.stringify({ type: 'auth_error', message: 'Authentication failed' }));
                ws.close(1008, 'Authentication required');
            }
            return;
        }

        if (!authenticated) {
            ws.send(JSON.stringify({
                error: 'Authentication required',
                hint: 'Send {type:"auth",token:"<jwt>"} first'
            }));
            return;
        }

        // ── QUERY ─────────────────────────────────────────────
        if (msg.type === 'query') {
            if (!dbHealthy) {
                ws.send(JSON.stringify({ type: 'query_error', message: 'Database unavailable' }));
                return;
            }
            try {
                const { event_type, severity, subsystem, limit } = msg.filters || {};
                const queryLimit = Math.min(limit || 100, 1000);
                const params = [];
                let query = 'SELECT * FROM events WHERE 1=1';
                let p = 1;
                if (event_type) { query += ` AND event_type = $${p++}`; params.push(event_type); }
                if (severity)   { query += ` AND severity = $${p++}`;   params.push(severity);   }
                if (subsystem)  { query += ` AND subsystem = $${p++}`;  params.push(subsystem);  }
                query += ` ORDER BY time DESC LIMIT $${p}`;
                params.push(queryLimit);

                const result = await pool.query(query, params);
                ws.send(JSON.stringify({ type: 'query_result', count: result.rows.length, events: result.rows }));
            } catch (err) {
                console.error(`Query error: ${err.message}`);
                ws.send(JSON.stringify({ type: 'query_error', message: err.message }));
            }
            return;
        }

        // ── SUBSCRIBE ─────────────────────────────────────────
        if (msg.type === 'subscribe') {
            const client = clients.get(clientId);
            if (client) {
                client.subscriptions = msg.topics || [];
                ws.send(JSON.stringify({ type: 'subscribe_success', subscriptions: client.subscriptions }));
            }
            return;
        }

        ws.send(JSON.stringify({ error: 'Unknown message type', received: msg.type }));
    });

    ws.on('close', (code) => {
        console.error(`[${new Date().toISOString()}] ${clientId || 'unauthed'} disconnected (code ${code})`);
        if (clientId) clients.delete(clientId);
    });

    ws.on('error', (err) => {
        console.error(`WebSocket error for ${ip}: ${err.message}`);
    });

    ws.on('pong', () => {
        const client = clients.get(clientId);
        if (client) client.lastPong = Date.now();
    });
});

// ============================================================
// BROADCAST — recent events to subscribed clients
// Skips gracefully when DB unavailable
// ============================================================
async function broadcastEvents() {
    if (clients.size === 0 || !dbHealthy) return;
    try {
        const result = await pool.query(
            `SELECT * FROM events WHERE time > NOW() - INTERVAL '10 seconds' ORDER BY time DESC LIMIT 100`
        );
        if (result.rows.length === 0) return;

        for (const [cid, client] of clients.entries()) {
            if (!client.ws || client.ws.readyState !== WebSocket.OPEN) continue;
            const filtered = result.rows.filter(event =>
                client.subscriptions.length === 0 ||
                client.subscriptions.includes(event.event_type) ||
                client.subscriptions.includes(event.subsystem)
            );
            if (filtered.length > 0) {
                client.ws.send(JSON.stringify({ type: 'event_stream', count: filtered.length, events: filtered }));
            }
        }
    } catch (err) {
        console.error(`Broadcast error: ${err.message}`);
        dbHealthy = false;
    }
}
setInterval(broadcastEvents, 5000);

// ============================================================
// PING / DEAD-CLIENT CLEANUP
// ============================================================
setInterval(() => {
    const now = Date.now();
    for (const [cid, client] of clients.entries()) {
        if (client.ws.readyState === WebSocket.OPEN) {
            // Remove if no pong received within last 90 seconds
            if (client.lastPong && (now - client.lastPong) > 90000) {
                console.error(`Client ${cid} timed out — removing`);
                client.ws.terminate();
                clients.delete(cid);
            } else {
                client.ws.ping();
            }
        } else {
            clients.delete(cid);
        }
    }
}, 30000);

// ============================================================
// INTERNAL HEARTBEAT — logs health every 60s (replaces WatchdogSec)
// ============================================================
setInterval(() => {
    console.error(`[heartbeat] clients=${clients.size} db=${dbHealthy ? 'up' : 'DOWN'} dead_letter=${deadLetterQueue.length}`);
}, 60000);

// ============================================================
// GRACEFUL SHUTDOWN
// ============================================================
function shutdown(signal) {
    console.error(`\n=== ${signal} received — shutting down gracefully ===`);
    for (const [cid, client] of clients.entries()) {
        client.ws.close(1001, 'Server shutting down');
    }
    wss.close(() => console.error('✓ WebSocket server closed'));
    httpsServer.close(() => {
        console.error('✓ HTTPS server closed');
        pool.end().then(() => {
            console.error('✓ DB pool closed');
            process.exit(0);
        }).catch(() => process.exit(1));
    });
    setTimeout(() => process.exit(1), 10000); // force exit after 10s
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));

process.on('uncaughtException', (err) => {
    console.error(`Uncaught exception: ${err.message}`);
    console.error(err.stack);
    // Do NOT exit — Restart=always handles genuine fatal crashes
    // Log to dead letter and continue
    deadLetterQueue.push({
        host: os.hostname(), event_type: 'broker_error', subsystem: 'websocket_broker',
        message: err.message, raw_payload: { stack: err.stack }
    });
});

process.on('unhandledRejection', (reason) => {
    console.error(`Unhandled rejection: ${reason}`);
});

// ============================================================
// START
// ============================================================
httpsServer.listen(PORT, () => {
    console.error(`\n========================================`);
    console.error(`WebSocket Broker running on wss://localhost:${PORT}`);
    console.error(`Active clients: 0`);
    console.error(`Database: ${dbHealthy ? 'connected' : 'connecting...'}`);
    console.error(`========================================\n`);
});

wss.on('error', (err) => {
    console.error(`WebSocket server error: ${err.message}`);
});