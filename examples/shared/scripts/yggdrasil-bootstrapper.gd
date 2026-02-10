extends Node
## Multi-transport LAN bootstrapper: ENet, Yggdrasil mesh, or WebRTC.
## Transport is selected via a dropdown. Yggdrasil mode includes LAN discovery.
## ENet and WebRTC modes use address:port.

enum Transport { YGGDRASIL, ENET, WEBRTC }

@export_category("UI")
@export var connect_ui: Control
@export var address_input: LineEdit
@export var port_input: LineEdit
@export var port_label: Label
@export var transport_dropdown: OptionButton
@export var discovery_container: Control
@export var server_list: ItemList
@export var scan_button: Button
@export var status_label: Label
@export var poll_rate_input: SpinBox

var _ygg_peer: YggdrasilPeer = null
var _orig_physics_ticks := 0
var _poll_active := false
var _discovered_keys: PackedStringArray = []
var _scanning := false

# WebRTC signaling state
var _sig_server: TCPServer = null
var _sig_clients: Array = []  # [{tcp: StreamPeerTCP, pps: PacketPeerStream, id: int}]
var _sig_tcp: StreamPeerTCP = null  # client-side TCP to signaling server
var _sig_pps: PacketPeerStream = null  # client-side packet peer
var _rtc_mp: WebRTCMultiplayerPeer = null
var _rtc_peers: Dictionary = {}  # peer_id -> WebRTCPeerConnection
var _next_rtc_id := 2
var _webrtc_active := false

func _enter_tree():
	NetworkEvents.on_client_start.connect(func(__): connect_ui.hide())
	NetworkEvents.on_server_start.connect(func(): connect_ui.hide())
	NetworkEvents.on_client_stop.connect(_on_network_stop)
	NetworkEvents.on_server_stop.connect(_on_network_stop)

	if transport_dropdown:
		transport_dropdown.item_selected.connect(_on_transport_changed)
		_on_transport_changed(transport_dropdown.selected)

	if scan_button:
		scan_button.pressed.connect(scan)

	if server_list:
		server_list.item_activated.connect(_on_server_double_clicked)

	set_process(false)
	set_physics_process(false)

func _on_network_stop():
	connect_ui.show()
	_cleanup_webrtc()
	_stop_extra_polling()

# --------------------------------------------------------------------------
# Extra multiplayer polling (boosts physics tick rate for more poll points)
# --------------------------------------------------------------------------
func _start_extra_polling():
	var hz = int(poll_rate_input.value) if poll_rate_input else 0
	if hz > 0:
		_orig_physics_ticks = Engine.physics_ticks_per_second
		Engine.physics_ticks_per_second = hz
		_poll_active = true
		set_physics_process(true)
		print("[Poll] physics_ticks_per_second: %d -> %d" % [_orig_physics_ticks, hz])

func _stop_extra_polling():
	if _poll_active:
		Engine.physics_ticks_per_second = _orig_physics_ticks
		print("[Poll] physics_ticks_per_second restored to %d" % _orig_physics_ticks)
	_poll_active = false
	set_physics_process(false)

func _physics_process(_delta):
	if not _poll_active:
		set_physics_process(false)
		return
	var mp = get_tree().get_multiplayer()
	if mp:
		mp.poll()

func _get_transport() -> int:
	if not transport_dropdown:
		return Transport.YGGDRASIL
	return transport_dropdown.selected

func _on_transport_changed(index: int):
	var is_ygg = (index == Transport.YGGDRASIL)
	var needs_port = (index != Transport.YGGDRASIL)

	if port_input:
		port_input.visible = needs_port
	if port_label:
		port_label.visible = needs_port
	if discovery_container:
		discovery_container.visible = is_ygg
	if server_list:
		server_list.clear()
	if status_label:
		status_label.text = ""
	if address_input:
		if is_ygg:
			address_input.text = ""
			address_input.placeholder_text = "Public key hex (empty = auto-discover)"
		else:
			address_input.text = "localhost"
			address_input.placeholder_text = ""
	if needs_port and port_input:
		port_input.text = "16384"
	_discovered_keys.clear()

