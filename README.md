# GodotSteam Server dedicated server on Edgegap

A minimal Godot 4 project that runs a **GodotSteam Server** dedicated server on [Edgegap](https://edgegap.com): a headless Linux server that logs on to Steam, and a Steam client that connects over ENet and must pass Steam's auth ticket check before it's let in.

Full walkthrough: **[Host a GodotSteam Server dedicated server on Edgegap](https://docs.edgegap.com/docs/sample-projects/godot/godotsteam-server)**.

Tested with Godot 4.7.2, GodotSteam Server 4.12.1 and GodotSteam 4.24 (both GDExtension, Steamworks SDK 1.65):

- 2026-11-09, on an Edgegap deployment: the server logged on to Steam, a Windows client authenticated with its Steam ticket, and the deployment stopped itself when the client left.
- 2026-11-27, with the [Edgegap Godot plugin](https://github.com/edgegap/buildtool-godot-plugin) 1.0.10's `Edgegap Linux Server` preset and this repository's `Dockerfile`: the image was pushed to the Edgegap registry and deployed on Edgegap (UDP 7777 `gameport`, UDP 27015 `queryport`). The server logged on to Steam, a Windows client authenticated with its Steam ticket through the deployment's external port, and the deployment stopped itself when the client left.

## What's inside

| Path | What it is |
| --- | --- |
| `net/session.gd` | One autoload for both sides. Server: `SteamServer.serverInitEx()`, `logOnAnonymous()` (or `logOn()` with a Game Server Login Token), ENet on UDP 7777, `beginAuthSession()` for every player, kicks players without a valid ticket, deletes its own Edgegap deployment when empty. Client: `Steam.steamInitEx()`, connects with ENet, sends an auth session ticket bound to the server's Steam ID. |
| `addons/edgegap/` | The Edgegap Godot plugin (1.0.10, commit `5b330ab`), already enabled. Its **Edgegap** dock exports the server, builds the image, runs it locally, uploads it and deploys it. |
| `Dockerfile` | What a Steam server needs on top of the plugin's default image: a SteamCMD stage for `steamclient.so`, and the GodotSteam Server `.so` files next to the binary. |
| `export_presets.cfg` | The plugin's `Edgegap Linux Server` preset, with the client add-on and the plugin excluded from the server. |
| `tools/fetch-godotsteam.sh` | Downloads the tested GodotSteam and GodotSteam Server GDExtensions into `addons/`. |

## Requirements

- Godot 4.4 or newer (tested 4.7.2) with the Linux export templates.
- Docker, running.
- The Steam client, running and signed in, for the game client.
- An [Edgegap account](https://app.edgegap.com/auth/register) (free tier is enough).

The sample uses Steam App ID `480` (Spacewar, Valve's test app). Replace `STEAM_APP_ID` in `net/session.gd` and `SteamAppId` in the `Dockerfile` with your own.

## Quick start

1. Download the GodotSteam add-ons (Git Bash works on Windows), then open the project in Godot:

   ```bash
   ./tools/fetch-godotsteam.sh
   ```

2. In the **Edgegap** dock, **1. Connect your Edgegap Account**: sign in.
3. **2. Build Your Game Server**: click **Export server**.
4. **3. Containerize Your Server**: set **Dockerfile path** to `Dockerfile` (the one in the project root), then click **Containerize with Docker**.
5. **4. Test Your Server Locally**: set **Docker run parameters** to `-p 7777:7777/udp`, then click **Deploy local container**. `docker logs <container>` shows `STEAM logged on steam_id=...`.
6. With Steam running, start a client:

   ```bash
   godot --path . -- --connect=127.0.0.1:7777
   ```

   The client shows `AUTHENTICATED by Steam`. Click **Terminate** in the dock when you're done.

To run the server from the editor instead, use `-- --server` as main run arguments.

## Deploy on Edgegap

1. **5. Upload to Edgegap**: enter an application name and click **Upload image & create app version**. The plugin pushes the image and opens the new version in the dashboard: add the port `gameport` 7777 **UDP** and create it.
2. **6. Deploy a Server on Edgegap**: pick the application and version, click **Deploy to cloud**.
3. Connect a client to the deployment's host and the external port of `gameport`, both shown on the deployment's page in the dashboard:

   ```bash
   godot --path . -- --connect=<deployment-host>:<external-gameport>
   ```

When the client leaves, the server stops its own deployment.

Optional version settings: a second port `queryport` 27015 **UDP** (verification off) for Steam server queries, and the variables `SteamAppId` (overrides the image's App ID) and `STEAM_GSLT` (a [Game Server Login Token](https://steamcommunity.com/dev/managegameservers) for a persistent server Steam ID).

## Bringing players in

Steam lists the server with the right connect address, but it records the internal query port (27015). Edgegap maps that port to a random external port, so Steam's server browser ping fails and the server shows as not responding. Bring players in with the [Edgegap Matchmaker](https://docs.edgegap.com/learn/matchmaking) or Steam lobbies (`Steam.setLobbyGameServer()`) instead. Details in the [guide](https://docs.edgegap.com/docs/sample-projects/godot/godotsteam-server).

## Notes

- With both add-ons in the project, the editor prints `SteamProjectSettings ... already registered` errors. They don't affect the server or the client. Exports ship one add-on each: exclude `addons/godotsteam_server/*` from client presets.
- The dock's fields reset when the editor restarts: set **Dockerfile path** again before you containerize. With the plugin's default Dockerfile the server fails with `non-existent singleton 'SteamServer'`.
- The `.dockerignore` keeps everything but `build/` out of the Docker build context.

## Credits

[GodotSteam and GodotSteam Server](https://godotsteam.com/) by GP Garcia and contributors (MIT), downloaded by `tools/fetch-godotsteam.sh`, not included in this repository. Steamworks and SteamCMD are provided by Valve.

## License

MIT, see [LICENSE](LICENSE).
