# redis-listener

Before generating any response, fetch recent local context and pending STT input from Redis.

## Required workflow
1. Read `MACHINE_ID` from environment.
2. Read `REDIS_HOST` from environment.
3. Check if speaking/cooldown is active. If true, do not respond to new STT yet.

```bash
SPEAKING="$(redis-cli -h "$REDIS_HOST" GET agent:speaking)"
NOW_MS="$(date +%s%3N)"
COOLDOWN_UNTIL_MS="$(redis-cli -h "$REDIS_HOST" GET agent:cooldown_until_ms)"
```

4. Read one pending user utterance from local STT queue:

```bash
INCOMING="$(redis-cli -h "$REDIS_HOST" RPOP conversation:incoming)"
```

5. If `INCOMING` is empty, stop and wait for the next turn trigger.
6. Parse `INCOMING` JSON and treat it as the latest user turn (`kind=user`).
7. Fetch the last 15 log entries for context:

```bash
redis-cli -h "$REDIS_HOST" LRANGE conversation:log 0 14
```

8. Parse each JSON entry:
   - `kind=user` entries are transcribed speech inputs.
   - `kind=assistant` entries are this agent's previous responses.
   - Preserve ordering and include only valid JSON records.

Use the context + one new `INCOMING` user turn before producing the next response.

Notes:
- This design is for isolated machines: each node uses only its local Redis.
- Cross-machine state transfer happens acoustically (TTS -> microphone), not via network.