# --------------------------------------------------------------------------
# Host
# --------------------------------------------------------------------------
func host():
	match _get_transport():
		Transport.YGGDRASIL: _host_yggdrasil()
		Transport.ENET: _host_enet()
		Transport.WEBRTC: _host_webrtc()

func host_only():
	var brawler_spawner: Node = get_node_or_null("%Brawler Spawner")
	if brawler_spawner != null and "spawn_host_avatar" in brawler_spawner:
		brawler_spawner.spawn_host_avatar = false
	host()

# --------------------------------------------------------------------------
# Join
# --------------------------------------------------------------------------
func join():
	match _get_transport():
		Transport.YGGDRASIL: await _join_yggdrasil()
		Transport.ENET: await _join_enet()
		Transport.WEBRTC: await _join_webrtc()

# --------------------------------------------------------------------------
# Scan (Yggdrasil only)
# --------------------------------------------------------------------------
func scan():
	if _scanning:
		return
	_scanning = true

	if server_list:
		server_list.clear()
	_discovered_keys.clear()

	if status_label:
		status_label.text = "Scanning..."
	if scan_button:
		scan_button.disabled = true

	var found = await YggdrasilDiscovery.find_lan_peers(get_tree())

	if server_list:
		for key in found:
			server_list.add_item(key.substr(0, 16) + "...")
			_discovered_keys.append(key)

	if status_label:
		if found.is_empty():
			status_label.text = "No hosts found"
		else:
			status_label.text = "Found %d host(s)" % found.size()

	if scan_button:
		scan_button.disabled = false
	_scanning = false

func _on_server_double_clicked(index: int):
	if index >= 0 and index < _discovered_keys.size():
		if address_input:
			address_input.text = _discovered_keys[index]
		await _join_yggdrasil_key(_discovered_keys[index])

# --------------------------------------------------------------------------
# ENet (standard LAN)
# --------------------------------------------------------------------------
func _host_enet():
	var parsed = _parse_enet_input()
	if parsed.size() == 0:
		return ERR_CANT_RESOLVE

	var port = parsed.port
	print("Starting host on port %s" % port)

	var peer = ENetMultiplayerPeer.new()
	if peer.create_server(port) != OK:
		print("Failed to listen on port %s" % port)
		return FAILED

	get_tree().get_multiplayer().multiplayer_peer = peer
	print("Listening on port %s" % port)

	await Async.condition(
		func(): return peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTING
	)

	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		OS.alert("Failed to start server!")
		return FAILED

	get_tree().get_multiplayer().server_relay = true
	NetworkTime.start()
	_start_extra_polling()
	return OK

func _join_enet():
	var parsed = _parse_enet_input()
	if parsed.size() == 0:
		return ERR_CANT_RESOLVE

	var address = parsed.address
	var port = parsed.port

	print("Connecting to %s:%s" % [address, port])
	var peer = ENetMultiplayerPeer.new()
	var err = peer.create_client(address, port)
	if err != OK:
		OS.alert("Failed to create client, reason: %s" % error_string(err))
		return err

	get_tree().get_multiplayer().multiplayer_peer = peer

	await Async.condition(
		func(): return peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTING
	)

	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		OS.alert("Failed to connect to %s:%s" % [address, port])
		return ERR_CANT_CONNECT

	print("Client started")
	NetworkTime.start()
	_start_extra_polling()
	return OK

func _parse_enet_input() -> Dictionary:
	var address = address_input.text if address_input else ""
	var port_text = port_input.text if port_input else ""

	if address == "":
		OS.alert("No host specified!")
		return {}
	if not port_text.is_valid_int():
		OS.alert("Invalid port!")
		return {}

	return {"address": address, "port": port_text.to_int()}

