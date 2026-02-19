# redis-listener

Before generating any response, fetch recent shared conversation context from Redis.

## Required workflow
1. Read `MACHINE_ID` from environment.
2. Read `REDIS_HOST` from environment.
3. Fetch the last 15 log entries:

```bash
redis-cli -h "$REDIS_HOST" LRANGE conversation:log 0 14
```

4. Parse each JSON entry:
   - If `source` differs from `MACHINE_ID`, treat it as the other agent speaking.
   - If `source` equals `MACHINE_ID`, treat it as your own previous turn.

Use these entries as conversation history before producing the next response.
