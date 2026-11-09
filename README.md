# GodotSteam Server dedicated server on Edgegap

A minimal Godot 4 project that runs a **GodotSteam Server** dedicated server on [Edgegap](https://edgegap.com): a headless Linux server that logs on to Steam, and a Steam client that connects over ENet and must pass Steam's auth ticket check before it's let in.

Full walkthrough: **[Host a GodotSteam Server dedicated server on Edgegap](https://docs.edgegap.com/godot/godotsteam-server)**.

Tested on 2026-11-09 with Godot 4.7.2, GodotSteam Server 4.12.1 and GodotSteam 4.24 (both GDExtension, Steamworks SDK 1.65): the server logged on to Steam on an Edgegap deployment, a Windows client authenticated with its Steam ticket, and the deployment stopped itself when the client left.

## What's inside

| Path | What it is |
| --- | --- |
| `net/session.gd` | One autoload for both sides. Server: `SteamServer.serverInitEx()`, `logOnAnonymous()` (or `logOn()` with a Game Server Login Token), ENet on UDP 7777, `beginAuthSession()` for every player, kicks players without a valid ticket, deletes its own Edgegap deployment when empty. Client: `Steam.steamInitEx()`, connects with ENet, sends an auth session ticket bound to the server's Steam ID. |
| `export_presets.cfg` | `Edgegap Linux Server` preset: dedicated server mode, excludes the client add-on, exports to `build/edgegap-linux-server.x86_64` (same path as the [Edgegap Godot plugin](https://github.com/edgegap/buildtool-godot-plugin)). |
| `Dockerfile` | SteamCMD stage for `steamclient.so`, Ubuntu 24.04 runtime, non-root user, `tini`. Copies the GodotSteam Server `.so` files, which the plugin's default Dockerfile leaves out. |
| `tools/fetch-godotsteam.sh` | Downloads the tested GodotSteam and GodotSteam Server GDExtensions into `addons/`. |

## Requirements

- Godot 4.4 or newer (tested 4.7.2) with the Linux export templates.
- Docker.
- The Steam client, running and signed in, for the game client.
- An [Edgegap account](https://app.edgegap.com/auth/register) (free tier is enough).

The sample uses Steam App ID `480` (Spacewar, Valve's test app). Replace `STEAM_APP_ID` in `net/session.gd` and `SteamAppId` in the `Dockerfile` with your own.

## Quick start

```bash
./tools/fetch-godotsteam.sh
godot --headless --path . --import
mkdir -p build
godot --headless --path . --export-release "Edgegap Linux Server" build/edgegap-linux-server.x86_64
docker build --platform linux/amd64 -t godotsteam-server:20261109-1924 .
docker run --name godotsteam-server -p 7777:7777/udp -p 27015:27015/udp godotsteam-server:20261109-1924
```

The server logs `STEAM logged on steam_id=...`. With Steam running, start a client:

```bash
godot --path . -- --connect=127.0.0.1:7777
```

The client shows `AUTHENTICATED by Steam`. Run the server from the editor instead with `-- --server` as main run arguments.

## Deploy on Edgegap

1. Push the image to the Edgegap Container Registry (or any registry Edgegap can pull from).
2. Create an app version with ports `gameport` 7777 **UDP** and, optionally, `queryport` 27015 **UDP** (verification off).
3. Deploy it, then connect a client to the deployment host and the external port of `gameport`:

   ```bash
   godot --path . -- --connect=<deployment-host>:<external-gameport>
   ```

Optional app version variables: `SteamAppId` (overrides the image's App ID) and `STEAM_GSLT` (a [Game Server Login Token](https://steamcommunity.com/dev/managegameservers) for a persistent server Steam ID; not tested here).

## Known limitation: Steam server browser

Steam lists the server with the right connect address, but it records the internal query port (27015). Edgegap maps that port to a random external port, so Steam's server browser ping fails and the server shows as not responding. Bring players in with the [Edgegap Matchmaker](https://docs.edgegap.com/learn/matchmaking) or Steam lobbies (`Steam.setLobbyGameServer()`) instead. Details in the [guide](https://docs.edgegap.com/godot/godotsteam-server).

## Notes

- With both add-ons in the project, the editor prints `SteamProjectSettings ... already registered` errors. They didn't affect the server or the client in testing. Exports ship one add-on each: exclude `addons/godotsteam_server/*` from client presets.
- Only the Linux server export was tested; the client was run from the editor binary on Windows.

## Credits

[GodotSteam and GodotSteam Server](https://godotsteam.com/) by GP Garcia and contributors (MIT), downloaded by `tools/fetch-godotsteam.sh`, not included in this repository. Steamworks and SteamCMD are provided by Valve.

## License

MIT, see [LICENSE](LICENSE).
