# Lunor-AntiCheat

================================================================================

LUNOR ANTI-CHEAT SYSTEM - TUTORIAL
Complete Setup Guide
================================================================================

TABLE OF CONTENTS
Installation
Testing Your Anti-Cheat
Understanding Console Output
Configuration & Customization
Troubleshooting
Advanced Usage
1. INSTALLATION
STEP 1: Insert the Anti-Cheat Script
Open # Roblox Studio

Open your game project

In the Explorer window, find # ServerScriptService

Right-click ServerScriptService → Insert Object → # Script

Rename the script to # "AntiCheat"

Delete the default print("Hello world!") line

Paste the entire AntiCheat.lua code into the script

Save your game

IMPORTANT: The anti-cheat MUST be in ServerScriptService to work properly. Never put it in StarterPlayer—exploiters can disable client-side scripts.
STEP 2: Insert the Testing Panel (Optional)
In Explorer, find # StarterPlayer

Expand StarterPlayer → Find # StarterPlayerScripts

Right-click StarterPlayerScripts → Insert Object → # LocalScript

Rename it to # "ACTester"

Paste the entire ACTester.lua code

2. TESTING YOUR ANTI-CHEAT
# Using the Test Panel
When you play the game with ACTester installed, you'll see a dark panel titled # "LUNOR AC TESTER" with four buttons. The indicator turns green when active.

# FLY HACK Testing
Click # "FLY HACK"

Use W/A/S/D and Space/Shift.

After ~2.5 seconds, the anti-cheat will forcefully push you down.

You will be # KICKED after 3 attempts.

# SPEED HACK Testing
Click # "SPEED HACK"

Try walking—you'll move at # 150 speed.

The anti-cheat will "rubber-band" you back to 16 speed.

You will be # KICKED after 5-6 violations.

3. UNDERSTANDING CONSOLE OUTPUT
# Normal Operation
[LUNOR AC] Anti-Cheat system initialized successfully

# Detection Messages
[LUNOR AC] Player detected using # FLY_HACK

[LUNOR AC] Player detected using # SPEED_HACK

[LUNOR AC] Player detected using # TELEPORT

4. CONFIGURATION & CUSTOMIZATION
Find the # CONFIG table at the top of the script:

MaxAirTime (2.5): Seconds allowed in air.
MaxWalkSpeed (16): Default speed limit.
ViolationLimit (8): Noclip attempts before kick.
KickOnDetection (true): Set to # false for "Silent Logging" mode.
5. TROUBLESHOOTING
Problem: Legitimate players getting kicked?
Solution: Increase # MaxAirTime or # SpeedMultiplier.

Problem: Rubber-banding during lag?
Solution: Increase # MaxDistancePerFrame in Teleport settings.

6. ADVANCED USAGE
# Creating Immunity for Admins
Add your # UserId to the admin table to prevent the anti-cheat from kicking you while you build or moderate.

# Discord Webhook Logging
Enable # HttpService to send live "Detection Reports" to your Discord server so you can see who is trying to exploit in real-time.

================================================================================

FINAL CHECKLIST
================================================================================

[ ] Anti-cheat in # ServerScriptService

[ ] Testing panel # REMOVED before publishing

[ ] Configuration tuned for your game

[ ] # LPL License intact in header

# © 2026 Lunor - All Rights Reserved
================================================================================
