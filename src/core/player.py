import discord
import asyncio
from core.scraper import search_audio

class GuildMusicManager:
    def __init__(self, bot, guild_id):
        self.bot = bot
        self.guild_id = guild_id
        self.queue = []
        self.current = None
        self.voice_client = None

    async def play_next(self, interaction: discord.Interaction = None):
        """Plays the next song in the queue."""
        if len(self.queue) == 0:
            self.current = None
            return
        self.current = self.queue.pop(0)
        
        ffmpeg_options = {
            'options': '-vn',
            "before_options": "-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5"
        }
        
        audio_source = discord.FFmpegPCMAudio(self.current['source'], **ffmpeg_options)
        

        def after_playing(error):
            if error:
                print(f"Player error in guild {self.guild_id}: {error}")

            self.bot.loop.call_soon_threadsafe(
                asyncio.create_task, self.play_next()
            )

        self.voice_client.play(audio_source, after=after_playing)


        if interaction and not interaction.response.is_done():
            await interaction.followup.send(f"🎶 Now playing: **{self.current['title']}**")

    def add_to_queue(self, track):
        self.queue.append(track)

    def skip(self):
        if self.voice_client and self.voice_client.is_playing():
            self.voice_client.stop()

    def pause(self):
        if self.voice_client and self.voice_client.is_playing():
            self.voice_client.pause()
            return True
        return False

    def resume(self):
        if self.voice_client and self.voice_client.is_paused():
            self.voice_client.resume()
            return True
        return False