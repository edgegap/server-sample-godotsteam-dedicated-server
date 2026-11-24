extends Node
## One autoload for both sides of the connection.
## Server (dedicated_server export or `-- --server`): ENet on GAME_PORT, logged on to Steam
## with GodotSteam Server, and every player must pass a Steam auth ticket check.
## Client (GodotSteam): connects with ENet, then sends a Steam auth ticket to the server.
## Uses Engine.get_singleton() so the script parses in exports that ship only one of the two add-ons.

const STEAM_APP_ID := 480            # Spacewar, Valve's test app. Use your own App ID.
const SERVER_VERSION := "1.0.0.0"    # x.x.x.x; Steam only lists servers on the latest version.
const GAME_PORT := 7777              # ENet, UDP. Edgegap port "gameport".
const QUERY_PORT := 27015            # Steam queries, UDP. Edgegap port "queryport" (optional).
                                     # This is the INTERNAL port: Steam binds it and also advertises
                                     # it as-is, so on Edgegap the server browser pings 27015 and times
                                     # out. Test A2S against the external "queryport" instead.
const MAX_PLAYERS := 8
const AUTH_TIMEOUT_SEC := 15.0       # Kick peers that don't send a valid ticket in time.
const NO_PLAYER_TIMEOUT_SEC := 120.0 # Stop the deployment if nobody joins.

# SteamServer.ServerMode and the BeginAuthSession / AuthSession results we check.
const SERVER_MODE_AUTHENTICATION := 2
const BEGIN_AUTH_RESULT_OK := 0
const AUTH_SESSION_RESPONSE_OK := 0

var steam_server: Object  # SteamServer singleton, server only
var steam: Object         # Steam singleton, client only
var server_steam_id := 0
var players := {}         # peer_id -> steam_id, authenticated players
var pending := {}         # peer_id -> {"steam_id": int, "deadline": float}
var had_players := false
var stopping := false


func _ready() -> void:
	if is_server_launch():
		_start_server()
	else:
		_start_client()


func _process(_delta: float) -> void:
	# Steam callbacks (signals) only fire when this is called.
	if steam_server:
		steam_server.run_callbacks()
	if steam:
		steam.run_callbacks()
	if multiplayer.is_server() and steam_server:
		_check_timeouts()


static func is_server_launch() -> bool:
	return OS.has_feature("dedicated_server") or "--server" in OS.get_cmdline_user_args()


# ---------------------------------------------------------------- server

