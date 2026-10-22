extends Node
## Autoload "Ads": the ad slots (docs/REMOTE_CONFIG_ADS_ANALYTICS.md §2).
## `await Ads.show(slot)` shows an ad when the server's config allows it
## (the master switch, the slot's switch, and no ad in the last
## `minIntervalSec` seconds) and answers whether one was shown. There is no ad
## SDK in the app yet: `_sdk_show` is the one place where it will plug in, and
## today it answers false at once. Every call records an `ad_slot` event.
##
## Slots: "pregame_ai" (before a game against the computer opens),
## "postgame" (leaving the results), "pregame_online" (the server's ad break
## before an online game, op 110).

signal _sdk_done(shown: bool)

var _last_shown := -1.0e9  ## when the last ad was shown (ticks, s)


## Show an ad in `slot` if the config allows it. True when one was shown.
func show(slot: String) -> bool:
	var shown := false
	if Remote.ad_slot_on(slot) and _now() - _last_shown >= Remote.ad_min_interval():
		shown = await _sdk_show(slot)
		if shown:
			_last_shown = _now()
	Analytics.event("ad_slot", {"slot": slot, "shown": shown})
	return shown


# ------------------------------------------------------------------ the ad SDK (not in the app yet)

## THE PLACE FOR THE AD SDK. A future Android plugin (Tapsell or Adivery)
## shows a full-screen ad for `slot` here and emits `_sdk_done(shown)` when
## it is closed (or failed to load); until then there is nothing to show.
##
## Sketch, once the plugin exists:
##     var sdk := Engine.get_singleton("TapsellPlus")
##     sdk.connect("ad_closed", func(): _sdk_done.emit(true), CONNECT_ONE_SHOT)
##     sdk.connect("ad_failed", func(): _sdk_done.emit(false), CONNECT_ONE_SHOT)
##     sdk.showInterstitial(ZONE_IDS[slot])
##     return await _sdk_done
func _sdk_show(_slot: String) -> bool:
	if not _sdk_ready():
		return false
	return await _sdk_done


## Whether an ad SDK is in this build and has an ad loaded. None yet.
func _sdk_ready() -> bool:
	return false


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
