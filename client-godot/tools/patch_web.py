"""After a Web export: let the build start over plain http on the local network.

Godot's page refuses to start outside a "secure context" (https or localhost).
This build has threads off, so nothing it uses needs one; testing from a phone
over Wi-Fi (http://192.168.x.x) would otherwise be blocked. Production hosting
should still use https.

Usage: python tools/patch_web.py build/web/index.html
"""
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "build/web/index.html"
s = open(path, encoding="utf-8").read()
old = """	const missing = Engine.getMissingFeatures({
		threads: GODOT_THREADS_ENABLED,
	});"""
new = """	const missing = Engine.getMissingFeatures({
		threads: GODOT_THREADS_ENABLED,
	}).filter((m) => !m.startsWith('Secure Context'));  // LAN testing over http"""
if new not in s:
    if old not in s:
        sys.exit("patch_web: startup check not found; Godot's page template changed")
    s = s.replace(old, new)
# Browsers only allow AudioWorklet in a secure context too. The game has no
# sound yet, so start with the silent audio driver when served over http.
if '"args":[]' in s:
    s = s.replace('"args":[]', '"args":(window.isSecureContext ? [] : ["--audio-driver","Dummy"])')
open(path, "w", encoding="utf-8").write(s)
print("patched", path)
