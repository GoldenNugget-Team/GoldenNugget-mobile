GoldenNugget Mobile: Guide for AI agents

## Requirements to build

1. Swift 6
2. xcode 26 or xtool with iOS 26+ SDK
3. Rust (neospring, airlift)
4. Python (Optional, but nedeed to generate code from desktop version and some scripts)

## notes

All code files have detailed descriptions in it\
Never do anything with code unless user follow requirements.
Always explore project first

## How it works

Main code stored in Nugget folder\
Core: all backend\
Views: frontend (SwiftUI)\
Scripts: many stuff like: building, debugging, generators and many other helpful things. Recommended to use these instead of raw CLI commands\
Vendor: Required to make app work, local forks with some patches

# Build Notes

Use coreui-car (GoldenNugget-Team/CoreUi-car), recommended user xtool and coreui-car instead of Xcode (Reason is easier debugging for me :))
Prefer Scripts rather than manual commands