# --------------------------------------------------------------------------
# Yggdrasil
# --------------------------------------------------------------------------
func _host_yggdrasil():
	if _ygg_peer != null:
		_ygg_peer.close()

	_ygg_peer = YggdrasilPeer.new()

	var config = '{"MulticastInterfaces":[{"Regex":".*","Beacon":true,"Listen":true,"Port":0,"Priority":0}]}'
	var err = _ygg_peer.create_host(config)
	if err != OK:
		print("[YggBootstrap] Failed to create host: ", error_string(err))
		if status_label:
			status_label.text = "Failed to start host"
		return err

	get_tree().get_multiplayer().multiplayer_peer = _ygg_peer
	get_tree().get_multiplayer().server_relay = true

	var pubkey = _ygg_peer.get_yggdrasil_public_key()
	print("[YggBootstrap] Host started, key: ", pubkey)
	if status_label:
		status_label.text = "Hosting: " + pubkey.substr(0, 16) + "..."

	NetworkTime.start()
	_start_extra_polling()
	return OK

func _join_yggdrasil():
	var identity = address_input.text.strip_edges() if address_input else ""

	# Auto-discover if empty or "localhost"
	if identity == "" or identity == "localhost":
		if status_label:
			status_label.text = "Discovering..."

		var found = await YggdrasilDiscovery.find_lan_peers(get_tree())
		if found.is_empty():
			if status_label:
				status_label.text = "No hosts found"
			return ERR_CANT_RESOLVE

		# Update server list UI
		if server_list:
			server_list.clear()
			_discovered_keys.clear()
			for key in found:
				server_list.add_item(key.substr(0, 16) + "...")
				_discovered_keys.append(key)

		# Try each discovered peer
		for key in found:
			if status_label:
				status_label.text = "Trying " + key.substr(0, 8) + "..."
			var result = await _join_yggdrasil_key(key)
			if result == OK:
				return OK

		if status_label:
			status_label.text = "No game host found"
		return ERR_CANT_CONNECT

	return await _join_yggdrasil_key(identity)

func _join_yggdrasil_key(server_key: String) -> Error:
	if _ygg_peer != null:
		get_tree().get_multiplayer().multiplayer_peer = null
		_ygg_peer.close()

	_ygg_peer = YggdrasilPeer.new()

	var config = '{"MulticastInterfaces":[{"Regex":".*","Beacon":true,"Listen":true,"Port":0,"Priority":0}]}'
	var err = _ygg_peer.create_client(server_key, config)
	if err != OK:
		print("[YggBootstrap] Failed to connect: ", error_string(err))
		if status_label:
			status_label.text = "Failed to connect"
		return err

	get_tree().get_multiplayer().multiplayer_peer = _ygg_peer

	if status_label:
		status_label.text = "Connecting..."

	await Async.condition(
		func(): return not _ygg_peer or _ygg_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTING
	)

	if _ygg_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		print("[YggBootstrap] Connection failed to ", server_key.substr(0, 16))
		get_tree().get_multiplayer().multiplayer_peer = null
		_ygg_peer.close()
		_ygg_peer = null
		if status_label:
			status_label.text = "Connection failed"
		return ERR_CANT_CONNECT

	print("[YggBootstrap] Connected! peer_id=", _ygg_peer.get_unique_id())
	if status_label:
		status_label.text = "Connected (peer " + str(_ygg_peer.get_unique_id()) + ")"

	NetworkTime.start()
	_start_extra_polling()
	return OK

# --------------------------------------------------------------------------
# WebRTC with TCP signaling
# --------------------------------------------------------------------------
func _check_webrtc_available() -> bool:
	if not ClassDB.class_exists("WebRTCLibPeerConnection"):
		OS.alert("WebRTC not available.\nInstall the webrtc-native GDExtension plugin.")
		return false
	return true

