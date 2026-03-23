monofuel note: grok couldn't find my nim library but this is the general gist of how to figure things out
they included links to all the docs, should rely on docs over their recommendations
we should be using `curly` for all http stuff, and https://github.com/treeform/ws for any websocket stuff.


## grok4 response

**Yes, here's the exact official Discord API documentation you need for the Discord-side of voice (joining, creating channels, etc.).** Since your bot is for your personal server only (just you), permissions and intents are trivial to set up—no rate limits or public bot concerns.

I searched extensively, but couldn't find any public Nim Discord library called "guildy" (the main ones are **dimscord**, **discordnim**, etc.). If it's your own/custom library, you'll implement the pieces below directly (super straightforward in Nim via WebSockets/UDP). If it's based on dimscord, it already has optional voice support via the `-d:dimscordVoice` compile flag (with examples).

### 1. Core: How a Bot Joins a Voice Channel (the main thing you need)
**Official docs: Voice Connections**  
https://discord.com/developers/docs/topics/voice-connections

This is the complete technical guide. High-level flow for your `/racha voice` command (you'll handle the actual audio/Opus/RTP part yourself):

1. (Optional but easy) Create a voice channel first (see #2 below).
2. Send **Voice State Update** (Gateway opcode 4) on your main Discord gateway connection:
   ```json
   {
     "op": 4,
     "d": {
       "guild_id": "your-guild-id",
       "channel_id": "the-voice-channel-id",
       "self_mute": false,
       "self_deaf": false
     }
   }
   ```
3. Discord replies with:
   - `VOICE_STATE_UPDATE` event (gives you the `session_id`)
   - `VOICE_SERVER_UPDATE` event (gives you `token` + `endpoint`)
4. Connect to the **Voice WebSocket** (wss://... from the endpoint).
5. Identify, get Ready event (SSRC, modes, etc.).
6. Do UDP handshake + IP discovery.
7. Select protocol, get encryption key.
8. Start sending/receiving voice packets (this is the part you said you'd handle—RTP + encryption with libsodium, Opus at 48kHz).

**Prerequisites**:
- `GUILD_VOICE_STATES` gateway intent (enable in your bot settings + when connecting the gateway).
- Bot must have **Connect** and **Speak** permissions in the voice channel.
- Use Voice Gateway v8 (`?v=8`).

Related sub-docs in the same page:
- Voice Gateway events/payloads
- UDP connection & IP discovery
- Transport encryption & sending voice (RTP packets)
- Speaking indicator (opcode 5)

There's also a simpler **REST-only** way to make the bot join (no manual gateway opcode):
- `PATCH /guilds/{guild.id}/voice-states/@me` with `{"channel_id": "..."}`  
  (Docs: https://discord.com/developers/docs/resources/voice#modify-current-user-voice-state)

### 2. "Open a voice channel" = Create one
**Official docs: Create Guild Channel**  
https://discord.com/developers/docs/resources/guild#create-guild-channel

- **Endpoint**: `POST /guilds/{guild.id}/channels`
- **Body** (JSON):
  ```json
  {
    "name": "Racha Voice",
    "type": 2,          // 2 = GUILD_VOICE
    "bitrate": 64000,   // optional
    "user_limit": 0     // 0 = unlimited
  }
  ```
- Requires **Manage Channels** permission on the bot.
- Returns the new channel object with its ID (use that to join/invite).

### 3. "Invite the user" (so you can just click and talk to the bot)
Two easy options:

**Option A (invite link – classic)**  
**Create Channel Invite**  
https://discord.com/developers/docs/resources/channel#create-channel-invite  
- `POST /channels/{channel.id}/invites`  
- Returns a link like `https://discord.gg/abc123`  
- Reply to your slash command with the link (or DM it). User clicks → joins instantly.

**Option B (auto-move the user – perfect party trick for your personal server)**  
**Modify User Voice State**  
https://discord.com/developers/docs/resources/voice#modify-user-voice-state  
- `PATCH /guilds/{guild.id}/voice-states/{user.id}` (use the command executor's ID)  
  Body: `{"channel_id": "the-voice-channel-id"}`  
- Requires **Move Members** permission.  
- Instantly pulls you into the channel with the bot—no clicking needed.

### Quick suggested flow for your `/racha voice` slash command
1. (Optional) Create a new voice channel via REST.
2. Bot joins it (gateway opcode 4 or REST @me voice state).
3. Either:
   - Create/send invite link, or
   - Auto-move you into it via the user voice state PATCH.
4. You join → talk to the bot (you handle the voice I/O on your side).

That's literally everything on the Discord API side. Your guildy library just needs to expose methods for sending gateway opcode 4, handling those two voice events, and the REST calls above (the heavy audio lifting is on you).

If you paste any specific part of your guildy code (e.g., how you handle gateway payloads), I can show exact Nim snippets for the voice state update or REST calls. Or if you meant a different library name, let me know! This should get your party trick working in no time. 🚀
