import discord
from discord import app_commands
from discord.ext import commands
import asyncio
from core.scraper import search_top_tracks
from core.player import GuildMusicManager

class TrackDropdown(discord.ui.Select):
    def __init__(self, tracks: list, manager: GuildMusicManager, cog: commands.Cog):
        self.tracks = tracks
        self.manager = manager
        self.cog = cog
        

        options = []
        for idx, track in enumerate(tracks):

            title = track['title']
            if len(title) > 90:
                title = title[:87] + "..."
                
            options.append(discord.SelectOption(
                label=f"{idx + 1}. {title}",
                value=str(idx),
                description=f"Duration: {track['duration'] // 60}m {track['duration'] % 60}s" if track['duration'] else "Unknown duration"
            ))

        super().__init__(placeholder="Select a song to play...", min_values=1, max_values=1, options=options)

    async def callback(self, interaction: discord.Interaction):

        await interaction.response.defer()
        

        selected_idx = int(self.values[0])
        track = self.tracks[selected_idx]
        

        manager = await self.cog.ensure_voice(interaction)
        if not manager:
            return


        manager.add_to_queue(track)
        

        self.disabled = True
        await interaction.edit_original_response(view=self.view)


        if not manager.voice_client.is_playing() and not manager.voice_client.is_paused():
            await manager.play_next()
            await interaction.followup.send(f"🎶 Now playing selection: **{track['title']}**")
        else:
            await interaction.followup.send(f"⏳ Added to queue: **{track['title']}** (Position: {len(manager.queue)})")


class DropdownView(discord.ui.View):
    def __init__(self, tracks: list, manager: GuildMusicManager, cog: commands.Cog):
        super().__init__(timeout=60)
        self.add_item(TrackDropdown(tracks, manager, cog))


class Music(commands.Cog):
    def __init__(self, bot):
        self.bot = bot
        self.managers = {}

    def get_manager(self, guild_id: int) -> GuildMusicManager:
        if guild_id not in self.managers:
            self.managers[guild_id] = GuildMusicManager(self.bot, guild_id)
        return self.managers[guild_id]

    async def ensure_voice(self, interaction: discord.Interaction):
        if not interaction.user.voice:

            try:
                await interaction.response.send_message("❌ You need to be in a voice channel first!", ephemeral=True)
            except discord.InteractionResponded:
                await interaction.followup.send("❌ You need to be in a voice channel first!")
            return None

        channel = interaction.user.voice.channel
        voice_client = discord.utils.get(self.bot.voice_clients, guild=interaction.guild)

        if not voice_client:
            voice_client = await channel.connect()
        elif voice_client.channel != channel:
            await voice_client.move_to(channel)

        manager = self.get_manager(interaction.guild_id)
        manager.voice_client = voice_client
        return manager

    @app_commands.command(name="play", description="Search for music and choose from top 10 results")
    async def play(self, interaction: discord.Interaction, query: str):
        await interaction.response.defer()
        

        if not interaction.user.voice:
            await interaction.followup.send("❌ You need to be in a voice channel first!")
            return
            
        manager = self.get_manager(interaction.guild_id)

        try:

            tracks = await asyncio.to_thread(search_top_tracks, query, 10)
            

            embed = discord.Embed(
                title=f"🔍 Search Results for: {query}", 
                description="Select your track from the dropdown menu below.",
                color=discord.Color.blue()
            )
            
            for idx, track in enumerate(tracks):
                duration_str = f"{track['duration'] // 60}m {track['duration'] % 60}s" if track['duration'] else "Unknown"
                embed.add_field(name=f"{idx + 1}. {track['title']}", value=f"Duration: {duration_str}", inline=False)


            view = DropdownView(tracks, manager, self)
            await interaction.followup.send(embed=embed, view=view)
            
        except Exception as e:
            await interaction.followup.send(f"❌ Scraping error: {e}")

    @app_commands.command(name="pause", description="Pause the currently playing track")
    async def pause(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        if manager.pause():
            await interaction.response.send_message("⏸️ Playback paused.")
        else:
            await interaction.response.send_message("❌ Nothing is currently playing.", ephemeral=True)

    @app_commands.command(name="resume", description="Resume the paused track")
    async def resume(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        if manager.resume():
            await interaction.response.send_message("▶️ Playback resumed.")
        else:
            await interaction.response.send_message("❌ Playback isn't paused.", ephemeral=True)

    @app_commands.command(name="skip", description="Skip the current track")
    async def skip(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        if manager.voice_client and (manager.voice_client.is_playing() or manager.voice_client.is_paused()):
            manager.skip()
            await interaction.response.send_message("⏭️ Skipped current track.")
        else:
            await interaction.response.send_message("❌ Nothing to skip.", ephemeral=True)

    @app_commands.command(name="queue", description="Show the upcoming tracks")
    async def queue(self, interaction: discord.Interaction):
        manager = self.get_manager(interaction.guild_id)
        embed = discord.Embed(title="📋 Current Queue", color=discord.Color.blurple())
        
        if manager.current:
            embed.add_field(name="Now Playing", value=manager.current['title'], inline=False)
        else:
            embed.description = "Queue is empty! Use `/play` to add a track."
            await interaction.response.send_message(embed=embed)
            return

        if manager.queue:
            queue_list = ""
            for idx, track in enumerate(manager.queue, start=1):
                queue_list += f"`{idx}.` {track['title']}\n"
                if idx >= 10:
                    queue_list += f"...and {len(manager.queue) - 10} more tracks."
                    break
            embed.add_field(name="Up Next", value=queue_list, inline=False)
        else:
            embed.add_field(name="Up Next", value="No songs queued up.", inline=False)

        await interaction.response.send_message(embed=embed)

async def setup(bot):
    await bot.add_cog(Music(bot))