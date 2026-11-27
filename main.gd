extends Control
## Diagnostic screen for the iPhone offline-PWA test.
##
## Each line on screen answers one question the airplane-mode test asks:
## is the network really off, did the app launch from the Home Screen, is
## the service worker (the offline cache) in control, do saves survive a
## relaunch, does audio play after a tap, and is the frame rate sane.

# Bump this on every export. It is shown on screen so you can tell whether
# the phone is running the build you just deployed or an older cached one --
# the classic PWA failure is a service worker serving yesterday's files.
const BUILD := 7
const SAVE_PATH := "user://save.cfg"

# Build 2 diagnostics. Build 1 only asked "is a service worker controlling
# this page?", which read "no" on the phone even after four real relaunches --
# an inference, not a fact. This asks the browser directly: is a worker
# registered and in what state, does calling register() succeed (and if not,
# with what error), and which files are actually sitting in the offline cache.
#
# Those browser APIs are asynchronous (they return Promises), but
# JavaScriptBridge.eval returns immediately. So the script stores its answers
# in window.__pwaDiag as they arrive, and _refresh() reads them back later.
# Plain ES5-style JS and no backslashes, so GDScript's string escaping
# cannot mangle it.
const DIAG_JS := """
(function () {
	var d = window.__pwaDiag = {reg: 'checking...', register: 'checking...', cache: 'checking...'};
	var m = navigator.userAgent.match(/OS [0-9_]+/);
	d.ios = m ? m[0].replace(/_/g, '.') : 'unknown';
	if (!('serviceWorker' in navigator)) {
		d.reg = 'API missing';
		d.register = 'API missing';
	} else {
		// Re-queried every few seconds by _refresh(), so a new build being
		// downloaded in the background shows up without a relaunch.
		window.__pwaPoll = function () {
			navigator.serviceWorker.getRegistration().then(function (r) {
				if (!r) { d.reg = 'none'; d.waiting = false; return; }
				var s = [];
				if (r.active) { s.push('active'); }
				if (r.waiting) { s.push('waiting'); }
				if (r.installing) { s.push('installing'); }
				d.reg = (s.join('+') || 'no worker') + ' @ ' + r.scope;
				d.waiting = !!r.waiting;
			}).catch(function (e) { d.reg = 'error: ' + e; });
		};
		// Build 4: the update path Godot's worker lacks. Its worker is
		// cache-first, and a newly downloaded worker sits "waiting" until every
		// page it would take over has closed -- which iOS Home Screen apps never
		// seemed to satisfy, leaving the phone on build 2 indefinitely. The
		// worker does accept an 'update' message (skipWaiting + claim + reload),
		// so the page sends it when the player taps the update button.
		window.__pwaApplyUpdate = function () {
			d.updateRequested = true;
			navigator.serviceWorker.getRegistration().then(function (r) {
				if (r && r.waiting) {
					r.waiting.postMessage('update');
				} else {
					// Build 7: the patched worker activates by itself, so usually
					// nothing is waiting -- the new version is already in charge
					// and a plain reload loads the new build through it.
					window.location.reload();
				}
			});
		};
		// Fallback reload. Godot's worker reloads pages via
		// WindowClient.navigate(), whose iOS support is unverified; this fires
		// when the new worker takes control and reloads the page ourselves.
		// Gated on updateRequested so it can never cause a reload loop.
		navigator.serviceWorker.addEventListener('controllerchange', function () {
			if (d.updateRequested) { window.location.reload(); }
		});
		navigator.serviceWorker.register('index.service.worker.js').then(function (r) {
			d.register = 'ok';
			// Build 7: since the patched worker skips the waiting stage, watch
			// for a new version arriving and finishing activation during this
			// session -- that is when "new build ready" becomes true.
			r.addEventListener('updatefound', function () {
				var nw = r.installing;
				if (!nw) { return; }
				nw.addEventListener('statechange', function () {
					if (nw.state === 'activated') { d.updateReady = true; }
				});
			});
			// Ask the browser to look for a newer worker right now instead of
			// whenever it gets round to it. Fails harmlessly when offline.
			return r.update();
		}).catch(function (e) { d.register = 'FAILED: ' + e; });
		window.__pwaPoll();
	}
	if (!('caches' in window)) {
		d.cache = 'API missing';
	} else {
		caches.keys().then(function (keys) {
			return Promise.all(keys.map(function (k) {
				return caches.open(k).then(function (c) { return c.keys(); }).then(function (reqs) {
					// Lead with the cache's version stamp (the part after
					// "cache-"): it changes with every export, so it shows
					// WHICH build's worker filled this cache.
					return '[' + k.split('cache-').pop() + '] ' +
						reqs.map(function (q) { return q.url.split('/').pop(); }).join(', ');
				});
			}));
		}).then(function (lists) {
			d.cache = lists.length ? lists.join(' | ') : 'empty';
		}).catch(function (e) { d.cache = 'error: ' + e; });
	}
})();
"""