func _start_server() -> void:
	steam_server = Engine.get_singleton("SteamServer")
	if steam_server == null:
		_fail("GodotSteam Server add-on not loaded")
		return

	# Edgegap maps internal ports to random external ones. Steam advertises the game port we
	# pass here, so give it the external port players actually connect to.
	var advertised_port := int(_env("ARBITRIUM_PORT_GAMEPORT_EXTERNAL", str(GAME_PORT)))
	# The query port can't get the same treatment: Steam uses one number both to bind its
	# query socket and to advertise it, and only the internal port is bound in the container.
	var init: Dictionary = steam_server.serverInitEx("0.0.0.0", advertised_port, QUERY_PORT,
			SERVER_MODE_AUTHENTICATION, SERVER_VERSION)
	if init.get("status", -1) != 0:
		_fail("serverInitEx failed: %s" % init)
		return
	# Log both query ports so the mismatch with what Steam advertises is visible.
	var query_port_external := _env("ARBITRIUM_PORT_QUERYPORT_EXTERNAL", "none")
	print("STEAM init ok game_port=%d query_port internal=%d external=%s" % [advertised_port, QUERY_PORT, query_port_external])

	steam_server.server_connected.connect(_on_steam_connected)
	steam_server.server_connect_failure.connect(_on_steam_connect_failure)
	steam_server.server_disconnected.connect(_on_steam_disconnected)
	steam_server.validate_auth_ticket_response.connect(_on_validate_auth_ticket_response)

	# These must be set before logging on.
	steam_server.setModDir("spacewar")        # Your game's folder name on Steam.
	steam_server.setProduct(str(STEAM_APP_ID))
	steam_server.setGameDescription("GodotSteam Server on Edgegap")
	steam_server.setDedicatedServer(true)
	steam_server.setMaxPlayerCount(MAX_PLAYERS)
	steam_server.setServerName("Edgegap %s" % _env("ARBITRIUM_REQUEST_ID", "local"))
	steam_server.setMapName("arena")

	var gslt := _env("STEAM_GSLT", "")
	if gslt.is_empty():
		steam_server.logOnAnonymous()
	else:
		steam_server.logOn(gslt)  # Persistent Steam ID, needs a Game Server Login Token.
	steam_server.setAdvertiseServerActive(true)

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(GAME_PORT, MAX_PLAYERS)
	if err != OK:
		_fail("ENet create_server failed: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("SERVER listening udp=%d request_id=%s" % [GAME_PORT, _env("ARBITRIUM_REQUEST_ID", "-")])
	get_tree().create_timer(NO_PLAYER_TIMEOUT_SEC).timeout.connect(func():
		if not had_players:
			_stop_server("nobody joined"))


func _on_steam_connected() -> void:
	server_steam_id = steam_server.getSteamID()
	var ip: Dictionary = steam_server.getPublicIP()
	print("STEAM logged on steam_id=%d public_ip=%s secure=%s" % [server_steam_id,
			_ip_to_string(ip.get("ipv4", 0)), steam_server.isServerSecure()])


func _on_steam_connect_failure(result: int, retrying: bool) -> void:
	print("STEAM connect failure result=%d retrying=%s" % [result, retrying])


func _on_steam_disconnected(result: int) -> void:
	print("STEAM disconnected result=%d" % result)


func _on_peer_connected(peer_id: int) -> void:
	pending[peer_id] = {"steam_id": 0, "deadline": Time.get_ticks_msec() / 1000.0 + AUTH_TIMEOUT_SEC}
	print("PEER connected peer=%d, waiting for Steam ticket" % peer_id)
	# Tell the client who we are: it binds its ticket to this server's Steam ID.
	server_hello.rpc_id(peer_id, server_steam_id)


func _on_peer_disconnected(peer_id: int) -> void:
	pending.erase(peer_id)
	if players.has(peer_id):
		steam_server.endAuthSession(players[peer_id])
		players.erase(peer_id)
	print("PEER left peer=%d players=%d" % [peer_id, players.size()])
	if had_players and players.is_empty() and pending.is_empty():
		_stop_server("everyone left")


@rpc("any_peer", "reliable")
func submit_ticket(ticket: PackedByteArray, steam_id: int) -> void:
	if not multiplayer.is_server():
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not pending.has(peer_id):
		return
	var result: int = steam_server.beginAuthSession(ticket, ticket.size(), steam_id)
	print("AUTH begin peer=%d steam_id=%d result=%d" % [peer_id, steam_id, result])
	if result != BEGIN_AUTH_RESULT_OK:
		_kick(peer_id, "ticket rejected (%d)" % result)
		return
	pending[peer_id]["steam_id"] = steam_id
	# Steam answers with validate_auth_ticket_response a moment later.


func _on_validate_auth_ticket_response(steam_id: int, response: int, owner_id: int) -> void:
	for peer_id in pending.keys():
		if pending[peer_id]["steam_id"] != steam_id:
			continue
		pending.erase(peer_id)
		if response != AUTH_SESSION_RESPONSE_OK:
			steam_server.endAuthSession(steam_id)
			_kick(peer_id, "Steam auth failed (%d)" % response)
			return
		players[peer_id] = steam_id
		had_players = true
		print("AUTH ok peer=%d steam_id=%d owner=%d players=%d" % [peer_id, steam_id, owner_id, players.size()])
		welcome.rpc_id(peer_id, players.size())
		return
	# A response for a player already in the game means Steam ended their session (ban, logged in elsewhere).
	for peer_id in players.keys():
		if players[peer_id] == steam_id and response != AUTH_SESSION_RESPONSE_OK:
			_kick(peer_id, "Steam session ended (%d)" % response)


func _check_timeouts() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for peer_id in pending.keys():
		if now > pending[peer_id]["deadline"]:
			_kick(peer_id, "no Steam ticket")


func _kick(peer_id: int, reason: String) -> void:
	print("KICK peer=%d reason=%s" % [peer_id, reason])
	pending.erase(peer_id)
	multiplayer.multiplayer_peer.disconnect_peer(peer_id)


func _stop_server(reason: String) -> void:
	if stopping:
		return
	stopping = true
	print("SERVER stopping reason=%s" % reason)
	steam_server.setAdvertiseServerActive(false)
	steam_server.logOff()
	steam_server.serverShutdown()
	var url := _env("ARBITRIUM_DELETE_URL", "")
	if url.is_empty():
		get_tree().quit()
		return
	# Edgegap: delete our own deployment so it stops billing.
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(result, code, _h, _b):
		print("SERVER self_stop result=%d http=%d" % [result, code])
		get_tree().quit())
	http.request(url, ["authorization: " + _env("ARBITRIUM_DELETE_TOKEN", "")], HTTPClient.METHOD_DELETE)


