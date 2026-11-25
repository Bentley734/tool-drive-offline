# Tool Drive Offline for Apple TV

Version 2.0.0.

Browse 1,299 documented TOOL shows on Apple TV. The catalog, concert photos, and theme artwork are bundled with the app. Use the Siri Remote to move between the catalog controls and show list. Select a show to see its recordings and setlist. Press Back to return.

## Appearance

Liquid Glass is the default on first launch. An existing theme choice takes precedence. Open **Appearance** on the catalog screen and choose **Front Row**, **Night Shift**, **Graphite**, **Laser Grid**, or **Liquid Glass**. Choose the **Classic** or **2006** logo. Front Row has two stage photos. Liquid Glass has nine wallpapers and a **Shuffle** option for a different concert photo on the next launch. Your Apple TV remembers these choices.

**Liquid Glass controls** also works with the four standard themes. Turning it off while using the Liquid Glass theme takes you back to your preceding standard theme. The app uses native Liquid Glass controls on tvOS 26 or later and translucent materials on earlier supported versions. Reduce Transparency uses solid surfaces.

## Listening

Choose an available recording to stream audio from the Tool Drive Project. Now Playing includes a track queue, seeking, an equalizer and a full-screen audio visualizer. Bookmark a show to find it under **Saved**. **Library** lets you play recordings saved for offline listening or refresh the catalog. Apple TV can reclaim cached audio when it needs storage space. Streaming and new downloads need an internet connection.

## Run the app

Open **Tool Drive Offline TV.xcodeproj** in Xcode 26 or later. Choose the **Tool Drive Offline TV** scheme and an Apple TV running tvOS 17 or later. For a physical Apple TV, pair it with Xcode, select your development team under **Signing & Capabilities**, and press **Run**. Use a unique bundle identifier if required by your team. The supplied device IPA needs signing before installation.

To use the prebuilt simulator copy, unzip **Tool.Drive.Offline.tvOS.Simulator.zip** and drag **Tool Drive Offline TV.app** into a running Apple TV simulator. Archive credits are in **Resources/NOTICE.md**.