func _host_webrtc():
	if not _check_webrtc_available():
		return ERR_UNAVAILABLE
	_cleanup_webrtc()
	var parsed = _parse_enet_input()
	if parsed.size() == 0:
		return ERR_CANT_RESOLVE

	_sig_server = TCPServer.new()
	var err = _sig_server.listen(parsed.port)
	if err != OK:
		print("[WebRTC] Failed to listen on port %d" % parsed.port)
		if status_label:
			status_label.text = "Failed to listen"
		return err

	_rtc_mp = WebRTCMultiplayerPeer.new()
	_rtc_mp.create_server()
	get_tree().get_multiplayer().multiplayer_peer = _rtc_mp
	get_tree().get_multiplayer().server_relay = true

	_webrtc_active = true
	set_process(true)

	print("[WebRTC] Host signaling on port %d" % parsed.port)
	if status_label:
		status_label.text = "WebRTC host (port %d)" % parsed.port

	NetworkTime.start()
	_start_extra_polling()
	return OK

func _join_webrtc():
	if not _check_webrtc_available():
		return ERR_UNAVAILABLE
	_cleanup_webrtc()
	var parsed = _parse_enet_input()
	if parsed.size() == 0:
		return ERR_CANT_RESOLVE

	_sig_tcp = StreamPeerTCP.new()
	var err = _sig_tcp.connect_to_host(parsed.address, parsed.port)
	if err != OK:
		print("[WebRTC] Failed to connect to %s:%d" % [parsed.address, parsed.port])
		if status_label:
			status_label.text = "Failed to connect"
		return err

	_sig_pps = PacketPeerStream.new()
	_sig_pps.stream_peer = _sig_tcp

	if status_label:
		status_label.text = "Connecting..."

	_webrtc_active = true
	set_process(true)

	# Wait for WebRTC data channel to open (status transitions to CONNECTED)
	var timeout := 10.0
	var elapsed := 0.0
	while elapsed < timeout and _webrtc_active:
		await get_tree().create_timer(0.1).timeout
		elapsed += 0.1
		if _rtc_mp and _rtc_mp.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			break

	if not _rtc_mp or _rtc_mp.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		print("[WebRTC] Connection timed out")
		_cleanup_webrtc()
		if status_label:
			status_label.text = "Connection failed"
		return ERR_TIMEOUT

	print("[WebRTC] Connected! peer_id=%d" % _rtc_mp.get_unique_id())
	if status_label:
		status_label.text = "Connected (WebRTC peer %d)" % _rtc_mp.get_unique_id()

	NetworkTime.start()
	_start_extra_polling()
	return OK

func _process(_delta):
	if not _webrtc_active:
		set_process(false)
		return
	_poll_signaling()

func _poll_signaling():
	# Server: accept new TCP clients for signaling
	if _sig_server and _sig_server.is_connection_available():
		_accept_signaling_client()

	# Server: read signaling messages from connected clients
	var i = _sig_clients.size() - 1
	while i >= 0:
		var c = _sig_clients[i]
		c.tcp.poll()
		if c.tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_sig_clients.remove_at(i)
			i -= 1
			continue
		while c.pps.get_available_packet_count() > 0:
			var data = c.pps.get_packet().get_string_from_utf8()
			var msg = JSON.parse_string(data)
			if msg:
				_on_sig_from_client(c.id, msg)
		i -= 1

	# Client: poll TCP and read signaling messages from server
	if _sig_tcp:
		_sig_tcp.poll()
		var status = _sig_tcp.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			while _sig_pps and _sig_pps.get_available_packet_count() > 0:
				var data = _sig_pps.get_packet().get_string_from_utf8()
				var msg = JSON.parse_string(data)
				if msg:
					_on_sig_from_server(msg)
		elif status == StreamPeerTCP.STATUS_ERROR:
			print("[WebRTC] Signaling TCP error")
			_cleanup_webrtc()

