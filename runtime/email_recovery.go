package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"net/mail"
	"strings"
	"time"

	"github.com/heroiclabs/nakama-common/runtime"
)

// email_recovery.go — a recovery email for an account.
//
// A player may attach an email to their account (checked with a 6-digit code
// sent to it). On a new phone (or later on a computer) the same email and a
// fresh code bring the old account to the new device: the device is moved
// onto that account, so it signs in as it from then on.
//
//	email_status     {}                       → {email, available}
//	email_send_code  {email, purpose, lang}   → {sent, already}
//	email_verify     {email, code, purpose}   → {email, displayName, avatarId, rating}
//
// purpose is "link" (attach to this account) or "recover" (bring that
// account here). Codes live 10 minutes and allow 5 tries; an address gets a
// new code at most once a minute and 6 times a day, an account 10 times a day.

const (
	EmailOwnerCollection = "email_owner" // system-owned, key = hash of the address
	EmailCodeCollection  = "email_code"  // system-owned, key = hash of the address
	EmailSendsCollection = "email_sends" // per user, key "today"
	emailCodeTTL         = 10 * time.Minute
	emailResendGap       = 60 * time.Second
	emailTries           = 5
	emailPerAddressDay   = 6
	emailPerUserDay      = 10
)

type emailOwner struct {
	UserID string `json:"userId"`
	Email  string `json:"email"`
}

type emailCode struct {
	Hash     string `json:"hash"`
	Purpose  string `json:"purpose"`
	UserID   string `json:"userId"` // who asked: only they may use it
	Expires  int64  `json:"expires"`
	SentAt   int64  `json:"sentAt"`
	Tries    int    `json:"tries"`
	Day      string `json:"day"`
	DaySends int    `json:"daySends"`
}

type emailSends struct {
	Day   string `json:"day"`
	Count int    `json:"count"`
}

// normalizeEmail is the address as stored: trimmed, lower case, checked.
func normalizeEmail(s string) (string, bool) {
	s = strings.ToLower(strings.TrimSpace(s))
	if len(s) < 6 || len(s) > 254 || strings.ContainsAny(s, " <>\"',;") {
		return "", false
	}
	a, err := mail.ParseAddress(s)
	if err != nil || a.Address != s {
		return "", false
	}
	at := strings.LastIndex(s, "@")
	if at < 1 || !strings.Contains(s[at+1:], ".") || strings.HasSuffix(s, ".") {
		return "", false
	}
	return s, true
}

func emailKey(email string) string {
	h := sha256.Sum256([]byte("splendor-email:" + email))
	return hex.EncodeToString(h[:])
}

func codeHash(email, code string) string {
	h := sha256.Sum256([]byte(email + "|" + code))
	return hex.EncodeToString(h[:])
}

func newCode() string {
	n, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		return fmt.Sprintf("%06d", time.Now().UnixNano()%1000000)
	}
	return fmt.Sprintf("%06d", n.Int64())
}

// ---------- storage

func readSystem(ctx context.Context, nk runtime.NakamaModule, collection, key string, out interface{}) (bool, error) {
	objs, err := nk.StorageRead(ctx, []*runtime.StorageRead{{Collection: collection, Key: key}})
	if err != nil {
		return false, err
	}
	if len(objs) == 0 {
		return false, nil
	}
	return true, json.Unmarshal([]byte(objs[0].GetValue()), out)
}

func writeSystem(ctx context.Context, nk runtime.NakamaModule, collection, key, userID string, v interface{}) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = nk.StorageWrite(ctx, []*runtime.StorageWrite{{
		Collection: collection, Key: key, UserID: userID, Value: string(b),
		PermissionRead: runtime.STORAGE_PERMISSION_NO_READ, PermissionWrite: runtime.STORAGE_PERMISSION_NO_WRITE,
	}})
	return err
}

func deleteSystem(ctx context.Context, nk runtime.NakamaModule, collection, key string) {
	_ = nk.StorageDelete(ctx, []*runtime.StorageDelete{{Collection: collection, Key: key}})
}

// ---------- RPCs

