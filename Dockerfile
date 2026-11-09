# Stage 1: SteamCMD downloads steamclient.so. The game server needs it to log on to
# Steam, and it is not part of the Steamworks redistributables that GodotSteam ships.
FROM ubuntu:24.04 AS steamcmd
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl lib32gcc-s1 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /steamcmd
RUN curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar -xz \
 && ./steamcmd.sh +quit \
 && test -f linux64/steamclient.so

# Stage 2: the Godot dedicated server.
FROM ubuntu:24.04
# Same contract as the Edgegap Godot plugin: project-relative path without extension.
ARG SERVER_BUILD_PATH=build/edgegap-linux-server

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tini \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 1001 game

# steam_api looks for the 64-bit Steam client library in ~/.steam/sdk64/.
COPY --from=steamcmd --chown=game:game /steamcmd/linux64/steamclient.so /home/game/.steam/sdk64/steamclient.so

WORKDIR /home/game/server
COPY --chown=game:game ${SERVER_BUILD_PATH}.x86_64 ./server.x86_64
COPY --chown=game:game ${SERVER_BUILD_PATH}.pck ./server.pck
# The GDExtension and the Steamworks API library, exported next to the binary.
COPY --chown=game:game build/libgodotsteam_server.linux.template_*.x86_64.so build/libsteam_api.so ./
RUN chmod +x server.x86_64

# Your Steam App ID (480 = Spacewar, Valve's test app). Same effect as a steam_appid.txt.
ENV SteamAppId=480

USER game
# tini forwards SIGTERM, so stopping the deployment ends the server right away.
ENTRYPOINT ["/usr/bin/tini", "--", "./server.x86_64"]
