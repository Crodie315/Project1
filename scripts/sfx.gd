extends Node
## Loaded in main.gd as SfxPlayer (preload), so it works without a global class name.
## Sound effects and background music made in code (no audio files needed):
## short synth blips, noise bursts and a looping chord track.
## play("jump") etc. M toggles all sound.

const RATE := 22050
const MUSIC_RATE := 16000
const MUSIC_DB := -14.0

## name: [wave, start Hz, end Hz, seconds, volume]
## wave: sine, square, saw, noise, or arp (4 rising/falling notes from start to end Hz)
const DEFS := {
	"jump": ["square", 300.0, 640.0, 0.12, 0.18],
	"land": ["noise", 0.0, 0.0, 0.07, 0.25],
	"hit": ["noise", 0.0, 0.0, 0.12, 0.55],
	"stomp": ["square", 240.0, 60.0, 0.22, 0.32],
	"ko": ["square", 700.0, 110.0, 0.3, 0.25],
	"open": ["sine", 500.0, 1000.0, 0.16, 0.4],
	"part": ["arp", 523.0, 1046.0, 0.32, 0.22],
	"weapon": ["arp", 330.0, 1320.0, 0.36, 0.22],
	"pickup": ["arp", 660.0, 1320.0, 0.26, 0.25],
	"laser": ["saw", 1700.0, 300.0, 0.16, 0.2],
	"flame": ["noise", 0.0, 0.0, 0.32, 0.4],
	"hurt": ["saw", 320.0, 90.0, 0.25, 0.3],
	"windup": ["sine", 110.0, 330.0, 0.55, 0.3],
	"boss_grab": ["arp", 400.0, 200.0, 0.3, 0.2],
	"win": ["arp", 392.0, 1568.0, 0.9, 0.25],
	"lose": ["arp", 392.0, 98.0, 0.9, 0.25],
	"click": ["sine", 900.0, 900.0, 0.04, 0.25],
}

var sounds := {}
var players: Array[AudioStreamPlayer] = []
var next_player := 0
var music: AudioStreamPlayer
var muted := false


func _ready() -> void:
	for sound_name in DEFS:
		sounds[sound_name] = _make(DEFS[sound_name])
	for i in 10:
		var p := AudioStreamPlayer.new()
		add_child(p)
		players.append(p)
	music = AudioStreamPlayer.new()
	music.stream = _make_music()
	music.volume_db = MUSIC_DB
	add_child(music)
	music.play()


func play(sound_name: String, pitch_jitter: float = 0.08, volume_db: float = 0.0) -> void:
	if muted or not sounds.has(sound_name):
		return
	var p := players[next_player]
	next_player = (next_player + 1) % players.size()
	p.stream = sounds[sound_name]
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.volume_db = volume_db
	p.play()


func toggle_mute() -> bool:
	muted = not muted
	music.stream_paused = muted
	return muted


func _make(def: Array) -> AudioStreamWAV:
	var wave: String = def[0]
	var f0 := float(def[1])
	var f1 := float(def[2])
	var dur := float(def[3])
	var vol := float(def[4])
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var noise := RandomNumberGenerator.new()
	noise.seed = 1234
	var phase := 0.0
	var smooth := 0.0
	for i in n:
		var t := float(i) / float(n)
		var f := lerpf(f0, f1, t)
		if wave == "arp":
			f = f0 * pow(f1 / f0, floorf(t * 4.0) / 3.0)
		phase += f / RATE
		var s := 0.0
		match wave:
			"sine":
				s = sin(TAU * phase)
			"square":
				s = 1.0 if fmod(phase, 1.0) < 0.5 else -1.0
			"arp":
				s = 0.6 * (1.0 if fmod(phase, 1.0) < 0.5 else -1.0) + 0.4 * sin(TAU * phase)
			"saw":
				s = 2.0 * fmod(phase, 1.0) - 1.0
			"noise":
				smooth += (noise.randf_range(-1.0, 1.0) - smooth) * 0.35
				s = smooth * 1.8
		var attack := minf(1.0, float(i) / (RATE * 0.005))
		var env := pow(1.0 - t, 1.6) * attack
		data.encode_s16(i * 2, int(clampf(s * env * vol, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = data
	return wav


## An 8-second loop: Am - F - C - G pads, a pulsing bass and a soft arpeggio.
func _make_music() -> AudioStreamWAV:
	var chords := [
		[220.0, 261.63, 329.63],
		[174.61, 220.0, 261.63],
		[261.63, 329.63, 392.0],
		[196.0, 246.94, 293.66],
	]
	var chord_len := 2.0
	var n := int(MUSIC_RATE * chord_len * 4.0)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := float(i) / MUSIC_RATE
		var chord: Array = chords[int(t / chord_len) % 4]
		var ct := fmod(t, chord_len)
		var pad_env := minf(1.0, ct / 0.4) * minf(1.0, (chord_len - ct) / 0.4)
		var s := 0.0
		for f in chord:
			s += sin(TAU * float(f) * t) * 0.11 * pad_env
		var beat := fmod(t, 0.25)
		var beat_env := exp(-beat * 9.0) * (1.0 - beat / 0.25)
		s += sin(TAU * float(chord[0]) * 0.5 * t) * 0.28 * beat_env
		var af := float(chord[int(t / 0.25) % 3]) * 2.0
		s += (2.0 * absf(2.0 * fmod(af * t, 1.0) - 1.0) - 1.0) * 0.07 * beat_env
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MUSIC_RATE
	wav.stereo = false
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = n
	return wav