func callerID(ctx context.Context) (string, error) {
	userID, _ := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}
	return userID, nil
}

// rpcEmailStatus: this account's recovery email, and whether email works.
func rpcEmailStatus(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, err := callerID(ctx)
	if err != nil {
		return "", err
	}
	meta, err := readMetadata(ctx, nk, userID)
	if err != nil {
		return "", runtime.NewError("failed to read account", 13)
	}
	out, _ := json.Marshal(map[string]interface{}{"email": meta.Email, "available": mailConfig().ready()})
	return string(out), nil
}

type emailRequest struct {
	Email   string `json:"email"`
	Code    string `json:"code"`
	Purpose string `json:"purpose"`
	Lang    string `json:"lang"`
}

func readEmailRequest(payload string) (*emailRequest, string, error) {
	var req emailRequest
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return nil, "", runtime.NewError("invalid payload", 3)
	}
	if req.Purpose != "link" && req.Purpose != "recover" {
		return nil, "", runtime.NewError("invalid purpose", 3)
	}
	email, ok := normalizeEmail(req.Email)
	if !ok {
		return nil, "", runtime.NewError("invalid email", 3)
	}
	return &req, email, nil
}

// rpcEmailSendCode emails a fresh code.
//
// Errors: 3 a bad address, 5 recover: no account has this email, 6 link: the
// email belongs to another account, 8 too many codes (retryAfter seconds in
// the message), 14 email is not set up or the mail server failed.
func rpcEmailSendCode(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, err := callerID(ctx)
	if err != nil {
		return "", err
	}
	req, email, err := readEmailRequest(payload)
	if err != nil {
		return "", err
	}
	if !mailConfig().ready() {
		return "", runtime.NewError("email is not available", 14)
	}
	key := emailKey(email)
	var owner emailOwner
	owned, err := readSystem(ctx, nk, EmailOwnerCollection, key, &owner)
	if err != nil {
		return "", runtime.NewError("storage failed", 13)
	}
	if owned && owner.UserID == userID {
		out, _ := json.Marshal(map[string]interface{}{"sent": false, "already": true})
		return string(out), nil
	}
	if req.Purpose == "link" && owned {
		return "", runtime.NewError("email belongs to another account", 6)
	}
	if req.Purpose == "recover" && !owned {
		return "", runtime.NewError("no account has this email", 5)
	}

	now := time.Now()
	day := now.UTC().Format("2006-01-02")
	var rec emailCode
	if _, err := readSystem(ctx, nk, EmailCodeCollection, key, &rec); err != nil {
		return "", runtime.NewError("storage failed", 13)
	}
	if rec.Day != day {
		rec.Day, rec.DaySends = day, 0
	}
	if wait := rec.SentAt + int64(emailResendGap/time.Millisecond) - now.UnixMilli(); wait > 0 {
		return "", runtime.NewError(fmt.Sprintf("retryAfter=%d", wait/1000+1), 8)
	}
	if rec.DaySends >= emailPerAddressDay {
		return "", runtime.NewError("retryAfter=86400", 8)
	}
	var sends emailSends
	objs, err := nk.StorageRead(ctx, []*runtime.StorageRead{{Collection: EmailSendsCollection, Key: "today", UserID: userID}})
	if err == nil && len(objs) > 0 {
		_ = json.Unmarshal([]byte(objs[0].GetValue()), &sends)
	}
	if sends.Day != day {
		sends = emailSends{Day: day}
	}
	if sends.Count >= emailPerUserDay {
		return "", runtime.NewError("retryAfter=86400", 8)
	}

	code := newCode()
	subject, text, html := codeEmail(code, req.Purpose, req.Lang)
	if err := mailSender(email, subject, text, html); err != nil {
		logger.Error("email to %s failed: %v", email, err)
		return "", runtime.NewError("email could not be sent", 14)
	}
	rec = emailCode{Hash: codeHash(email, code), Purpose: req.Purpose, UserID: userID,
		Expires: now.Add(emailCodeTTL).UnixMilli(), SentAt: now.UnixMilli(), Day: day, DaySends: rec.DaySends + 1}
	if err := writeSystem(ctx, nk, EmailCodeCollection, key, "", rec); err != nil {
		return "", runtime.NewError("storage failed", 13)
	}
	sends.Count++
	_ = writeSystem(ctx, nk, EmailSendsCollection, "today", userID, sends)
	logger.Info("email code sent (%s) userId=%s", req.Purpose, userID)
	out, _ := json.Marshal(map[string]interface{}{"sent": true, "already": false})
	return string(out), nil
}

