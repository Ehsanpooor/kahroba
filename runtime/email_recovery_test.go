package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// emailNK fakes accounts (metadata and devices) and storage.
type emailNK struct {
	runtime.NakamaModule
	store   map[string]string                 // collection/key/user -> value
	meta    map[string]map[string]interface{} // user -> metadata
	devices map[string][]string               // user -> device ids
	deleted []string
}

func newEmailNK() *emailNK {
	return &emailNK{store: map[string]string{}, meta: map[string]map[string]interface{}{}, devices: map[string][]string{}}
}

func (n *emailNK) StorageRead(_ context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	var out []*api.StorageObject
	for _, r := range reads {
		if v, ok := n.store[r.Collection+"/"+r.Key+"/"+r.UserID]; ok {
			out = append(out, &api.StorageObject{Collection: r.Collection, Key: r.Key, UserId: r.UserID, Value: v})
		}
	}
	return out, nil
}

func (n *emailNK) StorageWrite(_ context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	for _, w := range writes {
		n.store[w.Collection+"/"+w.Key+"/"+w.UserID] = w.Value
	}
	return nil, nil
}

func (n *emailNK) StorageDelete(_ context.Context, dels []*runtime.StorageDelete) error {
	for _, d := range dels {
		delete(n.store, d.Collection+"/"+d.Key+"/"+d.UserID)
	}
	return nil
}

func (n *emailNK) AccountGetId(_ context.Context, userID string) (*api.Account, error) {
	b, _ := json.Marshal(n.meta[userID])
	acc := &api.Account{User: &api.User{Id: userID, DisplayName: "name-" + userID, Metadata: string(b)}}
	for _, d := range n.devices[userID] {
		acc.Devices = append(acc.Devices, &api.AccountDevice{Id: d})
	}
	return acc, nil
}

func (n *emailNK) AccountUpdateId(_ context.Context, userID, _ string, m map[string]interface{}, _, _, _, _, _ string) error {
	if m != nil {
		n.meta[userID] = m
	}
	return nil
}

func (n *emailNK) LinkCustom(_ context.Context, _, _ string) error { return nil }

func (n *emailNK) UnlinkDevice(_ context.Context, userID, deviceID string) error {
	var keep []string
	for _, d := range n.devices[userID] {
		if d != deviceID {
			keep = append(keep, d)
		}
	}
	n.devices[userID] = keep
	return nil
}

func (n *emailNK) LinkDevice(_ context.Context, userID, deviceID string) error {
	n.devices[userID] = append(n.devices[userID], deviceID)
	return nil
}

func (n *emailNK) AccountDeleteId(_ context.Context, userID string, _ bool) error {
	n.deleted = append(n.deleted, userID)
	return nil
}

func (n *emailNK) LeaderboardRecordDelete(_ context.Context, _, _ string) error { return nil }

func asUser(userID string) context.Context {
	return context.WithValue(context.Background(), runtime.RUNTIME_CTX_USER_ID, userID)
}

// withMail sets up a mail account and catches the codes that are "sent".
func withMail(t *testing.T) *[]string {
	t.Setenv("SMTP_HOST", "smtp.example.com")
	t.Setenv("SMTP_USER", "game@example.com")
	t.Setenv("SMTP_PASSWORD", "secret")
	sent := &[]string{}
	old := mailSender
	mailSender = func(to, subject, text, html string) error {
		*sent = append(*sent, regexp.MustCompile(`\d{6}`).FindString(subject))
		return nil
	}
	t.Cleanup(func() { mailSender = old })
	return sent
}

func rpcCode(err error) int {
	if e, ok := err.(*runtime.Error); ok {
		return e.Code
	}
	return -1
}

