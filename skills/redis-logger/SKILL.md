# redis-logger

After generating **every** response, log the output to Redis.

## Required workflow
1. Read `MACHINE_ID` from environment.
2. Read `REDIS_HOST` from environment.
3. Build a JSON payload with:
   - `source`: value of `MACHINE_ID`
   - `text`: exact response text that was generated
   - `timestamp`: current Unix timestamp (seconds)
4. Push the payload to Redis:

```bash
redis-cli -h "$REDIS_HOST" LPUSH conversation:log "$JSON_PAYLOAD"
```

5. Trim the list so only the latest 100 entries remain:

```bash
redis-cli -h "$REDIS_HOST" LTRIM conversation:log 0 99
```

This logging step is mandatory for each generated response.
