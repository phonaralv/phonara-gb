export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  public: {
    Tables: {
      admin_review_queue: {
        Row: {
          created_at: string
          entity_id: string
          entity_type: string
          id: string
          payload: Json | null
          queue_type: string
          reason: string | null
          resolved_at: string | null
          resolved_by: string | null
          sla_due_at: string
          status: string
          user_id: string | null
        }
        Insert: {
          created_at?: string
          entity_id: string
          entity_type: string
          id?: string
          payload?: Json | null
          queue_type: string
          reason?: string | null
          resolved_at?: string | null
          resolved_by?: string | null
          sla_due_at: string
          status?: string
          user_id?: string | null
        }
        Update: {
          created_at?: string
          entity_id?: string
          entity_type?: string
          id?: string
          payload?: Json | null
          queue_type?: string
          reason?: string | null
          resolved_at?: string | null
          resolved_by?: string | null
          sla_due_at?: string
          status?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "admin_review_queue_resolved_by_fkey"
            columns: ["resolved_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "admin_review_queue_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      app_config: {
        Row: {
          description: string
          is_public: boolean
          key: string
          updated_at: string
          value: string
        }
        Insert: {
          description?: string
          is_public?: boolean
          key: string
          updated_at?: string
          value: string
        }
        Update: {
          description?: string
          is_public?: boolean
          key?: string
          updated_at?: string
          value?: string
        }
        Relationships: []
      }
      audit_logs: {
        Row: {
          action: string
          actor_id: string | null
          created_at: string
          entity_id: string | null
          entity_type: string | null
          id: string
          ip_address: unknown
          payload: Json | null
          user_agent: string | null
        }
        Insert: {
          action: string
          actor_id?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string | null
          id?: string
          ip_address?: unknown
          payload?: Json | null
          user_agent?: string | null
        }
        Update: {
          action?: string
          actor_id?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string | null
          id?: string
          ip_address?: unknown
          payload?: Json | null
          user_agent?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_logs_actor_id_fkey"
            columns: ["actor_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      bank_incoming_transfers: {
        Row: {
          amount_krw: string
          created_at: string
          depositor_name: string
          id: string
          matched_deposit_id: string | null
          received_at: string
          reconciliation_job_id: string | null
          reference_code: string | null
          transfer_id: string
        }
        Insert: {
          amount_krw: string
          created_at?: string
          depositor_name: string
          id?: string
          matched_deposit_id?: string | null
          received_at?: string
          reconciliation_job_id?: string | null
          reference_code?: string | null
          transfer_id: string
        }
        Update: {
          amount_krw?: string
          created_at?: string
          depositor_name?: string
          id?: string
          matched_deposit_id?: string | null
          received_at?: string
          reconciliation_job_id?: string | null
          reference_code?: string | null
          transfer_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bank_incoming_transfers_matched_deposit_id_fkey"
            columns: ["matched_deposit_id"]
            isOneToOne: false
            referencedRelation: "krw_deposit_requests"
            referencedColumns: ["id"]
          },
        ]
      }
      daily_claims: {
        Row: {
          claimed_date: string
          created_at: string
          id: string
          ledger_entry_id: string | null
          phon_awarded: string
          streak_day: number
          user_id: string
        }
        Insert: {
          claimed_date: string
          created_at?: string
          id?: string
          ledger_entry_id?: string | null
          phon_awarded: string
          streak_day?: number
          user_id: string
        }
        Update: {
          claimed_date?: string
          created_at?: string
          id?: string
          ledger_entry_id?: string | null
          phon_awarded?: string
          streak_day?: number
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "daily_claims_ledger_entry_id_fkey"
            columns: ["ledger_entry_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "daily_claims_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      deposit_reconciliation_jobs: {
        Row: {
          exception_count: number
          id: string
          matched_count: number
          operator_id: string | null
          payload: Json | null
          run_at: string
          source: string
          status: string
        }
        Insert: {
          exception_count?: number
          id?: string
          matched_count?: number
          operator_id?: string | null
          payload?: Json | null
          run_at?: string
          source?: string
          status?: string
        }
        Update: {
          exception_count?: number
          id?: string
          matched_count?: number
          operator_id?: string | null
          payload?: Json | null
          run_at?: string
          source?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "deposit_reconciliation_jobs_operator_id_fkey"
            columns: ["operator_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      exchange_rate_snapshots: {
        Row: {
          base_currency: Database["public"]["Enums"]["currency"]
          captured_at: string
          created_by: string | null
          id: string
          is_active: boolean
          quote_currency: Database["public"]["Enums"]["currency"]
          rate: string
          source: string
        }
        Insert: {
          base_currency: Database["public"]["Enums"]["currency"]
          captured_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          quote_currency: Database["public"]["Enums"]["currency"]
          rate: string
          source?: string
        }
        Update: {
          base_currency?: Database["public"]["Enums"]["currency"]
          captured_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          quote_currency?: Database["public"]["Enums"]["currency"]
          rate?: string
          source?: string
        }
        Relationships: [
          {
            foreignKeyName: "exchange_rate_snapshots_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      futures_markets: {
        Row: {
          base_label: string
          close_fee_rate: string
          created_at: string
          display_name: string
          is_active: boolean
          maintenance_margin_rate: string
          max_leverage: string
          max_open_interest: string | null
          max_user_positions: number
          min_notional: string | null
          open_fee_rate: string
          price_precision: number
          sort_order: number
          symbol: string
          tick_size: string | null
        }
        Insert: {
          base_label: string
          close_fee_rate?: string
          created_at?: string
          display_name: string
          is_active?: boolean
          maintenance_margin_rate?: string
          max_leverage?: string
          max_open_interest?: string | null
          max_user_positions?: number
          min_notional?: string | null
          open_fee_rate?: string
          price_precision?: number
          sort_order?: number
          symbol: string
          tick_size?: string | null
        }
        Update: {
          base_label?: string
          close_fee_rate?: string
          created_at?: string
          display_name?: string
          is_active?: boolean
          maintenance_margin_rate?: string
          max_leverage?: string
          max_open_interest?: string | null
          max_user_positions?: number
          min_notional?: string | null
          open_fee_rate?: string
          price_precision?: number
          sort_order?: number
          symbol?: string
          tick_size?: string | null
        }
        Relationships: []
      }
      futures_positions: {
        Row: {
          close_fee: string | null
          closed_at: string | null
          entry_price: string
          equity_returned: string | null
          exit_price: string | null
          id: string
          leverage: string
          liquidation_price: string
          margin_amount: string
          margin_currency: Database["public"]["Enums"]["currency"]
          market: string
          notional: string
          open_fee: string
          opened_at: string
          quantity: string
          realized_pnl: string | null
          side: Database["public"]["Enums"]["position_side"]
          status: Database["public"]["Enums"]["position_status"]
          stop_loss: string | null
          take_profit: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          close_fee?: string | null
          closed_at?: string | null
          entry_price: string
          equity_returned?: string | null
          exit_price?: string | null
          id?: string
          leverage: string
          liquidation_price: string
          margin_amount: string
          margin_currency: Database["public"]["Enums"]["currency"]
          market: string
          notional: string
          open_fee: string
          opened_at?: string
          quantity: string
          realized_pnl?: string | null
          side: Database["public"]["Enums"]["position_side"]
          status?: Database["public"]["Enums"]["position_status"]
          stop_loss?: string | null
          take_profit?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          close_fee?: string | null
          closed_at?: string | null
          entry_price?: string
          equity_returned?: string | null
          exit_price?: string | null
          id?: string
          leverage?: string
          liquidation_price?: string
          margin_amount?: string
          margin_currency?: Database["public"]["Enums"]["currency"]
          market?: string
          notional?: string
          open_fee?: string
          opened_at?: string
          quantity?: string
          realized_pnl?: string | null
          side?: Database["public"]["Enums"]["position_side"]
          status?: Database["public"]["Enums"]["position_status"]
          stop_loss?: string | null
          take_profit?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "futures_positions_market_fkey"
            columns: ["market"]
            isOneToOne: false
            referencedRelation: "futures_markets"
            referencedColumns: ["symbol"]
          },
          {
            foreignKeyName: "futures_positions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      game_bets: {
        Row: {
          client_seed: string
          created_at: string
          currency: Database["public"]["Enums"]["currency"]
          dust_ledger_transfer_id: string | null
          game: Database["public"]["Enums"]["game_code"]
          house_ledger_transfer_id: string | null
          id: string
          idempotency_key: string
          nonce: number
          parity_hold: boolean
          payout: string | null
          payout_ledger_id: string | null
          result_payload: Json | null
          round_id: string
          selection: Json
          settled_at: string | null
          stake: string
          stake_lock_id: string | null
          status: Database["public"]["Enums"]["bet_status"]
          user_id: string
        }
        Insert: {
          client_seed: string
          created_at?: string
          currency: Database["public"]["Enums"]["currency"]
          dust_ledger_transfer_id?: string | null
          game: Database["public"]["Enums"]["game_code"]
          house_ledger_transfer_id?: string | null
          id?: string
          idempotency_key: string
          nonce?: number
          parity_hold?: boolean
          payout?: string | null
          payout_ledger_id?: string | null
          result_payload?: Json | null
          round_id: string
          selection: Json
          settled_at?: string | null
          stake: string
          stake_lock_id?: string | null
          status?: Database["public"]["Enums"]["bet_status"]
          user_id: string
        }
        Update: {
          client_seed?: string
          created_at?: string
          currency?: Database["public"]["Enums"]["currency"]
          dust_ledger_transfer_id?: string | null
          game?: Database["public"]["Enums"]["game_code"]
          house_ledger_transfer_id?: string | null
          id?: string
          idempotency_key?: string
          nonce?: number
          parity_hold?: boolean
          payout?: string | null
          payout_ledger_id?: string | null
          result_payload?: Json | null
          round_id?: string
          selection?: Json
          settled_at?: string | null
          stake?: string
          stake_lock_id?: string | null
          status?: Database["public"]["Enums"]["bet_status"]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "game_bets_payout_ledger_id_fkey"
            columns: ["payout_ledger_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "game_bets_round_id_fkey"
            columns: ["round_id"]
            isOneToOne: false
            referencedRelation: "game_rounds"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "game_bets_round_id_fkey"
            columns: ["round_id"]
            isOneToOne: false
            referencedRelation: "v_game_rounds_public"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "game_bets_stake_lock_id_fkey"
            columns: ["stake_lock_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "game_bets_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      game_rounds: {
        Row: {
          created_at: string
          game: Database["public"]["Enums"]["game_code"]
          id: string
          result_payload: Json | null
          server_seed: string | null
          server_seed_hash: string
          settled_at: string | null
          status: Database["public"]["Enums"]["round_status"]
        }
        Insert: {
          created_at?: string
          game: Database["public"]["Enums"]["game_code"]
          id?: string
          result_payload?: Json | null
          server_seed?: string | null
          server_seed_hash: string
          settled_at?: string | null
          status?: Database["public"]["Enums"]["round_status"]
        }
        Update: {
          created_at?: string
          game?: Database["public"]["Enums"]["game_code"]
          id?: string
          result_payload?: Json | null
          server_seed?: string | null
          server_seed_hash?: string
          settled_at?: string | null
          status?: Database["public"]["Enums"]["round_status"]
        }
        Relationships: []
      }
      game_seed_reveals: {
        Row: {
          id: string
          revealed_at: string
          round_id: string
          server_seed: string
        }
        Insert: {
          id?: string
          revealed_at?: string
          round_id: string
          server_seed: string
        }
        Update: {
          id?: string
          revealed_at?: string
          round_id?: string
          server_seed?: string
        }
        Relationships: [
          {
            foreignKeyName: "game_seed_reveals_round_id_fkey"
            columns: ["round_id"]
            isOneToOne: false
            referencedRelation: "game_rounds"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "game_seed_reveals_round_id_fkey"
            columns: ["round_id"]
            isOneToOne: false
            referencedRelation: "v_game_rounds_public"
            referencedColumns: ["id"]
          },
        ]
      }
      krw_deposit_requests: {
        Row: {
          admin_note: string | null
          amount_krw: string
          created_at: string
          credited_at: string | null
          expected_phon: string | null
          expires_at: string
          id: string
          matched_at: string | null
          rate_snapshot_id: string | null
          reference_code: string
          status: Database["public"]["Enums"]["deposit_status"]
          updated_at: string
          user_id: string
          wallet_id: string
        }
        Insert: {
          admin_note?: string | null
          amount_krw: string
          created_at?: string
          credited_at?: string | null
          expected_phon?: string | null
          expires_at?: string
          id?: string
          matched_at?: string | null
          rate_snapshot_id?: string | null
          reference_code: string
          status?: Database["public"]["Enums"]["deposit_status"]
          updated_at?: string
          user_id: string
          wallet_id: string
        }
        Update: {
          admin_note?: string | null
          amount_krw?: string
          created_at?: string
          credited_at?: string | null
          expected_phon?: string | null
          expires_at?: string
          id?: string
          matched_at?: string | null
          rate_snapshot_id?: string | null
          reference_code?: string
          status?: Database["public"]["Enums"]["deposit_status"]
          updated_at?: string
          user_id?: string
          wallet_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "krw_deposit_requests_rate_snapshot_id_fkey"
            columns: ["rate_snapshot_id"]
            isOneToOne: false
            referencedRelation: "exchange_rate_snapshots"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "krw_deposit_requests_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "krw_deposit_requests_wallet_id_fkey"
            columns: ["wallet_id"]
            isOneToOne: false
            referencedRelation: "wallets"
            referencedColumns: ["id"]
          },
        ]
      }
      kyc_submissions: {
        Row: {
          country: string
          created_at: string
          document_last4: string
          document_type: string
          id: string
          idempotency_key: string
          legal_name: string
          rejection_reason: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          status: string
          submitted_at: string
          updated_at: string
          user_id: string
        }
        Insert: {
          country: string
          created_at?: string
          document_last4: string
          document_type: string
          id?: string
          idempotency_key: string
          legal_name: string
          rejection_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
          submitted_at?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          country?: string
          created_at?: string
          document_last4?: string
          document_type?: string
          id?: string
          idempotency_key?: string
          legal_name?: string
          rejection_reason?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          status?: string
          submitted_at?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "kyc_submissions_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kyc_submissions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      liquidation_run_log: {
        Row: {
          detail: Json
          duration_ms: number
          errors: number
          id: number
          liquidated: number
          ran_at: string
          skipped: number
        }
        Insert: {
          detail?: Json
          duration_ms: number
          errors: number
          id?: never
          liquidated: number
          ran_at?: string
          skipped: number
        }
        Update: {
          detail?: Json
          duration_ms?: number
          errors?: number
          id?: never
          liquidated?: number
          ran_at?: string
          skipped?: number
        }
        Relationships: []
      }
      market_circuit_breakers: {
        Row: {
          created_at: string
          halt_reason: string | null
          halted_at: string | null
          is_halted: boolean
          max_tick_pct: number
          price_at_halt: string | null
          resumed_at: string | null
          staleness_seconds: number
          symbol: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          halt_reason?: string | null
          halted_at?: string | null
          is_halted?: boolean
          max_tick_pct?: number
          price_at_halt?: string | null
          resumed_at?: string | null
          staleness_seconds?: number
          symbol: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          halt_reason?: string | null
          halted_at?: string | null
          is_halted?: boolean
          max_tick_pct?: number
          price_at_halt?: string | null
          resumed_at?: string | null
          staleness_seconds?: number
          symbol?: string
          updated_at?: string
        }
        Relationships: []
      }
      market_sources: {
        Row: {
          created_at: string
          enabled: boolean
          id: string
          internal_symbol: string
          provider: string
          provider_symbol: string
          updated_at: string
          weight: string
        }
        Insert: {
          created_at?: string
          enabled?: boolean
          id?: string
          internal_symbol: string
          provider: string
          provider_symbol: string
          updated_at?: string
          weight?: string
        }
        Update: {
          created_at?: string
          enabled?: boolean
          id?: string
          internal_symbol?: string
          provider?: string
          provider_symbol?: string
          updated_at?: string
          weight?: string
        }
        Relationships: []
      }
      missions: {
        Row: {
          completed_at: string | null
          created_at: string
          id: string
          ledger_entry_id: string | null
          mission: Database["public"]["Enums"]["mission_code"]
          phon_awarded: string
          user_id: string
        }
        Insert: {
          completed_at?: string | null
          created_at?: string
          id?: string
          ledger_entry_id?: string | null
          mission: Database["public"]["Enums"]["mission_code"]
          phon_awarded?: string
          user_id: string
        }
        Update: {
          completed_at?: string | null
          created_at?: string
          id?: string
          ledger_entry_id?: string | null
          mission?: Database["public"]["Enums"]["mission_code"]
          phon_awarded?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "missions_ledger_entry_id_fkey"
            columns: ["ledger_entry_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "missions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      oracle_prices: {
        Row: {
          price: string
          symbol: string
          updated_at: string
        }
        Insert: {
          price: string
          symbol: string
          updated_at?: string
        }
        Update: {
          price?: string
          symbol?: string
          updated_at?: string
        }
        Relationships: []
      }
      oracle_source_prices: {
        Row: {
          id: string
          price: string
          source_name: string
          submitted_at: string
          symbol: string
        }
        Insert: {
          id?: string
          price: string
          source_name: string
          submitted_at?: string
          symbol: string
        }
        Update: {
          id?: string
          price?: string
          source_name?: string
          submitted_at?: string
          symbol?: string
        }
        Relationships: []
      }
      ops_alerts: {
        Row: {
          ack_reason: string | null
          acknowledged_at: string | null
          acknowledged_by: string | null
          created_at: string
          dedupe_key: string
          first_seen_at: string
          id: string
          last_seen_at: string
          metadata: Json
          occurrence_count: number
          resolve_reason: string | null
          resolved_at: string | null
          resolved_by: string | null
          runbook_key: string
          severity: string
          source_check_id: string
          status: string
          summary: string
          updated_at: string
        }
        Insert: {
          ack_reason?: string | null
          acknowledged_at?: string | null
          acknowledged_by?: string | null
          created_at?: string
          dedupe_key: string
          first_seen_at?: string
          id?: string
          last_seen_at?: string
          metadata?: Json
          occurrence_count?: number
          resolve_reason?: string | null
          resolved_at?: string | null
          resolved_by?: string | null
          runbook_key: string
          severity: string
          source_check_id: string
          status?: string
          summary: string
          updated_at?: string
        }
        Update: {
          ack_reason?: string | null
          acknowledged_at?: string | null
          acknowledged_by?: string | null
          created_at?: string
          dedupe_key?: string
          first_seen_at?: string
          id?: string
          last_seen_at?: string
          metadata?: Json
          occurrence_count?: number
          resolve_reason?: string | null
          resolved_at?: string | null
          resolved_by?: string | null
          runbook_key?: string
          severity?: string
          source_check_id?: string
          status?: string
          summary?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "ops_alerts_acknowledged_by_fkey"
            columns: ["acknowledged_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "ops_alerts_resolved_by_fkey"
            columns: ["resolved_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      position_ledger: {
        Row: {
          created_at: string
          event: string
          fee: string | null
          id: string
          payload: Json | null
          position_id: string
          price: string | null
          realized_pnl: string | null
          user_id: string
        }
        Insert: {
          created_at?: string
          event: string
          fee?: string | null
          id?: string
          payload?: Json | null
          position_id: string
          price?: string | null
          realized_pnl?: string | null
          user_id: string
        }
        Update: {
          created_at?: string
          event?: string
          fee?: string | null
          id?: string
          payload?: Json | null
          position_id?: string
          price?: string | null
          realized_pnl?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "position_ledger_position_id_fkey"
            columns: ["position_id"]
            isOneToOne: false
            referencedRelation: "futures_positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "position_ledger_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      price_change_audit: {
        Row: {
          actor_id: string | null
          change_pct: number | null
          circuit_breaker_triggered: boolean
          created_at: string
          id: string
          price_after: string
          price_before: string | null
          reason: string | null
          source: string
          symbol: string
        }
        Insert: {
          actor_id?: string | null
          change_pct?: number | null
          circuit_breaker_triggered?: boolean
          created_at?: string
          id?: string
          price_after: string
          price_before?: string | null
          reason?: string | null
          source?: string
          symbol: string
        }
        Update: {
          actor_id?: string | null
          change_pct?: number | null
          circuit_breaker_triggered?: boolean
          created_at?: string
          id?: string
          price_after?: string
          price_before?: string | null
          reason?: string | null
          source?: string
          symbol?: string
        }
        Relationships: [
          {
            foreignKeyName: "price_change_audit_actor_id_fkey"
            columns: ["actor_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      price_ticks: {
        Row: {
          created_at: string
          id: string
          price: string
          symbol: string
        }
        Insert: {
          created_at?: string
          id?: string
          price: string
          symbol: string
        }
        Update: {
          created_at?: string
          id?: string
          price?: string
          symbol?: string
        }
        Relationships: []
      }
      profiles: {
        Row: {
          activity_frozen: boolean
          avatar_url: string | null
          ban_reason: string | null
          created_at: string
          display_name: string | null
          id: string
          is_banned: boolean
          kyc_tier: Database["public"]["Enums"]["kyc_tier"]
          legal_name: string | null
          locale: string
          referrer_id: string | null
          role: Database["public"]["Enums"]["user_role"]
          updated_at: string
          username: string | null
        }
        Insert: {
          activity_frozen?: boolean
          avatar_url?: string | null
          ban_reason?: string | null
          created_at?: string
          display_name?: string | null
          id: string
          is_banned?: boolean
          kyc_tier?: Database["public"]["Enums"]["kyc_tier"]
          legal_name?: string | null
          locale?: string
          referrer_id?: string | null
          role?: Database["public"]["Enums"]["user_role"]
          updated_at?: string
          username?: string | null
        }
        Update: {
          activity_frozen?: boolean
          avatar_url?: string | null
          ban_reason?: string | null
          created_at?: string
          display_name?: string | null
          id?: string
          is_banned?: boolean
          kyc_tier?: Database["public"]["Enums"]["kyc_tier"]
          legal_name?: string | null
          locale?: string
          referrer_id?: string | null
          role?: Database["public"]["Enums"]["user_role"]
          updated_at?: string
          username?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "profiles_referrer_id_fkey"
            columns: ["referrer_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      push_subscriptions: {
        Row: {
          auth: string
          created_at: string
          endpoint: string
          id: string
          p256dh: string
          ua: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          auth: string
          created_at?: string
          endpoint: string
          id?: string
          p256dh: string
          ua?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          auth?: string
          created_at?: string
          endpoint?: string
          id?: string
          p256dh?: string
          ua?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "push_subscriptions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      reconciliation_log: {
        Row: {
          broken_count: number | null
          check_type: string
          currency: Database["public"]["Enums"]["currency"] | null
          delta: string
          id: string
          is_match: boolean
          ledger_net: string | null
          notes: string | null
          run_at: string
          triggered_halt: boolean
          wallet_sum: string | null
        }
        Insert: {
          broken_count?: number | null
          check_type?: string
          currency?: Database["public"]["Enums"]["currency"] | null
          delta?: string
          id?: string
          is_match: boolean
          ledger_net?: string | null
          notes?: string | null
          run_at?: string
          triggered_halt?: boolean
          wallet_sum?: string | null
        }
        Update: {
          broken_count?: number | null
          check_type?: string
          currency?: Database["public"]["Enums"]["currency"] | null
          delta?: string
          id?: string
          is_match?: boolean
          ledger_net?: string | null
          notes?: string | null
          run_at?: string
          triggered_halt?: boolean
          wallet_sum?: string | null
        }
        Relationships: []
      }
      referrals: {
        Row: {
          created_at: string
          id: string
          referred_id: string
          referred_ledger_id: string | null
          referred_phon: string
          referrer_id: string
          referrer_ledger_id: string | null
          referrer_phon: string
          rewarded_at: string | null
        }
        Insert: {
          created_at?: string
          id?: string
          referred_id: string
          referred_ledger_id?: string | null
          referred_phon?: string
          referrer_id: string
          referrer_ledger_id?: string | null
          referrer_phon?: string
          rewarded_at?: string | null
        }
        Update: {
          created_at?: string
          id?: string
          referred_id?: string
          referred_ledger_id?: string | null
          referred_phon?: string
          referrer_id?: string
          referrer_ledger_id?: string | null
          referrer_phon?: string
          rewarded_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "referrals_referred_id_fkey"
            columns: ["referred_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "referrals_referred_ledger_id_fkey"
            columns: ["referred_ledger_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "referrals_referrer_id_fkey"
            columns: ["referrer_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "referrals_referrer_ledger_id_fkey"
            columns: ["referrer_ledger_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
        ]
      }
      risk_flags: {
        Row: {
          cleared_at: string | null
          cleared_by: string | null
          created_at: string
          details: Json | null
          flag_type: string
          id: string
          status: string
          user_id: string
        }
        Insert: {
          cleared_at?: string | null
          cleared_by?: string | null
          created_at?: string
          details?: Json | null
          flag_type: string
          id?: string
          status?: string
          user_id: string
        }
        Update: {
          cleared_at?: string | null
          cleared_by?: string | null
          created_at?: string
          details?: Json | null
          flag_type?: string
          id?: string
          status?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "risk_flags_cleared_by_fkey"
            columns: ["cleared_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "risk_flags_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      roulette_spins: {
        Row: {
          created_at: string
          id: string
          ledger_entry_id: string | null
          phon_awarded: string
          prize_index: number
          server_seed: string | null
          server_seed_hash: string
          spun_date: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          ledger_entry_id?: string | null
          phon_awarded: string
          prize_index: number
          server_seed?: string | null
          server_seed_hash: string
          spun_date: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          ledger_entry_id?: string | null
          phon_awarded?: string
          prize_index?: number
          server_seed?: string | null
          server_seed_hash?: string
          spun_date?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "roulette_spins_ledger_entry_id_fkey"
            columns: ["ledger_entry_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "roulette_spins_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      rpc_rate_limit_buckets: {
        Row: {
          last_refill: string
          rpc_name: string
          tokens: number
          user_id: string
        }
        Insert: {
          last_refill?: string
          rpc_name: string
          tokens?: number
          user_id: string
        }
        Update: {
          last_refill?: string
          rpc_name?: string
          tokens?: number
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "rpc_rate_limit_buckets_rpc_name_fkey"
            columns: ["rpc_name"]
            isOneToOne: false
            referencedRelation: "rpc_rate_limit_configs"
            referencedColumns: ["rpc_name"]
          },
          {
            foreignKeyName: "rpc_rate_limit_buckets_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      rpc_rate_limit_configs: {
        Row: {
          capacity: number
          cost: number
          is_active: boolean
          refill_rate: number
          rpc_name: string
          window_sec: number
        }
        Insert: {
          capacity?: number
          cost?: number
          is_active?: boolean
          refill_rate?: number
          rpc_name: string
          window_sec?: number
        }
        Update: {
          capacity?: number
          cost?: number
          is_active?: boolean
          refill_rate?: number
          rpc_name?: string
          window_sec?: number
        }
        Relationships: []
      }
      rpc_request_idem: {
        Row: {
          client_request_id: string
          created_at: string
          rpc_name: string
          user_id: string
        }
        Insert: {
          client_request_id: string
          created_at?: string
          rpc_name: string
          user_id: string
        }
        Update: {
          client_request_id?: string
          created_at?: string
          rpc_name?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "rpc_request_idem_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      sanctions_screenings: {
        Row: {
          created_at: string
          details: Json | null
          id: string
          screened_at: string
          source: string
          status: string
          user_id: string
        }
        Insert: {
          created_at?: string
          details?: Json | null
          id?: string
          screened_at?: string
          source?: string
          status?: string
          user_id: string
        }
        Update: {
          created_at?: string
          details?: Json | null
          id?: string
          screened_at?: string
          source?: string
          status?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sanctions_screenings_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      spot_markets: {
        Row: {
          created_at: string
          display_name: string
          fee_rate: string
          is_active: boolean
          min_notional: string | null
          price_precision: number
          sort_order: number
          symbol: string
          tick_size: string | null
        }
        Insert: {
          created_at?: string
          display_name: string
          fee_rate?: string
          is_active?: boolean
          min_notional?: string | null
          price_precision?: number
          sort_order?: number
          symbol: string
          tick_size?: string | null
        }
        Update: {
          created_at?: string
          display_name?: string
          fee_rate?: string
          is_active?: boolean
          min_notional?: string | null
          price_precision?: number
          sort_order?: number
          symbol?: string
          tick_size?: string | null
        }
        Relationships: []
      }
      spot_trades: {
        Row: {
          created_at: string
          fee_amount: string
          fee_currency: Database["public"]["Enums"]["currency"]
          id: string
          market: string
          phon_amount: string
          price: string
          side: Database["public"]["Enums"]["spot_side"]
          usdt_amount: string
          user_id: string
        }
        Insert: {
          created_at?: string
          fee_amount: string
          fee_currency: Database["public"]["Enums"]["currency"]
          id?: string
          market: string
          phon_amount: string
          price: string
          side: Database["public"]["Enums"]["spot_side"]
          usdt_amount: string
          user_id: string
        }
        Update: {
          created_at?: string
          fee_amount?: string
          fee_currency?: Database["public"]["Enums"]["currency"]
          id?: string
          market?: string
          phon_amount?: string
          price?: string
          side?: Database["public"]["Enums"]["spot_side"]
          usdt_amount?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "spot_trades_market_fkey"
            columns: ["market"]
            isOneToOne: false
            referencedRelation: "spot_markets"
            referencedColumns: ["symbol"]
          },
          {
            foreignKeyName: "spot_trades_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      staking_pools: {
        Row: {
          created_at: string
          estimated_apr: string
          id: string
          is_active: boolean
          lock_days: number
          term: Database["public"]["Enums"]["staking_term"]
        }
        Insert: {
          created_at?: string
          estimated_apr: string
          id?: string
          is_active?: boolean
          lock_days?: number
          term: Database["public"]["Enums"]["staking_term"]
        }
        Update: {
          created_at?: string
          estimated_apr?: string
          id?: string
          is_active?: boolean
          lock_days?: number
          term?: Database["public"]["Enums"]["staking_term"]
        }
        Relationships: []
      }
      staking_positions: {
        Row: {
          apr_snapshot: string
          id: string
          lock_days: number
          pool_id: string
          principal: string
          reward_claimed: string
          staked_at: string
          status: Database["public"]["Enums"]["staking_status"]
          term: Database["public"]["Enums"]["staking_term"]
          unlock_at: string | null
          unstaked_at: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          apr_snapshot: string
          id?: string
          lock_days?: number
          pool_id: string
          principal: string
          reward_claimed?: string
          staked_at?: string
          status?: Database["public"]["Enums"]["staking_status"]
          term: Database["public"]["Enums"]["staking_term"]
          unlock_at?: string | null
          unstaked_at?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          apr_snapshot?: string
          id?: string
          lock_days?: number
          pool_id?: string
          principal?: string
          reward_claimed?: string
          staked_at?: string
          status?: Database["public"]["Enums"]["staking_status"]
          term?: Database["public"]["Enums"]["staking_term"]
          unlock_at?: string | null
          unstaked_at?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "staking_positions_pool_id_fkey"
            columns: ["pool_id"]
            isOneToOne: false
            referencedRelation: "staking_pools"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staking_positions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      staking_rewards: {
        Row: {
          created_at: string
          id: string
          ledger_entry_id: string | null
          reward_amount: string
          staking_position_id: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          ledger_entry_id?: string | null
          reward_amount: string
          staking_position_id: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          ledger_entry_id?: string | null
          reward_amount?: string
          staking_position_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "staking_rewards_ledger_entry_id_fkey"
            columns: ["ledger_entry_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staking_rewards_staking_position_id_fkey"
            columns: ["staking_position_id"]
            isOneToOne: false
            referencedRelation: "staking_positions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staking_rewards_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      str_cases: {
        Row: {
          case_type: string
          created_at: string
          details: Json | null
          id: string
          status: string
          trigger_ref: string | null
          updated_at: string
          user_id: string | null
        }
        Insert: {
          case_type: string
          created_at?: string
          details?: Json | null
          id?: string
          status?: string
          trigger_ref?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Update: {
          case_type?: string
          created_at?: string
          details?: Json | null
          id?: string
          status?: string
          trigger_ref?: string | null
          updated_at?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "str_cases_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      system_account_ledger: {
        Row: {
          account_code: string
          amount: string
          balance_after: string
          balance_before: string
          created_at: string
          currency: Database["public"]["Enums"]["currency"]
          direction: string
          id: string
          prev_hash: string | null
          reason_code: string
          related_tx_id: string | null
          related_user_id: string | null
          row_hash: string | null
          seq: number
          transfer_id: string | null
        }
        Insert: {
          account_code: string
          amount: string
          balance_after: string
          balance_before: string
          created_at?: string
          currency: Database["public"]["Enums"]["currency"]
          direction: string
          id?: string
          prev_hash?: string | null
          reason_code: string
          related_tx_id?: string | null
          related_user_id?: string | null
          row_hash?: string | null
          seq?: number
          transfer_id?: string | null
        }
        Update: {
          account_code?: string
          amount?: string
          balance_after?: string
          balance_before?: string
          created_at?: string
          currency?: Database["public"]["Enums"]["currency"]
          direction?: string
          id?: string
          prev_hash?: string | null
          reason_code?: string
          related_tx_id?: string | null
          related_user_id?: string | null
          row_hash?: string | null
          seq?: number
          transfer_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "system_account_ledger_account_code_fkey"
            columns: ["account_code"]
            isOneToOne: false
            referencedRelation: "system_accounts"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "system_account_ledger_related_user_id_fkey"
            columns: ["related_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      system_accounts: {
        Row: {
          balance: string
          code: string
          created_at: string
          currency: Database["public"]["Enums"]["currency"]
          description: string
          id: string
          updated_at: string
        }
        Insert: {
          balance?: string
          code: string
          created_at?: string
          currency: Database["public"]["Enums"]["currency"]
          description?: string
          id?: string
          updated_at?: string
        }
        Update: {
          balance?: string
          code?: string
          created_at?: string
          currency?: Database["public"]["Enums"]["currency"]
          description?: string
          id?: string
          updated_at?: string
        }
        Relationships: []
      }
      treasury_reserves: {
        Row: {
          buffer_pct: number
          currency: Database["public"]["Enums"]["currency"]
          id: string
          notes: string | null
          payout_cap_pct: number
          real_balance: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          buffer_pct?: number
          currency: Database["public"]["Enums"]["currency"]
          id?: string
          notes?: string | null
          payout_cap_pct?: number
          real_balance?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          buffer_pct?: number
          currency?: Database["public"]["Enums"]["currency"]
          id?: string
          notes?: string | null
          payout_cap_pct?: number
          real_balance?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "treasury_reserves_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      user_consents: {
        Row: {
          accepted: boolean
          accepted_at: string
          doc_type: Database["public"]["Enums"]["consent_doc_type"]
          doc_version: string
          id: string
          ip_address: string | null
          locale: string
          user_agent: string | null
          user_id: string
        }
        Insert: {
          accepted: boolean
          accepted_at?: string
          doc_type: Database["public"]["Enums"]["consent_doc_type"]
          doc_version?: string
          id?: string
          ip_address?: string | null
          locale?: string
          user_agent?: string | null
          user_id: string
        }
        Update: {
          accepted?: boolean
          accepted_at?: string
          doc_type?: Database["public"]["Enums"]["consent_doc_type"]
          doc_version?: string
          id?: string
          ip_address?: string | null
          locale?: string
          user_agent?: string | null
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_consents_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      user_streaks: {
        Row: {
          current_streak: number
          last_claimed_date: string | null
          longest_streak: number
          total_phon_earned: string
          updated_at: string
          user_id: string
        }
        Insert: {
          current_streak?: number
          last_claimed_date?: string | null
          longest_streak?: number
          total_phon_earned?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          current_streak?: number
          last_claimed_date?: string | null
          longest_streak?: number
          total_phon_earned?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_streaks_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      wallet_ledger: {
        Row: {
          amount: string
          available_after: string
          available_before: string
          created_at: string
          currency: Database["public"]["Enums"]["currency"]
          direction: Database["public"]["Enums"]["ledger_direction"]
          id: string
          idempotency_key: string
          locked_after: string
          locked_before: string
          prev_hash: string | null
          rate_snapshot_id: string | null
          reason_code: string
          related_entity_id: string | null
          row_hash: string | null
          seq: number
          transfer_id: string | null
          user_id: string
          wallet_id: string
        }
        Insert: {
          amount: string
          available_after: string
          available_before: string
          created_at?: string
          currency: Database["public"]["Enums"]["currency"]
          direction: Database["public"]["Enums"]["ledger_direction"]
          id?: string
          idempotency_key: string
          locked_after: string
          locked_before: string
          prev_hash?: string | null
          rate_snapshot_id?: string | null
          reason_code: string
          related_entity_id?: string | null
          row_hash?: string | null
          seq?: number
          transfer_id?: string | null
          user_id: string
          wallet_id: string
        }
        Update: {
          amount?: string
          available_after?: string
          available_before?: string
          created_at?: string
          currency?: Database["public"]["Enums"]["currency"]
          direction?: Database["public"]["Enums"]["ledger_direction"]
          id?: string
          idempotency_key?: string
          locked_after?: string
          locked_before?: string
          prev_hash?: string | null
          rate_snapshot_id?: string | null
          reason_code?: string
          related_entity_id?: string | null
          row_hash?: string | null
          seq?: number
          transfer_id?: string | null
          user_id?: string
          wallet_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "wallet_ledger_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "wallet_ledger_wallet_id_fkey"
            columns: ["wallet_id"]
            isOneToOne: false
            referencedRelation: "wallets"
            referencedColumns: ["id"]
          },
        ]
      }
      wallets: {
        Row: {
          created_at: string
          id: string
          krw_available: string
          krw_locked: string
          phon_available: string
          phon_locked: string
          updated_at: string
          usdt_available: string
          usdt_locked: string
          user_id: string
          version: number
        }
        Insert: {
          created_at?: string
          id?: string
          krw_available?: string
          krw_locked?: string
          phon_available?: string
          phon_locked?: string
          updated_at?: string
          usdt_available?: string
          usdt_locked?: string
          user_id: string
          version?: number
        }
        Update: {
          created_at?: string
          id?: string
          krw_available?: string
          krw_locked?: string
          phon_available?: string
          phon_locked?: string
          updated_at?: string
          usdt_available?: string
          usdt_locked?: string
          user_id?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "wallets_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      welcome_bonuses: {
        Row: {
          claimed_at: string
          ledger_entry_id: string | null
          phon_awarded: string
          referral_bonus: string
          user_id: string
        }
        Insert: {
          claimed_at?: string
          ledger_entry_id?: string | null
          phon_awarded: string
          referral_bonus?: string
          user_id: string
        }
        Update: {
          claimed_at?: string
          ledger_entry_id?: string | null
          phon_awarded?: string
          referral_bonus?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "welcome_bonuses_ledger_entry_id_fkey"
            columns: ["ledger_entry_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "welcome_bonuses_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      withdrawal_requests: {
        Row: {
          admin_note: string | null
          amount: string
          approved_at: string | null
          approved_by: string | null
          client_request_id: string | null
          created_at: string
          currency: Database["public"]["Enums"]["currency"]
          destination: Json
          id: string
          idempotency_key: string
          ledger_approve_debit_id: string | null
          ledger_debit_id: string | null
          ledger_lock_id: string | null
          ledger_reject_unlock_id: string | null
          rejected_at: string | null
          rejected_by: string | null
          sent_at: string | null
          sent_by: string | null
          status: Database["public"]["Enums"]["withdrawal_status"]
          system_payout_transfer_id: string | null
          updated_at: string
          user_id: string
          wallet_id: string
        }
        Insert: {
          admin_note?: string | null
          amount: string
          approved_at?: string | null
          approved_by?: string | null
          client_request_id?: string | null
          created_at?: string
          currency: Database["public"]["Enums"]["currency"]
          destination?: Json
          id?: string
          idempotency_key: string
          ledger_approve_debit_id?: string | null
          ledger_debit_id?: string | null
          ledger_lock_id?: string | null
          ledger_reject_unlock_id?: string | null
          rejected_at?: string | null
          rejected_by?: string | null
          sent_at?: string | null
          sent_by?: string | null
          status?: Database["public"]["Enums"]["withdrawal_status"]
          system_payout_transfer_id?: string | null
          updated_at?: string
          user_id: string
          wallet_id: string
        }
        Update: {
          admin_note?: string | null
          amount?: string
          approved_at?: string | null
          approved_by?: string | null
          client_request_id?: string | null
          created_at?: string
          currency?: Database["public"]["Enums"]["currency"]
          destination?: Json
          id?: string
          idempotency_key?: string
          ledger_approve_debit_id?: string | null
          ledger_debit_id?: string | null
          ledger_lock_id?: string | null
          ledger_reject_unlock_id?: string | null
          rejected_at?: string | null
          rejected_by?: string | null
          sent_at?: string | null
          sent_by?: string | null
          status?: Database["public"]["Enums"]["withdrawal_status"]
          system_payout_transfer_id?: string | null
          updated_at?: string
          user_id?: string
          wallet_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "withdrawal_requests_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "withdrawal_requests_ledger_approve_debit_id_fkey"
            columns: ["ledger_approve_debit_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "withdrawal_requests_ledger_debit_id_fkey"
            columns: ["ledger_debit_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "withdrawal_requests_ledger_lock_id_fkey"
            columns: ["ledger_lock_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "withdrawal_requests_ledger_reject_unlock_id_fkey"
            columns: ["ledger_reject_unlock_id"]
            isOneToOne: false
            referencedRelation: "wallet_ledger"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "withdrawal_requests_rejected_by_fkey"
            columns: ["rejected_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "withdrawal_requests_sent_by_fkey"
            columns: ["sent_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "withdrawal_requests_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "withdrawal_requests_wallet_id_fkey"
            columns: ["wallet_id"]
            isOneToOne: false
            referencedRelation: "wallets"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      v_game_rounds_public: {
        Row: {
          created_at: string | null
          game: Database["public"]["Enums"]["game_code"] | null
          id: string | null
          result_payload: Json | null
          server_seed_hash: string | null
          settled_at: string | null
          status: Database["public"]["Enums"]["round_status"] | null
        }
        Insert: {
          created_at?: string | null
          game?: Database["public"]["Enums"]["game_code"] | null
          id?: string | null
          result_payload?: Json | null
          server_seed_hash?: string | null
          settled_at?: string | null
          status?: Database["public"]["Enums"]["round_status"] | null
        }
        Update: {
          created_at?: string | null
          game?: Database["public"]["Enums"]["game_code"] | null
          id?: string | null
          result_payload?: Json | null
          server_seed_hash?: string | null
          settled_at?: string | null
          status?: Database["public"]["Enums"]["round_status"] | null
        }
        Relationships: []
      }
      v_user_consent_latest: {
        Row: {
          accepted: boolean | null
          accepted_at: string | null
          doc_type: Database["public"]["Enums"]["consent_doc_type"] | null
          doc_version: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "user_consents_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Functions: {
      _app_config_numeric: {
        Args: { p_default: number; p_key: string }
        Returns: number
      }
      _apply_sanctions_hit: {
        Args: { p_details?: Json; p_user_id: string }
        Returns: undefined
      }
      _assert_account_activity_live: {
        Args: { p_user_id?: string }
        Returns: undefined
      }
      _assert_amount_text: { Args: { p_value: string }; Returns: undefined }
      _assert_feature_enabled: {
        Args: { p_feature: string }
        Returns: undefined
      }
      _assert_game_exposure_cap: {
        Args: {
          p_currency: Database["public"]["Enums"]["currency"]
          p_game: Database["public"]["Enums"]["game_code"]
          p_selection: Json
          p_stake: number
        }
        Returns: undefined
      }
      _assert_game_feature_enabled: {
        Args: { p_game: Database["public"]["Enums"]["game_code"] }
        Returns: undefined
      }
      _assert_game_stake_limits: {
        Args: {
          p_currency: Database["public"]["Enums"]["currency"]
          p_game: Database["public"]["Enums"]["game_code"]
          p_stake: number
        }
        Returns: undefined
      }
      _assert_kyc_withdrawal_gate: {
        Args: { p_user_id?: string }
        Returns: undefined
      }
      _assert_onboarding_consent: {
        Args: { p_user_id: string }
        Returns: undefined
      }
      _assert_position_limits: {
        Args: { p_market: string; p_new_notional: number; p_user_id: string }
        Returns: undefined
      }
      _assert_price_fresh: { Args: { p_symbol: string }; Returns: number }
      _assert_sanctions_screening: {
        Args: { p_user_id?: string }
        Returns: undefined
      }
      _assert_solvency_withdrawal_gate: {
        Args: { p_currency: Database["public"]["Enums"]["currency"] }
        Returns: undefined
      }
      _assert_system_live: { Args: never; Returns: undefined }
      _compute_oracle_median: { Args: { p_symbol: string }; Returns: number }
      _credit_krw_deposit_internal: {
        Args: { p_deposit_id: string; p_transfer_id: string }
        Returns: string
      }
      _credit_system_account: {
        Args: {
          p_amount: string
          p_code: string
          p_reason_code: string
          p_related_tx_id?: string
          p_related_user_id?: string
          p_transfer_id?: string
        }
        Returns: undefined
      }
      _credit_wallet_internal: {
        Args: {
          p_amount: string
          p_currency: Database["public"]["Enums"]["currency"]
          p_idempotency_key: string
          p_reason_code: string
          p_user_id: string
        }
        Returns: string
      }
      _debit_locked_wallet_internal: {
        Args: {
          p_amount: string
          p_currency: Database["public"]["Enums"]["currency"]
          p_idempotency_key: string
          p_reason_code: string
          p_related_entity_id?: string
          p_transfer_id?: string
          p_user_id: string
        }
        Returns: string
      }
      _debit_system_account: {
        Args: {
          p_amount: string
          p_code: string
          p_reason_code: string
          p_related_tx_id?: string
          p_related_user_id?: string
          p_transfer_id?: string
        }
        Returns: undefined
      }
      _debit_wallet_internal: {
        Args: {
          p_amount: string
          p_currency: Database["public"]["Enums"]["currency"]
          p_idempotency_key: string
          p_reason_code: string
          p_user_id: string
        }
        Returns: string
      }
      _depositor_name_matches: {
        Args: { p_depositor: string; p_legal_name: string }
        Returns: boolean
      }
      _enforce_rate_limit: {
        Args: { p_rpc_name: string; p_user_id: string }
        Returns: undefined
      }
      _enqueue_admin_review: {
        Args: {
          p_entity_id: string
          p_entity_type: string
          p_payload?: Json
          p_queue_type: string
          p_reason: string
          p_user_id: string
        }
        Returns: string
      }
      _fmt6: { Args: { v: number }; Returns: string }
      _game_float_stream: {
        Args: {
          p_client_seed: string
          p_count: number
          p_nonce: number
          p_server_seed: string
        }
        Returns: number[]
      }
      _game_max_payout_multiplier: {
        Args: {
          p_game: Database["public"]["Enums"]["game_code"]
          p_selection: Json
        }
        Returns: number
      }
      _game_result: {
        Args: {
          p_client_seed: string
          p_game: Database["public"]["Enums"]["game_code"]
          p_nonce: number
          p_selection: Json
          p_server_seed: string
        }
        Returns: Json
      }
      _get_wallet_for_user: {
        Args: { p_user_id: string }
        Returns: {
          created_at: string
          id: string
          krw_available: string
          krw_locked: string
          phon_available: string
          phon_locked: string
          updated_at: string
          usdt_available: string
          usdt_locked: string
          user_id: string
          version: number
        }
        SetofOptions: {
          from: "*"
          to: "wallets"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _grant_mission: {
        Args: {
          p_mission: Database["public"]["Enums"]["mission_code"]
          p_user_id: string
        }
        Returns: undefined
      }
      _has_active_risk_flag: {
        Args: { p_flag_type: string; p_user_id: string }
        Returns: boolean
      }
      _hilo_step_multiplier: {
        Args: { p_card: number; p_guess: string }
        Returns: number
      }
      _is_admin: { Args: never; Returns: boolean }
      _is_reward_issuance_reason: {
        Args: { p_reason_code: string }
        Returns: boolean
      }
      _lock_wallet_internal: {
        Args: {
          p_amount: string
          p_currency: Database["public"]["Enums"]["currency"]
          p_idempotency_key: string
          p_reason_code: string
          p_user_id: string
        }
        Returns: string
      }
      _mask_kyc_name: { Args: { p_name: string }; Returns: string }
      _mines_multiplier: {
        Args: { p_mine_count: number; p_reveal_count: number }
        Returns: number
      }
      _normalize_person_name: { Args: { p_name: string }; Returns: string }
      _plinko_multiplier: {
        Args: { p_bucket: number; p_risk: string; p_rows: number }
        Returns: number
      }
      _require_game_float: {
        Args: { p_floats: number[]; p_index: number }
        Returns: number
      }
      _roulette_roll_from_seed: {
        Args: { p_server_seed: string; p_spin_date: string; p_user_id: string }
        Returns: number
      }
      _roulette_weighted_index: { Args: { p_roll: number }; Returns: number }
      _run_liquidations_logged: { Args: never; Returns: undefined }
      _sal_row_hash: {
        Args: {
          p_account_code: string
          p_amount: string
          p_balance_after: string
          p_balance_before: string
          p_currency: string
          p_direction: string
          p_id: string
          p_prev_hash: string
          p_reason_code: string
          p_related_tx_id: string
          p_related_user_id: string
          p_seq: number
          p_transfer_id: string
        }
        Returns: string
      }
      _settle_futures_position: {
        Args: {
          p_event: string
          p_exit: number
          p_pos_id: string
          p_status: Database["public"]["Enums"]["position_status"]
        }
        Returns: Json
      }
      _try_match_krw_deposit: {
        Args: {
          p_amount_krw: string
          p_depositor_name: string
          p_reference_code: string
          p_transfer_id: string
        }
        Returns: Json
      }
      _unlock_wallet_internal: {
        Args: {
          p_amount: string
          p_currency: Database["public"]["Enums"]["currency"]
          p_idempotency_key: string
          p_reason_code: string
          p_user_id: string
        }
        Returns: string
      }
      _uuid_from_md5: { Args: { p_value: string }; Returns: string }
      _wl_row_hash: {
        Args: {
          p_amount: string
          p_available_after: string
          p_currency: string
          p_direction: string
          p_id: string
          p_locked_after: string
          p_prev_hash: string
          p_reason_code: string
          p_seq: number
          p_user_id: string
        }
        Returns: string
      }
      rpc_admin_void_game_bet: {
        Args: { p_bet_id: string; p_reason: string }
        Returns: Json
      }
      rpc_approve_withdrawal: {
        Args: { p_reason: string; p_withdrawal_id: string }
        Returns: Json
      }
      rpc_cancel_game_bet: { Args: { p_bet_id: string }; Returns: Json }
      rpc_check_onboarding_consent: { Args: never; Returns: Json }
      rpc_check_reserve_ratio: { Args: never; Returns: Json }
      rpc_claim_daily_reward: { Args: never; Returns: Json }
      rpc_claim_staking_reward: {
        Args: { p_position_id: string }
        Returns: Json
      }
      rpc_claim_welcome_bonus: {
        Args: { p_idempotency_key?: string }
        Returns: Json
      }
      rpc_clear_risk_flag: {
        Args: { p_flag_id: string; p_reason: string }
        Returns: Json
      }
      rpc_close_futures_position: {
        Args: { p_position_id: string }
        Returns: Json
      }
      rpc_complete_mission: { Args: { p_mission: string }; Returns: Json }
      rpc_contribute_insurance_capital: {
        Args: {
          p_amount: string
          p_confirm_large_change?: boolean
          p_currency: string
          p_idempotency_key: string
          p_reason: string
        }
        Returns: Json
      }
      rpc_create_game_round: {
        Args: {
          p_game: string
          p_server_seed: string
          p_server_seed_hash?: string
        }
        Returns: Json
      }
      rpc_create_krw_deposit_request: {
        Args: { p_amount_krw: string; p_client_request_id?: string }
        Returns: Json
      }
      rpc_disable_market_source: {
        Args: {
          p_internal_symbol: string
          p_provider: string
          p_reason: string
        }
        Returns: Json
      }
      rpc_get_candles: {
        Args: { p_interval: string; p_limit?: number; p_symbol: string }
        Returns: Json
      }
      rpc_get_ops_health: { Args: never; Returns: Json }
      rpc_get_ops_alerts: {
        Args: { p_resolved_days?: number; p_statuses?: string[] | null }
        Returns: Json
      }
      rpc_ack_ops_alert: {
        Args: { p_alert_id: string; p_reason: string }
        Returns: Json
      }
      rpc_resolve_ops_alert: {
        Args: { p_alert_id: string; p_reason: string }
        Returns: Json
      }
      rpc_sync_ops_alerts_from_health: { Args: never; Returns: Json }
      rpc_get_synthetic_book: {
        Args: { p_levels?: number; p_symbol: string }
        Returns: Json
      }
      rpc_liquidate_position: { Args: { p_position_id: string }; Returns: Json }
      rpc_lock_wallet: {
        Args: {
          p_amount: string
          p_currency: Database["public"]["Enums"]["currency"]
          p_idempotency_key: string
          p_reason_code: string
          p_related_entity_id?: string
        }
        Returns: string
      }
      rpc_mark_withdrawal_sent: {
        Args: { p_reason: string; p_withdrawal_id: string }
        Returns: Json
      }
      rpc_open_futures_position: {
        Args: {
          p_client_request_id?: string
          p_leverage: string
          p_margin_amount: string
          p_margin_currency: string
          p_market: string
          p_side: string
          p_stop_loss?: string
          p_take_profit?: string
        }
        Returns: Json
      }
      rpc_open_game_round: { Args: { p_game: string }; Returns: Json }
      rpc_place_game_bet: {
        Args: {
          p_client_seed: string
          p_currency: string
          p_expected_result?: Json
          p_idempotency_key: string
          p_round_id: string
          p_selection: Json
          p_stake: string
        }
        Returns: Json
      }
      rpc_process_bank_transfer: {
        Args: {
          p_amount_krw: string
          p_depositor_name: string
          p_reference_code: string
          p_transfer_id: string
        }
        Returns: Json
      }
      rpc_record_consent: {
        Args: {
          p_accepted: boolean
          p_doc_type: string
          p_doc_version: string
          p_ip_address?: string
          p_locale?: string
          p_user_agent?: string
        }
        Returns: Json
      }
      rpc_register_referral: {
        Args: { p_referrer_code: string }
        Returns: Json
      }
      rpc_reject_withdrawal: {
        Args: { p_reason: string; p_withdrawal_id: string }
        Returns: Json
      }
      rpc_request_withdrawal: {
        Args: {
          p_amount: string
          p_client_request_id?: string
          p_currency: string
          p_destination: Json
          p_idempotency_key: string
        }
        Returns: Json
      }
      rpc_resolve_admin_review_queue: {
        Args: { p_queue_id: string; p_reason: string }
        Returns: Json
      }
      rpc_resume_market: {
        Args: { p_reason: string; p_symbol: string }
        Returns: Json
      }
      rpc_reveal_game_round: { Args: { p_round_id: string }; Returns: Json }
      rpc_reveal_roulette_spin: {
        Args: { p_spin_date?: string }
        Returns: Json
      }
      rpc_review_kyc_submission: {
        Args: { p_reason: string; p_status: string; p_submission_id: string }
        Returns: Json
      }
      rpc_run_liquidations: { Args: never; Returns: Json }
      rpc_run_reconciliation: { Args: never; Returns: Json }
      rpc_set_feature_enabled: {
        Args: { p_enabled: boolean; p_feature: string; p_reason: string }
        Returns: Json
      }
      rpc_set_market_limits: {
        Args: {
          p_market: string
          p_max_leverage: string
          p_max_open_interest: string
          p_max_user_positions: number
          p_reason: string
        }
        Returns: Json
      }
      rpc_set_market_source: {
        Args: {
          p_enabled: boolean
          p_internal_symbol: string
          p_provider: string
          p_provider_symbol: string
          p_reason: string
          p_weight: string
        }
        Returns: Json
      }
      rpc_set_system_mode: {
        Args: { p_halt: boolean; p_readonly: boolean; p_reason: string }
        Returns: Json
      }
      rpc_settle_game_bet: {
        Args: { p_bet_id: string; p_server_seed: string }
        Returns: Json
      }
      rpc_spin_roulette: { Args: never; Returns: Json }
      rpc_spot_market_buy: {
        Args: { p_client_request_id?: string; p_usdt_spent: string }
        Returns: Json
      }
      rpc_spot_market_sell: {
        Args: { p_client_request_id?: string; p_phon_sold: string }
        Returns: Json
      }
      rpc_stake_phon: {
        Args: { p_amount: string; p_client_request_id?: string; p_term: string }
        Returns: Json
      }
      rpc_submit_kyc: {
        Args: { p_idempotency_key: string; p_payload: Json }
        Returns: Json
      }
      rpc_submit_oracle_source_price: {
        Args: { p_price: string; p_source_name: string; p_symbol: string }
        Returns: Json
      }
      rpc_sweep_stale_game_bets: { Args: never; Returns: Json }
      rpc_unlock_wallet: {
        Args: {
          p_amount: string
          p_currency: Database["public"]["Enums"]["currency"]
          p_idempotency_key: string
          p_reason_code: string
          p_related_entity_id?: string
        }
        Returns: string
      }
      rpc_unstake_phon: { Args: { p_position_id: string }; Returns: Json }
      rpc_update_oracle_price: {
        Args: {
          p_price: string
          p_reason?: string
          p_source?: string
          p_symbol: string
        }
        Returns: Json
      }
      rpc_update_str_case_status: {
        Args: { p_case_id: string; p_reason: string; p_status: string }
        Returns: Json
      }
      rpc_update_treasury_reserve: {
        Args: {
          p_balance: string
          p_buffer_pct?: number
          p_cap_pct?: number
          p_confirm_large_change?: boolean
          p_currency: string
          p_notes?: string
        }
        Returns: Json
      }
      verify_ledger_hash_chain: {
        Args: { p_user_id?: string }
        Returns: {
          actual: string
          broken_user_id: string
          entry_id: string
          entry_seq: number
          expected: string
        }[]
      }
      verify_system_account_hash_chain: {
        Args: { p_account_code?: string }
        Returns: {
          actual: string
          broken_account_code: string
          entry_id: string
          entry_seq: number
          expected: string
        }[]
      }
    }
    Enums: {
      admin_role:
        | "owner"
        | "finance"
        | "risk"
        | "support"
        | "operator"
        | "viewer"
      bet_status: "pending" | "won" | "lost" | "cancelled"
      consent_doc_type:
        | "terms_of_service"
        | "privacy_policy"
        | "risk_disclosure"
        | "age_verification"
        | "marketing_opt_in"
        | "push_notification"
        | "trading_risk_acknowledgement"
        | "game_risk_acknowledgement"
        | "withdrawal_policy_acknowledgement"
      currency: "PHON" | "USDT" | "KRW"
      deposit_status:
        | "pending"
        | "matched"
        | "credited"
        | "failed"
        | "expired"
        | "unmatched"
        | "disputed"
        | "admin_rejected"
      game_code: "crash" | "limbo" | "dice" | "mines" | "hilo" | "plinko"
      kyc_tier:
        | "anonymous"
        | "email_verified"
        | "phone_verified"
        | "id_verified"
      ledger_direction: "credit" | "debit" | "lock" | "unlock" | "reverse"
      mission_code:
        | "complete_profile"
        | "first_trade"
        | "first_game"
        | "first_deposit"
        | "kyc_verified"
        | "invite_3_friends"
        | "streak_7_days"
        | "streak_30_days"
      position_side: "long" | "short"
      position_status: "open" | "closed" | "liquidated"
      round_status: "open" | "settled" | "cancelled"
      spot_side: "buy" | "sell"
      staking_status: "active" | "unstaked"
      staking_term: "flexible" | "days_7" | "days_30" | "days_90"
      user_role: "user" | "admin"
      withdrawal_status:
        | "pending"
        | "approved"
        | "processing"
        | "completed"
        | "rejected"
        | "cancelled"
        | "sent"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      admin_role: ["owner", "finance", "risk", "support", "operator", "viewer"],
      bet_status: ["pending", "won", "lost", "cancelled"],
      consent_doc_type: [
        "terms_of_service",
        "privacy_policy",
        "risk_disclosure",
        "age_verification",
        "marketing_opt_in",
        "push_notification",
        "trading_risk_acknowledgement",
        "game_risk_acknowledgement",
        "withdrawal_policy_acknowledgement",
      ],
      currency: ["PHON", "USDT", "KRW"],
      deposit_status: [
        "pending",
        "matched",
        "credited",
        "failed",
        "expired",
        "unmatched",
        "disputed",
        "admin_rejected",
      ],
      game_code: ["crash", "limbo", "dice", "mines", "hilo", "plinko"],
      kyc_tier: [
        "anonymous",
        "email_verified",
        "phone_verified",
        "id_verified",
      ],
      ledger_direction: ["credit", "debit", "lock", "unlock", "reverse"],
      mission_code: [
        "complete_profile",
        "first_trade",
        "first_game",
        "first_deposit",
        "kyc_verified",
        "invite_3_friends",
        "streak_7_days",
        "streak_30_days",
      ],
      position_side: ["long", "short"],
      position_status: ["open", "closed", "liquidated"],
      round_status: ["open", "settled", "cancelled"],
      spot_side: ["buy", "sell"],
      staking_status: ["active", "unstaked"],
      staking_term: ["flexible", "days_7", "days_30", "days_90"],
      user_role: ["user", "admin"],
      withdrawal_status: [
        "pending",
        "approved",
        "processing",
        "completed",
        "rejected",
        "cancelled",
        "sent",
      ],
    },
  },
} as const
