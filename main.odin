package main

import "core:c"
import "core:c/libc"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"
import glfw "vendor:glfw"
import xlib "vendor:x11/xlib"

// ---------------------------------------------------------------------------
// libc foreign
// ---------------------------------------------------------------------------

foreign import clib "system:c"
foreign import x11lib "system:X11"

Pollfd :: struct {
	fd:      c.int,
	events:  c.short,
	revents: c.short,
}

POLLIN :: c.short(1)

@(default_calling_convention = "c")
foreign clib {
	popen :: proc(command: cstring, mode: cstring) -> ^libc.FILE ---
	pclose :: proc(stream: ^libc.FILE) -> c.int ---
	fileno :: proc(stream: ^libc.FILE) -> c.int ---
	poll :: proc(fds: ^Pollfd, nfds: c.ulong, timeout: c.int) -> c.int ---
}

@(default_calling_convention = "c")
foreign x11lib {
	XkbLockGroup :: proc(display: ^xlib.Display, device_spec: c.uint, group: c.uint) -> c.int ---
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

BAR_HEIGHT :: 30
FONT_SIZE :: 18
FONT_SPACING :: f32(1)
PAD :: 14

TITLE_MAX_W :: 300
TITLE_SCROLL_SPEED :: f32(40)
TITLE_GAP :: f32(80)

FONT_PATH :: "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf"

// Catppuccin Mocha
BG :: rl.Color{30, 30, 46, 216} // 0.85 opacity
FG :: rl.Color{205, 214, 244, 255}
FG_DIM :: rl.Color{108, 112, 134, 255}
ACCENT :: rl.Color{137, 180, 250, 255}
GREEN :: rl.Color{166, 227, 161, 255}
YELLOW :: rl.Color{249, 226, 175, 255}
RED :: rl.Color{243, 139, 168, 255}
SURFACE :: rl.Color{49, 50, 68, 255}

// Nerd Font icons (UTF-8)
ICON_CLOCK :: "\xef\x80\x97"
ICON_BAT_FULL :: "\xef\x89\x80"
ICON_BAT_3Q :: "\xef\x89\x81"
ICON_BAT_HALF :: "\xef\x89\x82"
ICON_BAT_LOW :: "\xef\x89\x83"
ICON_BAT_EMPTY :: "\xef\x89\x84"
ICON_BOLT :: "\xef\x83\xa7"
ICON_VOL_HIGH :: "\xef\x80\xa8"
ICON_VOL_LOW :: "\xef\x80\xa7"
ICON_VOL_MUTE :: "\xef\x80\xa6"
ICON_KBD :: "\xef\x84\x9c"
ICON_PREV :: "\xe2\x8f\xae"   // ⏮ U+23EE
ICON_PLAY :: "\xe2\x96\xb6"   // ▶ U+25B6
ICON_PAUSE :: "\xe2\x8f\xb8"  // ⏸ U+23F8
ICON_NEXT :: "\xe2\x8f\xad"   // ⏭ U+23ED

EMOJI_FONT_PATH :: "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf"

MEDIA_MAX_W :: 350
MEDIA_SCROLL_SPEED :: f32(35)

KBD_LAYOUTS :: [?]cstring{"US", "RU"}

BUF_SM :: 64
BUF_MD :: 256

// ---------------------------------------------------------------------------
// Bar state
// ---------------------------------------------------------------------------

BarData :: struct {
	ws_bufs:         [16][BUF_SM]u8,
	ws_count:        int,
	focused_idx:     int,

	title_buf:       [BUF_MD]u8,
	title_len:       int,
	title_scroll:    f32,

	icon_tex:        rl.Texture2D,
	icon_valid:      bool,
	last_active_win: xlib.Window,

	kbd_layout:      cstring,

	hour:            i32,
	min:             i32,
	sec:             i32,

	volume:          i32,
	muted:           bool,

	// Volume widget hit region (filled during draw)
	vol_x:           i32,
	vol_w:           i32,

	// Kbd widget hit region (filled during draw)
	kbd_x:           i32,
	kbd_w:           i32,

	battery_pct:     i32,
	charging:        bool,

	weather_buf:     [BUF_MD]u8,
	weather_len:     int,

	hidden:          bool, // hidden behind fullscreen window

	// Playerctl
	media_player:    [BUF_SM]u8,
	media_player_len:int,
	media_buf:       [BUF_MD]u8,
	media_len:       int,
	media_scroll:    f32,
	media_active:    bool,
	media_playing:   bool,

	// Media button hit regions (filled during draw)
	btn_prev_x:      i32,
	btn_play_x:      i32,
	btn_next_x:      i32,
	btn_w:           i32,
}

// ---------------------------------------------------------------------------
// Shell / buffer helpers
// ---------------------------------------------------------------------------

run_cmd :: proc(cmd: cstring, buf: []u8) -> int {
	fp := popen(cmd, "r")
	if fp == nil do return 0
	defer pclose(fp)

	n := 0
	for n < len(buf) - 1 {
		ch := libc.fgetc(fp)
		if ch == libc.EOF do break
		buf[n] = u8(ch)
		n += 1
	}
	for n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r') {n -= 1}
	buf[n] = 0
	return n
}

run_cmd_fire :: proc(cmd: cstring) {
	fp := popen(cmd, "r")
	if fp != nil do pclose(fp)
}

buf_cstr :: proc(buf: []u8) -> cstring {
	return transmute(cstring)raw_data(buf)
}

// ---------------------------------------------------------------------------
// X11 helpers
// ---------------------------------------------------------------------------

get_active_window :: proc(display: ^xlib.Display) -> xlib.Window {
	root := xlib.DefaultRootWindow(display)
	active_atom := xlib.InternAtom(display, "_NET_ACTIVE_WINDOW", false)

	act_type: [1]xlib.Atom
	act_format: [1]i32
	nitems: [1]uint
	bytes_after: [1]uint
	prop: rawptr

	xlib.GetWindowProperty(
		display, root, active_atom, 0, 1, false, xlib.Atom(0),
		raw_data(act_type[:]), raw_data(act_format[:]),
		raw_data(nitems[:]), raw_data(bytes_after[:]), &prop,
	)

	if nitems[0] > 0 && prop != nil {
		win := (cast(^xlib.Window)prop)^
		xlib.Free(prop)
		return win
	}
	return xlib.Window(0)
}

is_fullscreen :: proc(display: ^xlib.Display) -> bool {
	active := get_active_window(display)
	if active == xlib.Window(0) do return false

	wm_state := xlib.InternAtom(display, "_NET_WM_STATE", false)
	fs_atom := xlib.InternAtom(display, "_NET_WM_STATE_FULLSCREEN", false)

	act_type: [1]xlib.Atom
	act_format: [1]i32
	nitems: [1]uint
	bytes_after: [1]uint
	prop: rawptr

	xlib.GetWindowProperty(
		display, active, wm_state, 0, 32, false, xlib.XA_ATOM,
		raw_data(act_type[:]), raw_data(act_format[:]),
		raw_data(nitems[:]), raw_data(bytes_after[:]), &prop,
	)

	if nitems[0] == 0 || prop == nil do return false
	defer xlib.Free(prop)

	atoms := cast([^]xlib.Atom)prop
	for i in 0 ..< int(nitems[0]) {
		if atoms[i] == fs_atom do return true
	}
	return false
}

load_window_icon :: proc(data: ^BarData, display: ^xlib.Display, window: xlib.Window) {
	if data.icon_valid {
		rl.UnloadTexture(data.icon_tex)
		data.icon_valid = false
	}
	if window == xlib.Window(0) do return

	icon_atom := xlib.InternAtom(display, "_NET_WM_ICON", false)
	cardinal := xlib.InternAtom(display, "CARDINAL", false)

	act_type: [1]xlib.Atom
	act_format: [1]i32
	nitems: [1]uint
	bytes_after: [1]uint
	prop: rawptr

	xlib.GetWindowProperty(
		display, window, icon_atom, 0, 0x7FFFFFFF, false, cardinal,
		raw_data(act_type[:]), raw_data(act_format[:]),
		raw_data(nitems[:]), raw_data(bytes_after[:]), &prop,
	)

	if nitems[0] < 3 || prop == nil do return
	defer xlib.Free(prop)

	icon_data := cast([^]uint)prop
	n := int(nitems[0])
	target := BAR_HEIGHT - 8

	offset := 0
	best_off := -1
	best_w, best_h := 0, 0

	for offset + 2 < n {
		w := int(icon_data[offset])
		h := int(icon_data[offset + 1])
		if w <= 0 || h <= 0 || w > 512 || h > 512 do break
		if offset + 2 + w * h > n do break

		if best_off == -1 || abs(w - target) < abs(best_w - target) {
			best_off = offset
			best_w = w
			best_h = h
		}
		offset += 2 + w * h
	}

	if best_off < 0 do return

	pixels := make([]u8, best_w * best_h * 4)
	defer delete(pixels)

	for i in 0 ..< best_w * best_h {
		argb := u32(icon_data[best_off + 2 + i])
		pixels[i * 4 + 0] = u8((argb >> 16) & 0xFF)
		pixels[i * 4 + 1] = u8((argb >> 8) & 0xFF)
		pixels[i * 4 + 2] = u8(argb & 0xFF)
		pixels[i * 4 + 3] = u8((argb >> 24) & 0xFF)
	}

	img := rl.Image {
		data    = raw_data(pixels),
		width   = i32(best_w),
		height  = i32(best_h),
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}

	data.icon_tex = rl.LoadTextureFromImage(img)
	rl.SetTextureFilter(data.icon_tex, .BILINEAR)
	data.icon_valid = true
}

// ---------------------------------------------------------------------------
// bspc subscribe — persistent pipe for instant workspace events
// ---------------------------------------------------------------------------

BspcSub :: struct {
	pipe: ^libc.FILE,
	fd:   c.int,
}

bspc_sub_open :: proc() -> BspcSub {
	pipe := popen("bspc subscribe desktop_focus node_focus node_add node_remove node_transfer", "r")
	fd: c.int = -1
	if pipe != nil do fd = fileno(pipe)
	return {pipe, fd}
}

bspc_sub_close :: proc(sub: ^BspcSub) {
	if sub.pipe != nil {
		pclose(sub.pipe)
		sub.pipe = nil
		sub.fd = -1
	}
}

// Drain all pending events. Returns true if any event was received.
bspc_sub_poll :: proc(sub: ^BspcSub) -> bool {
	if sub.pipe == nil || sub.fd < 0 do return false

	got := false
	for {
		pfd := Pollfd{fd = sub.fd, events = POLLIN}
		if poll(&pfd, 1, 0) <= 0 do break
		if (pfd.revents & POLLIN) == 0 do break

		// Consume one line
		for {
			ch := libc.fgetc(sub.pipe)
			if ch == libc.EOF {
				// Subscribe process died — will restart next cycle
				bspc_sub_close(sub)
				return got
			}
			if ch == c.int('\n') do break
		}
		got = true
	}
	return got
}

// ---------------------------------------------------------------------------
// Data update procs
// ---------------------------------------------------------------------------

update_workspaces :: proc(data: ^BarData) {
	buf: [512]u8
	n := run_cmd("bspc query -D --names", buf[:])
	if n == 0 do return

	data.ws_count = 0
	start := 0
	for i in 0 ..= n {
		if i == n || buf[i] == '\n' {
			line_len := i - start
			if line_len > 0 && data.ws_count < len(data.ws_bufs) {
				copy_len := min(line_len, BUF_SM - 1)
				for j in 0 ..< copy_len {
					data.ws_bufs[data.ws_count][j] = buf[start + j]
				}
				data.ws_bufs[data.ws_count][copy_len] = 0
				data.ws_count += 1
			}
			start = i + 1
		}
	}

	focused: [BUF_SM]u8
	fn := run_cmd("bspc query -D -d focused --names", focused[:])
	data.focused_idx = -1
	if fn > 0 {
		focused_str := string(focused[:fn])
		for i in 0 ..< data.ws_count {
			ws_len := 0
			for ws_len < BUF_SM && data.ws_bufs[i][ws_len] != 0 {ws_len += 1}
			if string(data.ws_bufs[i][:ws_len]) == focused_str {
				data.focused_idx = i
				break
			}
		}
	}
}

update_window_info :: proc(data: ^BarData, display: ^xlib.Display) {
	active_win := get_active_window(display)

	data.title_len = run_cmd("xdotool getactivewindow getwindowname 2>/dev/null", data.title_buf[:])

	if active_win != data.last_active_win {
		data.last_active_win = active_win
		data.title_scroll = 0
		load_window_icon(data, display, active_win)
	}
}

update_kbd_layout :: proc(data: ^BarData, display: ^xlib.Display) {
	state: xlib.XkbStateRec
	xlib.XkbGetState(display, xlib.XkbUseCoreKbd, &state)
	idx := int(state.group)
	layouts := KBD_LAYOUTS
	data.kbd_layout = idx >= 0 && idx < len(layouts) ? layouts[idx] : "??"
}

update_time :: proc(data: ^BarData) {
	raw_time: libc.time_t
	libc.time(&raw_time)
	tm := libc.localtime(&raw_time)
	data.hour = tm.tm_hour
	data.min = tm.tm_min
	data.sec = tm.tm_sec
}

update_volume :: proc(data: ^BarData) {
	buf: [BUF_SM]u8
	n := run_cmd("pamixer --get-volume 2>/dev/null", buf[:])
	if n > 0 {
		v, ok := strconv.parse_int(string(buf[:n]))
		if ok do data.volume = i32(v)
	}
	mute_buf: [BUF_SM]u8
	mn := run_cmd("pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null", mute_buf[:])
	if mn > 0 {
		data.muted = strings.contains(string(mute_buf[:mn]), "yes")
	}
}

update_battery :: proc(data: ^BarData) {
	if cap_data, ok := os.read_entire_file("/sys/class/power_supply/BAT0/capacity"); ok {
		v, parse_ok := strconv.parse_int(strings.trim_space(string(cap_data)))
		if parse_ok do data.battery_pct = i32(v)
		delete(cap_data)
	}
	if stat_data, ok := os.read_entire_file("/sys/class/power_supply/BAT0/status"); ok {
		data.charging = strings.contains(string(stat_data), "Charging")
		delete(stat_data)
	}
}

update_weather :: proc(data: ^BarData) {
	data.weather_len = run_cmd("curl -s --max-time 5 'wttr.in/?format=%C+%t' 2>/dev/null", data.weather_buf[:])
}

PLAYERCTL_FIND_PLAYING :: "playerctl -l 2>/dev/null | while read p; do [ \"$(playerctl -p \"$p\" status 2>/dev/null)\" = \"Playing\" ] && echo \"$p\" && break; done"
PLAYERCTL_FIND_PAUSED :: "playerctl -l 2>/dev/null | while read p; do [ \"$(playerctl -p \"$p\" status 2>/dev/null)\" = \"Paused\" ] && echo \"$p\" && break; done"

update_media :: proc(data: ^BarData) {
	// Find playing player first, then paused
	data.media_player_len = run_cmd(PLAYERCTL_FIND_PLAYING, data.media_player[:])
	if data.media_player_len > 0 {
		data.media_playing = true
	} else {
		data.media_player_len = run_cmd(PLAYERCTL_FIND_PAUSED, data.media_player[:])
		data.media_playing = false
	}

	if data.media_player_len == 0 {
		data.media_active = false
		data.media_len = 0
		return
	}

	data.media_active = true

	old_len := data.media_len
	old_first: u8 = data.media_len > 0 ? data.media_buf[0] : 0
	data.media_len = run_cmd(
		rl.TextFormat("songname %s 2>/dev/null", buf_cstr(data.media_player[:])),
		data.media_buf[:],
	)
	if data.media_len != old_len || (data.media_len > 0 && data.media_buf[0] != old_first) {
		data.media_scroll = 0
	}
}

// ---------------------------------------------------------------------------
// Font loading
// ---------------------------------------------------------------------------

load_font :: proc() -> rl.Font {
	codepoints: [dynamic]rune
	defer delete(codepoints)

	for cp in rune(32) ..= rune(126) {append(&codepoints, cp)}
	for cp in rune(0x00A0) ..= rune(0x00FF) {append(&codepoints, cp)}
	for cp in rune(0x0100) ..= rune(0x024F) {append(&codepoints, cp)}
	for cp in rune(0x0370) ..= rune(0x03FF) {append(&codepoints, cp)}
	for cp in rune(0x0400) ..= rune(0x04FF) {append(&codepoints, cp)}
	for cp in rune(0x0500) ..= rune(0x052F) {append(&codepoints, cp)}
	for cp in rune(0x2000) ..= rune(0x206F) {append(&codepoints, cp)}
	for cp in rune(0x20A0) ..= rune(0x20CF) {append(&codepoints, cp)}
	for cp in rune(0x2100) ..= rune(0x214F) {append(&codepoints, cp)}
	for cp in rune(0x2190) ..= rune(0x21FF) {append(&codepoints, cp)}
	for cp in rune(0x2200) ..= rune(0x22FF) {append(&codepoints, cp)}
	for cp in rune(0x2300) ..= rune(0x23FF) {append(&codepoints, cp)} // Misc Technical (⏮⏭⏸)
	for cp in rune(0x25A0) ..= rune(0x25FF) {append(&codepoints, cp)} // Geometric Shapes (▶)
	for cp in rune(0x2600) ..= rune(0x26FF) {append(&codepoints, cp)}
	for cp in rune(0x2700) ..= rune(0x27BF) {append(&codepoints, cp)}
	for cp in rune(0x3000) ..= rune(0x303F) {append(&codepoints, cp)}

	nf_ranges := [?][2]rune {
		{0xE000, 0xE00A},
		{0xE0A0, 0xE0D4},
		{0xE200, 0xE2A9},
		{0xE300, 0xE3E3},
		{0xE5FA, 0xE6B5},
		{0xE700, 0xE7C5},
		{0xEA60, 0xEBEB},
		{0xF000, 0xF2E0},
		{0xF300, 0xF375},
		{0xF400, 0xF532},
	}
	for r in nf_ranges {
		for cp in r[0] ..= r[1] {append(&codepoints, cp)}
	}

	font := rl.LoadFontEx(FONT_PATH, FONT_SIZE, raw_data(codepoints[:]), i32(len(codepoints)))
	rl.SetTextureFilter(font.texture, .BILINEAR)
	return font
}

load_emoji_font :: proc() -> rl.Font {
	codepoints := [?]rune{0x23ED, 0x23EE, 0x23F8, 0x25B6}
	font := rl.LoadFontEx(EMOJI_FONT_PATH, FONT_SIZE, raw_data(codepoints[:]), i32(len(codepoints)))
	rl.SetTextureFilter(font.texture, .BILINEAR)
	return font
}

// ---------------------------------------------------------------------------
// X11 dock setup
// ---------------------------------------------------------------------------

setup_dock :: proc(screen_w: i32) {
	{
		buf: [4]u8
		run_cmd("bspc rule -a bar manage=off sticky=on layer=above", buf[:])
	}

	glfw_handle := cast(glfw.WindowHandle)rl.GetWindowHandle()
	display := glfw.GetX11Display()
	window := glfw.GetX11Window(glfw_handle)
	root := xlib.DefaultRootWindow(display)
	cardinal := xlib.InternAtom(display, "CARDINAL", false)

	wm_type := xlib.InternAtom(display, "_NET_WM_WINDOW_TYPE", false)
	dock := xlib.InternAtom(display, "_NET_WM_WINDOW_TYPE_DOCK", false)
	xlib.ChangeProperty(display, window, wm_type, xlib.XA_ATOM, 32, xlib.PropModeReplace, &dock, 1)

	wm_state := xlib.InternAtom(display, "_NET_WM_STATE", false)
	sticky := xlib.InternAtom(display, "_NET_WM_STATE_STICKY", false)
	above := xlib.InternAtom(display, "_NET_WM_STATE_ABOVE", false)

	send_wm_state :: proc(display: ^xlib.Display, root: xlib.Window, window: xlib.Window, atom: xlib.Atom, wm_state: xlib.Atom) {
		ev: xlib.XEvent
		ev.xclient.type = .ClientMessage
		ev.xclient.window = window
		ev.xclient.message_type = wm_state
		ev.xclient.format = 32
		ev.xclient.data.l[0] = 1
		ev.xclient.data.l[1] = int(atom)
		ev.xclient.data.l[4] = 1
		xlib.SendEvent(display, root, false, {.SubstructureRedirect, .SubstructureNotify}, &ev)
	}

	send_wm_state(display, root, window, sticky, wm_state)
	send_wm_state(display, root, window, above, wm_state)

	state_atoms: [2]xlib.Atom = {sticky, above}
	xlib.ChangeProperty(display, window, wm_state, xlib.XA_ATOM, 32, xlib.PropModeReplace, &state_atoms, 2)

	wm_desktop := xlib.InternAtom(display, "_NET_WM_DESKTOP", false)
	{
		ev: xlib.XEvent
		ev.xclient.type = .ClientMessage
		ev.xclient.window = window
		ev.xclient.message_type = wm_desktop
		ev.xclient.format = 32
		ev.xclient.data.l[0] = -1
		ev.xclient.data.l[1] = 1
		xlib.SendEvent(display, root, false, {.SubstructureRedirect, .SubstructureNotify}, &ev)
	}
	all_desktops: c.ulong = 0xFFFFFFFF
	xlib.ChangeProperty(display, window, wm_desktop, cardinal, 32, xlib.PropModeReplace, &all_desktops, 1)

	strut_partial := xlib.InternAtom(display, "_NET_WM_STRUT_PARTIAL", false)
	struts: [12]c.long = {0, 0, c.long(BAR_HEIGHT), 0, 0, 0, 0, 0, 0, c.long(screen_w - 1), 0, 0}
	xlib.ChangeProperty(display, window, strut_partial, cardinal, 32, xlib.PropModeReplace, &struts, 12)

	strut_atom := xlib.InternAtom(display, "_NET_WM_STRUT", false)
	struts_basic: [4]c.long = {0, 0, c.long(BAR_HEIGHT), 0}
	xlib.ChangeProperty(display, window, strut_atom, cardinal, 32, xlib.PropModeReplace, &struts_basic, 4)

	xlib.Flush(display)
}

// ---------------------------------------------------------------------------
// Drawing helpers
// ---------------------------------------------------------------------------

measure :: proc(font: rl.Font, text: cstring) -> i32 {
	return i32(rl.MeasureTextEx(font, text, FONT_SIZE, FONT_SPACING).x)
}

draw_text :: proc(font: rl.Font, text: cstring, x: i32, color: rl.Color) {
	rl.DrawTextEx(font, text, {f32(x), f32((BAR_HEIGHT - FONT_SIZE) / 2)}, FONT_SIZE, FONT_SPACING, color)
}

draw_right :: proc(rx: ^i32, font: rl.Font, text: cstring, color: rl.Color) -> (x: i32, w: i32) {
	w = measure(font, text)
	rx^ -= w
	x = rx^
	draw_text(font, text, x, color)
	rx^ -= PAD
	return
}

draw_separator :: proc(rx: ^i32) {
	rx^ -= 6
	rl.DrawRectangle(rx^, 7, 1, BAR_HEIGHT - 14, FG_DIM)
	rx^ -= 6
}

// ---------------------------------------------------------------------------
// Main render
// ---------------------------------------------------------------------------

draw_bar :: proc(data: ^BarData, font: rl.Font, emoji_font: rl.Font, screen_w: i32) {
	dt := rl.GetFrameTime()

	// --- Left: workspaces ---
	x: i32 = 8
	for i in 0 ..< data.ws_count {
		ws := buf_cstr(data.ws_bufs[i][:])
		is_focused := i == data.focused_idx
		ws_w := measure(font, ws) + 14

		bg_col := is_focused ? ACCENT : SURFACE
		fg_col := is_focused ? BG : FG_DIM

		rl.DrawRectangle(x, 4, ws_w, BAR_HEIGHT - 8, bg_col)
		draw_text(font, ws, x + 7, fg_col)
		x += ws_w + 4
	}

	// --- Center: icon + window title ---
	if data.title_len > 0 {
		title := buf_cstr(data.title_buf[:])
		title_w := f32(measure(font, title))
		max_w := f32(TITLE_MAX_W)

		icon_size := f32(BAR_HEIGHT - 8)
		icon_gap := data.icon_valid ? icon_size + 6 : f32(0)
		visible_title_w := min(title_w, max_w)
		content_w := icon_gap + visible_title_w
		start_x := (f32(screen_w) * 0.38) - content_w / 2

		if data.icon_valid {
			aspect := f32(data.icon_tex.width) / max(f32(data.icon_tex.height), 1)
			iw := icon_size * aspect
			rl.DrawTexturePro(
				data.icon_tex,
				{0, 0, f32(data.icon_tex.width), f32(data.icon_tex.height)},
				{start_x, 4, iw, icon_size},
				{0, 0}, 0, rl.WHITE,
			)
		}

		title_x := i32(start_x + icon_gap)

		if title_w <= max_w {
			draw_text(font, title, title_x, FG)
			data.title_scroll = 0
		} else {
			data.title_scroll += TITLE_SCROLL_SPEED * dt
			cycle := title_w + TITLE_GAP
			if data.title_scroll >= cycle {
				data.title_scroll -= cycle
			}
			rl.BeginScissorMode(title_x, 0, i32(max_w), BAR_HEIGHT)
			draw_text(font, title, title_x - i32(data.title_scroll), FG)
			draw_text(font, title, title_x + i32(cycle - data.title_scroll), FG)
			rl.EndScissorMode()
		}
	}

	// --- Right: status items ---
	rx: i32 = screen_w - PAD

	// Time
	time_text := rl.TextFormat("%s %02d:%02d:%02d", cstring(ICON_CLOCK), data.hour, data.min, data.sec)
	draw_right(&rx, font, time_text, FG)
	draw_separator(&rx)

	// Weather
	{
		weather_text: cstring = data.weather_len > 0 ? buf_cstr(data.weather_buf[:]) : "Loading..."
		weather_col: rl.Color = data.weather_len > 0 ? FG_DIM : SURFACE
		draw_right(&rx, font, weather_text, weather_col)
		draw_separator(&rx)
	}

	// Battery
	bat_col := data.battery_pct > 50 ? GREEN : (data.battery_pct > 20 ? YELLOW : RED)
	bat_icon: cstring
	if data.charging {
		bat_icon = cstring(ICON_BOLT)
	} else if data.battery_pct > 75 {
		bat_icon = cstring(ICON_BAT_FULL)
	} else if data.battery_pct > 50 {
		bat_icon = cstring(ICON_BAT_3Q)
	} else if data.battery_pct > 25 {
		bat_icon = cstring(ICON_BAT_HALF)
	} else if data.battery_pct > 10 {
		bat_icon = cstring(ICON_BAT_LOW)
	} else {
		bat_icon = cstring(ICON_BAT_EMPTY)
	}
	bat_text := rl.TextFormat("%s %d%%", bat_icon, data.battery_pct)
	draw_right(&rx, font, bat_text, bat_col)
	draw_separator(&rx)

	// Volume — record hit region for mouse interaction
	if data.muted {
		vol_text := rl.TextFormat("%s MUTE", cstring(ICON_VOL_MUTE))
		vx, vw := draw_right(&rx, font, vol_text, RED)
		data.vol_x = vx - 4
		data.vol_w = vw + PAD + 8
	} else {
		vol_icon: cstring = data.volume > 50 ? cstring(ICON_VOL_HIGH) : cstring(ICON_VOL_LOW)
		vol_text := rl.TextFormat("%s %d%%", vol_icon, data.volume)
		vx, vw := draw_right(&rx, font, vol_text, FG)
		data.vol_x = vx - 4
		data.vol_w = vw + PAD + 8
	}
	draw_separator(&rx)

	// Keyboard layout — record hit region for mouse interaction
	if data.kbd_layout != nil {
		kbd_text := rl.TextFormat("%s %s", cstring(ICON_KBD), data.kbd_layout)
		kx, kw := draw_right(&rx, font, kbd_text, ACCENT)
		data.kbd_x = kx - 4
		data.kbd_w = kw + PAD + 8
	}

	// Media (playerctl) — left of kbd widget
	if data.media_active && data.media_len > 0 {
		draw_separator(&rx)

		// Buttons: prev | play/pause | next
		btn_w := i32(measure(emoji_font, cstring(ICON_NEXT))) + 8
		data.btn_w = btn_w
		btn_gap: i32 = 2

		// Next button (rightmost)
		rx -= btn_w
		data.btn_next_x = rx
		draw_text(emoji_font, cstring(ICON_NEXT), rx + 4, FG_DIM)

		rx -= btn_gap

		// Play/pause button
		rx -= btn_w
		data.btn_play_x = rx
		play_icon: cstring = data.media_playing ? cstring(ICON_PAUSE) : cstring(ICON_PLAY)
		draw_text(emoji_font, play_icon, rx + 4, ACCENT)

		rx -= btn_gap

		// Prev button
		rx -= btn_w
		data.btn_prev_x = rx
		draw_text(emoji_font, cstring(ICON_PREV), rx + 4, FG_DIM)

		rx -= 6

		// Song text with marquee
		media_text := buf_cstr(data.media_buf[:])
		media_full_w := f32(measure(font, media_text))
		media_max := f32(MEDIA_MAX_W)
		visible_media_w := i32(min(media_full_w, media_max))

		rx -= visible_media_w
		text_x := rx

		if media_full_w <= media_max {
			draw_text(font, media_text, text_x, FG_DIM)
			data.media_scroll = 0
		} else {
			data.media_scroll += MEDIA_SCROLL_SPEED * dt
			cycle := media_full_w + TITLE_GAP
			if data.media_scroll >= cycle {
				data.media_scroll -= cycle
			}
			rl.BeginScissorMode(text_x, 0, i32(media_max), BAR_HEIGHT)
			draw_text(font, media_text, text_x - i32(data.media_scroll), FG_DIM)
			draw_text(font, media_text, text_x + i32(cycle - data.media_scroll), FG_DIM)
			rl.EndScissorMode()
		}

		rx -= PAD
	} else {
		data.btn_w = 0
	}
}

// ---------------------------------------------------------------------------
// Volume mouse interaction
// ---------------------------------------------------------------------------

handle_volume_input :: proc(data: ^BarData) {
	mx := rl.GetMouseX()
	my := rl.GetMouseY()

	// Check if mouse is over volume widget
	over_vol := mx >= data.vol_x && mx <= data.vol_x + data.vol_w && my >= 0 && my < BAR_HEIGHT

	if !over_vol do return

	// Scroll wheel: adjust volume
	wheel := rl.GetMouseWheelMove()
	if wheel > 0 {
		run_cmd_fire("pamixer -i 5")
		update_volume(data)
	} else if wheel < 0 {
		run_cmd_fire("pamixer -d 5")
		update_volume(data)
	}

	// Click: toggle mute
	if rl.IsMouseButtonPressed(.LEFT) {
		run_cmd_fire("pamixer -t")
		update_volume(data)
	}
}

// ---------------------------------------------------------------------------
// Keyboard layout mouse interaction
// ---------------------------------------------------------------------------

handle_kbd_input :: proc(data: ^BarData, display: ^xlib.Display) {
	mx := rl.GetMouseX()
	my := rl.GetMouseY()

	over_kbd := mx >= data.kbd_x && mx <= data.kbd_x + data.kbd_w && my >= 0 && my < BAR_HEIGHT
	if !over_kbd do return

	if rl.IsMouseButtonPressed(.LEFT) {
		state: xlib.XkbStateRec
		xlib.XkbGetState(display, xlib.XkbUseCoreKbd, &state)
		next := c.uint((int(state.group) + 1) % len(KBD_LAYOUTS))
		XkbLockGroup(display, c.uint(xlib.XkbUseCoreKbd), next)
		xlib.Flush(display)
		update_kbd_layout(data, display)
	}
}

// ---------------------------------------------------------------------------
// Media mouse interaction
// ---------------------------------------------------------------------------

handle_media_input :: proc(data: ^BarData) {
	if data.btn_w <= 0 || data.media_player_len == 0 do return
	if !rl.IsMouseButtonPressed(.LEFT) do return

	mx := rl.GetMouseX()
	my := rl.GetMouseY()
	if my < 0 || my >= BAR_HEIGHT do return

	player := buf_cstr(data.media_player[:])
	w := data.btn_w

	if mx >= data.btn_prev_x && mx < data.btn_prev_x + w {
		run_cmd_fire(rl.TextFormat("playerctl -p %s previous &", player))
	} else if mx >= data.btn_play_x && mx < data.btn_play_x + w {
		run_cmd_fire(rl.TextFormat("playerctl -p %s play-pause &", player))
	} else if mx >= data.btn_next_x && mx < data.btn_next_x + w {
		run_cmd_fire(rl.TextFormat("playerctl -p %s next &", player))
	}
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

main :: proc() {
	screen_w := i32(1920)

	// Remove MOUSE_PASSTHROUGH so volume widget can receive clicks/scroll
	rl.SetConfigFlags({.WINDOW_UNDECORATED, .WINDOW_TOPMOST, .WINDOW_TRANSPARENT})
	rl.InitWindow(screen_w, BAR_HEIGHT, "bar")
	defer rl.CloseWindow()

	mon := rl.GetCurrentMonitor()
	screen_w = i32(rl.GetMonitorWidth(mon))
	rl.SetWindowSize(screen_w, BAR_HEIGHT)
	rl.SetWindowPosition(0, 0)
	rl.SetTargetFPS(30)

	setup_dock(screen_w)

	font := load_font()
	defer rl.UnloadFont(font)

	emoji_font := load_emoji_font()
	defer rl.UnloadFont(emoji_font)

	x_display := glfw.GetX11Display()

	data: BarData
	data.focused_idx = -1
	data.kbd_layout = "??"

	// bspc subscribe for instant workspace events
	sub := bspc_sub_open()

	last_fast: f64 = -9999
	last_medium: f64 = -9999
	last_slow: f64 = -9999
	last_weather: f64 = -597 // fires ~3s after launch, not on first frame
	frame: int = 0

	// Initial fast fetches only
	update_workspaces(&data)
	update_time(&data)
	update_kbd_layout(&data, x_display)

	for !rl.WindowShouldClose() {
		now := rl.GetTime()

		// --- Instant workspace updates via bspc subscribe ---
		if sub.pipe == nil {
			sub = bspc_sub_open() // reconnect if died
		}
		if bspc_sub_poll(&sub) {
			update_workspaces(&data)
			update_window_info(&data, x_display)
		}

		// --- Periodic polls ---
		if now - last_fast >= 0.5 {
			last_fast = now
			update_window_info(&data, x_display)
			update_kbd_layout(&data, x_display)

			// Check fullscreen state
			fs := is_fullscreen(x_display)
			if fs != data.hidden {
				data.hidden = fs
				if fs {
					rl.SetWindowPosition(0, -BAR_HEIGHT) // slide off screen
				} else {
					rl.SetWindowPosition(0, 0)
				}
			}
		}

		if now - last_medium >= 1.0 {
			last_medium = now
			update_time(&data)
			update_volume(&data)
			update_media(&data)
		}

		if now - last_slow >= 30.0 {
			last_slow = now
			update_battery(&data)
		}

		if now - last_weather >= 600.0 {
			last_weather = now
			update_weather(&data)
		}

		// --- Mouse interaction ---
		handle_volume_input(&data)
		handle_kbd_input(&data, x_display)
		handle_media_input(&data)

		// --- Cursor ---
		{
			mx := rl.GetMouseX()
			my := rl.GetMouseY()
			over_bar := my >= 0 && my < BAR_HEIGHT
			hand := false
			if over_bar {
				// Volume
				if mx >= data.vol_x && mx <= data.vol_x + data.vol_w do hand = true
				// Kbd
				if mx >= data.kbd_x && mx <= data.kbd_x + data.kbd_w do hand = true
				// Media buttons
				if data.btn_w > 0 {
					if mx >= data.btn_prev_x && mx < data.btn_prev_x + data.btn_w do hand = true
					if mx >= data.btn_play_x && mx < data.btn_play_x + data.btn_w do hand = true
					if mx >= data.btn_next_x && mx < data.btn_next_x + data.btn_w do hand = true
				}
			}
			rl.SetMouseCursor(hand ? .POINTING_HAND : .DEFAULT)
		}

		// --- Render ---
		rl.BeginDrawing()
		rl.ClearBackground(BG)
		draw_bar(&data, font, emoji_font, screen_w)
		rl.EndDrawing()
	}

	bspc_sub_close(&sub)
	if data.icon_valid {
		rl.UnloadTexture(data.icon_tex)
	}
}