func _accept_signaling_client():
	var tcp = _sig_server.take_connection()
	var pps = PacketPeerStream.new()
	pps.stream_peer = tcp

	var peer_id = _next_rtc_id
	_next_rtc_id += 1
	_sig_clients.append({"tcp": tcp, "pps": pps, "id": peer_id})

	# Create WebRTC connection for this client
	var rtc = WebRTCPeerConnection.new()
	rtc.initialize({"iceServers": []})  # No STUN/TURN needed for LAN

	var pid = peer_id  # capture for closures
	rtc.session_description_created.connect(func(type: String, sdp: String):
		rtc.set_local_description(type, sdp)
		_send_to_client(pid, {"type": type, "sdp": sdp})
	)
	rtc.ice_candidate_created.connect(func(media: String, index: int, name: String):
		_send_to_client(pid, {"type": "ice", "media": media, "index": index, "name": name})
	)

	_rtc_peers[peer_id] = rtc
	_rtc_mp.add_peer(rtc, peer_id)

	# Tell client its assigned ID
	_send_to_client(peer_id, {"type": "id", "id": peer_id})

	# Server initiates the offer
	rtc.create_offer()
	print("[WebRTC] New client %d, creating offer" % peer_id)

func _on_sig_from_client(peer_id: int, msg: Dictionary):
	var rtc = _rtc_peers.get(peer_id) as WebRTCPeerConnection
	if not rtc:
		return
	match msg.get("type", ""):
		"answer":
			rtc.set_remote_description("answer", msg.sdp)
		"ice":
			rtc.add_ice_candidate(msg.media, int(msg.index), msg.name)

func _on_sig_from_server(msg: Dictionary):
	match msg.get("type", ""):
		"id":
			var my_id = int(msg.id)
			_rtc_mp = WebRTCMultiplayerPeer.new()
			_rtc_mp.create_client(my_id)
			get_tree().get_multiplayer().multiplayer_peer = _rtc_mp

			# Create connection to server (peer 1)
			var rtc = WebRTCPeerConnection.new()
			rtc.initialize({"iceServers": []})
			rtc.session_description_created.connect(func(type: String, sdp: String):
				rtc.set_local_description(type, sdp)
				_send_to_server({"type": type, "sdp": sdp})
			)
			rtc.ice_candidate_created.connect(func(media: String, index: int, name: String):
				_send_to_server({"type": "ice", "media": media, "index": index, "name": name})
			)

			_rtc_peers[1] = rtc
			_rtc_mp.add_peer(rtc, 1)
			print("[WebRTC] Assigned ID %d, waiting for offer" % my_id)

		"offer":
			# set_remote_description("offer") auto-generates the answer
			# and emits session_description_created("answer", sdp)
			var rtc = _rtc_peers.get(1) as WebRTCPeerConnection
			if rtc:
				rtc.set_remote_description("offer", msg.sdp)

		"answer":
			var rtc = _rtc_peers.get(1) as WebRTCPeerConnection
			if rtc:
				rtc.set_remote_description("answer", msg.sdp)

		"ice":
			var rtc = _rtc_peers.get(1) as WebRTCPeerConnection
			if rtc:
				rtc.add_ice_candidate(msg.media, int(msg.index), msg.name)

func _send_to_client(peer_id: int, msg: Dictionary):
	for c in _sig_clients:
		if c.id == peer_id:
			c.pps.put_packet(JSON.stringify(msg).to_utf8_buffer())
			return

func _send_to_server(msg: Dictionary):
	if _sig_pps:
		_sig_pps.put_packet(JSON.stringify(msg).to_utf8_buffer())

func _cleanup_webrtc():
	_webrtc_active = false
	set_process(false)
	for rtc in _rtc_peers.values():
		if rtc:
			rtc.close()
	_rtc_peers.clear()
	_sig_clients.clear()
	_sig_server = null
	_sig_tcp = null
	_sig_pps = null
	if _rtc_mp:
		get_tree().get_multiplayer().multiplayer_peer = null
		_rtc_mp = null
	_next_rtc_id = 2

# --------------------------------------------------------------------------
# Cleanup
# --------------------------------------------------------------------------
func _exit_tree():
	_stop_extra_polling()
	_cleanup_webrtc()
	if _ygg_peer != null:
		get_tree().get_multiplayer().multiplayer_peer = null
		_ygg_peer.close()
		_ygg_peer = null
