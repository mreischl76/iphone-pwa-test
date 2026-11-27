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
const BUILD := 2
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
		navigator.serviceWorker.getRegistration().then(function (r) {
			if (!r) { d.reg = 'none'; return; }
			var s = [];
			if (r.active) { s.push('active'); }
			if (r.waiting) { s.push('waiting'); }
			if (r.installing) { s.push('installing'); }
			d.reg = (s.join('+') || 'no worker') + ' @ ' + r.scope;
		}).catch(function (e) { d.reg = 'error: ' + e; });
		navigator.serviceWorker.register('index.service.worker.js').then(function () {
			d.register = 'ok';
		}).catch(function (e) { d.register = 'FAILED: ' + e; });
	}
	if (!('caches' in window)) {
		d.cache = 'API missing';
	} else {
		caches.keys().then(function (keys) {
			return Promise.all(keys.map(function (k) {
				return caches.open(k).then(function (c) { return c.keys(); }).then(function (reqs) {
					return reqs.map(function (q) { return q.url.split('/').pop(); }).join(', ');
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


func _ready() -> void:
	var t := Theme.new()
	t.default_font_size = 28  # smaller than build 1: the cache listing is long
	theme = t

	if OS.has_feature("web"):
		JavaScriptBridge.eval(DIAG_JS, true)
		# The Promises above usually settle within a second; refresh twice so
		# the answers appear without needing the Refresh button.
		get_tree().create_timer(1.5).timeout.connect(_refresh)
		get_tree().create_timer(5.0).timeout.connect(_refresh)

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

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	_counts = Label.new()
	box.add_child(_counts)

	_fps = Label.new()
	box.add_child(_fps)

	# The spinner sits in a plain Control, not directly in the VBox: a
	# container repositions its children every layout pass, which would
	# fight the rotation. The plain Control just reserves the space.
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(0, 160)
	box.add_child(holder)
	_spinner = ColorRect.new()
	_spinner.color = Color("e9c46a")
	_spinner.size = Vector2(100, 100)
	_spinner.pivot_offset = Vector2(50, 50)  # rotate about the centre, not the corner
	_spinner.position = Vector2(30, 30)
	holder.add_child(_spinner)

	var tap := Button.new()
	tap.text = "Tap: count + beep"
	tap.custom_minimum_size = Vector2(0, 140)
	tap.pressed.connect(_on_tap)
	box.add_child(tap)

	var refresh := Button.new()
	refresh.text = "Refresh status"
	refresh.custom_minimum_size = Vector2(0, 110)
	refresh.pressed.connect(_refresh)
	box.add_child(refresh)


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
		var d := _diag()
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
	# eval returns a Variant: a JS boolean arrives as a GDScript bool, and a
	# failed expression arrives as null. Checking the type first means a
	# broken expression reads as "no" instead of crashing the comparison.
	var r: Variant = JavaScriptBridge.eval(expr, true)
	return r is bool and r


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
