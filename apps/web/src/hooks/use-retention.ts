import { useState, useCallback } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../lib/supabase'
import type { MessageKey } from '@phonara/i18n'
import { useAuth } from '../contexts/auth-context'
import { translateError } from '../lib/translate-error'

// ─── Types ────────────────────────────────────────────────────

export interface WelcomeBonusResult {
  already_claimed: boolean
  phon_awarded: string
  referral_bonus: string
}

export interface DailyClaimResult {
  already_claimed: boolean
  phon_awarded: string
  streak_day: number
  next_day_preview: string
}

export interface RouletteResult {
  already_spun: boolean
  prize_index: number
  phon_awarded: string
  seed_hash: string
  seed_revealed: string
}

export interface UserStreak {
  current_streak: number
  longest_streak: number
  last_claimed_date: string | null
  total_phon_earned: string
}

export interface MissionStatus {
  mission: string
  phon_awarded: string
  completed_at: string | null
}

// ─── Roulette prizes (must match SQL) ─────────────────────────

export const ROULETTE_PRIZES = [10, 20, 30, 50, 100, 300, 500, 1000] as const

export const ROULETTE_LABELS = [
  '10 PHON',
  '20 PHON',
  '30 PHON',
  '50 PHON',
  '100 PHON',
  '300 PHON',
  '500 PHON',
  '1,000 PHON 🎉',
] as const

// ─── Query keys ───────────────────────────────────────────────

export const retentionKeys = {
  streak: (userId: string | null) => ['streak', userId] as const,
  missions: (userId: string | null) => ['missions', userId] as const,
  rouletteToday: (userId: string | null, date: string) => ['roulette-today', userId, date] as const,
  welcomeClaimed: (userId: string | null) => ['welcome-claimed', userId] as const,
  referralDashboard: (userId: string | null) => ['referral-dashboard', userId] as const,
}

// ─── Welcome Bonus hook ───────────────────────────────────────

export function useWelcomeBonus() {
  const { session } = useAuth()
  const userId = session?.user.id ?? null
  const qc = useQueryClient()

  const [loading, setLoading] = useState(false)
  const [result, setResult] = useState<WelcomeBonusResult | null>(null)
  const [error, setError] = useState<MessageKey | null>(null)

  const { data: claimedData } = useQuery({
    queryKey: retentionKeys.welcomeClaimed(userId),
    queryFn: async () => {
      if (!userId) return null
      const { data } = await supabase
        .from('welcome_bonuses')
        .select('phon_awarded, referral_bonus, claimed_at')
        .eq('user_id', userId)
        .maybeSingle()
      return data
    },
    enabled: !!userId,
  })

  const claimWelcomeBonus = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const { data, error: rpcError } = await supabase.rpc('rpc_claim_welcome_bonus')
      if (rpcError) throw rpcError
      const claimed = data as unknown as WelcomeBonusResult
      setResult(claimed)
      void qc.invalidateQueries({ queryKey: retentionKeys.welcomeClaimed(userId) })
      return claimed
    } catch (err) {
      setError(translateError(err, 'error.WELCOME_CLAIM_FAILED'))
      return null
    } finally {
      setLoading(false)
    }
  }, [qc, userId])

  const checkClaimed = useCallback(async () => {
    if (!userId) return false
    if (claimedData) {
      setResult({
        already_claimed: true,
        phon_awarded: claimedData.phon_awarded,
        referral_bonus: claimedData.referral_bonus,
      })
      return true
    }
    return false
  }, [userId, claimedData])

  return { claimWelcomeBonus, checkClaimed, result, loading, error }
}

// ─── Daily Claim hook ─────────────────────────────────────────

export function useDailyClaim() {
  const { session } = useAuth()
  const userId = session?.user.id ?? null
  const qc = useQueryClient()

  const [loading, setLoading] = useState(false)
  const [result, setResult] = useState<DailyClaimResult | null>(null)
  const [error, setError] = useState<MessageKey | null>(null)

  const { data: streak = null } = useQuery({
    queryKey: retentionKeys.streak(userId),
    queryFn: async () => {
      const { data } = await supabase
        .from('user_streaks')
        .select('current_streak, longest_streak, last_claimed_date, total_phon_earned')
        .eq('user_id', userId!)
        .maybeSingle()
      return (data as UserStreak | null) ?? null
    },
    enabled: !!userId,
  })

  const fetchStreak = useCallback(() => {
    void qc.invalidateQueries({ queryKey: retentionKeys.streak(userId) })
  }, [qc, userId])

  const claimDaily = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const { data, error: rpcError } = await supabase.rpc('rpc_claim_daily_reward')
      if (rpcError) throw rpcError
      const claimed = data as unknown as DailyClaimResult
      setResult(claimed)
      void qc.invalidateQueries({ queryKey: retentionKeys.streak(userId) })
      return claimed
    } catch (err) {
      setError(translateError(err, 'error.DAILY_CLAIM_FAILED'))
      return null
    } finally {
      setLoading(false)
    }
  }, [qc, userId])

  const canClaimToday = useCallback(() => {
    if (!streak?.last_claimed_date) return true
    const today = new Date().toISOString().split('T')[0]
    return streak.last_claimed_date !== today
  }, [streak])

  return { claimDaily, fetchStreak, canClaimToday, result, streak, loading, error }
}

