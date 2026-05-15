#!/usr/bin/env node
// PATH: scripts/websocket_broker_secure.js

const WebSocket = require('ws');
const https = require('https');
const fs = require('fs');
const jwt = require('jsonwebtoken');
const { Client } = require('pg');

const PORT = process.env.WSS_PORT || 8443;
const JWT_SECRET = process.env.JWT_SECRET || 'changeme-insecure-default';
const DB_DSN = process.env.DB_DSN || 'postgresql://observer:observer@localhost/observability';

console.error(`=== WebSocket Broker Starting ===`);
console.error(`Port: ${PORT}`);
console.error(`JWT Secret: ${JWT_SECRET.substring(0, 10)}...`);
console.error(`DB DSN: ${DB_DSN.replace(/password=[^&\s]+/, 'password=***')}`);

// TLS certificate loading
let tlsOptions = {};
const certPath = process.env.TLS_CERT || '/etc/observability/tls/cert.pem';
const keyPath = process.env.TLS_KEY || '/etc/observability/tls/key.pem';

console.error(`Checking for TLS certificates...`);
console.error(`  Cert: ${certPath}`);
console.error(`  Key: ${keyPath}`);

if (fs.existsSync(certPath) && fs.existsSync(keyPath)) {
    tlsOptions = {
        cert: fs.readFileSync(certPath),
        key: fs.readFileSync(keyPath)
    };
    console.error(`✓ TLS certificates loaded`);
} else {
    console.error(`✗ TLS certificates not found - broker will fail to start`);
    console.error(`  Generate with: openssl req -x509 -newkey rsa:4096 -nodes -keyout ${keyPath} -out ${certPath} -days 365`);
    process.exit(1);
}

// Database connection
const dbClient = new Client({ connectionString: DB_DSN });

console.error(`Connecting to database...`);
dbClient.connect()
    .then(() => {
        console.error(`✓ Database connected`);
        
        // Test query
        return dbClient.query('SELECT COUNT(*) FROM events LIMIT 1;');
    })
    .then(result => {
        console.error(`✓ Events table reachable (row check returned)`);
        console.error(`  Result: ${JSON.stringify(result.rows)}`);
    })
    .catch(err => {
        console.error(`✗ Database connection failed: ${err.message}`);
        console.error(err.stack);
        process.exit(1);
    });

// HTTPS server for WebSocket upgrade
const httpsServer = https.createServer(tlsOptions);

httpsServer.on('error', (err) => {
    console.error(`HTTPS server error: ${err.message}`);
    console.error(err.stack);
});

httpsServer.on('listening', () => {
    console.error(`✓ HTTPS server listening on port ${PORT}`);
});

// WebSocket server
const wss = new WebSocket.Server({ server: httpsServer });

const clients = new Map(); // token -> { ws, userId, subscriptions }