// A player adds an email, loses the phone, and brings the account to a new one.
func TestEmail_LinkThenRecover(t *testing.T) {
	sent := withMail(t)
	nk := newEmailNK()
	nk.devices["old"] = []string{"phone-1"}
	nk.devices["new"] = []string{"phone-2"}
	log := &mockLogger{t}

	// link on the old phone
	if _, err := rpcEmailSendCode(asUser("old"), log, nil, nk, `{"email":" Sara@Mail.com ","purpose":"link"}`); err != nil {
		t.Fatalf("send link code: %v", err)
	}
	if _, err := rpcEmailVerify(asUser("old"), log, nil, nk, `{"email":"sara@mail.com","code":"000000x","purpose":"link"}`); rpcCode(err) != 3 {
		t.Fatalf("a wrong code: err %v, want code 3", err)
	}
	if _, err := rpcEmailVerify(asUser("old"), log, nil, nk, `{"email":"sara@mail.com","code":"`+(*sent)[0]+`","purpose":"link"}`); err != nil {
		t.Fatalf("verify link: %v", err)
	}
	if nk.meta["old"]["email"] != "sara@mail.com" {
		t.Errorf("metadata email = %v", nk.meta["old"]["email"])
	}
	// the same code cannot be used twice
	if _, err := rpcEmailVerify(asUser("old"), log, nil, nk, `{"email":"sara@mail.com","code":"`+(*sent)[0]+`","purpose":"link"}`); rpcCode(err) != 4 {
		t.Errorf("reusing a code: err %v, want 4", err)
	}

	// another account cannot take it
	if _, err := rpcEmailSendCode(asUser("new"), log, nil, nk, `{"email":"sara@mail.com","purpose":"link"}`); rpcCode(err) != 6 {
		t.Errorf("taking another's email: err %v, want 6", err)
	}
	// an unknown email cannot recover anything
	if _, err := rpcEmailSendCode(asUser("new"), log, nil, nk, `{"email":"nobody@mail.com","purpose":"recover"}`); rpcCode(err) != 5 {
		t.Errorf("recover unknown: err %v, want 5", err)
	}

	// recover on the new phone (the address was mailed a minute ago: wait it out)
	key := emailKey("sara@mail.com")
	var rec emailCode
	_ = json.Unmarshal([]byte(nk.store[EmailCodeCollection+"/"+key+"/"]), &rec)
	rec.SentAt -= 61000
	b, _ := json.Marshal(rec)
	nk.store[EmailCodeCollection+"/"+key+"/"] = string(b)
	if _, err := rpcEmailSendCode(asUser("new"), log, nil, nk, `{"email":"sara@mail.com","purpose":"recover","lang":"fa"}`); err != nil {
		t.Fatalf("send recover code: %v", err)
	}
	out, err := rpcEmailVerify(asUser("new"), log, nil, nk, `{"email":"sara@mail.com","code":"`+(*sent)[1]+`","purpose":"recover"}`)
	if err != nil {
		t.Fatalf("verify recover: %v", err)
	}
	if !strings.Contains(out, `"displayName":"name-old"`) {
		t.Errorf("reply %s, want the old account's profile", out)
	}
	if strings.Join(nk.devices["old"], ",") != "phone-1,phone-2" || len(nk.devices["new"]) != 0 {
		t.Errorf("devices old=%v new=%v, want both phones on the old account", nk.devices["old"], nk.devices["new"])
	}
	if len(nk.deleted) != 1 || nk.deleted[0] != "new" {
		t.Errorf("deleted %v, want the empty new account", nk.deleted)
	}
}

// Codes are rationed: one a minute per address.
func TestEmail_ResendGap(t *testing.T) {
	withMail(t)
	nk := newEmailNK()
	log := &mockLogger{t}
	req := `{"email":"a.b@mail.ir","purpose":"link"}`
	if _, err := rpcEmailSendCode(asUser("u"), log, nil, nk, req); err != nil {
		t.Fatal(err)
	}
	if _, err := rpcEmailSendCode(asUser("u"), log, nil, nk, req); rpcCode(err) != 8 {
		t.Errorf("second code at once: err %v, want 8", err)
	}
}

func TestEmail_Normalize(t *testing.T) {
	for in, ok := range map[string]bool{"Ali@Gmail.com": true, "a@b": false, "no at.com": false, "x@y.co.": false, "<a@b.com>": false} {
		if _, got := normalizeEmail(in); got != ok {
			t.Errorf("normalizeEmail(%q) ok=%v, want %v", in, got, ok)
		}
	}
}

// EMAIL_PREVIEW=<dir> writes the code emails as HTML files to look at.
func TestEmail_Preview(t *testing.T) {
	dir := os.Getenv("EMAIL_PREVIEW")
	if dir == "" {
		t.Skip("set EMAIL_PREVIEW to a folder")
	}
	t.Setenv("SMTP_UNSUBSCRIBE", "{unsubscribe}")
	for _, lang := range []string{"fa", "en"} {
		_, _, html := codeEmail("407152", "link", lang)
		if err := os.WriteFile(filepath.Join(dir, "email_"+lang+".html"), []byte(html), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// EMAIL_LIVE_TO=<address> sends a real code email through the SMTP_* account.
func TestEmail_Live(t *testing.T) {
	to := os.Getenv("EMAIL_LIVE_TO")
	if to == "" {
		t.Skip("set EMAIL_LIVE_TO and the SMTP_* settings")
	}
	subject, text, html := codeEmail("407152", "link", "fa")
	if err := sendMail(to, subject, text, html); err != nil {
		t.Fatal(err)
	}
}
