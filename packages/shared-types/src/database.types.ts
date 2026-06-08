export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
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
            foreignKeyName: "daily_claims_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
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
            foreignKeyName: "missions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
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
            foreignKeyName: "referrals_referrer_id_fkey"
            columns: ["referrer_id"]
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
            foreignKeyName: "roulette_spins_user_id_fkey"
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
            foreignKeyName: "welcome_bonuses_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          avatar_url: string | null
          ban_reason: string | null
          created_at: string
          display_name: string | null
          id: string
          is_banned: boolean
          kyc_tier: Database["public"]["Enums"]["kyc_tier"]
          locale: string
          referrer_id: string | null
          role: Database["public"]["Enums"]["user_role"]
          updated_at: string
          username: string | null
        }
        Insert: {
          avatar_url?: string | null
          ban_reason?: string | null
          created_at?: string
          display_name?: string | null
          id: string
          is_banned?: boolean
          kyc_tier?: Database["public"]["Enums"]["kyc_tier"]
          locale?: string
          referrer_id?: string | null
          role?: Database["public"]["Enums"]["user_role"]
          updated_at?: string
          username?: string | null
        }
        Update: {
          avatar_url?: string | null
          ban_reason?: string | null
          created_at?: string
          display_name?: string | null
          id?: string
          is_banned?: boolean
          kyc_tier?: Database["public"]["Enums"]["kyc_tier"]
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
          rate_snapshot_id: string | null
          reason_code: string
          related_entity_id: string | null
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
          rate_snapshot_id?: string | null
          reason_code: string
          related_entity_id?: string | null
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
          rate_snapshot_id?: string | null
          reason_code?: string
          related_entity_id?: string | null
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
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
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
      }
      rpc_credit_wallet: {
        Args: {
          p_amount: string
          p_currency: Database["public"]["Enums"]["currency"]
          p_idempotency_key: string
          p_rate_snapshot_id?: string
          p_reason_code: string
          p_related_entity_id?: string
        }
        Returns: string
      }
      rpc_debit_wallet: {
        Args: {
          p_amount: string
          p_currency: Database["public"]["Enums"]["currency"]
          p_idempotency_key: string
          p_rate_snapshot_id?: string
          p_reason_code: string
          p_related_entity_id?: string
        }
        Returns: string
      }
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
      rpc_claim_welcome_bonus: {
        Args: { p_idempotency_key?: string }
        Returns: Json
      }
      rpc_claim_daily_reward: {
        Args: Record<string, never>
        Returns: Json
      }
      rpc_spin_roulette: {
        Args: Record<string, never>
        Returns: Json
      }
      rpc_complete_mission: {
        Args: { p_mission: string }
        Returns: Json
      }
      rpc_register_referral: {
        Args: { p_referrer_code: string }
        Returns: Json
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
      currency: "PHON" | "USDT" | "KRW"
      deposit_status: "pending" | "matched" | "credited" | "failed" | "expired"
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
      user_role: "user" | "admin"
      withdrawal_status:
        | "pending"
        | "approved"
        | "processing"
        | "completed"
        | "rejected"
        | "cancelled"
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

export const Constants = {
  public: {
    Enums: {
      admin_role: ["owner", "finance", "risk", "support", "operator", "viewer"],
      currency: ["PHON", "USDT", "KRW"],
      deposit_status: ["pending", "matched", "credited", "failed", "expired"],
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
      user_role: ["user", "admin"],
      withdrawal_status: [
        "pending",
        "approved",
        "processing",
        "completed",
        "rejected",
        "cancelled",
      ],
    },
  },
} as const
