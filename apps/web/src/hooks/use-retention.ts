import { useState, useCallback } from 'react'
import { supabase } from '../lib/supabase'

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

// ─── Welcome Bonus hook ───────────────────────────────────────

export function useWelcomeBonus() {
  const [loading, setLoading] = useState(false)
  const [result, setResult] = useState<WelcomeBonusResult | null>(null)
  const [error, setError] = useState<string | null>(null)

  const claimWelcomeBonus = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const { data, error: rpcError } = await supabase.rpc('rpc_claim_welcome_bonus')
      if (rpcError) throw rpcError
      setResult(data as unknown as WelcomeBonusResult)
      return data as unknown as WelcomeBonusResult
    } catch (e) {
      const msg = e instanceof Error ? e.message : '보너스 지급 실패'
      setError(msg)
      return null
    } finally {
      setLoading(false)
    }
  }, [])

  const checkClaimed = useCallback(async () => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return false
    const { data } = await supabase
      .from('welcome_bonuses')
      .select('phon_awarded, referral_bonus, claimed_at')
      .eq('user_id', user.id)
      .maybeSingle()
    if (data) {
      setResult({
        already_claimed: true,
        phon_awarded: data.phon_awarded,
        referral_bonus: data.referral_bonus,
      })
      return true
    }
    return false
  }, [])

  return { claimWelcomeBonus, checkClaimed, result, loading, error }
}

// ─── Daily Claim hook ─────────────────────────────────────────

export function useDailyClaim() {
  const [loading, setLoading] = useState(false)
  const [result, setResult] = useState<DailyClaimResult | null>(null)
  const [streak, setStreak] = useState<UserStreak | null>(null)
  const [error, setError] = useState<string | null>(null)

  const fetchStreak = useCallback(async () => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return
    const { data } = await supabase
      .from('user_streaks')
      .select('current_streak, longest_streak, last_claimed_date, total_phon_earned')
      .eq('user_id', user.id)
      .maybeSingle()
    if (data) setStreak(data)
  }, [])

  const claimDaily = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const { data, error: rpcError } = await supabase.rpc('rpc_claim_daily_reward')
      if (rpcError) throw rpcError
      const claimed = data as unknown as DailyClaimResult
      setResult(claimed)
      // refresh streak
      await fetchStreak()
      return claimed
    } catch (e) {
      const msg = e instanceof Error ? e.message : '출석 체크 실패'
      setError(msg)
      return null
    } finally {
      setLoading(false)
    }
  }, [fetchStreak])

  const canClaimToday = useCallback(() => {
    if (!streak?.last_claimed_date) return true
    const today = new Date().toISOString().split('T')[0]
    return streak.last_claimed_date !== today
  }, [streak])

  return { claimDaily, fetchStreak, canClaimToday, result, streak, loading, error }
}

// ─── Roulette hook ────────────────────────────────────────────

export function useRoulette() {
  const [loading, setLoading] = useState(false)
  const [result, setResult] = useState<RouletteResult | null>(null)
  const [spinning, setSpinning] = useState(false)
  const [error, setError] = useState<string | null>(null)

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
      return spinResult
    } catch (e) {
      const msg = e instanceof Error ? e.message : '룰렛 오류'
      setError(msg)
      return null
    } finally {
      setLoading(false)
      setSpinning(false)
    }
  }, [])

  const canSpinToday = useCallback(async () => {
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return false
    const today = new Date().toISOString().slice(0, 10)
    const { data } = await supabase
      .from('roulette_spins')
      .select('id')
      .eq('user_id', user.id)
      .eq('spun_date', today)
      .maybeSingle()
    return !data
  }, [])

  return { spin, canSpinToday, result, spinning, loading, error }
}

// ─── Missions hook ────────────────────────────────────────────

export function useMissions() {
  const [missions, setMissions] = useState<MissionStatus[]>([])
  const [loading, setLoading] = useState(false)

  const fetchMissions = useCallback(async () => {
    setLoading(true)
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) { setLoading(false); return }
    const { data } = await supabase
      .from('missions')
      .select('mission, phon_awarded, completed_at')
      .eq('user_id', user.id)
    if (data) setMissions(data as MissionStatus[])
    setLoading(false)
  }, [])

  const completeMission = useCallback(async (mission: string) => {
    const { data, error } = await supabase.rpc('rpc_complete_mission', { p_mission: mission })
    if (!error) await fetchMissions()
    return { data, error }
  }, [fetchMissions])

  return { fetchMissions, completeMission, missions, loading }
}

// ─── Referral hook ────────────────────────────────────────────

export function useReferral() {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
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
          result.reason === 'invalid_code'    ? '올바른 추천 코드가 아닙니다.' :
          result.reason === 'already_referred' ? '이미 추천인이 등록되어 있습니다.' :
          result.reason === 'self_referral'    ? '자기 자신은 추천할 수 없습니다.' :
          '추천 코드 등록 실패'
        )
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : '추천 코드 등록 실패')
    } finally {
      setLoading(false)
    }
  }, [])

  return { registerReferral, loading, error, success }
}
