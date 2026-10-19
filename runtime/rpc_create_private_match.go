package main

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

// privateInviteDoc is the storage record written when a private match is created (§15).
// System-owned (UserID="") so it can be read by the server without knowing the host's ID.
type privateInviteDoc struct {
	MatchID    string   `json:"matchId"`
	HostID     string   `json:"hostId"`
	InvitedIDs []string `json:"invitedIds"`
	Status     string   `json:"status"` // "open" | "closed"
	// A room opened with a code admits anyone who has the code.
	Code string `json:"code,omitempty"`
	Open bool   `json:"open,omitempty"`
}

type createPrivateMatchRequest struct {
	PlayerCount      int      `json:"playerCount"`
	InvitedFriendIds []string `json:"invitedFriendIds"` // empty: a room with a code to share instead
	WinThreshold     int      `json:"winThreshold"`     // optional: one of WinThresholdOptions, default WinThreshold
}

type createPrivateMatchResponse struct {
	MatchID string `json:"matchId"`
	Code    string `json:"code,omitempty"` // the room code, when no friends were named
}

// rpcCreatePrivateMatch implements the create_private_match RPC (BACKEND_DOC §16.2).
// Creates an unrated authoritative match, writes the invite record, and sends
// in-app notifications to each invited friend.
func rpcCreatePrivateMatch(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok || userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}

	var req createPrivateMatchRequest
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return "", runtime.NewError("invalid payload", 3)
	}

	if req.PlayerCount < 2 || req.PlayerCount > 4 {
		return "", runtime.NewError("playerCount must be 2, 3, or 4", 3)
	}
	withCode := len(req.InvitedFriendIds) == 0
	if !withCode && len(req.InvitedFriendIds) != req.PlayerCount-1 {
		return "", runtime.NewError("invitedFriendIds length must equal playerCount-1", 3)
	}
	if req.WinThreshold == 0 {
		req.WinThreshold = WinThreshold
	}
	if !validWinThreshold(req.WinThreshold) {
		return "", runtime.NewError("winThreshold must be 15, 18, 21, 25 or 30", 3)
	}

	meta, err := readMetadata(ctx, nk, userID)
	if err != nil {
		return "", runtime.NewError("failed to read account", 13)
	}
	if meta.ActiveMatchID != nil {
		return "", runtime.NewError("already in a match", 9)
	}

	matchID, err := nk.MatchCreate(ctx, "splendor_match", map[string]interface{}{
		"rated":        false,
		"playerCount":  req.PlayerCount,
		"hostUserId":   userID,
		"winThreshold": req.WinThreshold,
	})
	if err != nil {
		return "", runtime.NewError("failed to create match", 13)
	}

	// Write system-owned invite record so MatchJoinAttempt and join_private_match
	// can look it up by matchId without needing the host's user ID.
	doc := privateInviteDoc{
		MatchID:    matchID,
		HostID:     userID,
		InvitedIDs: req.InvitedFriendIds,
		Status:     "open",
		Open:       withCode,
	}
	if withCode {
		code, err := newRoomCode(ctx, nk, matchID)
		if err != nil {
			return "", runtime.NewError("failed to open a room code", 13)
		}
		doc.Code = code
	}
	docBytes, err := json.Marshal(doc)
	if err != nil {
		return "", runtime.NewError("failed to encode invite record", 13)
	}
	if _, err := nk.StorageWrite(ctx, []*runtime.StorageWrite{
		{
			Collection:      "private_invites",
			Key:             matchID,
			UserID:          "",
			Value:           string(docBytes),
			PermissionRead:  runtime.STORAGE_PERMISSION_NO_READ, // server-only reads
			PermissionWrite: runtime.STORAGE_PERMISSION_NO_WRITE,
		},
	}); err != nil {
		return "", runtime.NewError("failed to write invite record", 13)
	}

	// Notify each invited friend (§6, §14).
	notifs := make([]*runtime.NotificationSend, 0, len(req.InvitedFriendIds))
	for _, friendID := range req.InvitedFriendIds {
		notifs = append(notifs, &runtime.NotificationSend{
			UserID:     friendID,
			Subject:    "private_match_invite",
			Content:    map[string]interface{}{"matchId": matchID},
			Code:       1001,
			Sender:     userID,
			Persistent: true,
		})
	}
	if err := nk.NotificationsSend(ctx, notifs); err != nil {
		return "", runtime.NewError("failed to send invite notifications", 13)
	}

	// Stamp the host's activeMatchId now that the match is created.
	meta.ActiveMatchID = &matchID
	if err := writeMetadata(ctx, nk, userID, meta); err != nil {
		return "", runtime.NewError("failed to update account", 13)
	}

	out, _ := json.Marshal(createPrivateMatchResponse{MatchID: matchID, Code: doc.Code})
	return string(out), nil
}