// rpcEmailVerify checks a code and does what it was for.
//
// Errors: 3 a wrong code (triesLeft=N in the message), 4 the code ran out or
// was used up (ask for a new one), 6 link: the email was taken meanwhile,
// 9 recover: this device's account has its own email or a game in progress.
func rpcEmailVerify(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, err := callerID(ctx)
	if err != nil {
		return "", err
	}
	req, email, err := readEmailRequest(payload)
	if err != nil {
		return "", err
	}
	key := emailKey(email)
	var rec emailCode
	found, err := readSystem(ctx, nk, EmailCodeCollection, key, &rec)
	if err != nil {
		return "", runtime.NewError("storage failed", 13)
	}
	if !found || rec.Hash == "" || rec.UserID != userID || rec.Purpose != req.Purpose ||
		time.Now().UnixMilli() > rec.Expires || rec.Tries >= emailTries {
		return "", runtime.NewError("code expired", 4)
	}
	if codeHash(email, strings.TrimSpace(req.Code)) != rec.Hash {
		rec.Tries++
		_ = writeSystem(ctx, nk, EmailCodeCollection, key, "", rec)
		return "", runtime.NewError(fmt.Sprintf("triesLeft=%d", emailTries-rec.Tries), 3)
	}
	// used: keep the counters, drop the code
	rec.Hash = ""
	_ = writeSystem(ctx, nk, EmailCodeCollection, key, "", rec)

	var owner emailOwner
	owned, err := readSystem(ctx, nk, EmailOwnerCollection, key, &owner)
	if err != nil {
		return "", runtime.NewError("storage failed", 13)
	}
	target := userID
	if req.Purpose == "link" {
		if owned && owner.UserID != userID {
			return "", runtime.NewError("email belongs to another account", 6)
		}
		if err := linkEmail(ctx, nk, userID, email); err != nil {
			logger.Error("link email failed userId=%s: %v", userID, err)
			return "", runtime.NewError("failed to save", 13)
		}
		logger.Info("recovery email linked userId=%s", userID)
	} else {
		if !owned {
			return "", runtime.NewError("no account has this email", 5)
		}
		target = owner.UserID
		if target != userID {
			if err := moveDevices(ctx, logger, nk, userID, target); err != nil {
				return "", err
			}
			logger.Info("account recovered: devices of %s now sign in as %s", userID, target)
		}
	}
	return profileReply(ctx, nk, target, email)
}

// linkEmail makes `email` this account's recovery email (freeing any other
// it had).
func linkEmail(ctx context.Context, nk runtime.NakamaModule, userID, email string) error {
	meta, err := readMetadata(ctx, nk, userID)
	if err != nil {
		return err
	}
	if meta.Email != "" && meta.Email != email {
		deleteSystem(ctx, nk, EmailOwnerCollection, emailKey(meta.Email))
	}
	if err := writeSystem(ctx, nk, EmailOwnerCollection, emailKey(email), "", emailOwner{UserID: userID, Email: email}); err != nil {
		return err
	}
	meta.Email = email
	return writeMetadata(ctx, nk, userID, meta)
}

