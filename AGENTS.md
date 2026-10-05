GoldenNugget Mobile: Guide for AI agents
## Requirements to build 
1. Swift 6
2. xcode 26 or xtool with iOS 26+ SDK
3. Rust (neospring, airlift)
4. Python (Optional, but nedeed to generate code from desktop version and some scripts)
## notes
All code files have detailed descriptions in it\
Never do anything with code unless user follow requirements.
## How it works
Main code stored in Nugget folder\
Core: all backend\
Views: frontend (SwiftUI)\
Scripts: many stuff like: building, debugging, generators and many other helpful things. Recommended to use these instead of raw CLI commands\
Tools: have AssetKit in it. useless if you have actool\
Vendor: Required to make app work, local forks with some patches