var _launches := 0
var _taps := 0
var _status: Label
var _counts: Label
var _fps: Label
var _spinner: ColorRect
var _beep: AudioStreamPlayer
var _update_btn: Button


func _ready() -> void:
	var t := Theme.new()
	t.default_font_size = 28  # smaller than build 1: the cache listing is long
	theme = t

	if OS.has_feature("web"):
		JavaScriptBridge.eval(DIAG_JS, true)
		# Refresh every 3 s: the Promises above settle a moment after launch,
		# and a background update download can finish at any time.
		var poll := Timer.new()
		poll.wait_time = 3.0
		poll.autostart = true
		poll.timeout.connect(_refresh)
		add_child(poll)

	# Count this launch and save immediately. If the number keeps climbing
	# across relaunches -- including offline ones -- saves are persisting.
	_load()
	_launches += 1
	_save()

	_build_ui()
	_beep = AudioStreamPlayer.new()
	_beep.stream = _make_beep()
	add_child(_beep)
	_refresh()


func _process(delta: float) -> void:
	# Something always moving, so a stutter or a low frame rate is visible
	# at a glance rather than only as a number.
	_spinner.rotation += delta * 2.0
	_fps.text = "FPS: %d" % Engine.get_frames_per_second()


func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Large top margin: launched from the Home Screen, the page runs up under
	# the status bar / Dynamic Island. Hard-coded here rather than read from
	# iOS's safe-area insets -- whether text collides with the notch is one
	# of the things this test is meant to show.
	margin.add_theme_constant_override("margin_left", 40)
	margin.add_theme_constant_override("margin_right", 40)
	margin.add_theme_constant_override("margin_top", 140)
	margin.add_theme_constant_override("margin_bottom", 80)
	add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 24)
	margin.add_child(box)

	var title := Label.new()
	title.text = "iPhone PWA test  (build %d)" % BUILD
	title.add_theme_font_size_override("font_size", 44)
	box.add_child(title)

	# Hidden until a newer build has downloaded and is waiting. A button rather
	# than an automatic reload, because in a real game a reload mid-play would
	# throw away whatever the player was doing.
	_update_btn = Button.new()
	_update_btn.text = "New build ready - tap to load"
	_update_btn.custom_minimum_size = Vector2(0, 120)
	_update_btn.visible = false
	_update_btn.pressed.connect(func() -> void: JavaScriptBridge.eval("window.__pwaApplyUpdate && window.__pwaApplyUpdate()", true))
	box.add_child(_update_btn)

	# Build 6 layout: everything fixed-size goes at the TOP, and the status
	# text -- which grew with every build until it pushed the buttons off the
	# bottom of the phone -- goes last, in a ScrollContainer that takes only
	# the space left over. More lines now means more scrolling, never lost
	# buttons.
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 20)
	box.add_child(buttons)

	var tap := Button.new()
	tap.text = "Tap: count + beep"
	tap.custom_minimum_size = Vector2(0, 120)
	tap.size_flags_horizontal = Control.SIZE_EXPAND_FILL  # share the row evenly
	tap.pressed.connect(_on_tap)
	buttons.add_child(tap)

	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.custom_minimum_size = Vector2(0, 120)
	refresh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	refresh.pressed.connect(_refresh)
	buttons.add_child(refresh)

	var stats := HBoxContainer.new()
	stats.add_theme_constant_override("separation", 30)
	box.add_child(stats)

	_counts = Label.new()
	stats.add_child(_counts)

	_fps = Label.new()
	stats.add_child(_fps)

	# The spinner sits in a plain Control, not directly in the HBox: a
	# container repositions its children every layout pass, which would
	# fight the rotation. The plain Control just reserves the space.
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(60, 60)
	stats.add_child(holder)
	_spinner = ColorRect.new()
	_spinner.color = Color("e9c46a")
	_spinner.size = Vector2(44, 44)
	_spinner.pivot_offset = Vector2(22, 22)  # rotate about the centre, not the corner
	_spinner.position = Vector2(8, 8)
	holder.add_child(_spinner)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL  # take whatever height is left
	# No sideways scrolling: this forces the label to the container's width,
	# which is what lets its word-wrap work. Drag up/down to scroll.
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_status)


