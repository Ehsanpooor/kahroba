package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"fmt"
	"math/big"
	"strings"

	"github.com/heroiclabs/nakama-common/runtime"
)

// Room codes: a private match created without named friends gets a 6-digit
// code. Whoever has the code can join with join_by_code, then joins the
// match on the socket as usual. Codes live in the system-owned "room_codes"
// collection, keyed by the code.

const roomCodeCollection = "room_codes"

type roomCodeDoc struct {
	MatchID string `json:"matchId"`
}

type joinByCodeRequest struct {
	Code string `json:"code"`
}

type joinByCodeResponse struct {
	MatchID string `json:"matchId"`
}

// newRoomCode picks an unused 6-digit code and stores it for matchID.
func newRoomCode(ctx context.Context, nk runtime.NakamaModule, matchID string) (string, error) {
	for try := 0; try < 20; try++ {
		n, err := rand.Int(rand.Reader, big.NewInt(900000))
		if err != nil {
			return "", err
		}
		code := fmt.Sprintf("%06d", n.Int64()+100000)
		existing, err := nk.StorageRead(ctx, []*runtime.StorageRead{{Collection: roomCodeCollection, Key: code, UserID: ""}})
		if err != nil {
			return "", err
		}
		if len(existing) > 0 && roomCodeLive(ctx, nk, existing[0].GetValue()) {
			continue
		}
		b, _ := json.Marshal(roomCodeDoc{MatchID: matchID})
		if _, err := nk.StorageWrite(ctx, []*runtime.StorageWrite{{
			Collection:      roomCodeCollection,
			Key:             code,
			UserID:          "",
			Value:           string(b),
			PermissionRead:  runtime.STORAGE_PERMISSION_NO_READ,
			PermissionWrite: runtime.STORAGE_PERMISSION_NO_WRITE,
		}}); err != nil {
			return "", err
		}
		return code, nil
	}
	return "", fmt.Errorf("no free room code")
}

// roomCodeLive reports whether the match a stored code points at still runs,
// so an old code can be handed out again.
func roomCodeLive(ctx context.Context, nk runtime.NakamaModule, value string) bool {
	var doc roomCodeDoc
	if json.Unmarshal([]byte(value), &doc) != nil || doc.MatchID == "" {
		return false
	}
	m, err := nk.MatchGet(ctx, doc.MatchID)
	return err == nil && m != nil
}

// rpcJoinByCode turns a room code into the match to join.
func rpcJoinByCode(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok || userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}
	var req joinByCodeRequest
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return "", runtime.NewError("invalid payload", 3)
	}
	code := strings.TrimSpace(req.Code)
	if len(code) != 6 {
		return "", runtime.NewError("code must be 6 digits", 3)
	}
	objects, err := nk.StorageRead(ctx, []*runtime.StorageRead{{Collection: roomCodeCollection, Key: code, UserID: ""}})
	if err != nil {
		return "", runtime.NewError("failed to read room code", 13)
	}
	if len(objects) == 0 {
		return "", runtime.NewError("room not found", 5)
	}
	var doc roomCodeDoc
	if err := json.Unmarshal([]byte(objects[0].GetValue()), &doc); err != nil || doc.MatchID == "" {
		return "", runtime.NewError("room not found", 5)
	}
	m, err := nk.MatchGet(ctx, doc.MatchID)
	if err != nil || m == nil {
		return "", runtime.NewError("room not found", 5)
	}
	meta, err := readMetadata(ctx, nk, userID)
	if err != nil {
		return "", runtime.NewError("failed to read account", 13)
	}
	if meta.ActiveMatchID != nil && *meta.ActiveMatchID != doc.MatchID {
		return "", runtime.NewError("already in a match", 9)
	}
	out, _ := json.Marshal(joinByCodeResponse{MatchID: doc.MatchID})
	return string(out), nil
}