// moveDevices signs the caller's devices in as `to` from now on. The caller's
// own account is left without a device: deleted when it never played a
// rated game, otherwise kept (off the leaderboard) under a placeholder id.
func moveDevices(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule, from, to string) error {
	meta, err := readMetadata(ctx, nk, from)
	if err != nil {
		return runtime.NewError("failed to read account", 13)
	}
	if meta.Email != "" {
		return runtime.NewError("this account has its own email", 9)
	}
	if meta.ActiveMatchID != nil && *meta.ActiveMatchID != "" {
		return runtime.NewError("a game is in progress", 9)
	}
	acc, err := nk.AccountGetId(ctx, from)
	if err != nil {
		return runtime.NewError("failed to read account", 13)
	}
	devices := acc.GetDevices()
	if len(devices) == 0 {
		return runtime.NewError("no device to move", 9)
	}
	// an account must keep one way in, so the old one gets a placeholder
	if err := nk.LinkCustom(ctx, from, "moved-"+from); err != nil {
		logger.Warn("recover: placeholder for %s: %v", from, err)
	}
	for _, d := range devices {
		if err := nk.UnlinkDevice(ctx, from, d.GetId()); err != nil {
			logger.Error("recover: unlink device from %s: %v", from, err)
			return runtime.NewError("failed to move the device", 13)
		}
		if err := nk.LinkDevice(ctx, to, d.GetId()); err != nil {
			logger.Error("recover: link device to %s: %v", to, err)
			_ = nk.LinkDevice(ctx, from, d.GetId()) // put it back
			return runtime.NewError("failed to move the device", 13)
		}
	}
	if prof, err := readRatingProfile(ctx, nk, from); err == nil && prof.GamesPlayed == 0 {
		if err := nk.AccountDeleteId(ctx, from, false); err != nil {
			logger.Warn("recover: delete empty account %s: %v", from, err)
		}
	} else {
		_ = nk.LeaderboardRecordDelete(ctx, LeaderboardID, from)
	}
	return nil
}

