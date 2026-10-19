class_name TS
extends RefCounted
## Mobile type scale. The table is designed at 2400 x 1080 design px, which a
## phone in landscape shows about 390 pt tall, so 1 pt = 1080 / 390 design px.
## Every text and number on the table takes its size from here, so nothing is
## smaller than a phone can comfortably read (12 pt).

const PT := 1080.0 / 390.0

const CAPTION := 12.0 * PT  # small notes, never smaller
const BODY := 15.0 * PT  # sentences, secondary lines
const LABEL := 17.0 * PT  # names, button text
const TITLE := 22.0 * PT  # dialog titles, banners' second line
const BANNER := 30.0 * PT  # "Your turn"

const NUM_S := 16.0 * PT  # counts on small pieces (cost medallions)
const NUM_M := 22.0 * PT  # counts beside tokens and cards
const NUM_L := 28.0 * PT  # score, card points
const NUM_XL := 40.0 * PT  # the big numbers in dialogs

const TOUCH := 44.0 * PT  # the smallest thing a thumb should have to hit