// ─── Roulette hook ────────────────────────────────────────────

export function useRoulette() {
  const { session } = useAuth()
  const userId = session?.user.id ?? null
  const qc = useQueryClient()
  const today = new Date().toISOString().slice(0, 10)

  const [loading, setLoading] = useState(false)
  const [result, setResult] = useState<RouletteResult | null>(null)
  const [spinning, setSpinning] = useState(false)
  const [error, setError] = useState<MessageKey | null>(null)

  const { data: spunToday = false } = useQuery({
    queryKey: retentionKeys.rouletteToday(userId, today),
    queryFn: async () => {
      const { data } = await supabase
        .from('roulette_spins')
        .select('id')
        .eq('user_id', userId!)
        .eq('spun_date', today)
        .maybeSingle()
      return !!data
    },
    enabled: !!userId,
  })

  const spin = useCallback(async () => {
    setLoading(true)
    setSpinning(true)
    setError(null)
    try {
      const { data, error: rpcError } = await supabase.rpc('rpc_spin_roulette')
      if (rpcError) throw rpcError
      const spinResult = data as unknown as RouletteResult
      // Simulate spin animation delay
      await new Promise(r => setTimeout(r, 2000))
      setResult(spinResult)
      void qc.invalidateQueries({ queryKey: retentionKeys.rouletteToday(userId, today) })
      return spinResult
    } catch (err) {
      setError(translateError(err, 'error.ROULETTE_FAILED'))
      return null
    } finally {
      setLoading(false)
      setSpinning(false)
    }
  }, [qc, userId, today])

  const canSpinToday = useCallback(() => {
    return !spunToday
  }, [spunToday])

  return { spin, canSpinToday, result, spinning, loading, error }
}

// ─── Missions hook ────────────────────────────────────────────

export function useMissions() {
  const { session } = useAuth()
  const userId = session?.user.id ?? null
  const qc = useQueryClient()

  const { data: missions = [], isLoading: loading } = useQuery({
    queryKey: retentionKeys.missions(userId),
    queryFn: async () => {
      const { data } = await supabase
        .from('missions')
        .select('mission, phon_awarded, completed_at')
        .eq('user_id', userId!)
      return (data ?? []) as MissionStatus[]
    },
    enabled: !!userId,
  })

  const fetchMissions = useCallback(() => {
    void qc.invalidateQueries({ queryKey: retentionKeys.missions(userId) })
  }, [qc, userId])

  return { fetchMissions, missions, loading }
}

// ─── Referral hook ────────────────────────────────────────────

export function useReferral() {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<MessageKey | null>(null)
  const [success, setSuccess] = useState(false)

  const registerReferral = useCallback(async (code: string) => {
    if (!code.trim()) return
    setLoading(true)
    setError(null)
    try {
      const { data, error: rpcError } = await supabase.rpc('rpc_register_referral', {
        p_referrer_code: code.trim(),
      })
      if (rpcError) throw rpcError
      const result = data as unknown as { registered: boolean; reason?: string }
      if (result.registered) {
        setSuccess(true)
      } else {
        setError(
          result.reason === 'invalid_code'     ? 'error.REFERRAL_INVALID_CODE' :
          result.reason === 'already_referred' ? 'error.REFERRAL_ALREADY' :
          result.reason === 'self_referral'    ? 'error.REFERRAL_SELF' :
          'error.REFERRAL_FAILED'
        )
      }
    } catch (err) {
      setError(translateError(err, 'error.REFERRAL_FAILED'))
    } finally {
      setLoading(false)
    }
  }, [])

  return { registerReferral, loading, error, success }
}

export function useReferralDashboard() {
  const { session } = useAuth()
  const userId = session?.user.id ?? null

  return useQuery({
    queryKey: retentionKeys.referralDashboard(userId),
    queryFn: async () => {
      const [{ data: profile }, { data: referrals }] = await Promise.all([
        supabase
          .from('profiles')
          .select('username')
          .eq('id', userId!)
          .maybeSingle(),
        supabase
          .from('referrals')
          .select('id, referrer_phon, rewarded_at')
          .eq('referrer_id', userId!),
      ])

      const rows = referrals ?? []
      return {
        code: profile?.username ?? '',
        pending: rows.filter((row) => !row.rewarded_at).length,
        approved: rows.filter((row) => !!row.rewarded_at).length,
        paidPhon: rows.filter((row) => !!row.rewarded_at).map((row) => row.referrer_phon),
      }
    },
    enabled: !!userId,
  })
}