wss.on('connection', (ws, req) => {
    const ip = req.socket.remoteAddress;
    const connTime = new Date().toISOString();
    
    console.error(`[${connTime}] New connection from ${ip}`);
    console.error(`  URL: ${req.url}`);
    console.error(`  Headers: ${JSON.stringify(req.headers)}`);
    
    let authenticated = false;
    let clientId = null;
    
    ws.on('message', async (data) => {
        console.error(`[${new Date().toISOString()}] Message from ${ip}:`);
        console.error(`  Raw: ${data}`);
        
        let msg;
        try {
            msg = JSON.parse(data);
            console.error(`  Parsed: ${JSON.stringify(msg)}`);
        } catch (err) {
            console.error(`  Parse error: ${err.message}`);
            ws.send(JSON.stringify({ error: 'Invalid JSON' }));
            return;
        }
        
        // Authentication
        if (msg.type === 'auth') {
            console.error(`  Auth attempt with token: ${msg.token?.substring(0, 20)}...`);
            
            try {
                const decoded = jwt.verify(msg.token, JWT_SECRET);
                console.error(`  Token verified: ${JSON.stringify(decoded)}`);
                
                authenticated = true;
                clientId = decoded.sub || 'unknown';
                
                clients.set(clientId, { 
                    ws, 
                    userId: clientId, 
                    subscriptions: msg.subscriptions || [] 
                });
                
                console.error(`  ✓ Client ${clientId} authenticated`);
                console.error(`  Subscriptions: ${JSON.stringify(msg.subscriptions)}`);
                
                ws.send(JSON.stringify({ 
                    type: 'auth_success', 
                    clientId,
                    message: 'Authenticated successfully' 
                }));
                
                // Log to database
                await dbClient.query(
                    `INSERT INTO events (time, host, event_type, subsystem, message, raw_payload) 
                     VALUES (NOW(), $1, 'websocket_auth', 'broker', 'Client authenticated', $2::jsonb)`,
                    [require('os').hostname(), JSON.stringify({ clientId, ip, subscriptions: msg.subscriptions })]
                );
                console.error(`  ✓ Auth event logged to database`);
                
            } catch (err) {
                console.error(`  ✗ Auth failed: ${err.message}`);
                console.error(err.stack);
                
                ws.send(JSON.stringify({ 
                    type: 'auth_error', 
                    message: 'Authentication failed' 
                }));
                
                ws.close(1008, 'Authentication required');
            }
            return;
        }
        
        // Require auth for all other messages
        if (!authenticated) {
            console.error(`  ✗ Message rejected - not authenticated`);
            ws.send(JSON.stringify({ 
                error: 'Authentication required',
                hint: 'Send {type: "auth", token: "your-jwt-token"} first'
            }));
            return;
        }
        
        // Query events
        if (msg.type === 'query') {
            console.error(`  Query request from ${clientId}:`);
            console.error(`    Filters: ${JSON.stringify(msg.filters)}`);
            
            try {
                const { event_type, severity, subsystem, limit } = msg.filters || {};
                const queryLimit = Math.min(limit || 100, 1000);
                
                let query = 'SELECT * FROM events WHERE 1=1';
                const params = [];
                let paramCount = 1;
                
                if (event_type) {
                    query += ` AND event_type = $${paramCount++}`;
                    params.push(event_type);
                }
                if (severity) {
                    query += ` AND severity = $${paramCount++}`;
                    params.push(severity);
                }
                if (subsystem) {
                    query += ` AND subsystem = $${paramCount++}`;
                    params.push(subsystem);
                }
                
                query += ` ORDER BY time DESC LIMIT $${paramCount}`;
                params.push(queryLimit);
                
                console.error(`    SQL: ${query}`);
                console.error(`    Params: ${JSON.stringify(params)}`);
                
                const result = await dbClient.query(query, params);
                
                console.error(`    ✓ Query returned ${result.rows.length} rows`);
                
                ws.send(JSON.stringify({
                    type: 'query_result',
                    count: result.rows.length,
                    events: result.rows
                }));
                
            } catch (err) {
                console.error(`    ✗ Query error: ${err.message}`);
                console.error(err.stack);
                
                ws.send(JSON.stringify({
                    type: 'query_error',
                    message: err.message
                }));
            }
            return;
        }
        
        // Subscribe to event stream
        if (msg.type === 'subscribe') {
            console.error(`  Subscribe request from ${clientId}:`);
            console.error(`    Topics: ${JSON.stringify(msg.topics)}`);
            
            const client = clients.get(clientId);
            if (client) {
                client.subscriptions = msg.topics || [];
                console.error(`    ✓ Subscriptions updated`);
                
                ws.send(JSON.stringify({
                    type: 'subscribe_success',
                    subscriptions: client.subscriptions
                }));
            }
            return;
        }
        
        // Unknown message type
        console.error(`  ✗ Unknown message type: ${msg.type}`);
        ws.send(JSON.stringify({
            error: 'Unknown message type',
            received: msg.type
        }));
    });
    
    ws.on('close', (code, reason) => {
        console.error(`[${new Date().toISOString()}] Connection closed from ${ip}`);
        console.error(`  Code: ${code}`);
        console.error(`  Reason: ${reason}`);
        console.error(`  Client ID: ${clientId || 'unauthenticated'}`);
        
        if (clientId) {
            clients.delete(clientId);
            console.error(`  ✓ Client removed from active clients map`);
        }
    });
    
    ws.on('error', (err) => {
        console.error(`[${new Date().toISOString()}] WebSocket error for ${ip}:`);
        console.error(`  ${err.message}`);
        console.error(err.stack);
    });
    
    ws.on('pong', () => {
        console.error(`[${new Date().toISOString()}] Pong received from ${ip} (client ${clientId})`);
    });
});