// profileReply is what the device needs to show the account: name, portrait,
// rating and email.
func profileReply(ctx context.Context, nk runtime.NakamaModule, userID, email string) (string, error) {
	out := map[string]interface{}{"email": email, "rating": DefaultRating}
	if acc, err := nk.AccountGetId(ctx, userID); err == nil && acc.GetUser() != nil {
		out["displayName"] = acc.GetUser().GetDisplayName()
		var meta accountMetadata
		if raw := acc.GetUser().GetMetadata(); raw != "" && json.Unmarshal([]byte(raw), &meta) == nil {
			out["avatarId"] = meta.AvatarID
		}
	}
	if prof, err := readRatingProfile(ctx, nk, userID); err == nil && prof != nil {
		out["rating"] = prof.Rating
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}

// ---------- the email itself
//
// The email looks like a dialog of the game: the logo, the crest and ribbon,
// the gold-framed leather with the code on the ivory plate, the footer
// flourish. The pieces are the game's own art, served with the website
// (deploy/web/mail, made from client-godot/assets/splendor/ui). Without
// images (some mail apps) it falls back to the same colours.

const mailArt = "https://splendor.aizood.ir/mail/"

type mailText struct {
	dir, title, hello, intro, why, ignore, maker, unsub string
}

func codeEmail(code, purpose, lang string) (subject, text, html string) {
	t := mailText{dir: "rtl", hello: "سلام،", intro: "کد شما در بازی اسپلندور:",
		ignore: "اگر شما این کد را نخواسته‌اید، این ایمیل را نادیده بگیرید.",
		maker:  "اسپلندور · ساختهٔ زود گیمرز", unsub: "لغو دریافت ایمیل"}
	if purpose == "recover" {
		t.title, t.why = "بازیابی حساب", "این کد برای آوردن حساب شما به این دستگاه است و تا 10 دقیقه کار می‌کند."
	} else {
		t.title, t.why = "ایمیل بازیابی", "این کد برای ثبت این ایمیل به‌عنوان ایمیل بازیابی حساب شما است و تا 10 دقیقه کار می‌کند."
	}
	subject = "کد اسپلندور: " + code
	if lang == "en" {
		t = mailText{dir: "ltr", hello: "Hello,", intro: "Your Splendor code:",
			ignore: "If you did not ask for it, ignore this email.",
			maker:  "Splendor · by Zood Gamers", unsub: "Unsubscribe"}
		if purpose == "recover" {
			t.title, t.why = "Recover account", "Use it to bring your account to this device. It works for 10 minutes."
		} else {
			t.title, t.why = "Recovery email", "Use it to add this address as your account's recovery email. It works for 10 minutes."
		}
		subject = "Splendor code: " + code
	}
	text = fmt.Sprintf("%s\n\n%s %s\n\n%s\n%s\n\n%s — https://splendor.aizood.ir\n",
		t.hello, t.intro, code, t.why, t.ignore, t.maker)
	html = emailHTML(t, code)
	if tag := mailConfig().Unsubscribe; tag != "" {
		// the provider's own link, labelled in the player's language (without
		// the tag it would add an English one)
		text += t.unsub + ": " + tag + "\n"
		html = strings.Replace(html, "<!--unsub-->",
			` · <a href="`+tag+`" style="color:#8f8268;text-decoration:underline">`+t.unsub+`</a>`, 1)
	}
	return
}

func emailHTML(t mailText, code string) string {
	align := "right"
	if t.dir == "ltr" {
		align = "left"
	}
	font := `font-family:Tahoma,'Segoe UI',Arial,sans-serif;`
	r := strings.NewReplacer("{ART}", mailArt, "{DIR}", t.dir, "{ALIGN}", align, "{FONT}", font,
		"{TITLE}", t.title, "{HELLO}", t.hello, "{INTRO}", t.intro, "{CODE}", code,
		"{WHY}", t.why, "{IGNORE}", t.ignore, "{MAKER}", t.maker)
	return r.Replace(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark"><meta name="supported-color-schemes" content="dark"></head>
<body style="margin:0;padding:0;background:#0d0b08">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#0d0b08" style="background:#0d0b08">
<tr><td align="center" style="padding:22px 8px 28px">
<table role="presentation" width="520" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:520px">
<tr><td align="center" style="padding:0 0 6px"><img src="{ART}logo.jpg" width="340" alt="Splendor" style="display:block;width:65%;max-width:340px;height:auto;border:0"></td></tr>
<tr><td align="center" valign="top" height="177" background="{ART}head.jpg" bgcolor="#1b1713"
 style="height:177px;background:#1b1713 url('{ART}head.jpg') center top/100% 100% no-repeat;{FONT}">
 <div style="padding-top:72px;font-size:17px;line-height:24px;font-weight:bold;color:#f6e7bf">{TITLE}</div></td></tr>
<tr><td dir="{DIR}" background="{ART}mid.jpg" bgcolor="#1b1713"
 style="background:#1b1713 url('{ART}mid.jpg') center top/100% auto repeat-y;padding:0 48px 4px;text-align:{ALIGN};{FONT}color:#efe3c8">
 <div style="font-size:16px;line-height:28px">{HELLO}</div>
 <div style="font-size:16px;line-height:28px">{INTRO}</div>
 <table role="presentation" align="center" cellpadding="0" cellspacing="0" border="0" style="margin:16px auto 18px">
 <tr><td align="center" valign="middle" width="380" height="75" background="{ART}plate.jpg" bgcolor="#efe3c8"
  style="width:380px;max-width:100%;height:75px;background:#efe3c8 url('{ART}plate.jpg') center/100% 100% no-repeat;border-radius:38px">
  <div dir="ltr" style="font-family:Georgia,'Times New Roman',serif;font-size:38px;line-height:75px;font-weight:bold;letter-spacing:12px;color:#3a2913;padding-left:12px">{CODE}</div>
 </td></tr></table>
 <div style="font-size:15px;line-height:26px;color:#e2d6bd">{WHY}</div>
 <div style="font-size:13px;line-height:24px;color:#a99a7c;padding-top:8px">{IGNORE}</div>
</td></tr>
<tr><td style="line-height:0;font-size:0"><img src="{ART}foot.jpg" width="520" alt="" style="display:block;width:100%;height:auto;border:0"></td></tr>
<tr><td align="center" dir="{DIR}" style="padding:14px 10px 0;{FONT}font-size:12px;line-height:22px;color:#8f8268">
 {MAKER} · <a href="https://splendor.aizood.ir" style="color:#c9a85c;text-decoration:none">splendor.aizood.ir</a><!--unsub-->
</td></tr>
</table></td></tr></table>
</body></html>`)
}
