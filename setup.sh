#!/usr/bin/env bash
set -e

echo "🔥 Setting up Simvox..."

# Create directories
mkdir -p simvox/src/{cogs,core,ui,utils}
cd simvox

echo "Writing .env.example..."
cat > ".env.example" << 'HEREDOC'
TOKEN=your_discord_bot_token_here

HEREDOC

echo "Writing requirements.txt..."
cat > "requirements.txt" << 'HEREDOC'
discord.py>=2.4.0
yt-dlp>=2024.1.1
python-dotenv>=1.0.0
PyNaCl>=1.5.0

HEREDOC

echo "Writing src/__init__.py..."
cat > "src/__init__.py" << 'HEREDOC'


HEREDOC

echo "Writing src/cogs/__init__.py..."
cat > "src/cogs/__init__.py" << 'HEREDOC'

HEREDOC

echo "Writing src/cogs/music.py..."
cat > "src/cogs/music.py" << 'HEREDOC'
"""
cogs/music.py
All slash commands for Simvox.
"""
import discord
from discord import app_commands
from discord.ext import commands
import asyncio
import logging

from core.player  import GuildMusicManager
from core.scraper import search_top_tracks, fetch_by_url
from ui.views     import (
    SearchView, NowPlayingView, QueueView,
    FilterView, LoopView, VoteSkipView,
)
from utils.embeds import (
    now_playing, queue_embed, search_results, error_embed,
    success_embed, info_embed, history_embed, filters_embed,
    volume_embed, _fmt_time,
)
from utils.helpers import send_error, send_success, parse_time

log = logging.getLogger("simvox.music")


