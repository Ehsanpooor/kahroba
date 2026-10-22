package main

import (
	"context"
	"database/sql"

	"github.com/heroiclabs/nakama-common/runtime"
)

func InitModule(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, initializer runtime.Initializer) error {
	logger.Info("module loaded")

	if err := initializer.RegisterRpc("get_catalog", rpcGetCatalog); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("bootstrap_profile", rpcBootstrapProfile); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("get_active_game", rpcGetActiveGame); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("start_public_search", rpcStartPublicSearch); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("create_private_match", rpcCreatePrivateMatch); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("join_private_match", rpcJoinPrivateMatch); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("join_by_code", rpcJoinByCode); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("concede_match", rpcConcedeMatch); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("create_ai_match", rpcCreateAIMatch); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("submit_ai_result", rpcSubmitAIResult); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("report_player", rpcReportPlayer); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("get_match_history", rpcGetMatchHistory); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("email_status", rpcEmailStatus); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("email_send_code", rpcEmailSendCode); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("email_verify", rpcEmailVerify); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("get_client_config", rpcGetClientConfig); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("track", rpcTrack); err != nil {
		return err
	}
	// The admin page's RPCs: refused with a player's session, reached with
	// the runtime http key through nginx (deploy/nginx/splendor.conf).
	if err := initializer.RegisterRpc("admin_get_config", rpcAdminGetConfig); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("admin_set_config", rpcAdminSetConfig); err != nil {
		return err
	}
	if err := initializer.RegisterRpc("admin_stats", rpcAdminStats); err != nil {
		return err
	}
	loadClientConfig(ctx, logger, nk)
	initAnalytics(ctx, logger, db)
	if err := nk.LeaderboardCreate(ctx, LeaderboardID, true, "desc", "set", "", nil); err != nil {
		logger.Warn("LeaderboardCreate: %v (may already exist)", err)
	}
	initPersonas(ctx, logger, nk)
	if err := initializer.RegisterMatchmakerMatched(onMatchmakerMatched); err != nil {
		return err
	}
	if err := initializer.RegisterMatch("splendor_match", func(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule) (runtime.Match, error) {
		return &SplendorMatch{}, nil
	}); err != nil {
		return err
	}

	return nil
}