func _refresh() -> void:
	var lines := PackedStringArray()
	if OS.has_feature("web"):
		# navigator.onLine is the browser's own view of connectivity. In
		# airplane mode it should read OFFLINE -- which proves the game you
		# are looking at came from the phone's cache, not the network.
		lines.append("Network: " + ("ONLINE" if _js_bool("navigator.onLine") else "OFFLINE"))
		# navigator.standalone is Safari's own flag for "opened from the Home
		# Screen"; the media query is the cross-browser equivalent.
		lines.append("From Home Screen: " + _yes_no(_js_bool(
			"navigator.standalone === true || matchMedia('(display-mode: standalone)').matches || matchMedia('(display-mode: fullscreen)').matches")))
		# The service worker is the piece that serves cached files offline.
		# It only takes control from the SECOND load onward, so "no" on the
		# very first visit is expected.
		lines.append("Worker controls page: " + _yes_no(_js_bool(
			"!!(navigator.serviceWorker && navigator.serviceWorker.controller)")))
		# Confirms or refutes the _js_bool() diagnosis: what Godot type does a
		# plain JS `true` arrive as? "bool" would mean the build 1-2 bug lay
		# elsewhere.
		var probe: Variant = JavaScriptBridge.eval("true", true)
		lines.append("JS true arrives as: %s (%s)" % [type_string(typeof(probe)), str(probe)])
		# Kick off a fresh registration query; its answer lands in
		# window.__pwaDiag in a moment, so this refresh shows the previous
		# poll's result and the next one shows this one's. Fine at 3 s.
		JavaScriptBridge.eval("window.__pwaPoll && window.__pwaPoll()", true)
		var d := _diag()
		_update_btn.visible = d.get("waiting", false) == true or d.get("updateReady", false) == true
		lines.append("iOS: " + str(d.get("ios", "?")))
		lines.append("Worker registration: " + str(d.get("reg", "?")))
		lines.append("register() call: " + str(d.get("register", "?")))
		var cache_s := str(d.get("cache", "?"))
		# index.wasm is the 37 MB engine; without it in the cache, an offline
		# launch can only show Godot's "you need a connection" page.
		lines.append("ENGINE FILE CACHED: " + _yes_no(cache_s.contains("index.wasm")))
		lines.append("Cache: " + cache_s)
	else:
		lines.append("Desktop run -- browser checks skipped")
	lines.append("Saves persistent: " + _yes_no(OS.is_userfs_persistent()))
	lines.append("GPU: " + RenderingServer.get_video_adapter_name())
	lines.append("Viewport: %dx%d" % [int(get_viewport_rect().size.x), int(get_viewport_rect().size.y)])
	_status.text = "\n".join(lines)
	_update_counts()


func _on_tap() -> void:
	_taps += 1
	_save()
	_update_counts()
	# Safari blocks audio until the page receives a user gesture. If the
	# very first tap beeps, Godot's audio unlock works on this phone.
	_beep.play()


func _update_counts() -> void:
	_counts.text = "Launches: %d     Taps: %d" % [_launches, _taps]


func _js_bool(expr: String) -> bool:
	# Builds 1-2 returned the JS boolean directly and checked `r is bool`. On
	# the phone every line that went through here read false -- "Network:
	# OFFLINE" while on Wi-Fi -- even though the worker was provably active,
	# while every STRING result (the build 2 diagnostics) came through fine.
	# Suspected cause: the bridge does not hand JS booleans back as a GDScript
	# bool, so `is bool` always failed. Rather than depend on that conversion,
	# make JS produce the text "true"/"false" and compare the text: strings
	# are the path already shown to work on this phone.
	var r: Variant = JavaScriptBridge.eval("String(!!(" + expr + "))", true)
	return r is String and r == "true"


func _diag() -> Dictionary:
	# window.__pwaDiag comes back as a JSON string; anything unexpected
	# (script not run yet, parse failure) yields an empty Dictionary, which
	# displays as "?" rather than crashing.
	var raw: Variant = JavaScriptBridge.eval("JSON.stringify(window.__pwaDiag || {})", true)
	if raw is String:
		var parsed: Variant = JSON.parse_string(raw)
		if parsed is Dictionary:
			return parsed
	return {}


func _yes_no(b: bool) -> String:
	return "yes" if b else "no"


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		_launches = cfg.get_value("stats", "launches", 0)
		_taps = cfg.get_value("stats", "taps", 0)


func _save() -> void:
	# On the web, user:// is backed by the browser's IndexedDB storage.
	var cfg := ConfigFile.new()
	cfg.set_value("stats", "launches", _launches)
	cfg.set_value("stats", "taps", _taps)
	cfg.save(SAVE_PATH)


func _make_beep() -> AudioStreamWAV:
	# Synthesize a 0.15 s, 880 Hz tone in code so the test needs no audio
	# file. 16-bit mono PCM: two bytes per sample.
	var rate := 44100
	var n := int(rate * 0.15)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var env := 1.0 - float(i) / n  # linear fade-out avoids a click at the end
		var s := int(sin(TAU * 880.0 * i / rate) * 0.5 * env * 32767.0)
		data.encode_s16(i * 2, s)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	return w