class Music(commands.Cog):
    def __init__(self, bot: commands.Bot):
        self.bot      = bot
        self.managers: dict[int, GuildMusicManager] = {}

    # ── Internal helpers ────────────────────────────────────────────────────

    def get_manager(self, guild_id: int) -> GuildMusicManager:
        if guild_id not in self.managers:
            self.managers[guild_id] = GuildMusicManager(self.bot, guild_id)
        return self.managers[guild_id]

    async def ensure_voice(self, interaction: discord.Interaction) -> GuildMusicManager | None:
        if not interaction.user.voice:
            await send_error(interaction, "You need to be in a voice channel first.")
            return None

        channel = interaction.user.voice.channel
        vc = discord.utils.get(self.bot.voice_clients, guild=interaction.guild)

        if not vc:
            vc = await channel.connect()
        elif vc.channel != channel:
            await vc.move_to(channel)

        manager = self.get_manager(interaction.guild_id)
        manager.voice_client = vc
        return manager

    # ── /play ────────────────────────────────────────────────────────────────

    @app_commands.command(name="play", description="Search and play a track")
    @app_commands.describe(query="Song name, artist, or YouTube URL")
    async def play(self, interaction: discord.Interaction, query: str):
        await interaction.response.defer()

        if not interaction.user.voice:
            await interaction.followup.send(embed=error_embed("Join a voice channel first!"))
            return

        try:
            if query.startswith("http"):
                tracks = [await asyncio.to_thread(fetch_by_url, query)]
            else:
                tracks = await asyncio.to_thread(search_top_tracks, query, 10)
        except Exception as e:
            await interaction.followup.send(embed=error_embed(str(e)))
            return

        if len(tracks) == 1:
            # Direct URL — skip the picker
            manager = await self.ensure_voice(interaction)
            if not manager:
                return
            manager.add_to_queue(tracks[0])
            manager.text_channel = interaction.channel

            if not manager.voice_client.is_playing() and not manager.voice_client.is_paused():
                await manager.play_next()
                embed = now_playing(tracks[0], 0, interaction.user)
                view  = NowPlayingView(manager)
                msg   = await interaction.followup.send(embed=embed, view=view)
                manager.np_message = msg
            else:
                from utils.embeds import track_added
                pos = len(manager.queue)
                await interaction.followup.send(embed=track_added(tracks[0], pos))
        else:
            embed = search_results(query, tracks)
            view  = SearchView(tracks, self)
            await interaction.followup.send(embed=embed, view=view)

    # ── /nowplaying ──────────────────────────────────────────────────────────

    @app_commands.command(name="nowplaying", description="Show what's currently playing")
    async def nowplaying(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        if not manager.current:
            await interaction.response.send_message(embed=info_embed("Nothing Playing", "Queue is empty."))
            return
        embed = now_playing(manager.current, manager.position)
        view  = NowPlayingView(manager)
        msg   = await interaction.response.send_message(embed=embed, view=view)
        manager.np_message   = await interaction.original_response()
        manager.text_channel = interaction.channel

    # ── /pause ───────────────────────────────────────────────────────────────

    @app_commands.command(name="pause", description="Pause playback")
    async def pause(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        if manager.pause():
            await interaction.response.send_message(embed=success_embed("Playback paused."))
        else:
            await interaction.response.send_message(embed=error_embed("Nothing is playing."), ephemeral=True)

    # ── /resume ──────────────────────────────────────────────────────────────

    @app_commands.command(name="resume", description="Resume playback")
    async def resume(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        if manager.resume():
            await interaction.response.send_message(embed=success_embed("Playback resumed."))
        else:
            await interaction.response.send_message(embed=error_embed("Nothing is paused."), ephemeral=True)

    # ── /skip ────────────────────────────────────────────────────────────────

    @app_commands.command(name="skip", description="Skip the current track")
    async def skip(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        if manager.skip():
            await interaction.response.send_message(embed=success_embed("Skipped."))
        else:
            await interaction.response.send_message(embed=error_embed("Nothing to skip."), ephemeral=True)

    # ── /voteskip ────────────────────────────────────────────────────────────

    @app_commands.command(name="voteskip", description="Start a vote to skip the current track")
    async def voteskip(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        if not manager.current:
            await interaction.response.send_message(embed=error_embed("Nothing is playing."), ephemeral=True)
            return

        vc = manager.voice_client
        if not vc:
            await interaction.response.send_message(embed=error_embed("Bot isn't in a voice channel."), ephemeral=True)
            return

        listeners = [m for m in vc.channel.members if not m.bot]
        required  = max(2, (len(listeners) + 1) // 2)

        embed = discord.Embed(
            title="⏭  Vote Skip",
            description=f"**{manager.current['title']}**\nNeed `{required}` votes to skip.",
            color=0xE8132A,
        )
        view = VoteSkipView(manager, required)
        await interaction.response.send_message(embed=embed, view=view)

    # ── /queue ───────────────────────────────────────────────────────────────

    @app_commands.command(name="queue", description="Show the current queue")
    async def queue(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        embed   = queue_embed(manager, 0)
        view    = QueueView(manager, 0)
        await interaction.response.send_message(embed=embed, view=view)

    # ── /remove ──────────────────────────────────────────────────────────────

    @app_commands.command(name="remove", description="Remove a track from the queue by position")
    @app_commands.describe(position="Queue position to remove (1 = next up)")
    async def remove(self, interaction: discord.Interaction, position: int):
        manager = self.get_manager(interaction.guild_id)
        track   = manager.remove(position)
        if track:
            await interaction.response.send_message(
                embed=success_embed(f"Removed **{track['title']}** from position {position}.")
            )
        else:
            await interaction.response.send_message(
                embed=error_embed(f"No track at position {position}."), ephemeral=True
            )

    # ── /move ────────────────────────────────────────────────────────────────

    @app_commands.command(name="move", description="Move a track to a different queue position")
    @app_commands.describe(from_pos="Current position", to_pos="Target position")
    async def move(self, interaction: discord.Interaction, from_pos: int, to_pos: int):
        manager = self.get_manager(interaction.guild_id)
        if manager.move(from_pos, to_pos):
            await interaction.response.send_message(
                embed=success_embed(f"Moved track from `#{from_pos}` to `#{to_pos}`.")
            )
        else:
            await interaction.response.send_message(
                embed=error_embed("Invalid position(s)."), ephemeral=True
            )

    # ── /shuffle ─────────────────────────────────────────────────────────────

    @app_commands.command(name="shuffle", description="Shuffle the queue")
    async def shuffle(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        if not manager.queue:
            await interaction.response.send_message(embed=error_embed("Queue is empty."), ephemeral=True)
            return
        manager.shuffle()
        await interaction.response.send_message(embed=success_embed(f"🔀 Shuffled {len(manager.queue)} tracks."))

    # ── /clear ───────────────────────────────────────────────────────────────

    @app_commands.command(name="clear", description="Clear the entire queue")
    async def clear(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        count   = len(manager.queue)
        manager.clear_queue()
        await interaction.response.send_message(embed=success_embed(f"Cleared {count} tracks from the queue."))

    # ── /loop ────────────────────────────────────────────────────────────────

    @app_commands.command(name="loop", description="Set loop mode")
    async def loop(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        view    = LoopView(manager)
        modes   = {"off": "Off", "track": "🔂 Track", "queue": "🔁 Queue"}
        embed   = info_embed(
            "🔁  Loop Mode",
            f"Current: **{modes.get(manager.loop_mode,'Off')}**\n\nPick a new mode below."
        )
        await interaction.response.send_message(embed=embed, view=view, ephemeral=True)

    # ── /volume ──────────────────────────────────────────────────────────────

    @app_commands.command(name="volume", description="Set playback volume (0–200)")
    @app_commands.describe(level="Volume level 0–200 (default 100)")
    async def volume(self, interaction: discord.Interaction, level: int):
        if not 0 <= level <= 200:
            await interaction.response.send_message(
                embed=error_embed("Volume must be between 0 and 200."), ephemeral=True
            )
            return
        manager = self.get_manager(interaction.guild_id)
        manager.set_volume(level)
        await interaction.response.send_message(embed=volume_embed(level))

    # ── /seek ────────────────────────────────────────────────────────────────

    @app_commands.command(name="seek", description="Seek to a position in the current track")
    @app_commands.describe(timestamp="Time to seek to, e.g. 1:30 or 90")
    async def seek(self, interaction: discord.Interaction, timestamp: str):
        await interaction.response.defer()
        seconds = parse_time(timestamp)
        if seconds is None:
            await interaction.followup.send(embed=error_embed("Invalid timestamp. Use `mm:ss` or seconds."))
            return
        manager = self.get_manager(interaction.guild_id)
        if await manager.seek(seconds):
            await interaction.followup.send(embed=success_embed(f"⏩ Seeked to `{_fmt_time(seconds)}`."))
        else:
            await interaction.followup.send(embed=error_embed("Nothing is playing."))

    # ── /replay ──────────────────────────────────────────────────────────────

    @app_commands.command(name="replay", description="Replay the current track from the beginning")
    async def replay(self, interaction: discord.Interaction):
        await interaction.response.defer()
        manager = self.get_manager(interaction.guild_id)
        if await manager.replay():
            await interaction.followup.send(embed=success_embed("⏮ Replaying from start."))
        else:
            await interaction.followup.send(embed=error_embed("Nothing is playing."))

    # ── /filter ──────────────────────────────────────────────────────────────

    @app_commands.command(name="filter", description="Apply an audio filter")
    async def filter(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        embed   = filters_embed(manager.active_filter)
        view    = FilterView(manager)
        await interaction.response.send_message(embed=embed, view=view, ephemeral=True)

    # ── /autoplay ────────────────────────────────────────────────────────────

    @app_commands.command(name="autoplay", description="Toggle autoplay of related tracks")
    async def autoplay(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        manager.autoplay = not manager.autoplay
        state = "enabled 🟢" if manager.autoplay else "disabled 🔴"
        await interaction.response.send_message(embed=success_embed(f"Autoplay {state}."))

    # ── /history ─────────────────────────────────────────────────────────────

    @app_commands.command(name="history", description="Show recently played tracks")
    async def history(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        await interaction.response.send_message(embed=history_embed(manager.history))

    # ── /disconnect ──────────────────────────────────────────────────────────

    @app_commands.command(name="disconnect", description="Disconnect the bot from voice")
    async def disconnect(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        await manager.disconnect()
        await interaction.response.send_message(embed=success_embed("Disconnected. See ya. 👋"))

    # ── /playtop ─────────────────────────────────────────────────────────────

    @app_commands.command(name="playtop", description="Add a track to the top of the queue")
    @app_commands.describe(query="Song name, artist, or YouTube URL")
    async def playtop(self, interaction: discord.Interaction, query: str):
        await interaction.response.defer()

        if not interaction.user.voice:
            await interaction.followup.send(embed=error_embed("Join a voice channel first!"))
            return

        try:
            if query.startswith("http"):
                tracks = [await asyncio.to_thread(fetch_by_url, query)]
            else:
                tracks = await asyncio.to_thread(search_top_tracks, query, 1)
        except Exception as e:
            await interaction.followup.send(embed=error_embed(str(e)))
            return

        manager = await self.ensure_voice(interaction)
        if not manager:
            return

        track = tracks[0]
        manager.queue.insert(0, track)
        manager.text_channel = interaction.channel

        if not manager.voice_client.is_playing() and not manager.voice_client.is_paused():
            await manager.play_next()
            embed = now_playing(track, 0, interaction.user)
            view  = NowPlayingView(manager)
            msg   = await interaction.followup.send(embed=embed, view=view)
            manager.np_message = msg
        else:
            from utils.embeds import track_added
            await interaction.followup.send(embed=track_added(track, 1))

    # ── /search ──────────────────────────────────────────────────────────────

    @app_commands.command(name="search", description="Search for tracks without playing immediately")
    @app_commands.describe(query="What to search for")
    async def search(self, interaction: discord.Interaction, query: str):
        await interaction.response.defer()
        try:
            tracks = await asyncio.to_thread(search_top_tracks, query, 10)
        except Exception as e:
            await interaction.followup.send(embed=error_embed(str(e)))
            return
        embed = search_results(query, tracks)
        view  = SearchView(tracks, self)
        await interaction.followup.send(embed=embed, view=view)

    # ── /lyrics ──────────────────────────────────────────────────────────────

    @app_commands.command(name="lyrics", description="Search for lyrics of the current or a specified track")
    @app_commands.describe(query="Override song name (optional)")
    async def lyrics(self, interaction: discord.Interaction, query: str = ""):
        await interaction.response.defer()
        manager = self.get_manager(interaction.guild_id)
        title   = query or (manager.current["title"] if manager.current else "")
        if not title:
            await interaction.followup.send(embed=error_embed("Nothing is playing and no query provided."))
            return

        embed = discord.Embed(
            title=f"🎤  Lyrics: {title[:80]}",
            description=(
                "Simvox doesn't bundle a lyrics provider to avoid rate-limit and copyright issues.\n\n"
                f"🔎 **[Search on Genius](https://genius.com/search?q={discord.utils.escape_markdown(title).replace(' ','+')})**\n"
                f"🔎 **[Search on AZLyrics](https://www.azlyrics.com/lyrics/{title.replace(' ','').lower()[:30]}.html)**"
            ),
            color=0xE8132A,
        )
        await interaction.followup.send(embed=embed)

    # ── /help ────────────────────────────────────────────────────────────────

    @app_commands.command(name="help", description="Show all Simvox commands")
    async def help(self, interaction: discord.Interaction):
        embed = discord.Embed(
            title="🎵  SIMVOX — Command Reference",
            color=0xE8132A,
        )
        sections = {
            "🎶 Playback": [
                ("`/play [query]`",      "Search and pick from top 10 results"),
                ("`/playtop [query]`",   "Jump to front of queue"),
                ("`/search [query]`",    "Browse without auto-playing"),
                ("`/nowplaying`",        "Live now-playing card with controls"),
                ("`/pause`",             "Pause"),
                ("`/resume`",            "Resume"),
                ("`/skip`",              "Force skip"),
                ("`/voteskip`",          "Democratic skip"),
                ("`/replay`",            "Restart current track"),
                ("`/seek [mm:ss]`",      "Jump to timestamp"),
            ],
            "📋 Queue": [
                ("`/queue`",             "Paginated queue viewer"),
                ("`/remove [pos]`",      "Remove by position"),
                ("`/move [from] [to]`",  "Reorder tracks"),
                ("`/shuffle`",           "Randomise queue"),
                ("`/clear`",             "Wipe queue"),
                ("`/history`",           "Last 15 played"),
            ],
            "⚙️ Settings": [
                ("`/volume [0–200]`",    "Set volume level"),
                ("`/loop`",              "Off / Track / Queue"),
                ("`/filter`",            "Bass boost, Nightcore, 8D, Vaporwave…"),
                ("`/autoplay`",          "Toggle autoplay of related tracks"),
                ("`/lyrics`",            "Find lyrics for current track"),
                ("`/disconnect`",        "Disconnect from voice"),
            ],
        }
        for section, cmds in sections.items():
            value = "\n".join(f"{cmd} — {desc}" for cmd, desc in cmds)
            embed.add_field(name=section, value=value, inline=False)
        embed.set_footer(text="SIMVOX  •  Red by design.")
        await interaction.response.send_message(embed=embed)


async def setup(bot: commands.Bot):
    await bot.add_cog(Music(bot))

HEREDOC

echo "Writing src/core/__init__.py..."
cat > "src/core/__init__.py" << 'HEREDOC'

HEREDOC

echo "Writing src/core/player.py..."
cat > "src/core/player.py" << 'HEREDOC'
"""
core/player.py
Per-guild music state machine.
Handles queue, playback, loop, volume, filters, history, autoplay, seek.
"""
import discord
import asyncio
import time
import random
import logging
from typing import Optional

log = logging.getLogger("simvox.player")

AUDIO_FILTERS = {
    "none":      "",
    "bassboost": "bass=g=20,dynaudnorm=f=200",
    "nightcore": "aresample=48000,asetrate=48000*1.25",
    "vaporwave": "aresample=48000,asetrate=48000*0.8",
    "8d":        "apulsator=hz=0.08",
    "karaoke":   "pan=stereo|c0=c0-c1|c1=c1-c0",
    "treble":    "treble=g=10",
}


class GuildMusicManager:
    def __init__(self, bot: discord.Client, guild_id: int):
        self.bot         = bot
        self.guild_id    = guild_id
        self.queue: list[dict]  = []
        self.history: list[dict] = []
        self.current: Optional[dict] = None
        self.voice_client: Optional[discord.VoiceClient] = None
        self.loop_mode   = "off"        # "off" | "track" | "queue"
        self.volume      = 100          # 0–200
        self.autoplay    = False
        self.active_filter = "none"
        self._position_start: float = 0.0   # wall-clock when play started
        self._seek_offset:    int   = 0     # seconds already consumed before restart

        # vote-skip state
        self.skip_votes: set[int] = set()

        # now-playing message for live updates
        self.np_message: Optional[discord.Message] = None
        self.text_channel: Optional[discord.TextChannel] = None

    # ── Public state ────────────────────────────────────────────────────────

    @property
    def position(self) -> int:
        """Estimated playback position in seconds."""
        if self.voice_client and self.voice_client.is_playing():
            return self._seek_offset + int(time.monotonic() - self._position_start)
        return self._seek_offset

    # ── Playback ─────────────────────────────────────────────────────────────

    async def play_next(self):
        if not self.voice_client or not self.voice_client.is_connected():
            return

        # Loop track
        if self.loop_mode == "track" and self.current:
            next_track = self.current
        # Loop queue
        elif self.loop_mode == "queue" and self.current:
            self.queue.append(self.current)
            next_track = self.queue.pop(0) if self.queue else None
        else:
            next_track = self.queue.pop(0) if self.queue else None

        # Autoplay
        if next_track is None and self.autoplay and self.current:
            try:
                from core.scraper import search_related
                related = await asyncio.to_thread(
                    search_related, self.current["title"], self.current.get("uploader", "")
                )
                # Filter out exact title match (don't re-queue same song)
                candidates = [t for t in related if t["title"] != self.current["title"]]
                if candidates:
                    next_track = candidates[0]
                    log.info(f"Autoplay queued: {next_track['title']}")
            except Exception as e:
                log.warning(f"Autoplay fetch failed: {e}")

        if next_track is None:
            self.current = None
            self._seek_offset = 0
            if self.text_channel:
                try:
                    await self.text_channel.send(
                        embed=_queue_empty_embed(), delete_after=30
                    )
                except Exception:
                    pass
            return

        if self.current and self.loop_mode != "track":
            self.history.append(self.current)
            if len(self.history) > 50:
                self.history.pop(0)

        self.current = next_track
        self.skip_votes.clear()
        self._seek_offset = 0
        self._position_start = time.monotonic()

        await self._start_stream(next_track)

    async def _start_stream(self, track: dict, seek: int = 0):
        """Build FFmpeg source and start playing."""
        self._seek_offset = seek
        self._position_start = time.monotonic()

        af = AUDIO_FILTERS.get(self.active_filter, "")
        vol_filter = f"volume={self.volume/100:.2f}"
        combined = ",".join(filter(None, [af, vol_filter]))

        ffmpeg_opts = {
            "before_options": (
                "-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5"
                + (f" -ss {seek}" if seek else "")
            ),
            "options": f"-vn -af {combined}" if combined else "-vn",
        }

        source = discord.FFmpegPCMAudio(track["source"], **ffmpeg_opts)

        def _after(error):
            if error:
                log.error(f"Player error [{self.guild_id}]: {error}")
            asyncio.run_coroutine_threadsafe(self.play_next(), self.bot.loop)

        if self.voice_client.is_playing():
            self.voice_client.stop()

        self.voice_client.play(source, after=_after)

        # Update now-playing message if it exists
        if self.text_channel:
            asyncio.run_coroutine_threadsafe(
                self._update_np_message(), self.bot.loop
            )

    async def _update_np_message(self):
        from utils.embeds import now_playing
        from ui.views   import NowPlayingView
        if not self.current:
            return
        embed = now_playing(self.current, self.position)
        view  = NowPlayingView(self)
        try:
            if self.np_message:
                await self.np_message.edit(embed=embed, view=view)
        except Exception:
            pass

    # ── Controls ─────────────────────────────────────────────────────────────

    def add_to_queue(self, track: dict):
        self.queue.append(track)

    def skip(self):
        self.skip_votes.clear()
        if self.voice_client and (self.voice_client.is_playing() or self.voice_client.is_paused()):
            self.voice_client.stop()
            return True
        return False

    def pause(self) -> bool:
        if self.voice_client and self.voice_client.is_playing():
            self.voice_client.pause()
            return True
        return False

    def resume(self) -> bool:
        if self.voice_client and self.voice_client.is_paused():
            self.voice_client.resume()
            return True
        return False

    def set_volume(self, vol: int):
        self.volume = max(0, min(200, vol))

    def set_loop(self, mode: str):
        if mode in ("off", "track", "queue"):
            self.loop_mode = mode

    def shuffle(self):
        random.shuffle(self.queue)

    def remove(self, index: int) -> Optional[dict]:
        """Remove track at 1-based index. Returns removed track or None."""
        idx = index - 1
        if 0 <= idx < len(self.queue):
            return self.queue.pop(idx)
        return None

    def move(self, from_pos: int, to_pos: int) -> bool:
        """Move track from 1-based from_pos to 1-based to_pos."""
        fi, ti = from_pos - 1, to_pos - 1
        if 0 <= fi < len(self.queue) and 0 <= ti < len(self.queue):
            track = self.queue.pop(fi)
            self.queue.insert(ti, track)
            return True
        return False

    def clear_queue(self):
        self.queue.clear()
        self.skip_votes.clear()

    async def seek(self, seconds: int):
        """Seek to absolute position in seconds."""
        if not self.current or not self.voice_client:
            return False
        await self._start_stream(self.current, seek=seconds)
        return True

    async def replay(self):
        """Restart current track from beginning."""
        if not self.current:
            return False
        await self._start_stream(self.current, seek=0)
        return True

    def set_filter(self, filter_name: str) -> bool:
        if filter_name not in AUDIO_FILTERS:
            return False
        self.active_filter = filter_name
        return True

    async def apply_filter(self, filter_name: str) -> bool:
        """Change filter and restart stream at current position."""
        if not self.set_filter(filter_name):
            return False
        if self.current and self.voice_client and (
            self.voice_client.is_playing() or self.voice_client.is_paused()
        ):
            pos = self.position
            await self._start_stream(self.current, seek=pos)
        return True

    async def disconnect(self):
        self.queue.clear()
        self.current = None
        self.skip_votes.clear()
        if self.voice_client and self.voice_client.is_connected():
            await self.voice_client.disconnect()
        self.voice_client = None


def _queue_empty_embed() -> discord.Embed:
    from utils.embeds import info_embed
    return info_embed("Queue Empty", "No more tracks — use `/play` to add more.")

HEREDOC

echo "Writing src/core/scraper.py..."
cat > "src/core/scraper.py" << 'HEREDOC'
"""
core/scraper.py
yt-dlp wrapper — search, direct URL, related tracks.
"""
import yt_dlp
import logging

log = logging.getLogger("simvox.scraper")

_YTDL_OPTS = {
    "format": "bestaudio/best",
    "noplaylist": True,
    "nocheckcertificate": True,
    "quiet": True,
    "no_warnings": True,
    "default_search": "auto",
    "source_address": "0.0.0.0",
    "skip_download": True,
}

_ytdl = yt_dlp.YoutubeDL(_YTDL_OPTS)


def _build_track(entry: dict) -> dict:
    return {
        "source":      entry.get("url", ""),
        "title":       entry.get("title", "Unknown Title"),
        "duration":    entry.get("duration", 0) or 0,
        "thumbnail":   entry.get("thumbnail"),
        "webpage_url": entry.get("webpage_url", entry.get("url", "")),
        "uploader":    entry.get("uploader", "Unknown Artist"),
        "view_count":  entry.get("view_count", 0),
    }


def search_top_tracks(query: str, max_results: int = 10) -> list[dict]:
    """Return up to max_results tracks matching query."""
    search_query = query if query.startswith("http") else f"ytsearch{max_results}:{query}"
    try:
        info = _ytdl.extract_info(search_query, download=False)
    except Exception as e:
        log.error(f"yt-dlp search error: {e}")
        raise RuntimeError(f"Search failed: {e}") from e

    tracks = []
    if "entries" in info:
        for entry in info["entries"]:
            if entry:
                tracks.append(_build_track(entry))
    else:
        tracks.append(_build_track(info))

    if not tracks:
        raise RuntimeError("No results found.")
    return tracks


def fetch_by_url(url: str) -> dict:
    """Fetch a single track directly by URL."""
    try:
        info = _ytdl.extract_info(url, download=False)
        entry = info["entries"][0] if "entries" in info else info
        return _build_track(entry)
    except Exception as e:
        log.error(f"yt-dlp fetch error: {e}")
        raise RuntimeError(f"Could not load URL: {e}") from e


def search_related(title: str, uploader: str, max_results: int = 5) -> list[dict]:
    """Find loosely related tracks for autoplay."""
    clean = title.split("(")[0].split("[")[0].split("-")[0].strip()
    query = f"{uploader} {clean}"
    try:
        return search_top_tracks(query, max_results)
    except Exception:
        return []

HEREDOC

echo "Writing src/main.py..."
cat > "src/main.py" << 'HEREDOC'
import discord
from discord.ext import commands
import os
import logging
from dotenv import load_dotenv

load_dotenv()
TOKEN = os.getenv("TOKEN")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("simvox")


class SimvoxBot(commands.Bot):
    def __init__(self):
        intents = discord.Intents.default()
        intents.message_content = True
        intents.voice_states = True
        super().__init__(command_prefix="sv!", intents=intents, help_command=None)

    async def setup_hook(self):
        extensions = ["cogs.music"]
        for ext in extensions:
            try:
                await self.load_extension(ext)
                log.info(f"Loaded extension: {ext}")
            except Exception as e:
                log.error(f"Failed to load {ext}: {e}")
        await self.tree.sync()
        log.info("Slash commands synced.")

    async def on_ready(self):
        await self.change_presence(
            activity=discord.Activity(
                type=discord.ActivityType.listening,
                name="/play • SIMVOX",
            )
        )
        log.info(f"Online as {self.user} ({self.user.id})")

    async def on_command_error(self, ctx, error):
        log.warning(f"Command error: {error}")


bot = SimvoxBot()

if __name__ == "__main__":
    if not TOKEN:
        log.critical("TOKEN not found in environment. Set it in your .env file.")
    else:
        bot.run(TOKEN, log_handler=None)

HEREDOC

echo "Writing src/ui/__init__.py..."
cat > "src/ui/__init__.py" << 'HEREDOC'

HEREDOC

echo "Writing src/ui/views.py..."
cat > "src/ui/views.py" << 'HEREDOC'
"""
ui/views.py
All discord.ui Views, Selects and Buttons used by Simvox.
"""
import discord
import asyncio
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from core.player import GuildMusicManager
    from discord.ext import commands


# ── Search Dropdown ──────────────────────────────────────────────────────────

class TrackSelect(discord.ui.Select):
    def __init__(self, tracks: list, cog):
        self.tracks = tracks
        self.cog    = cog
        opts = []
        for i, t in enumerate(tracks[:25]):
            from utils.embeds import _fmt_time
            label = t["title"][:90] if len(t["title"]) > 90 else t["title"]
            dur   = _fmt_time(t.get("duration", 0))
            opts.append(discord.SelectOption(
                label=f"{i+1}. {label}",
                value=str(i),
                description=f"{t.get('uploader','?')} • {dur}",
                emoji="🎵",
            ))
        super().__init__(
            placeholder="🎵  Choose a track…",
            min_values=1, max_values=1,
            options=opts,
        )

    async def callback(self, interaction: discord.Interaction):
        await interaction.response.defer()
        track = self.tracks[int(self.values[0])]

        manager = await self.cog.ensure_voice(interaction)
        if not manager:
            return

        manager.add_to_queue(track)
        self.disabled = True
        await interaction.edit_original_response(view=self.view)

        pos = len(manager.queue)
        if not manager.voice_client.is_playing() and not manager.voice_client.is_paused():
            await manager.play_next()
            from utils.embeds import now_playing
            from ui.views import NowPlayingView
            embed = now_playing(track, 0, interaction.user)
            view  = NowPlayingView(manager)
            msg   = await interaction.followup.send(embed=embed, view=view)
            manager.np_message   = msg
            manager.text_channel = interaction.channel
        else:
            from utils.embeds import track_added
            await interaction.followup.send(embed=track_added(track, pos))


class SearchView(discord.ui.View):
    def __init__(self, tracks: list, cog):
        super().__init__(timeout=60)
        self.add_item(TrackSelect(tracks, cog))

    async def on_timeout(self):
        for item in self.children:
            item.disabled = True


# ── Now Playing Controls ─────────────────────────────────────────────────────

class NowPlayingView(discord.ui.View):
    def __init__(self, manager: "GuildMusicManager"):
        super().__init__(timeout=None)
        self.manager = manager
        self._update_loop_label()

    def _update_loop_label(self):
        for item in self.children:
            if getattr(item, "custom_id", None) == "loop_btn":
                icons = {"off": "🔁", "track": "🔂", "queue": "🔁"}
                item.emoji = discord.PartialEmoji(name=icons.get(self.manager.loop_mode, "🔁"))

    @discord.ui.button(emoji="⏮", style=discord.ButtonStyle.secondary, row=0)
    async def replay_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.defer()
        await self.manager.replay()
        await interaction.followup.send("⏮ Replaying from start.", ephemeral=True, delete_after=5)

    @discord.ui.button(emoji="⏸", style=discord.ButtonStyle.primary, row=0)
    async def pause_resume_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.defer()
        if self.manager.voice_client and self.manager.voice_client.is_playing():
            self.manager.pause()
            button.emoji = discord.PartialEmoji(name="▶")
            button.style = discord.ButtonStyle.success
        else:
            self.manager.resume()
            button.emoji = discord.PartialEmoji(name="⏸")
            button.style = discord.ButtonStyle.primary
        await interaction.edit_original_response(view=self)

    @discord.ui.button(emoji="⏭", style=discord.ButtonStyle.secondary, row=0)
    async def skip_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.defer()
        self.manager.skip()
        await interaction.followup.send("⏭ Skipped.", ephemeral=True, delete_after=5)

    @discord.ui.button(emoji="🔁", style=discord.ButtonStyle.secondary, row=0, custom_id="loop_btn")
    async def loop_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.defer()
        modes = ["off", "track", "queue"]
        idx   = modes.index(self.manager.loop_mode)
        self.manager.loop_mode = modes[(idx + 1) % len(modes)]
        labels = {"off": "Loop: Off", "track": "Loop: Track 🔂", "queue": "Loop: Queue 🔁"}
        await interaction.followup.send(f"🔁 {labels[self.manager.loop_mode]}", ephemeral=True, delete_after=5)

    @discord.ui.button(emoji="🔀", style=discord.ButtonStyle.secondary, row=0)
    async def shuffle_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.defer()
        self.manager.shuffle()
        await interaction.followup.send("🔀 Queue shuffled.", ephemeral=True, delete_after=5)

    @discord.ui.button(label="Queue", emoji="📋", style=discord.ButtonStyle.secondary, row=1)
    async def queue_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        from utils.embeds import queue_embed
        from ui.views    import QueueView
        embed = queue_embed(self.manager, 0)
        view  = QueueView(self.manager, 0)
        await interaction.response.send_message(embed=embed, view=view, ephemeral=True)

    @discord.ui.button(label="Filter", emoji="🎛", style=discord.ButtonStyle.secondary, row=1)
    async def filter_btn(self, interaction: discord.Interaction, button: discord.ui.Button):
        view = FilterView(self.manager)
        from utils.embeds import filters_embed
        await interaction.response.send_message(
            embed=filters_embed(self.manager.active_filter), view=view, ephemeral=True
        )

    @discord.ui.button(label="Vol –", emoji="🔉", style=discord.ButtonStyle.danger, row=1)
    async def vol_down(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.defer()
        self.manager.set_volume(self.manager.volume - 10)
        from utils.embeds import volume_embed
        await interaction.followup.send(embed=volume_embed(self.manager.volume), ephemeral=True, delete_after=5)

    @discord.ui.button(label="Vol +", emoji="🔊", style=discord.ButtonStyle.success, row=1)
    async def vol_up(self, interaction: discord.Interaction, button: discord.ui.Button):
        await interaction.response.defer()
        self.manager.set_volume(self.manager.volume + 10)
        from utils.embeds import volume_embed
        await interaction.followup.send(embed=volume_embed(self.manager.volume), ephemeral=True, delete_after=5)


# ── Queue Paginator ──────────────────────────────────────────────────────────

class QueueView(discord.ui.View):
    def __init__(self, manager: "GuildMusicManager", page: int = 0):
        super().__init__(timeout=120)
        self.manager = manager
        self.page    = page
        self._refresh_buttons()

    def _refresh_buttons(self):
        total = len(self.manager.queue)
        max_page = max(0, (total - 1) // 10)
        for item in self.children:
            if getattr(item, "custom_id", None) == "prev_page":
                item.disabled = self.page <= 0
            if getattr(item, "custom_id", None) == "next_page":
                item.disabled = self.page >= max_page

    @discord.ui.button(label="◀", style=discord.ButtonStyle.secondary, custom_id="prev_page")
    async def prev_page(self, interaction: discord.Interaction, button: discord.ui.Button):
        self.page = max(0, self.page - 1)
        self._refresh_buttons()
        from utils.embeds import queue_embed
        await interaction.response.edit_message(embed=queue_embed(self.manager, self.page), view=self)

    @discord.ui.button(label="▶", style=discord.ButtonStyle.secondary, custom_id="next_page")
    async def next_page(self, interaction: discord.Interaction, button: discord.ui.Button):
        max_page = max(0, (len(self.manager.queue) - 1) // 10)
        self.page = min(max_page, self.page + 1)
        self._refresh_buttons()
        from utils.embeds import queue_embed
        await interaction.response.edit_message(embed=queue_embed(self.manager, self.page), view=self)

    @discord.ui.button(label="🔀 Shuffle", style=discord.ButtonStyle.primary)
    async def shuffle(self, interaction: discord.Interaction, button: discord.ui.Button):
        self.manager.shuffle()
        from utils.embeds import queue_embed
        await interaction.response.edit_message(embed=queue_embed(self.manager, self.page), view=self)

    @discord.ui.button(label="🗑 Clear", style=discord.ButtonStyle.danger)
    async def clear(self, interaction: discord.Interaction, button: discord.ui.Button):
        self.manager.clear_queue()
        from utils.embeds import queue_embed
        await interaction.response.edit_message(embed=queue_embed(self.manager, 0), view=self)


# ── Audio Filter Select ───────────────────────────────────────────────────────

class FilterSelect(discord.ui.Select):
    FILTERS = [
        ("none",      "Off",         "No processing", "🎵"),
        ("bassboost", "Bass Boost",  "Heavy low-end",  "🔊"),
        ("nightcore", "Nightcore",   "Fast & pitched up", "⚡"),
        ("vaporwave", "Vaporwave",   "Slow & dreamy",  "🌊"),
        ("8d",        "8D Audio",    "Rotating stereo", "🎧"),
        ("karaoke",   "Karaoke",     "Vocal removal",  "🎤"),
        ("treble",    "Treble Boost","Crispy highs",   "✨"),
    ]

    def __init__(self, manager: "GuildMusicManager"):
        self.manager = manager
        opts = [
            discord.SelectOption(
                label=label, value=key, description=desc, emoji=emoji,
                default=(key == manager.active_filter),
            )
            for key, label, desc, emoji in self.FILTERS
        ]
        super().__init__(placeholder="Choose a filter…", options=opts)

    async def callback(self, interaction: discord.Interaction):
        await interaction.response.defer()
        await self.manager.apply_filter(self.values[0])
        from utils.embeds import filters_embed
        await interaction.edit_original_response(
            embed=filters_embed(self.manager.active_filter)
        )
        await interaction.followup.send(
            f"🎛 Filter set to **{self.values[0]}**.", ephemeral=True, delete_after=5
        )


class FilterView(discord.ui.View):
    def __init__(self, manager: "GuildMusicManager"):
        super().__init__(timeout=60)
        self.add_item(FilterSelect(manager))


# ── Loop Mode Select ─────────────────────────────────────────────────────────

class LoopSelect(discord.ui.Select):
    def __init__(self, manager: "GuildMusicManager"):
        self.manager = manager
        opts = [
            discord.SelectOption(label="Off",       value="off",   emoji="➡", default=manager.loop_mode=="off"),
            discord.SelectOption(label="Loop Track", value="track", emoji="🔂", default=manager.loop_mode=="track"),
            discord.SelectOption(label="Loop Queue", value="queue", emoji="🔁", default=manager.loop_mode=="queue"),
        ]
        super().__init__(placeholder="Loop mode…", options=opts)

    async def callback(self, interaction: discord.Interaction):
        self.manager.set_loop(self.values[0])
        await interaction.response.send_message(
            f"Loop set to **{self.values[0]}**.", ephemeral=True, delete_after=5
        )


class LoopView(discord.ui.View):
    def __init__(self, manager: "GuildMusicManager"):
        super().__init__(timeout=30)
        self.add_item(LoopSelect(manager))


# ── Vote Skip ────────────────────────────────────────────────────────────────

class VoteSkipView(discord.ui.View):
    def __init__(self, manager: "GuildMusicManager", required: int):
        super().__init__(timeout=30)
        self.manager  = manager
        self.required = required

    @discord.ui.button(label="Skip (0)", emoji="⏭", style=discord.ButtonStyle.danger)
    async def vote(self, interaction: discord.Interaction, button: discord.ui.Button):
        uid = interaction.user.id
        if uid in self.manager.skip_votes:
            await interaction.response.send_message("You already voted.", ephemeral=True, delete_after=5)
            return
        self.manager.skip_votes.add(uid)
        count = len(self.manager.skip_votes)
        button.label = f"Skip ({count}/{self.required})"
        if count >= self.required:
            self.manager.skip()
            self.stop()
            await interaction.response.edit_message(content="⏭ Vote passed — skipped!", view=None)
        else:
            await interaction.response.edit_message(view=self)

HEREDOC

echo "Writing src/utils/__init__.py..."
cat > "src/utils/__init__.py" << 'HEREDOC'

HEREDOC

echo "Writing src/utils/embeds.py..."
cat > "src/utils/embeds.py" << 'HEREDOC'
"""
utils/embeds.py
All embed builders for Simvox. Red-accent house style.
"""
import discord
from typing import Optional

# ── Palette ────────────────────────────────────────────────────────────────
RED        = 0xE8132A   # primary accent
RED_DARK   = 0x8B0000   # deeper red for errors
DARK       = 0x0A0A0F   # void background
GOLD       = 0xFFD700   # highlights (queue positions etc.)
GREY       = 0x2B2D31   # neutral fields

SIMVOX_ICON = "https://i.imgur.com/placeholder.png"   # swap for real icon


def _base(color: int = RED) -> discord.Embed:
    e = discord.Embed(color=color)
    e.set_footer(text="SIMVOX", icon_url=SIMVOX_ICON)
    return e


def now_playing(track: dict, position: int = 0, requester: Optional[discord.Member] = None) -> discord.Embed:
    dur   = track.get("duration", 0) or 0
    pos   = min(position, dur)
    pct   = (pos / dur) if dur else 0
    bar   = _progress_bar(pct)
    elapsed = _fmt_time(pos)
    total   = _fmt_time(dur)

    e = _base(RED)
    e.title = "▶  NOW PLAYING"
    e.description = f"### [{track['title']}]({track.get('webpage_url', '')})"
    e.add_field(name="", value=f"`{elapsed}` {bar} `{total}`", inline=False)
    e.add_field(name="🎤 Artist",    value=track.get("uploader", "Unknown"),   inline=True)
    e.add_field(name="⏱ Duration",  value=total,                               inline=True)
    if requester:
        e.add_field(name="👤 Requested by", value=requester.mention,           inline=True)
    if track.get("thumbnail"):
        e.set_thumbnail(url=track["thumbnail"])
    return e


def queue_embed(manager, page: int = 0) -> discord.Embed:
    per_page = 10
    q        = manager.queue
    total    = len(q)
    start    = page * per_page
    end      = start + per_page
    chunk    = q[start:end]

    e = _base(RED)
    e.title = "📋  QUEUE"

    if manager.current:
        dur_str = _fmt_time(manager.current.get("duration", 0))
        e.add_field(
            name="▶ Now Playing",
            value=f"[{manager.current['title']}]({manager.current.get('webpage_url','')}) `{dur_str}`",
            inline=False,
        )
    else:
        e.description = "Queue is empty — use `/play` to load something up."
        return e

    if chunk:
        lines = []
        for i, t in enumerate(chunk, start=start + 1):
            dur_str = _fmt_time(t.get("duration", 0))
            lines.append(f"`{i:02}.` **{t['title']}** `{dur_str}`")
        e.add_field(name=f"Up Next  [{start+1}–{min(end,total)} of {total}]",
                    value="\n".join(lines), inline=False)
    else:
        e.add_field(name="Up Next", value="Nothing queued.", inline=False)

    total_dur = sum(t.get("duration", 0) or 0 for t in q)
    loop_str  = {"off": "Off", "track": "🔂 Track", "queue": "🔁 Queue"}.get(manager.loop_mode, "Off")
    e.set_footer(text=f"SIMVOX  •  Total: {_fmt_time(total_dur)}  •  Loop: {loop_str}  •  Page {page+1}/{max(1,(total-1)//per_page+1)}")
    return e


def search_results(query: str, tracks: list) -> discord.Embed:
    e = _base(RED)
    e.title = f"🔍  Search: {query[:50]}"
    e.description = "Pick a track from the dropdown below."
    for i, t in enumerate(tracks[:10], 1):
        dur = _fmt_time(t.get("duration", 0))
        e.add_field(
            name=f"{i}. {t['title'][:60]}",
            value=f"🎤 {t.get('uploader','?')}  •  ⏱ {dur}",
            inline=False,
        )
    return e


def track_added(track: dict, position: int) -> discord.Embed:
    e = _base(RED)
    e.title = "➕  Added to Queue"
    e.description = f"[{track['title']}]({track.get('webpage_url','')})"
    e.add_field(name="Position",  value=f"`#{position}`",                inline=True)
    e.add_field(name="Duration",  value=_fmt_time(track.get("duration",0)), inline=True)
    e.add_field(name="Artist",    value=track.get("uploader","?"),       inline=True)
    if track.get("thumbnail"):
        e.set_thumbnail(url=track["thumbnail"])
    return e


def error_embed(message: str) -> discord.Embed:
    e = _base(RED_DARK)
    e.title = "❌  Error"
    e.description = message
    return e


def success_embed(message: str) -> discord.Embed:
    e = _base(RED)
    e.title = "✅  Done"
    e.description = message
    return e


def info_embed(title: str, message: str) -> discord.Embed:
    e = _base(GREY)
    e.title = title
    e.description = message
    return e


def history_embed(history: list) -> discord.Embed:
    e = _base(RED)
    e.title = "📜  Play History"
    if not history:
        e.description = "Nothing played yet this session."
        return e
    lines = []
    for i, t in enumerate(reversed(history[-15:]), 1):
        dur = _fmt_time(t.get("duration", 0))
        lines.append(f"`{i:02}.` {t['title'][:55]} `{dur}`")
    e.description = "\n".join(lines)
    return e


def filters_embed(active_filter: str) -> discord.Embed:
    e = _base(RED)
    e.title = "🎛  Audio Filters"
    filters = {
        "none":       ("Off",         "No processing applied."),
        "bassboost":  ("Bass Boost",  "Heavy low-end enhancement."),
        "nightcore":  ("Nightcore",   "Pitched up, sped up."),
        "vaporwave":  ("Vaporwave",   "Slowed, pitched down."),
        "8d":         ("8D Audio",    "Panning stereo effect."),
        "karaoke":    ("Karaoke",     "Vocal removal attempt."),
        "treble":     ("Treble Boost","High-end clarity boost."),
    }
    lines = []
    for key, (label, desc) in filters.items():
        mark = "▶" if key == active_filter else "·"
        lines.append(f"`{mark}` **{label}** — {desc}")
    e.description = "\n".join(lines)
    return e


def volume_embed(vol: int) -> discord.Embed:
    e = _base(RED)
    e.title = "🔊  Volume"
    bar = _volume_bar(vol)
    e.description = f"{bar}  **{vol}%**"
    return e


# ── Helpers ─────────────────────────────────────────────────────────────────
def _fmt_time(seconds: int) -> str:
    if not seconds:
        return "0:00"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s   = divmod(rem, 60)
    return f"{h}:{m:02}:{s:02}" if h else f"{m}:{s:02}"


def _progress_bar(pct: float, length: int = 18) -> str:
    filled = int(pct * length)
    bar    = "█" * filled + "▒" * (length - filled)
    return f"[{bar}]"


def _volume_bar(vol: int, length: int = 16) -> str:
    filled = int((min(vol, 200) / 200) * length)
    return "▮" * filled + "▯" * (length - filled)

HEREDOC

echo "Writing src/utils/helpers.py..."
cat > "src/utils/helpers.py" << 'HEREDOC'
"""
utils/helpers.py
Small utility functions shared across the codebase.
"""
import discord
from typing import Optional


async def send_error(interaction: discord.Interaction, message: str, ephemeral: bool = True):
    from utils.embeds import error_embed
    e = error_embed(message)
    try:
        if interaction.response.is_done():
            await interaction.followup.send(embed=e, ephemeral=ephemeral)
        else:
            await interaction.response.send_message(embed=e, ephemeral=ephemeral)
    except Exception:
        pass


async def send_success(interaction: discord.Interaction, message: str, ephemeral: bool = False):
    from utils.embeds import success_embed
    e = success_embed(message)
    try:
        if interaction.response.is_done():
            await interaction.followup.send(embed=e, ephemeral=ephemeral)
        else:
            await interaction.response.send_message(embed=e, ephemeral=ephemeral)
    except Exception:
        pass


def fmt_time(seconds: int) -> str:
    if not seconds:
        return "0:00"
    seconds = int(seconds)
    h, rem = divmod(seconds, 3600)
    m, s   = divmod(rem, 60)
    return f"{h}:{m:02}:{s:02}" if h else f"{m}:{s:02}"


def parse_time(time_str: str) -> Optional[int]:
    """Parse mm:ss or ss into total seconds. Returns None on failure."""
    try:
        parts = time_str.strip().split(":")
        if len(parts) == 1:
            return int(parts[0])
        elif len(parts) == 2:
            return int(parts[0]) * 60 + int(parts[1])
        elif len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
    except ValueError:
        return None

HEREDOC

echo ""
echo "✅ Done! Now:"
echo "  cd simvox"
echo "  cp .env.example .env && nano .env   # add your TOKEN"
echo "  pip install -r requirements.txt"
echo "  python src/main.py"