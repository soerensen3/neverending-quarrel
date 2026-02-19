# Offline Two-Machine OpenClaw Voice Agent Stack

This repository provides a fully containerized, air-gap-friendly setup where two OpenClaw agents can talk to each other using microphone/speaker IO and a shared Redis conversation log.

## Services per machine

- `ollama/ollama` for local LLM inference
- `onerahmet/openai-whisper-asr-webservice` for offline STT (internal service on port `9000`)
- `ghcr.io/remsky/kokoro-fastapi-cpu` for offline TTS (internal service on port `8880`)
- `redis:alpine` for shared conversation log
- OpenClaw service built from `Dockerfile.openclaw`

Only the OpenClaw WebChat UI is exposed externally on host port `18789`.

## Repository layout

```text
/
├── docker-compose.yml
├── docker-compose.build.yml
├── Dockerfile.openclaw
├── Dockerfile.cache
├── cache/
│   └── .gitkeep
├── skills/
│   ├── redis-logger/
│   │   └── SKILL.md
│   └── redis-listener/
│       └── SKILL.md
├── config/
│   └── openclaw.json.example
├── soul/
│   └── SOUL.md.example
└── README.md
```

## 1) One-time online setup (model pre-cache)

Create a `.env` file (example below), then run:

```bash
docker compose -f docker-compose.build.yml build
```

This builds `Dockerfile.cache`, pre-fetches Whisper, Kokoro, and Ollama artifacts, and stores them under bind-mounted `./cache/*` directories so they remain available offline.

## 2) Runtime start

```bash
docker compose up -d
```

## 3) Configure runtime variables with `.env`

Create `.env` in the repo root:

```dotenv
# Unique per machine (example values: machine-a, machine-b)
MACHINE_ID=machine-a

# Build/runtime model selectors
OLLAMA_MODEL=llama3
WHISPER_MODEL=base
```

Then prepare OpenClaw config:

```bash
cp config/openclaw.json.example config/openclaw.json
```

Edit `config/openclaw.json` and set:
- `machineId` to match your `MACHINE_ID`
- `llm.model` to your intended local model name (`YOUR_MODEL_HERE` by default)
- endpoints if you customize service names/ports

## 4) Personality and user-owned skills

Personality is intentionally user-defined.

```bash
cp soul/SOUL.md.example soul/SOUL.md
```

Fill `soul/SOUL.md` with your own persona instructions.
Additional skills can be placed under `skills/` and are mounted into OpenClaw at runtime.

## 5) Audio device note (required for local mic/speaker)

Voice wake/STT capture and TTS playback require host audio access inside the OpenClaw container.

This compose file already includes:

```yaml
devices:
  - /dev/snd:/dev/snd
```

Equivalent `docker run` style would be:

```bash
--device /dev/snd
```

## Offline operation expectation

After the initial online build cache step, the stack is intended to run in air-gapped mode without fetching external models again, as long as `./cache` is preserved.

## Included skills in this repo

- `redis-logger` (logs every response to Redis)
- `redis-listener` (reads recent conversation history from Redis)

The OpenClaw image additionally installs only:
- `offline-voice`
- `redis-agent-memory`
