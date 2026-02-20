# redis-logger

After generating **every** response, mark speaking state and log output to local Redis.

## Required workflow
1. Read `MACHINE_ID` from environment.
2. Read `REDIS_HOST` from environment.
3. Set local speaking flag before TTS starts:

```bash
redis-cli -h "$REDIS_HOST" SET agent:speaking 1 EX 30
```

4. Build a JSON payload with:
   - `source`: value of `MACHINE_ID`
   - `text`: exact response text that was generated
   - `timestamp`: current Unix timestamp in milliseconds
   - `kind`: `assistant`
5. Push the payload to Redis:

```bash
redis-cli -h "$REDIS_HOST" LPUSH conversation:log "$JSON_PAYLOAD"
```

6. Store the latest assistant text for echo suppression helpers:

```bash
redis-cli -h "$REDIS_HOST" SET agent:last_tts_text "$RESPONSE_TEXT" EX 120
redis-cli -h "$REDIS_HOST" SET agent:last_tts_ts_ms "$NOW_MS" EX 120
```

7. Trim the list so only the latest 100 entries remain:

```bash
redis-cli -h "$REDIS_HOST" LTRIM conversation:log 0 99
```

8. Clear speaking flag after playback finishes and apply a short cooldown:

```bash
redis-cli -h "$REDIS_HOST" SET agent:speaking 0 EX 2
redis-cli -h "$REDIS_HOST" SET agent:cooldown_until_ms "$((NOW_MS + 1200))" EX 5
```

Notes:
- This Redis is local to each machine. Do not assume cross-machine connectivity.
- If TTS crashes mid-playback, let the `agent:speaking` TTL expire naturally.
