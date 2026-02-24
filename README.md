# Offline Two-Machine OpenClaw Voice Agent Stack

This repository provides a fully containerized, air-gap-friendly setup where two OpenClaw agents can talk to each other using microphone/speaker IO. Each machine keeps its own local Redis state.

## Services per machine

- `ollama/ollama` for local LLM inference
- `onerahmet/openai-whisper-asr-webservice` for offline STT (internal service on port `9000`)
- `ghcr.io/remsky/kokoro-fastapi-cpu` for offline TTS (internal service on port `8880`)
- `redis:alpine` for local turn queue/state
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
├── scripts/
│   └── local-stt-gate.sh
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

If you only want to download Ollama models (and skip Python/Whisper/Kokoro downloads), run:

```bash
docker compose -f docker-compose.build.yml run --rm ollama-cache-builder
```

## 2) Runtime start

```bash
docker compose up -d
```

## 2.1) Local STT gate (recommended)

To avoid self-hearing loops, feed transcribed text through:

```bash
scripts/local-stt-gate.sh "transcribed text here"
```

This script writes accepted turns to:
- `conversation:incoming` (pending user turns for the agent)
- `conversation:log` (recent local history)

It suppresses turns when:
- `agent:speaking=1`
- cooldown is active (`agent:cooldown_until_ms`)
- text matches recent TTS output (`agent:last_tts_text`) within a short echo window

## 2.2) STT Redis bridge (Whisper -> gate -> OpenClaw)

`docker-compose.yml` includes an `stt-bridge` sidecar that reads transcripts from:
- input queue: `stt:transcripts` (configurable via `STT_INPUT_LIST`)

For each entry, it:
1. extracts transcript text (plain text or JSON `{ "text": "..." }`)
2. applies `scripts/local-stt-gate.sh`
3. pushes accepted turns into `conversation:incoming`

This makes OpenClaw react only to gated STT content.

## 2.3) Turn driver (Redis incoming -> Ollama reply)

`docker-compose.yml` includes a `turn-driver` service that consumes:
- `conversation:incoming`

For each queued turn, it runs:
- `POST /api/chat` on the local `ollama` service (default)

So the full loop is:
- `stt:transcripts` -> `stt-bridge` -> `conversation:incoming` -> `turn-driver` -> Ollama response

Environment knobs:
- `OLLAMA_HOST=ollama`
- `OLLAMA_PORT=11434`
- `OLLAMA_MODEL=<model-name>`
- `OLLAMA_NUM_PREDICT=160`
- `TURN_DRIVER_DEBUG=1` for verbose logs

Build cache knobs:
- `OLLAMA_MODELS=<comma-separated models>` (prefetch multiple Ollama models in one cache build)

Note:
- `turn-driver` is built from `Dockerfile.turn-driver` and includes `redis-cli` at image build time.
- No runtime package install is required (important for `internal: true` air-gapped networks).
- each service mounts its own config at:
  - `/home/node/.openclaw/openclaw.json`
- configure gateway mode per service once:
  - `openclaw`: `gateway.mode=local`
  - `turn-driver`: `gateway.mode=remote` targeting `ws://openclaw:18789`

Quick local test:

```bash
docker compose exec redis sh -lc 'redis-cli LPUSH stt:transcripts "hello from test"'
docker compose exec redis sh -lc 'redis-cli LRANGE conversation:incoming 0 2'
docker compose logs --tail=100 turn-driver
```

If your Whisper pipeline writes to a different key, set:

```dotenv
STT_INPUT_LIST=your:whisper:key
OLLAMA_MODELS_DIR=./models/ollama
OLLAMA_MODELS=qwen2.5-coder:7b-instruct-q4_K_M,qwen2.5-coder:3b-instruct-q4_K_M,qwen2.5-coder:1.5b-instruct-q4_K_M
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
- `llm.model` to your intended local model name (`llama3` by default)
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

## 6) Echo cancellation (PulseAudio / PipeWire-Pulse)

Enable acoustic echo cancellation on each host so an agent does not re-transcribe its own TTS.

Temporary (runtime) load:

```bash
pactl load-module module-echo-cancel aec_method=webrtc source_name=mic_aec sink_name=spk_aec
```

Then select:
- input source: `mic_aec`
- output sink: `spk_aec`

Persistent setup:
- PulseAudio: add the same `load-module module-echo-cancel ...` line to `default.pa`.
- PipeWire-Pulse: create equivalent echo-cancel filter-chain config and set it as default source/sink.

Recommendation:
- keep software gating enabled even with AEC (`scripts/local-stt-gate.sh`), because AEC alone does not fully prevent loopbacks in loud rooms.
- keep Whisper ingestion through `stt-bridge`, not directly into `conversation:incoming`.

## Offline operation expectation

After the initial online build cache step, the stack is intended to run in air-gapped mode without fetching external models again, as long as `./cache` is preserved. The two machines do not need network connectivity to each other.

## Included skills in this repo

- `redis-logger` (marks speaking state + logs assistant turns)
- `redis-listener` (reads pending local STT turns + recent context)

The OpenClaw image additionally installs only:
- `offline-voice`
- `redis-agent-memory`