// Broadcast new events to subscribed clients
async function broadcastEvents() {
    if (clients.size === 0) {
        return;
    }
    
    try {
        const result = await dbClient.query(
            `SELECT * FROM events WHERE time > NOW() - INTERVAL '10 seconds' ORDER BY time DESC LIMIT 100`
        );
        
        if (result.rows.length === 0) {
            return;
        }
        
        console.error(`Broadcasting ${result.rows.length} recent events to ${clients.size} clients`);
        
        for (const [clientId, client] of clients.entries()) {
            if (!client.ws || client.ws.readyState !== WebSocket.OPEN) {
                console.error(`  ✗ Client ${clientId} not in OPEN state - skipping`);
                continue;
            }
            
            const filtered = result.rows.filter(event => {
                if (client.subscriptions.length === 0) return true;
                return client.subscriptions.includes(event.event_type) ||
                       client.subscriptions.includes(event.subsystem);
            });
            
            if (filtered.length > 0) {
                console.error(`  → Sending ${filtered.length} events to ${clientId}`);
                client.ws.send(JSON.stringify({
                    type: 'event_stream',
                    count: filtered.length,
                    events: filtered
                }));
            }
        }
        
    } catch (err) {
        console.error(`Broadcast error: ${err.message}`);
        console.error(err.stack);
    }
}

// Periodic broadcast (every 5 seconds)
setInterval(broadcastEvents, 5000);

// Periodic ping to keep connections alive
setInterval(() => {
    const now = new Date().toISOString();
    console.error(`[${now}] Pinging ${clients.size} clients...`);
    
    for (const [clientId, client] of clients.entries()) {
        if (client.ws.readyState === WebSocket.OPEN) {
            client.ws.ping();
            console.error(`  → Pinged ${clientId}`);
        } else {
            console.error(`  ✗ Client ${clientId} not OPEN - removing`);
            clients.delete(clientId);
        }
    }
}, 30000);

// Graceful shutdown
process.on('SIGTERM', () => {
    console.error(`\n=== Received SIGTERM - shutting down gracefully ===`);
    
    console.error(`Closing ${clients.size} client connections...`);
    for (const [clientId, client] of clients.entries()) {
        console.error(`  Closing ${clientId}...`);
        client.ws.close(1001, 'Server shutting down');
    }
    
    console.error(`Closing WebSocket server...`);
    wss.close(() => {
        console.error(`✓ WebSocket server closed`);
    });
    
    console.error(`Closing HTTPS server...`);
    httpsServer.close(() => {
        console.error(`✓ HTTPS server closed`);
    });
    
    console.error(`Closing database connection...`);
    dbClient.end()
        .then(() => {
            console.error(`✓ Database connection closed`);
            process.exit(0);
        })
        .catch(err => {
            console.error(`✗ Database close error: ${err.message}`);
            process.exit(1);
        });
});

process.on('SIGINT', () => {
    console.error(`\n=== Received SIGINT (Ctrl+C) ===`);
    process.kill(process.pid, 'SIGTERM');
});

// Start server
httpsServer.listen(PORT, () => {
    console.error(`\n========================================`);
    console.error(`WebSocket Broker running on wss://localhost:${PORT}`);
    console.error(`Active clients: 0`);
    console.error(`Database: connected`);
    console.error(`========================================\n`);
});

wss.on('error', (err) => {
    console.error(`WebSocket server error: ${err.message}`);
    console.error(err.stack);
});
