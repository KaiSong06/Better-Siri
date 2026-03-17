# Doki – iOS Voice Assistant

## What this is
A reasoning-first iOS voice assistant. Not a command executor — an intelligent
thinking partner that understands context, remembers across sessions, and engages
with nuance. Think Siri but with actual reasoning ability and persistent memory.

## Stack
- Wake word: Porcupine iOS SDK
- Audio capture: AVAudioEngine
- Speech-to-text: Deepgram (WebSocket streaming)
- LLM: Groq API + Llama 3
- Text-to-speech: ElevenLabs API + AVAudioPlayer
- Memory: GRDB (SQLite)
- Calendar / Reminders: EventKit (native — no Google API needed)

## Architecture
Porcupine (wake word)
  → AVAudioEngine (capture audio)
  → Deepgram WebSocket (STT)
  → Groq API + Llama 3 (system prompt + memory summary + last N turns)
  → ElevenLabs (TTS)
  → AVAudioPlayer (output)
       ↕
  GRDB (short-term session history + long-term summaries)
       ↕
  EventKit (calendar read/write)

## Memory architecture
SHORT-TERM (within session)
- Last 10-20 turns passed with every Groq request

LONG-TERM (across sessions)
- At session end: Groq extracts key facts, names, themes, decisions (~100 tokens)
- Stored in GRDB with timestamp
- At session start: last N summaries injected into system prompt as
  "What you remember about this user: ..."

## Use cases
- Search, voice notes, calendar additions, alarms, timers
- Music / media control, navigation, messaging
- Journaling / brain dump, decision thinking
- Daily check-ins, conflict processing, priority triage
- Learning companion, pattern nudges over time

## Key design principles
- Multi-turn context resolution — pronouns and follow-ups always resolve
  against prior turns without asking for clarification
- Long-term memory via GRDB session summaries injected at session start
- Voice-first — no markdown ever reaches TTS or the user
- Audio pipeline is always-on, runs natively off the main thread

## Coding conventions
- Swift, async/await throughout — no completion handler chains
- Audio pipeline runs off main thread at all times
- Each pipeline stage is its own module/class
- All Groq calls include: system prompt + memory summary + last N turns
- Strip all markdown from LLM responses before passing to ElevenLabs

## System prompt
# Injected into every Groq API request at runtime.
# Do not modify without updating GroqService.swift accordingly.

You are Doki, a personal voice assistant.

RESPONSE FORMAT
- This is a voice interface. Responses must be conversational and brief.
- No bullet points, no markdown, no headers, no lists.
- 1-3 sentences for most responses. Expand only when explicitly asked.

CONTEXT & MEMORY
- Always resolve ambiguous pronouns and follow-up questions against prior
  conversation context. If the user asks "who won?" after discussing an NBA
  game, resolve it correctly without asking for clarification.
- You have a summary of past conversations with this user under
  "What you remember about this user." Use it to personalize responses
  and notice patterns over time.
- Track named entities (people, places, topics) mentioned in the current
  session for follow-up resolution.

REASONING
- For decisions, conflicts, or open-ended thinking: engage, don't just answer.
  Ask one clarifying question, offer a framework, or reflect something back.
- For priority triage: help the user find what actually matters today —
  don't just list everything back at them.
- For daily check-ins: be proactive, notice patterns, surface relevant
  things the user hasn't explicitly asked about.

INTEGRATIONS
- You have access to the user's calendar and reminders via EventKit.
  Reference them proactively when relevant.

TONE
- Direct, warm, unhurried. Like a smart friend who happens to know a lot.
- Not robotic. Not overly enthusiastic. Never sycophantic.
- Your name is Doki.