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

