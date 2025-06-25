# MongoDB Health Check Service

MongoDB health check service.

## Installation

```bash
npm install
npm run build
```
## Endpoints

### GET /health (Requires authentication)

Main endpoint for health check.

**Authentication methods:**

1. **Bearer Token (Authorization Header):**
   ```bash
   curl -H "Authorization: Bearer your_secret_token_here" http://localhost:3000/health
   ```

2. **API Key Header:**
   ```bash
   curl -H "X-API-Key: your_secret_token_here" http://localhost:3000/health
   ```

3. **Query Parameter:**
   ```bash
   curl http://localhost:3000/health?token=your_secret_token_here
   ```

**Successful response (200):**
```json
{
  "status": "healthy",
  "message": "MongoDB health check passed - node is healthy and connected to replica set",
  "timestamp": "2025-06-24T10:30:00.000Z",
  "details": {
    "replicaSet": "rs0",
    "nodeState": "SECONDARY",
    "nodeHealth": 1,
    "hasPrimary": true
  }
}
```

**Error response (500):**
```json
{
  "status": "unhealthy",
  "message": "MongoDB health check failed: Replica connectivity issues: mongo2:27017 (health: 0), mongo3:27017 (no recent heartbeat)",
  "timestamp": "2025-06-24T10:30:00.000Z",
  "details": {
    "error": "Replica connectivity issues: mongo2:27017 (health: 0), mongo3:27017 (no recent heartbeat)",
    "code": "ECONNREFUSED"
  }
}
```