# ---------------------------------------------------------------- client

func _start_client() -> void:
	steam = Engine.get_singleton("Steam")
	if steam == null:
		_fail("GodotSteam add-on not loaded")
		return
	var init: Dictionary = steam.steamInitEx(STEAM_APP_ID)
	if init.get("status", -1) != 0:
		_fail("Steam init failed, is Steam running and logged in? %s" % init)
		return
	print("CLIENT steam_id=%d name=%s" % [steam.getSteamID(), steam.getPersonaName()])

	var address := _arg("connect", "127.0.0.1:%d" % GAME_PORT)
	var host := address.get_slice(":", 0)
	var port := int(address.get_slice(":", 1))
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		_fail("ENet create_client failed: %s" % error_string(err))
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.connection_failed.connect(func(): _fail("could not reach %s" % address))
	multiplayer.server_disconnected.connect(func(): _status("Disconnected by server"))
	_status("Connecting to %s..." % address)


@rpc("authority", "reliable")
func server_hello(steam_id_of_server: int) -> void:
	# A ticket bound to this server's Steam ID can't be replayed against another server.
	var ticket: Dictionary = steam.getAuthSessionTicket(steam_id_of_server)
	var bytes: PackedByteArray = ticket["buffer"].slice(0, ticket["size"])
	# Steam needs a moment to register the ticket: send it once Steam confirms.
	while true:
		var response: Array = await steam.get_auth_session_ticket_response
		if response[0] == ticket["id"]:
			if response[1] != 1:  # Steam Result OK
				_fail("Steam could not issue a ticket (result %d)" % response[1])
				return
			break
	_status("Connected, sending Steam ticket (%d bytes) to server %d" % [bytes.size(), steam_id_of_server])
	submit_ticket.rpc_id(1, bytes, steam.getSteamID())


@rpc("authority", "reliable")
func welcome(player_count: int) -> void:
	_status("AUTHENTICATED by Steam, %d player(s) on the server" % player_count)
	if "--quit-after-auth" in OS.get_cmdline_user_args():
		await get_tree().create_timer(2.0).timeout
		get_tree().quit()


# ---------------------------------------------------------------- helpers

func _status(text: String) -> void:
	print("CLIENT " + text)
	var label := get_tree().current_scene as Label
	if label:
		label.text = text


func _fail(text: String) -> void:
	push_error(text)
	print("ERROR " + text)
	if is_server_launch():
		get_tree().quit(1)
	else:
		_status(text)


static func _env(key: String, default: String) -> String:
	var value := OS.get_environment(key)
	return default if value.is_empty() else value


static func _arg(key: String, default: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % key):
			return a.get_slice("=", 1)
	return default


static func _ip_to_string(ip: int) -> String:
	return "%d.%d.%d.%d" % [(ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255]
